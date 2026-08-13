# Brief: Phase 1 MVP schema — OKR/KRA Performance Management PoC

## Context
This is a personal proof-of-concept web app. Phase 1 scope is **KRA only** (no OKR/Objective/Key-Result tables yet — that's Phase 2). The target org shape is mid-size (200–2,000 employees) with a direct-line reporting hierarchy (matrix reporting is also Phase 2 — Phase 1 only needs employee → direct line manager).

This schema is grounded in research into how SAP SuccessFactors, Oracle Fusion HCM, and Workday implement performance/goal management. Two mechanisms from that research are load-bearing and must be preserved exactly:

1. **Cascade and align are different relationships, not one generic "parent goal" field.**
   - *Cascade*: a manager's goal is copied into a new goal owned by a report. The cascader is always the logical "parent" regardless of who edits the copy afterward. This must be its own table recording the copy event (source goal, resulting goal, who cascaded, when) — not a self-referencing FK on the goal table.
   - *Align*: two **independently pre-existing** goals get linked (no content copying). A goal may align **upward to only one** parent goal, but a parent goal may have **many** children aligned to it. This is also its own table, separate from cascade, with a uniqueness constraint enforcing "one alignment up."
   - Do not merge these into a single `parent_goal_id` column — that loses the "did this originate top-down or bottom-up" distinction, which is the whole point of tracking both.

2. **The rating rollup must implement Oracle's documented "Average Method" exactly**, because Phase 3 (calibration) and any future comp-linkage will depend on this being right:
   - Per goal: `item_score = rating / rating_scale_max` (a decimal 0–1).
   - Per category: weighted sum of its goals' `item_score * goal_weight`, where goal weights are percentages of the category (should sum to 100 within a category, but don't hard-block on this at insert time — validate at submission/finalization time instead, since plans are built incrementally).
   - Overall: weighted sum of category scores * category_weight (category weights are percentages of the whole plan, should sum to 100 across a plan).
   - Rescale the final 0–1 decimal back onto the plan's chosen overall rating scale (e.g. × 5 for a 1–5 scale).
   - This must be computable **twice independently** per goal plan — once from self-ratings, once from manager-ratings — as two separate stored/computed rows, not overwritten in place, so both remain visible during the manager-eval step.

## Required entities (Phase 1 only — do not add Objective/KeyResult/Calibration tables)

- **profiles** — extends `auth.users`. Fields: `id` (references `auth.users.id`), `full_name`, `email`, `manager_id` (nullable self-FK to `profiles.id`, direct line manager only), `is_hr_admin` (boolean, default false).
- **review_cycle** — `id`, `name`, `start_date`, `end_date`, `status` (`draft` / `active` / `self_eval` / `manager_eval` / `closed`), timestamps.
- **employee_goal_plan** — one per employee per cycle. `id`, `review_cycle_id`, `employee_id` (→ profiles), `status` (`draft` / `submitted` / `manager_reviewed` / `finalized`), `overall_rating_scale_max` (int, default 5), timestamps. Unique on `(review_cycle_id, employee_id)`.
- **kra_category** — `id`, `employee_goal_plan_id`, `name`, `description`, `weight` (numeric, percent of the plan), timestamps.
- **goal** — `id`, `kra_category_id`, `title`, `description`, `weight` (numeric, percent within its category), `target_metric` (text), `rating_scale_max` (int, default 5), `self_rating` (numeric, nullable), `self_comment` (text, nullable), `manager_rating` (numeric, nullable), `manager_comment` (text, nullable), timestamps.
- **goal_cascade** — `id`, `source_goal_id` (→ goal), `cascaded_goal_id` (→ goal, unique — a goal can only be the *result* of one cascade), `cascaded_by` (→ profiles), `cascaded_at`.
- **goal_alignment** — `id`, `parent_goal_id` (→ goal), `child_goal_id` (→ goal, **unique** — enforces "one alignment up"), `created_by` (→ profiles), `created_at`.
- **review_participant** — `id`, `employee_goal_plan_id`, `participant_id` (→ profiles), `role` (`employee` / `line_manager` / `hr_admin` — Phase 1 only, no `matrix_manager` yet), `created_at`. This table is what RLS policies key off, not role names alone.
- **goal_plan_rating** — `id`, `employee_goal_plan_id`, `rating_type` (`self` / `manager`), `overall_score` (numeric — the rescaled result of the Average Method above), `computed_at`. One row per `(employee_goal_plan_id, rating_type)`.

## Row-level security (must be enforced, not just documented)
- `profiles`: a user can select their own row, their direct reports' rows (`manager_id = auth.uid()`), and HR admins can select all.
- `employee_goal_plan` / `kra_category` / `goal`: visibility and write access must be derived from `review_participant` rows for that plan — **do not** write a policy that grants access by role name alone (this repeats a documented SAP bug where a broadly-granted role surfaced UI for people it shouldn't have applied to). An employee can read/write their own plan while `status = 'draft'` or `'submitted'`; a line manager can read + write `manager_rating`/`manager_comment` only during `manager_eval`; HR admin can do everything.
- `goal_cascade` / `goal_alignment`: visible to participants of either linked goal's plan.
- `goal_plan_rating`: same visibility as the parent `employee_goal_plan`.

## Deliverables
1. Supabase SQL migrations under `supabase/migrations/` (one migration per logical change is fine, or a single well-commented migration — your call, but it must be idempotent and runnable via `supabase db reset`).
2. RLS policies enabled on every table above (no table left with RLS off).
3. A SQL function or view implementing the Average Method rollup described above, callable to populate `goal_plan_rating`.
4. A `supabase/seed.sql` with realistic sample data: 1 HR admin, 2 line managers, 5 employees (some reporting to each manager), 1 active review cycle, at least one employee with 2 KRA categories each containing 2–3 goals with realistic weights, and at least one `goal_cascade` and one `goal_alignment` example so both mechanisms are exercised by the seed data.
5. A short `VERIFICATION.md` noting how you'd confirm the RLS policies actually work (e.g. specific test queries run as different simulated users) — you don't need a full test framework, but show the queries and expected results.

## Constraints
- Local Supabase stack only (this runs against `supabase start`, not a hosted project) — no hosted-Supabase-specific features.
- Don't touch anything outside `supabase/` and this `BRIEF.md`/`VERIFICATION.md` — no app frontend code yet, that's a later phase.
- Weight fields are percentages (0–100), stored as `numeric`, not floats.
