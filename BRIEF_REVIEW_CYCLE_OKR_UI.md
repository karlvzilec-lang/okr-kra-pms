# Brief: Review cycle management UI + OKR creation/check-in UI

Repo: `okr-kra-pms` (Next.js App Router + Supabase/Postgres RLS). This is
Round 2 of a 9-round gap-closure effort following a brutal critique; Round 1
(Goal/Rating creation UI) is merged on `master` at `d6fa8ca`. Read `README.md`
in full first — it documents the schema, RLS design decisions, and the
column-scope-trigger idiom used repeatedly in this codebase.

## Ground truth (pre-verified — do not re-derive, but do verify anything
you rely on beyond what's stated here)

**`review_cycle` table** (`0001_core_tables.sql`): `id, name, start_date,
end_date, status review_cycle_status not null, created_at, updated_at`.
Enum `review_cycle_status`: `'draft', 'active', 'self_eval', 'manager_eval',
'closed'`. `review_cycle_dates_ordered` check: `end_date >= start_date`.

**`review_cycle` RLS** (`0003_rls_policies.sql:299-315`): `review_cycle_hr_all`
is `for all` `using/with check (public.is_hr_admin())` — HR can already
insert, update (including status), or delete any cycle. Everyone else gets
`review_cycle_select_scoped` (select only, own-participation-scoped). **There
is no gating function, trigger, or constraint restricting which status
transitions are allowed** — an HR admin can currently set `status` to any
value in any order via a raw UPDATE, and nothing stops them from skipping
straight from `'draft'` to `'closed'`, or from re-opening a `'closed'` cycle.
This is a real design gap: decide during planning whether the UI needs a
client-side (or DB trigger) guard restricting transitions to the natural
forward sequence (`draft → active → self_eval → manager_eval → closed`, no
skipping, no going backwards), and implement whichever you decide, with your
reasoning stated in the plan.

**`objective` table** (`0006_okr_tables.sql:36-53`): `id, review_cycle_id
(FK review_cycle, cascade), owner_id (FK profiles, cascade), title,
description, status objective_status not null default 'active', created_at,
updated_at`. Enum `objective_status`: `'active', 'closed'`.

**`key_result` table** (`0006_okr_tables.sql:64-84`): `id, objective_id (FK
objective, cascade), title, metric_unit, start_value numeric not null default
0, target_value numeric not null, current_value numeric (nullable, NO
default despite a stale comment claiming otherwise — the column is only
populated by the check-in trigger or an explicit insert value), score
numeric(4,3), score_override numeric(4,3)`, both score columns constrained to
`[0,1]` or null.

**`check_in` table** (`0006_okr_tables.sql:102-109`): `id, key_result_id (FK
key_result, cascade), checked_in_by (FK profiles), new_value numeric not
null, note, created_at`. No `updated_at` — append-only history by design.

**OKR RLS** (`0008_okr_matrix_rls.sql`): `objective_owner_insert` (`with
check (owner_id = auth.uid())`) + `objective_hr_all`. `key_result_owner_insert`
(`with check (public.can_write_objective(objective_id))`, i.e. HR or the
objective's owner) + `key_result_hr_all`. `check_in_owner_insert` (`with
check (checked_in_by = auth.uid() and public.can_check_in_key_result(key_result_id))`,
i.e. HR or the parent objective's owner — checking in is restricted to the
objective owner only, not any arbitrary participant) + `check_in_hr_all`.
**None of these gate on `review_cycle.status`** — an objective/key_result/
check_in can be created or written regardless of what state the cycle is in.
Decide during planning whether that's acceptable for this UI (e.g., should
the "add objective" button be hidden/disabled once a cycle is `'closed'`?)
and state your reasoning.

**Scoring is automatic**: `recompute_key_result_score()` (BEFORE INSERT OR
UPDATE on `key_result`) computes `score` from `(current_value - start_value)
/ (target_value - start_value)`, clamped `[0,1]`, null if the range is
degenerate. `apply_check_in_to_key_result()` (AFTER INSERT on `check_in`)
overwrites `key_result.current_value` with the new check-in's value, which
in turn fires the score recompute as a side effect. **The frontend must never
compute score/current_value itself** — insert the check-in row and let the
triggers do the arithmetic, then re-read.

**Existing read-only presentation components** (do not duplicate, reuse if
convenient, do not break): `web/components/objective-card.tsx` renders
`kr.effective_score` (not `score`/`score_override` directly — this field is
resolved server-side, likely by the `employee_review_summary` RPC merging
`score_override ?? score`, confirm exact merge logic before relying on it)
via `web/components/progress-bar.tsx`. Both are presentational only, driven
by props.

**`web/lib/types.ts`** already has `Objective`/`KeyResult`/`ReviewCycleStatus`
types (read the current file for exact shape — additive edits only, do not
touch existing exported types other modules depend on, same rule as Round 1).

**verify.sql coverage gaps** (confirmed zero matches by direct grep): no
INSERT test for `objective` (positive owner-success or negative non-owner-
denied), no INSERT test for `key_result` (same), no negative/denied test for
`check_in` (only a positive owner-check-in test exists), no test around HR
writing `review_cycle.status`. Close these as part of this round, following
the file's existing structure and assertion style (see the 46 assertions
already in the file — read several to match the pattern exactly, including
how RLS-denial is asserted: a raise/exception check vs. a zero-rows-affected
check depending on whether it's a `with check` violation or a trigger raise).

**`web/app/review/page.tsx`** nav-link pattern (lines 89-121, current file):
conditional `{condition && <Link ...>}` blocks, all sharing one className/
style, Phosphor icons from `@phosphor-icons/react/dist/ssr/*`, gated on a
boolean computed earlier in the server component. A new HR-only "Manage
review cycles" link fits this exact pattern, gated on `profile?.is_hr_admin`.

## Scope for this round

1. **Review cycle management UI (HR only)**: a list of all cycles (any
   status), a "create cycle" form (name, start_date, end_date — client + DB
   both enforce `end_date >= start_date`), and a way to advance a cycle's
   status. Decide and implement your transition-guard approach per the
   ground-truth note above.
2. **Objective creation UI**: any authenticated employee can create an
   objective for themselves against a review cycle (owner_id = self is
   enforced by RLS already — the UI must not let a payload claim a different
   owner_id even if RLS would reject it, don't rely on RLS as the only
   defense against a UI bug). Add/edit key results under an objective
   (title, metric_unit, start_value, target_value). Surface objectives
   somewhere reachable from `/review` (new route(s), your choice of shape —
   e.g. `/objectives` list + `/objectives/[id]` detail/edit, consistent with
   the existing `/goals/[planId]` and `/reports/[planId]` route shapes).
3. **Check-in UI**: on a key result the current user owns (via their
   objective), log a new check-in (value + optional note) and see the
   check-in history list (append-only, most recent first). After a check-in,
   the UI must reflect the newly recomputed `current_value`/`score` — re-read
   from the DB after insert, don't compute it client-side.
4. **Nav wiring**: add the "Manage review cycles" link (HR-gated) and an
   "My objectives" or equivalent link (any employee) to `/review`, matching
   the existing conditional-link pattern exactly.
5. **verify.sql**: close the five coverage gaps listed above, matching the
   file's existing assertion style and structure exactly (read the file
   first, don't guess the pattern).

## Explicitly out of scope for this round

- Objective alignment/cascade UI (parent/child objective linking) — that's
  Round 3 (Admin UI).
- Matrix-manager scope grants — Round 3.
- Any notification/email on cycle status change — permanently out of scope
  per the user's own decision (no provider configured).
- Actual hosted deployment — out of scope, GitHub push + green CI is the
  only "publish" target.

## Constraints (repo-wide, carried from every prior round)

- Follow the existing design system: CSS custom properties (`var(--background)`,
  `var(--foreground)`, `var(--accent)`, `var(--muted-foreground)`, `var(--border)`),
  `min-h-11` touch targets, `active:scale-[0.98]` press feedback, Phosphor
  icons only (`@phosphor-icons/react/dist/ssr/*`), no new dependencies without
  a strong stated reason.
- Server Components by default; `"use client"` only on the isolated
  interactive leaf components (forms, the check-in button, etc.).
- Money/rating arithmetic and weight-sum validation must use integer
  "hundredths" comparison against DB `numeric` semantics, not floating point
  — see `web/lib/goals.ts` from Round 1 for the established pattern if any
  numeric validation is needed here (e.g. `start_value`/`target_value`
  sanity — target != start, since the DB divides by that difference and
  returns null score on a degenerate range; the UI should proactively warn
  rather than silently accept a config that produces a permanently-null
  score).
- `npm run lint && npm run build` must pass clean before you report done.
- Do not touch `README.md` or copy brief/ruling docs into the repo — Fable
  handles that after merge, matching every prior round.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your view on the review-cycle status-transition guard question above.
- Your view on whether OKR writes should gate on cycle status, and how (UI-
  only vs. a DB-level guard).
- Route/component shape for objective creation + check-in UI.
- Division of labor if you were pairing with another builder (which files/
  concerns you'd own).
- How you'd extend verify.sql for the five gaps, and what other RLS/trigger
  edge cases (if any) you'd add coverage for that aren't listed above.
