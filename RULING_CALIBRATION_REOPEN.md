# Gate 1 Ruling: Calibration un-finalize/unpublish + grant tightening

Jcode and Sol converged almost completely — same two-function split, same
"un-finalize returns to plain `open`, no third state" reasoning, same
band-deletion guard, same mandatory-reason design, near-identical
latest-reversal-metadata approach. This ruling adopts the union of both,
picking the stronger option wherever they differed, and is final.

## Resolved (both agreed)

**Two separate functions, unpublish is the lower-level primitive:**
```sql
public.unpublish_employee_goal_plan(p_plan_id uuid, p_reason text) returns void
public.unfinalize_calibration_session(p_session_id uuid, p_reason text) returns void
```
`unpublish` touches one plan, leaves `calibrated_score`/`band_id`/session
status untouched, works whether the session is `open` or `finalized`.
`unfinalize` is session-wide, hard-blocked (`55000`) if any participant is
still published. The safe sequence for "I published by mistake and need to
re-score" is: unpublish the affected plan(s) → zero published participants
→ unfinalize → adjust normally. Both HR-only (`42501` otherwise), both
require a non-blank reason (`23514` on blank/too-short), both `security
definer`/`set search_path = ''`, both revoked from `public`, granted to
`authenticated, service_role`.

**Un-finalize returns to plain `'open'` — no third enum state, no
behavioral branch in `adjust_calibration_participant`.** Both builders
independently rejected a `reopened` state as adding complexity for no real
gain — the actual safety property is "an open session can never contain a
published participant," which the unpublish-before-unfinalize precondition
already guarantees. Add the belt-and-braces check anyway (Jcode's
suggestion): `adjust_calibration_participant` should also directly verify
`published_at is null` for the row it's touching, so the invariant holds
even if some future path ever reopens a session a different way.

**Band deletion is blocked whenever any `calibration_participant`
references it, unconditionally, regardless of session status.** No HR
bypass, no session-status exception. An unreferenced band (e.g., in a
freshly-created, empty session) can still be deleted freely.

**Mandatory reason text on both actions, stored as latest-reversal
metadata, not a full audit trail** (Round 9 owns the generic audit log).
Use Sol's naming — it signals "latest, not history" more honestly than
Jcode's:
- `calibration_session.last_unfinalized_at`, `last_unfinalized_by` (→
  `profiles`), `last_unfinalize_reason`
- `employee_goal_plan.last_unpublished_at`, `last_unpublished_by`,
  `last_unpublish_reason`

Each triple is written atomically and is collectively null or collectively
populated (add a check constraint for this, per Sol's point). Repeated
reversals overwrite the latest triple — that's honest about what this is,
not a log.

## Resolved (my ruling on the real disagreement)

**Drop the blanket `calibration_session_hr_all` / `calibration_band_hr_all`
policies and remove `authenticated`'s direct `INSERT`/`UPDATE`/`DELETE`
table grants on both tables — Sol's approach, not Jcode's.** This is
Sol's proposal, and it directly satisfies the brief's second, equally-real
mandate (tightening the blanket grant itself, not just patching the one
reopen exploit through it) — Jcode's plan left the blanket grant in place
and relied solely on the new trigger to reject the dangerous transition,
which closes the specific vulnerability but leaves the underlying gap the
README calls out (arbitrary direct writes to these two tables) technically
still open for anything the trigger doesn't happen to check. Verified this
is safe to do: grepped the entire frontend for any direct `.from(
"calibration_session")`/`.from("calibration_band")` write — **zero
matches**. Session/band creation isn't exposed in the app UI at all today
(both are seed-data-only); the facilitator board only ever reads them and
acts through `finalize_calibration_session`/`adjust_calibration_participant`/
`publish_employee_goal_plan`. So removing the blanket grant breaks nothing
that currently works. Note for your summary, not a blocker: this does mean
HR still has no way to create a *new* session or band through the app after
this round — that was already true before this round and stays out of
scope here, but flag it as a natural next gap for whoever picks up Round 9
or later.

Keep the trigger-level guard on top of the revoked grant anyway (defense in
depth, matching Sol's own two-layer reasoning) — use Jcode's more concrete
mechanism for it, not Sol's vaguer one: a **transaction-local random token**
set via `set_config('app.calibration_unfinalize_token', <random uuid/md5>,
true)` by `unfinalize_calibration_session` immediately before its UPDATE,
checked and matched (not just "is it set to a static string") by the
trigger. A static flag name is guessable and forgeable by a client that
sets the same GUC itself; a per-transaction random value the trigger
compares against isn't. Even with the grant already revoked, this catches
the case of `service_role` or some future elevated caller attempting the
same raw write.

**Extend the same class of guard to `employee_goal_plan.published_at`,
per Sol's point** — add a `before update` trigger rejecting a direct
`published_at: not null → null` transition unless it goes through
`unpublish_employee_goal_plan`'s own transaction-local token, mirroring the
session-status guard. This closes the parallel gap on the other side of the
publish/unpublish pair, which the brief's live-vulnerability framing was
specifically about. Existing employee/manager plan column-scope triggers
(`restrict_employee_plan_status_updates`, `restrict_manager_plan_status_transition`
from `0017`) must also add the four new metadata columns to their
protected-column lists, so an employee/manager can't forge reversal
metadata even though they were never going to be able to unpublish anyway.

## Functions — full rule set (merging both plans' specifics)

`unpublish_employee_goal_plan`: HR-only; requires the plan to exist and
currently be published (`P0002`/`55000` as appropriate); requires non-blank
reason; sets `published_at = null` + the three metadata columns
atomically; does not touch `calibrated_score`/`band_id`/session status.

`unfinalize_calibration_session`: HR-only; requires the session to exist
and currently be `finalized`; requires non-blank reason; rejects `55000`
if any participant of that session is still published; sets `status =
'open'` + the three metadata columns atomically, via the token mechanism
above so the trigger allows it.

**Lock ordering** (Sol's point, adopt it): `publish_employee_goal_plan`
should acquire its calibration-session-related lock before its plan lock,
matching the order `unfinalize_calibration_session` uses, to avoid a race
where a publish and an unfinalize could both pass their precondition
checks against stale state. State clearly in your summary what you changed
in `publish_employee_goal_plan` for this and why, since it's a modification
to existing, already-shipped code from Phase 3.

The existing `add_plan_to_calibration_session` rejection message (verbatim:
`'Published employee goal plan % cannot be recalibrated without an
unpublish step'`) must not change — a real `verify.sql` assertion pins it.

## Trigger design

`restrict_calibration_session_status_transition()` — `before insert or
update`: INSERT must be `'open'` (`55000` otherwise); same-status UPDATE
always allowed; `open → finalized` always allowed; `finalized → open`
allowed only under the matched transaction-local token, else `55000`;
anything else `55000`. No HR/service_role bypass anywhere in this trigger.

`reject_assigned_calibration_band_delete()` — `before delete` on
`calibration_band`: `55000` if any `calibration_participant.band_id =
old.id` exists, else allow. `security definer` per Sol's/Jcode's shared
reasoning (matches `reject_closed_cycle_objective_writes`'s precedent — the
check shouldn't depend on the caller's own read scope). No bypass.

`published_at` reversal guard on `employee_goal_plan` — per the ruling
above, same token-matching shape as the session trigger.

## UI shape

No new routes — everything lives in `web/components/calibration/
calibration-board.tsx` plus new isolated dialog/modal components (name
them however fits your existing component conventions — both plans
proposed reasonable, near-identical shapes here, pick one and be
consistent).

- **Un-finalize control**: visible in the finalized-session banner, but
  **disabled with an explanatory line** (not hidden) when any participant
  is still published — HR should see *why* it's unavailable, not have the
  control vanish (Jcode's point, adopt it). Confirmation friction: a
  required reason textarea **plus** typing the session name (or the literal
  word `UNFINALIZE`, your call) to confirm — this is the more consequential
  direction of the two actions and should feel that way.
- **Unpublish control**: per-participant, replacing the region where the
  existing Publish button lives once `published_at !== null`. Required
  reason textarea; no typed-confirmation requirement (narrower blast
  radius — one employee, and the underlying score/band is untouched, only
  visibility).
- Both go through `supabase.rpc(...)` + `router.refresh()`, reusing the
  existing `calibrationErrorMessage` helper — the `55000` branch already
  surfaces the DB's message verbatim, so no new error-mapping work is
  needed for the new rejection strings.
- `web/lib/calibration.ts`: additive only — the six new latest-reversal
  fields across the session/participant shapes, and `calibration_session_detail`
  (the RPC in `0016` that builds JSON explicitly) must be updated to emit
  them — this is a required data-shape change, not automatic.

## Division of labor

**Sol — DB layer**: migration `0022` (both new functions, all three
triggers, the grant removal, the lock-ordering change to
`publish_employee_goal_plan`, the `0016` RPC field additions), and the full
`verify.sql` extension list below.

**Jcode — UI layer**: the two dialog/modal components, `calibration-board.tsx`
wiring, `web/lib/calibration.ts` additive types.

**Shared contract, agree before either writes code**: the exact function
names/signatures above (already fixed by this ruling), the exact new
column names (already fixed by this ruling), and the exact SQLSTATE per
case (`42501` non-HR, `55000` state-violation, `23514` blank reason,
`P0002` not-found) — Jcode's UI error-mapping depends on these being
stable.

## `scripts/verify.sql` — required assertions (merging both lists)

Headline sequence reproducing then closing the live vulnerability, as HR:
1. Raw `UPDATE calibration_session SET status = 'open' WHERE id =
   '44444444-...0001'` → `55000` (pre-fix this would succeed — that's the
   vulnerability this pins shut).
2. Confirm the session is still `finalized` afterward.
3. `adjust_calibration_participant` on Dara's published participant →
   still `55000`.
4. As `service_role`, the same raw UPDATE attempt → still `55000` — proves
   the trigger itself blocks it, not merely the revoked `authenticated`
   grant (Sol's point — test both layers independently).
5. A forged/guessed static GUC flag (set the same setting name to `'on'`
   manually, not through the real function) followed by the raw UPDATE →
   still `55000` — proves the token isn't just a checkable-flag, it's a
   matched value only the real function can produce.

Then:
6. Non-HR calls to both new functions → `42501`.
7. `unfinalize_calibration_session` on the seeded session while Dara is
   still published → `55000`, message names the blocking participant
   count.
8. `unpublish_employee_goal_plan(dara_plan, '')` → `23514` (blank reason).
9. `unpublish_employee_goal_plan(dara_plan, 'published in error')` →
   succeeds; `published_at is null`, `calibrated_score` still `3.200`,
   `band_id` unchanged, session still `finalized`, all three metadata
   columns set correctly.
10. The now-unpublished plan disappears from `comp_export_rows`'s output
    for that cycle (ties this round back to Round 4's surface).
11. Re-publishing it while still `finalized` succeeds (proves unpublish
    doesn't require unfinalize first).
12. Now `unfinalize_calibration_session` succeeds (after unpublishing
    again first) — status `open`, metadata columns set.
13. `adjust_calibration_participant` on Dara now succeeds — pins the
    "reopened means normally editable" design decision.
14. Publishing while the session is back in `open` still correctly
    rejected (existing Phase-3 guard, confirm it still holds post-reopen).
15. Re-finalize + re-publish round-trips cleanly back to the original
    fixture state.
16. Assigned-band deletion fails in both an `open` and a `finalized`
    fixture, `band_id` unchanged on the referencing participant.
17. An unreferenced band deletes successfully.
18. The existing published-plan-rejoin assertion's exact error message
    (verbatim string) still holds, using Vuthy's plan
    `33333333-...000e` as the fixture, proving the new unpublish path
    didn't disturb it.
19. `insert into calibration_session (..., status = 'finalized')` directly
    → `55000` (INSERT must start `open`).

That's a large list — matches the bar every prior round has set. Convert
any existing raw `published_at = null` / `status = 'open'` test-fixture
resets in `verify.sql` to go through the new controlled functions where
doing so doesn't defeat the point of the specific assertion (some negative
tests legitimately need the raw path to prove the guard fires — use
judgment, state which is which).

## Explicitly out of scope this round

A generic audit-log table (Round 9). A way for HR to create new
calibration sessions/bands from the app (doesn't exist today, stays that
way — note it as a flagged future gap, don't build it). Notifications on
unpublish/unfinalize (permanently out, no provider). Hosted deployment
(permanently out).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies. Server Components by default, isolated `"use
client"` leaves. `npm run lint && npm run build` clean before reporting
done. Do not touch `README.md` or copy brief/ruling docs into the repo —
Fable handles that after merge.

## Execute now

This ruling is approved. Proceed to implementation in your isolated
worktree, following exactly your assigned half above.
