# Gate 1 ruling — Phase 2 (OKR overlay + matrix manager)

## Ruling 1 — objective read-authority direction (brief correction)
`BRIEF_PHASE2.md` described this backwards ("the owner's direct line manager" can read). The correct rule, matching Phase 1's actual `can_read_goal` predicate exactly, is the **upward** direction: a caller can read an objective if they are the owner, HR, hold a matrix scope grant referencing it, **or the objective's owner_id equals the caller's own manager_id** (i.e. you can read your own manager's objective — the same mechanism that lets Rith read Ana's goal in Phase 1). Both builders independently confirmed this correction after review. Implement `can_read_objective` with this direction. This is what makes the seeded Dara-aligns-up-to-Ana `objective_alignment` example resolve correctly.

## Ruling 2 — `employee_review_summary`: function, not view
Both builders argued both sides after cross-challenge and ended up swapping their original positions — a genuine disagreement, not one arguing harder than the other. Final call:

**Build it as the `STABLE SECURITY INVOKER` table function** (`employee_review_summary(p_review_cycle_id uuid, p_employee_id uuid) returns jsonb` or a single-row composite — implementer's choice on exact return shape), not the flat `UNION ALL` view.

Reasoning: the brief itself scopes this as a single-employee, single-cycle detail screen ("KRA number + OKR evidence side by side" — i.e. a review summary page for one person, not a cross-employee list/analytics view), and already specified it with parameterized call syntax (`employee_review_summary(p_review_cycle_id, p_employee_id)`). A function returning nested JSON (objectives, each with their key results, alongside the KRA rating rows) maps directly onto how that screen would render — one fetch, no client-side re-grouping of a flat `row_kind`-discriminated table. The view's real advantage (PostgREST-composable ad-hoc filtering/sorting) matters more for a list/analytics screen than a fixed per-employee detail view, which isn't what's being built here. `SECURITY INVOKER` is also simpler to reason about correctly than a view's `security_invoker = true` reloption, since it's the actual PostgreSQL function default rather than an easy-to-silently-drop option on `CREATE OR REPLACE VIEW`.

## Everything else
No other disagreements — both plans independently converged on: the `0005` migration containing only the bare `ALTER TYPE ... ADD VALUE`, the `BEFORE INSERT OR UPDATE` score-recompute trigger with `greatest/least` clamping and `NULL` on the degenerate `start_value = target_value` case, the `AFTER INSERT` check-in trigger updating `current_value`, the exact matrix-scope RLS join (`review_participant` → `review_participant_scope` on that same participant row → `scope_id = goal.kra_category_id` → cycle status `manager_eval`), and `objective_alignment` mirroring Phase 1 Ruling 3 exactly (child write-authority + parent read-authority, not both-plan participation). Implement as planned.

## Division of labor
Same split as Phase 1 — Jcode owns the schema stream, Sol owns the RLS/logic stream — for consistency and because both are now deep in their respective Phase 1 files' conventions.

**Jcode owns:**
- `supabase/migrations/0005_participant_role_matrix.sql` — bare `ALTER TYPE public.participant_role ADD VALUE IF NOT EXISTS 'matrix_manager'`, nothing else in this file.
- `supabase/migrations/0006_okr_tables.sql` — `objective`, `key_result`, `check_in`, `objective_alignment` tables, enums, indexes, `set_updated_at` triggers. No RLS, no scoring logic yet.
- `supabase/migrations/0007_matrix_tables.sql` — `review_participant_scope`, `goal_matrix_rating` tables, the polymorphic `scope_id` existence-validation trigger, and the trigger enforcing the referenced `review_participant.role = 'matrix_manager'`. No RLS policies yet (that's 0008).
- `supabase/seed.sql` additions (append) — per the brief: matrix manager profile + scope grant + advisory rating, 2 objectives × 2 key results each (~0.70 and ~0.30), 2 check-ins showing progression, 1 `objective_alignment` example (created by Ana, since per Ruling 1 Dara can read Ana's objective but Ana must be the one creating it if the alignment needs write-authority on a goal Dara owns — actually per Ruling 3's pattern, the CHILD-plan-write-authority holder creates the link, so if Dara's objective is the child, Dara creates it, and now correctly CAN read Ana's parent objective per Ruling 1's fix — seed it as created by Dara).

**Sol owns:**
- `supabase/migrations/0008_okr_matrix_rls.sql` — all SECURITY DEFINER helpers (`can_read_objective` per Ruling 1, `can_write_objective`, `can_matrix_rate_goal`, etc.), grants, RLS enable + policies on all 6 new tables.
- `supabase/migrations/0009_okr_scoring.sql` — the `key_result` score-recompute trigger and the `check_in` → `current_value` trigger.
- `supabase/migrations/0010_employee_review_summary.sql` — the function per Ruling 2.
- `VERIFICATION.md` additions (append) — per the brief's list, plus explicit coverage of Ruling 1 and Ruling 2's chosen shape, and the Phase 1 regression guard (`compute_goal_plan_rating` still returns `4.220`/`3.580` for Dara's plan, unchanged).

## Sequencing
`0005` → `0010` in order. Work in your own worktree; don't touch the other builder's files or anything in `0001`–`0004`. Do not run `supabase db reset` yet — Fable runs that at Gate 2.
