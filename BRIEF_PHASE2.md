# Brief: Phase 2 — OKR overlay + matrix manager

## Context
Phase 1 (merged) built the KRA scorecard: `profiles`, `review_cycle`, `employee_goal_plan`, `kra_category`, `goal`, `goal_cascade`, `goal_alignment`, `review_participant`, `goal_plan_rating`, plus the Average Method rollup and RLS. **Do not modify any Phase 1 table's core shape or the rollup function** — this phase adds alongside it, per the earlier design decision: KRA drives the appraisal number, OKR is a structurally separate overlay that feeds evidence into the same conversation without being mathematically merged into the KRA score. `compute_goal_plan_rating` must not change its output for existing Phase 1 data.

This phase adds two things: (1) an Objective/Key-Result tree with check-ins, alignment-only linking (no cascade — Viva Goals research confirmed OKR tools use alignment, not the cascade-copy mechanism KRAs use), and industry-standard 0.0–1.0 scoring; (2) a matrix-manager role that can rate specific scoped sections of an employee's KRA plan without being their line manager, modeled on Oracle's first-class "Performance Role" and SAP's `EX`/`EY` matrix codes.

## Part A — OKR entities

- **objective** — `id`, `review_cycle_id` (→ review_cycle), `owner_id` (→ profiles), `title`, `description`, `status` (`active` / `closed`, default `active`), timestamps. Single-owner for this phase (team-owned objectives are a later extension, don't build for it).
- **key_result** — `id`, `objective_id` (→ objective), `title`, `metric_unit` (text, e.g. `"%"`, `"requests/sec"`, free text), `start_value` (numeric, default 0), `target_value` (numeric, not null), `current_value` (numeric, default = `start_value`), `score` (numeric, nullable — the 0.0–1.0 result), `score_override` (numeric, nullable — if set, wins over the auto-computed score), timestamps.
  - `score` auto-recomputes whenever `current_value` changes: `clamp((current_value - start_value) / nullif(target_value - start_value, 0), 0, 1)`. Implement as a `BEFORE INSERT OR UPDATE` trigger, not application logic — this is a stored, queryable column, not a view, because the summary in Part C needs to read it directly.
  - The effective score for display purposes is `coalesce(score_override, score)`.
- **check_in** — `id`, `key_result_id` (→ key_result), `checked_in_by` (→ profiles), `new_value` (numeric — becomes the key_result's `current_value`), `note` (text, nullable), `created_at`. Inserting a check-in must update the parent `key_result.current_value` to `new_value` (trigger or function — your call, but document which).
- **objective_alignment** — `id`, `parent_objective_id` (→ objective), `child_objective_id` (→ objective, **unique** — same "one alignment up" rule as `goal_alignment` in Phase 1), `created_by` (→ profiles), `created_at`. No cascade table for objectives — alignment only, per the research finding that OKR tools don't copy-cascade.

### OKR visibility & write rules
- An objective is readable by: its owner, the owner's direct line manager (`profiles.manager_id` chain, same pattern as the Phase 1 `can_read_goal` manager fallback), any matrix manager with a scope grant referencing it (see Part B), or HR admin.
- Only the owner or HR admin may write `objective`/`key_result` core fields (title, description, target_value, etc.).
- `check_in` may be inserted only by the key_result's objective owner or HR admin — no delegated check-in owners in this phase (that's a later extension, don't build for it).
- `objective_alignment` insert authorization mirrors Phase 1 Ruling 3 exactly: caller must have write authority on the **child** objective (owner or HR) and read authority on the **parent** objective. Do not require participation/ownership of both — that repeats the bug Phase 1 already fixed once.

## Part B — Matrix manager role

- Add `'matrix_manager'` to the existing `participant_role` enum (`ALTER TYPE ... ADD VALUE` — note this cannot run inside the same transaction as code that uses the new value, so it needs its own migration file that runs before anything references it).
- **review_participant_scope** — `id`, `review_participant_id` (→ review_participant, and the referenced row's `role` must be `matrix_manager` — enforce with a trigger or check, not just convention), `scope_type` (`kra_category` / `objective`), `scope_id` (uuid — the referenced category or objective's id, no FK since it's polymorphic; validate existence via trigger instead), `created_at`. This is what makes matrix access scoped rather than blanket, per the Oracle/SAP research: a matrix manager can rate only the specific sections they've been explicitly granted, and cannot add/remove goals or categories.
- **goal_matrix_rating** — `id`, `goal_id` (→ goal), `participant_id` (→ profiles, the matrix manager), `rating` (numeric, nullable), `comment` (text, nullable), timestamps. Unique on `(goal_id, participant_id)`. **This is deliberately a separate table from `goal.manager_rating`/`manager_comment`** — those columns and their Phase 1 update-guard trigger belong to the line manager relationship; a matrix manager writing there would collide with that trigger's ownership assumptions, and multiple matrix managers may independently rate the same goal. Matrix ratings are advisory input surfaced to the line manager/HR during review — they do **not** feed `compute_goal_plan_rating`. Don't touch that function.
- A matrix manager may write a `goal_matrix_rating` row only if: they hold a `review_participant` row with role `matrix_manager` on that goal's plan, AND a `review_participant_scope` row on that same participant row whose `scope_type = 'kra_category'` and `scope_id` matches the goal's `kra_category_id` (or `scope_type = 'objective'` scope entries are for OKR-side scoping in a future phase — for this phase only `kra_category` scoping is exercised against `goal_matrix_rating`), AND the plan's cycle is in `manager_eval`. Matrix write access must never be granted by checking `role = 'matrix_manager'` alone without the scope-row join — that's the exact SAP `EX`-role bug the original research flagged, and Phase 1 already avoided by keying everything off `review_participant`; keep that discipline here.

## Part C — Combined summary (read-only)

- A view (or table function) `employee_review_summary(p_review_cycle_id uuid, p_employee_id uuid)` — or a plain view filtered by RLS, your call on shape — that returns, for one employee's plan in one cycle: the KRA `overall_score` rows from `goal_plan_rating` (self + manager), and a list of that employee's objectives with their key results' `coalesce(score_override, score)` values. This is the "KRA number + OKR evidence side by side" view from the roadmap — it is a read aggregation only, it must not write anything, and it must respect RLS (use `security_invoker = true` if you implement it as a view, so it runs as the querying user rather than its owner — otherwise it silently bypasses every policy above).

## RLS
Every new table gets RLS enabled, keyed off `review_participant`/`review_participant_scope`/direct ownership as specified above — never off a bare role name. Follow the same SECURITY DEFINER helper-function pattern from Phase 1's `0003_rls_policies.sql` (new helpers are fine, e.g. `can_read_objective`, `can_write_objective`, `has_matrix_scope`).

## Deliverables
1. New migrations in `supabase/migrations/`, numbered `0005` onward, applied after Phase 1's `0004`. Idempotent.
2. RLS on every new table.
3. Updates to `supabase/seed.sql` (or a new `supabase/seed_phase2.sql` appended via `db.seed.sql_paths` in `config.toml` — your call) adding: at least 2 objectives with 2 key results each (one on-track scoring ~0.7, one behind scoring ~0.3, to exercise the color-banding math even though banding itself is a display concern not a DB one), at least 2 check-ins showing progression on one key result, one `objective_alignment` example, one matrix manager (a new profile) granted scope on one specific `kra_category` from the Phase 1 seed data with at least one `goal_matrix_rating` row.
4. `VERIFICATION.md` additions (append, don't replace) covering: matrix manager can rate only their scoped category's goals and nothing else, matrix manager cannot write `goal.manager_rating` (line-manager-only column), objective_alignment's asymmetric authorization (mirroring Phase 1's Ruling 3 test), check-in updates `current_value` and the score trigger recomputes correctly, and the `employee_review_summary` view returns nothing for a caller with no relationship to the employee.

## Constraints
- Local Supabase stack only, same as Phase 1.
- Don't touch `0001`–`0004` or the Phase 1 rollup function's behavior for existing data.
- No frontend code yet.
- No calibration tables yet (Phase 3).
