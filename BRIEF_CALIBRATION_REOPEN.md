# Brief: Calibration un-finalize/unpublish workflow + tightening the blanket HR grant

Repo: `okr-kra-pms`. Round 5 of the gap-closure effort. Rounds 1-4 are
merged on `master` at `7dbac70`. Read `README.md` in full first, especially
the "A published score is a one-way door" design decision and the "Known
follow-up" bullet about the blanket `calibration_session`/`calibration_band`
grant.

## A real, currently-live security gap — read this first

**This is not a hypothetical the brief is asking you to prevent — it exists
right now.** `calibration_session_hr_all` and `calibration_band_hr_all` are
both blanket `for all using (is_hr_admin()) with check (is_hr_admin())`
policies with **no state-transition guard and no column scoping** —
confirmed by direct inspection, nothing else touches these tables at the
RLS layer. This means, today, an HR admin (or anyone with an HR admin's
session) can issue a raw `UPDATE calibration_session SET status = 'open'
WHERE id = ...` directly against PostgREST, with nothing in the database
rejecting it.

That matters because `adjust_calibration_participant`'s *only* guard against
editing a `calibrated_score` is `if v_session_status = 'finalized' then
reject` (`0014_calibration_functions.sql:186-191`) — a function-level check,
not a trigger, and it only checks the session's *current* status at call
time. **Reopening a finalized session via the raw UPDATE above, then calling
`adjust_calibration_participant` on an already-*published* participant,
currently succeeds** — silently changing a `calibrated_score` the employee
has already seen, with no unpublish step, completely undermining the
"published score is a one-way door" guarantee the README documents as a
deliberate design commitment. This is the actual, concrete vulnerability
this round closes — not a defensive nice-to-have.

## Ground truth (pre-verified — do not re-derive)

**`calibration_session_status` enum**: only `'open'` / `'finalized'` —
`0012_calibration_tables.sql:24-29`. No `draft`, no third state.

**No status-transition trigger exists on `calibration_session`** — unlike
`review_cycle` (`restrict_review_cycle_status_transition()`,
`0018:42-89`, which enforces its 5-state sequence for every caller
including HR). This round is where `calibration_session` gets the
equivalent treatment.

**`calibration_band` deletion is currently unrestricted** —
`calibration_participant.band_id` is `on delete set null`
(`0012:170`), so deleting a band silently un-assigns every participant
currently classified into it, with no trigger blocking the delete
regardless of session status or whether participants reference it.

**`finalize_calibration_session(p_session_id)`** (`0014:213-236`): checks
only `is_hr_admin()`, sets `status = 'finalized'` unconditionally
(idempotent if already finalized, but does not check current status before
transitioning — there's no "must currently be open" guard either). No
un-finalize function exists.

**`publish_employee_goal_plan(p_plan_id)`** (`0014:242-306`): HR-only,
locks the plan row, requires either (a) the plan has a
`calibration_participant` whose session is `finalized`, or (b) no
calibration participant exists and `employee_goal_plan.status in
('manager_reviewed', 'finalized')`. Sets `published_at = now()`. **No
function anywhere sets `published_at` back to `null`** — confirmed by
grepping every migration; the only `published_at = null` writes in the
whole repo are `verify.sql`/`seed.sql` test-fixture resets run as an
unrestricted `psql` session outside RLS entirely, not reachable through any
application code path.

**`original_score` is immutable by trigger, `calibrated_score` is not.**
`enforce_original_score_immutable()` (`0012:209-228`) is a `before update`
trigger that blocks `original_score` from ever changing, for *any* caller
including SECURITY DEFINER functions — explicit in its own comment. No
equivalent trigger exists for `calibrated_score`; its only protection is
the function-level `finalized` check described above, which the live gap
defeats once a session can be silently reopened.

**Two textual acknowledgments of a future unpublish workflow already exist
in comments, unimplemented**: `0016_calibration_facilitator_views.sql:239-242`
("Published plans are immutable calibration outputs until an explicit
unpublish workflow exists") and `:296-301` (the exact rejection message
`'Published employee goal plan % cannot be recalibrated without an unpublish
step'`, raised by `add_plan_to_calibration_session` when a published plan
is re-added — a real assertion in `verify.sql` pins this exact string,
lines ~1003-1040 — don't break that message's wording).

**No UI surface hints at reversal today** — confirmed by reading
`web/components/calibration/calibration-board.tsx` in full. "Finalize
session" only renders pre-finalize; per-participant "Publish" only renders
when `published_at === null`. Neither has a disabled/hidden counterpart.
This is a from-scratch UI addition on both ends.

**Real seed fixtures to design against**: session
`44444444-4444-4444-8444-000000000001` ("FY2026 Engineering Calibration")
is currently `finalized`, with one published participant — Dara's plan
`33333333-3333-4333-8333-00000000000a` (`original_score` 3.580 →
`calibrated_score` 3.200, band "Meets Expectations", crossed a band edge
during calibration). Vuthy's plan `33333333-3333-4333-8333-00000000000e`
is manager-reviewed but has no calibration participant at all — usable as
a fresh add-to-session fixture if you need one unpublished/uncalibrated
case to test against without disturbing the published Dara fixture.

**`web/lib/calibration.ts`** (not `types.ts` — calibration types live in
their own file) has the current `CalibrationSessionStatus`,
`CalibrationParticipant` (includes `published_at: string | null`),
`CalibrationSessionDetail` shapes — additive only if you need new fields
(e.g., a `can_unpublish`/`can_unfinalize` computed flag for the UI).

## The real design question — decide and justify

**Un-finalizing a session must never be allowed while any of its
participants is already published.** That's the one non-negotiable
invariant — it's the exact mechanism of the live gap above. Beyond that,
decide:

1. **Should "un-finalize a session" and "unpublish a single plan" be two
   separate actions, or does unpublishing require reopening the session
   first?** Consider: HR might want to unpublish *one* plan they published
   by mistake without touching the other, correctly-published participants
   in the same session, or without reopening scoring for everyone. A
   standalone "unpublish this plan" action (sets `published_at = null`,
   `calibrated_score`/`band_id` untouched, session status untouched) seems
   like the safer, narrower primitive — but state your reasoning, don't
   just default to it.
2. **Does un-finalizing a session put it back in a state where scores can
   be re-adjusted, or is it purely a correction path for "I finalized
   before I meant to, nothing's published yet, let me fix a mistake"?**
   Both readings are defensible; pick one and be explicit about what
   `adjust_calibration_participant` should do differently (if anything)
   once a session has been un-finalized versus its original `open` state.
3. **Band deletion**: should a band with at least one `calibration_participant`
   currently assigned to it be un-deletable regardless of session status?
   This seems like the clear, low-risk fix regardless of how you resolve
   (1)/(2) above.
4. **UI**: where do these controls live, what confirmation friction do they
   need (this is more consequential than "Finalize," which already has a
   confirmation dialog), and what does the persisted record of an
   unpublish/un-finalize action look like given there's no audit-log table
   yet (that's Round 9 — don't build one now, but don't silently lose the
   "who did this and why" information either; a `facilitator_note`-style
   free-text reason field, matching the existing `calibration_participant.
   facilitator_note` pattern, may be the pragmatic answer for this round).

## Scope for this round

1. **DB**: a status-transition trigger on `calibration_session` (mirroring
   `restrict_review_cycle_status_transition()`'s idiom) that blocks
   `finalized → open` unless going through the new controlled function, and
   that function itself must check zero published participants before
   allowing the transition. A band-deletion guard preventing deletion of a
   band with any assigned participant. New function(s) per your design
   answers above (unpublish-a-plan and/or unfinalize-a-session).
2. **`scripts/verify.sql`**: cover the actual vulnerability (raw reopen +
   adjust on a published participant, now rejected), the new function(s)'
   positive and negative paths, the band-deletion guard, and confirm the
   existing "published plan can't rejoin a session" assertion's exact error
   message still holds.
3. **UI**: controls on `calibration-board.tsx` (or wherever your design
   calls for them) for HR to un-finalize / unpublish, with confirmation
   friction proportionate to how consequential each action is.

## Explicitly out of scope this round

A generic audit-log table (Round 9). Notifications on unpublish/un-finalize
(permanently out, no provider). Hosted deployment (permanently out).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies. Server Components by default, isolated `"use
client"` leaves. `npm run lint && npm run build` clean before reporting
done. Do not touch `README.md` or copy brief/ruling docs into the repo —
Fable handles that after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your answers to the four design questions above, with reasoning.
- Exact function name(s)/signature(s) for whatever you're adding.
- The trigger design for the `calibration_session` status guard and the
  band-deletion guard.
- Route/component shape for the UI controls.
- Division of labor if pairing with another builder.
- `verify.sql` extensions, including the assertion that actually
  reproduces and then closes the live vulnerability described above.
