# Gate 1 Ruling: Review cycle management UI + OKR creation/check-in UI

Jcode and Sol both planned independently, cross-challenged each other, and
converged. This ruling is final — implement exactly this, don't re-litigate
resolved points. Where the two plans agreed, I kept their agreement. Where
they disagreed, I ruled below with reasoning.

## Resolved (both agreed after cross-challenge)

**(a) SQLSTATE `55000`** (`object_not_in_prerequisite_state`) for lifecycle-
order violations (skip/backward/reopen-closed on `review_cycle.status`, and
closed-cycle OKR write rejection). Keep `42501` for genuine RLS/ownership/
column-scope denials — the two error classes must stay distinguishable in
both the DB and the frontend's error-mapping helper. This is a deliberate
deviation from the `0017` precedent (which used `42501` for a *different*
kind of violation — column-scope, not lifecycle-order) — Sol's distinction is
correct: `42501` implies "you lack permission" (invites a retry as a
different role), `55000` means "the object's state doesn't allow this,
regardless of who you are."

**(b) Closed-cycle OKR-write gate is DB-enforced this round**, not deferred.
Jcode's original UI-only plan is overruled — Jcode itself conceded this on
cross-challenge: a documented gap here is a data-integrity hole reachable by
any direct PostgREST call, not a UX nicety. Applies to objective/key_result
(INSERT/UPDATE/DELETE) and check_in (INSERT), and applies to HR too — no
role bypass. "Closed" means frozen, full stop; there is no reopen path (see
(a) — reopening a closed cycle is itself rejected).

**(c) Column-scope `key_result` owner writes.** An owner's UPDATE may only
touch structural columns (`title`, `metric_unit`, `start_value`,
`target_value`). `current_value` and `score` must only ever change via the
check-in propagation path (`apply_check_in_to_key_result` → its internal
UPDATE); `score_override` may only be set by HR. Implementation note (both
builders flagged the same risk): the guard trigger must not break the
existing legitimate propagation where `apply_check_in_to_key_result`'s own
UPDATE statement fires the same BEFORE UPDATE chain. Recommended mechanism:
`pg_trigger_depth() > 1` inside the new guard trigger to detect "this UPDATE
originated from inside another trigger's function body" (i.e., the check-in
AFTER INSERT trigger), vs. `= 1` for a direct client-issued UPDATE. Verify
this empirically rather than trusting the reasoning — write a verify.sql
case that inserts a check-in and confirms `current_value`/`score` still
update correctly *after* the guard trigger exists, immediately alongside the
case proving a direct forged UPDATE is rejected. If `pg_trigger_depth` proves
unreliable in testing, use a session-local `set_config` flag set by
`apply_check_in_to_key_result` instead — implementer's call, but the
regression test is mandatory either way.

**(d) `check_in` is immutable at the DB level, including against HR.**
`check_in_hr_all` (currently `for all`, meaning HR can silently rewrite or
delete check-in history) is a genuine defect — check-ins are the evidence
trail behind OKR progress; if HR can edit them post-hoc, the record isn't
attestable. Replace it with HR select-only. After this change there is no
UPDATE or DELETE policy on `check_in` at all — RLS default-deny means nobody
can update/delete a check-in row directly (cascade deletes from a parent
`key_result`/`objective` row removal are a separate mechanism and remain
unaffected; there is no known UI path that deletes objectives/key_results
today, so this is a theoretical edge case — verify empirically that a
cascade-delete of a parent still works with no explicit DELETE policy on the
child, and note the result either way rather than assuming).

## Additional hardening surfaced during cross-challenge — also in scope

**`review_cycle` lifecycle guard, full spec**: one `before insert or update`
trigger, `restrict_review_cycle_status_transition()`. On INSERT: `status`
must be `'draft'` (reject anything else, `55000`). On UPDATE: `status`
unchanged is always allowed (HR can still edit `name`/dates freely);
otherwise the new status must be exactly the next value in `draft → active →
self_eval → manager_eval → closed` — no skip, no backward, no reopening
`closed`. No role bypass of any kind (not `service_role`, not HR) — this
means `seed.sql` and any `scripts/verify.sql` fixture that currently jumps a
cycle directly to a later status (e.g. straight to `'manager_eval'`) must be
rewritten to walk the cycle through each intermediate status first. Find
every such spot and fix it — don't leave a fixture that only worked because
it ran as an untriggered superuser path; confirm it actually goes through
the trigger.

**Guard `check_in.checked_in_by` and `check_in.created_at` against
spoofing.** RLS's `with check` already requires `checked_in_by = auth.uid()`,
but that's client-payload-dependent — belt-and-suspenders it with a `before
insert` trigger that force-sets `new.checked_in_by := auth.uid()` and
`new.created_at := now()` regardless of what the client sent, so a malicious
or buggy direct PostgREST call can't backdate history or attribute a
check-in to someone else even before RLS is considered.

**Tighten `objective_owner_insert`.** Today it only checks `owner_id =
auth.uid()` — an owner can target *any* `review_cycle_id` that exists,
including one they can't otherwise see (a guessed UUID for a cycle whose
`review_cycle_select_scoped` policy would normally hide it from them). Add
to the `with check`: `and (public.is_hr_admin() or
public.is_review_cycle_participant(review_cycle_id))`, reusing the existing
helper — no new function needed. If this turns out to be overly restrictive
for employees who don't yet have an `employee_goal_plan` row (and therefore
no `review_participant` row) for a given cycle, that's a signal for a later
round, not a reason to skip this fix — state the finding either way in your
summary rather than silently loosening it.

**UI cycle selection**: the objective-creation cycle picker must exclude
`'closed'` cycles entirely (the DB would reject the write anyway, but the UI
shouldn't offer a dead option) and should default-select/prioritize the
currently `'active'` cycle rather than "most recent by date" — a future
`'draft'` cycle inserted for planning purposes must not silently become the
default target.

## Route/component shape (both plans converged — use this)

```
web/app/review-cycles/page.tsx        HR-only: list all cycles + create form
                                       + one "advance to next status" action
web/app/objectives/page.tsx           signed-in user's own objectives,
                                       create form (no owner_id field —
                                       always the authenticated user)
web/app/objectives/[objectiveId]/page.tsx
                                       owner-only edit surface: key-result
                                       add/edit, check-in form, check-in
                                       history (most recent first)
web/lib/okr-queries.ts                server loaders, mirrors goal-plan-queries.ts
web/lib/okr.ts                        validation + error mapping, mirrors goals.ts
                                       (must map 55000 as a distinct case from
                                       42501/23514/22023/PGRST116, not lump them)
web/components/cycles/...             "use client" leaves: create form, advance button
web/components/okr/...                "use client" leaves: objective/KR forms,
                                       check-in form; check-in history can be
                                       server-rendered (no interactivity needed)
```

- Client Supabase writes (matching this repo's established idiom — Server
  Actions are not used anywhere in this codebase, don't introduce them here).
- `owner_id`/`checked_in_by` are never form fields — taken from
  `auth.getUser()` server-side or client-side at submit time, never trusted
  from a hidden input, exactly as `goal-plan-editor.tsx` does for
  `manager_rating`.
- After a check-in insert, re-`select` the key result's `current_value`/
  `score`/`score_override` and the check-in history — never compute either
  client-side.
- `start_value === target_value` blocks submit client-side with an
  explanatory warning (the DB returns `score = null` on this degenerate
  range and the UI should explain why rather than silently accept it),
  compared via integer-hundredths per the `lib/goals.ts` precedent.
- Additive types only in `types.ts`: `ReviewCycle`, `CheckIn`,
  `ObjectiveWithCycle` (exact shape at implementer's discretion, but must not
  alter the existing `Objective`/`KeyResult`/`ReviewCycleStatus` exports
  other modules depend on).
- `/review` nav: add "Manage review cycles" (HR-gated,
  `profile?.is_hr_admin`) and "My objectives" (unconditional for any
  authenticated user), matching the existing conditional-`Link` pattern
  exactly (same className/style, Phosphor SSR imports, placed alongside the
  existing links).

## Division of labor

**Sol — DB layer**: new migration `0018_review_cycle_okr_hardening.sql`
containing every trigger/policy change above (lifecycle guard, closed-cycle
gate, key_result column-scope, check_in immutability + spoof-guard,
objective_owner_insert tightening). Fix every `seed.sql`/`scripts/verify.sql`
fixture that breaks under the new lifecycle guard. Extend `scripts/verify.sql`
with the full assertion set below. Do not touch anything under `web/`.

**Jcode — UI layer**: everything under `web/` per the route/component shape
above, including `web/lib/types.ts` additions and the `web/app/review/
page.tsx` nav edit. Do not touch `supabase/` or `scripts/verify.sql`.

**Shared contract, agree before either of you writes code**: the exact
SQLSTATE-to-message mapping in `lib/okr.ts` needs to know Sol's exact codes
(`55000` for every lifecycle/closed-cycle case, `42501` for every RLS/
ownership/column-scope case, `23514` for check constraints e.g. inverted
dates) — Sol, state your final code-per-case list explicitly in your
migration's header comment so Jcode can read it without guessing. Neither of
you touches `web/lib/types.ts` except Jcode. Neither of you touches
`scripts/verify.sql` except Sol.

## `scripts/verify.sql` — required assertions

Match the file's existing two idioms exactly (read several existing
assertions first): `get diagnostics v_rows = row_count` + expect-0 for
silent RLS no-ops, and `raise exception ... exception when sqlstate 'XXXXX'
then null` blocks for trigger/policy rejections.

1. `objective` INSERT positive (owner, own cycle) — succeeds.
2. `objective` INSERT denied — payload claims another user's `owner_id`,
   `42501`.
3. `objective` INSERT denied — a cycle the user can't see (per the
   tightened `objective_owner_insert`), `42501`.
4. `key_result` INSERT positive (objective owner) — `current_value`/`score`
   both null initially.
5. `key_result` INSERT denied — non-owner, non-HR targets someone else's
   objective, `42501`.
6. `key_result` UPDATE denied — owner attempts to directly set
   `current_value` or `score_override`, `42501` (or whatever code the guard
   trigger uses — must match Sol's stated mapping).
7. `key_result` UPDATE positive — owner changes a structural column
   (`title`/`target_value`), succeeds.
8. Check-in propagation regression — insert a check-in, confirm
   `current_value`/`score` update correctly through the column-scope guard
   (proves (c)'s mechanism doesn't break the legitimate path).
9. `check_in` INSERT denied — non-owner, non-HR, `42501`.
10. `check_in` UPDATE denied for the owner, `42501`/RLS-denied (no policy
    exists — confirm the exact failure mode, e.g. 0-row silent no-op vs.
    explicit denial, and assert whichever is actually true).
11. `check_in` UPDATE/DELETE denied for HR too — proves (d).
12. `check_in` spoofed `checked_in_by` — insert as owner but with another
    profile's id in the payload — either rejected or silently overwritten to
    the real `auth.uid()` (assert whichever the trigger actually does).
13. `check_in` spoofed `created_at` — payload sends a backdated timestamp,
    assert the stored value is `now()`-ish, not the spoofed one.
14. `review_cycle` INSERT with non-`'draft'` status — `55000`.
15. `review_cycle` UPDATE one valid forward step — succeeds, exactly 1 row.
16. `review_cycle` UPDATE skip (e.g. `draft → manager_eval`) — `55000`.
17. `review_cycle` UPDATE backward — `55000`.
18. `review_cycle` UPDATE reopening `'closed'` — `55000`.
19. `review_cycle` UPDATE by non-HR — 0-row silent no-op (existing RLS,
    unchanged by this round, but confirm it still behaves this way after the
    new trigger is added).
20. Closed-cycle `objective` INSERT/UPDATE — `55000`, including as HR.
21. Closed-cycle `key_result` INSERT — `55000`, including as HR.
22. Closed-cycle `check_in` INSERT — `55000`, including as HR.
23. `key_result.score` clamps at `0` on a check-in below `start_value` (the
    existing test only proves the upper clamp at `1`).
24. Degenerate range (`start_value = target_value`) yields `score = null`,
    not an error.
25. Two sequential check-ins — `current_value` reflects the second
    (last-write-wins, not high-water-mark) — the UI's re-read-after-insert
    logic depends on this being true.

That's a large list — this matches the bar Round 1 set (46 assertions for a
comparably-scoped round). Don't cut corners on it; this is exactly the kind
of regression coverage that's caught real bugs twice already this session.

## Explicitly still out of scope this round

Objective alignment/cascade UI, matrix-manager scope grants (Round 3).
Notifications/email (permanently out, no provider). Hosted deployment
(permanently out, GitHub + green CI only).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons only,
no new dependencies, Server Components by default with isolated `"use
client"` leaves, `npm run lint && npm run build` clean before reporting
done. Do not touch `README.md` or copy brief/ruling docs into the repo —
Fable handles that after merge.

## Execute now

This ruling is approved. Proceed to implementation in your isolated
worktree, following exactly your assigned half above.
