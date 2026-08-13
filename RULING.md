# Gate 1 ruling — consolidated plan for Phase 1 schema

Both independent plans (Jcode, Sol) converged almost entirely. The three points where they diverged were cross-challenged and are ruled below. **Implement exactly as ruled — do not re-litigate.**

## Ruling 1 — `review_cycle` needs its own explicit RLS policy
Both builders agreed this was a gap in the first draft. Add:
- `SELECT`: `is_hr_admin()` OR the caller can read at least one `employee_goal_plan` in that cycle (via `review_participant`).
- `INSERT`/`UPDATE`/`DELETE`: HR admin only.

## Ruling 2 — missing ratings: reject, don't zero-fill
`compute_goal_plan_rating(plan_id, rating_type)` must raise an exception if any goal in the plan has a NULL rating for the requested `rating_type`. Do **not** treat a NULL rating as contributing zero. Rationale (both builders independently landed here): the brief's "defer validation" instruction applies to weight totals during incremental plan-building, not to the rollup call itself — the rollup **is** the finalization step, and a persisted `goal_plan_rating` row is read downstream (Phase 3 calibration, future comp linkage), so a silently-deflated score is worse than a loud error. The same function must also validate that category weights sum to 100 across the plan and goal weights sum to 100 within each category, raising if not — this is the deferred-validation point the brief describes.

## Ruling 3 — cascade/align insert authorization: target-plan only, not both plans
Sol's original "both plans" rule is **rejected** — it would silently block the primary bottom-up use case: an employee aligning their own goal upward to a manager's goal is not a `review_participant` on the manager's own plan (the manager is the *employee* on that plan, not them), so requiring participation in both plans breaks the exact mechanism `goal_alignment` exists for.

Adopted rule for inserting `goal_cascade` / `goal_alignment`:
- Caller has write authority on the **cascaded/child goal's plan** (i.e. is a participant with write access there), OR is HR admin.
- Caller can **read** the source/parent goal (via the normal `goal` SELECT policy — so it must already be a goal they're a participant on, or their direct manager's goal, or HR — not an arbitrary UUID).
- `cascaded_by` / `created_by` must equal `auth.uid()` (except HR admin, who may set it explicitly).

`SELECT` on both link tables stays as originally specified: visible to participants of *either* linked goal's plan.

## Enum / status value strings — use exactly these (both builders must match)
- `review_cycle.status`: `draft`, `active`, `self_eval`, `manager_eval`, `closed`
- `employee_goal_plan.status`: `draft`, `submitted`, `manager_reviewed`, `finalized`
- `review_participant.role`: `employee`, `line_manager`, `hr_admin`
- `goal_plan_rating.rating_type`: `self`, `manager`

## Division of labor (agreed by both builders independently — same split)

**Jcode owns:**
- `supabase/migrations/0001_core_tables.sql` — enums, `profiles`, `review_cycle`, `employee_goal_plan`, `kra_category`, `goal`, `updated_at` trigger, all CHECK constraints from the brief.
- `supabase/migrations/0002_relationship_tables.sql` — `goal_cascade`, `goal_alignment` (with the uniqueness constraints from the brief), `review_participant`, `goal_plan_rating` (table only, no policies/functions yet).
- `supabase/seed.sql` — per the brief: 1 HR admin, 2 line managers, 5 employees, 1 active cycle, a detailed employee plan (2 categories, 2–3 goals each, weights summing correctly), one `goal_cascade` example, one `goal_alignment` example, both self and manager ratings populated so the rollup produces two different hand-checkable numbers.

**Sol owns:**
- `supabase/migrations/0003_rls_policies.sql` — `is_hr_admin()`, `is_goal_plan_participant()` (or equivalent) SECURITY DEFINER helpers, RLS enabled + policies on every table per the brief and Rulings 1 & 3 above, including the `review_cycle` policy from Ruling 1 and the cascade/alignment insert rule from Ruling 3. Also the `BEFORE UPDATE` trigger on `goal` restricting managers to `manager_rating`/`manager_comment` only.
- `supabase/migrations/0004_rating_rollup.sql` — `validate_goal_plan_weights(plan_id)`, `compute_goal_plan_rating(plan_id, rating_type)` implementing Ruling 2 exactly (reject on NULL rating, validate weights, numeric arithmetic, upsert into `goal_plan_rating`).
- `VERIFICATION.md` — the RLS + rollup test queries described in the brief, run as simulated users via `SET LOCAL ROLE authenticated` + JWT claim substitution, including a negative test proving Ruling 3 (an employee CAN align upward to a manager's goal despite not participating in the manager's plan) and a negative test proving Ruling 2 (rollup raises when a goal is unrated).

## Sequencing
Migrations apply in filename order (0001 → 0004), so Jcode's tables must exist before Sol's policies/functions reference them. Work in your own worktree; do not touch the other builder's files. Do not run `supabase start` / `supabase db reset` yet — Fable will run that once both parts land, as the Gate 2 review.

## Scope reminder (from the brief)
Local Supabase stack only. Don't touch anything outside `supabase/`, `BRIEF.md`, `RULING.md`, `VERIFICATION.md`, `seed.sql`. No frontend code. No Objective/KeyResult/Calibration tables — that's Phase 2/3.
