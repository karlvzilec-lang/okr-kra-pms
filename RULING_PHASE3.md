# Gate 1 ruling — Phase 3 (calibration, publish/close gate, comp export)

## Ruling 1 — `comp_export_rows` is explicitly HR-only, not pure RLS composition
Both builders independently caught the same flaw in `BRIEF_PHASE3.md`'s assumption that plain RLS composition would yield "zero rows for non-HR": it doesn't — a line manager already has legitimate RLS visibility into their own reports' `employee_goal_plan`/`profiles`/`goal_plan_rating` rows, so an unguarded invoker join would return their reports' export rows too. They resolved it in opposite directions (Sol added an explicit HR gate; Jcode accepted manager visibility as consistent with the rest of the app's model). Final call: **add the explicit gate, Sol's approach** —

```sql
join public.profiles as caller
  on caller.id = auth.uid()
 and caller.is_hr_admin
```

Reasoning: a comp export is a fundamentally different sensitivity class than day-to-day review visibility, even in orgs where managers can see their reports' individual reviews — compensation-cycle exports are routinely restricted to HR/Comp specifically, as a deliberate governance boundary, not an oversight. The function name and purpose (`comp_export_rows`, "feeding a comp cycle") signal a purpose-built HR tool, not a general dashboard query. This also matches the brief's literal stated requirement ("a non-HR caller should get zero rows") without needing to reinterpret it.

## Ruling 2 — `final_score` appears only on the `manager` KRA rating block
Neither builder's plan diverged on this, but neither resolved it either — both defaulted to placing the same `final_score` value on both the `self` and `manager` blocks inside `kra_ratings`. That's wrong: self-assessments are never inputs to calibration (`add_plan_to_calibration_session` snapshots from the **manager** rating only), so showing a calibrated value next to `rating_type: 'self'` misrepresents it as something the employee's own self-assessment produced. Implement: `final_score` is computed and populated only when `rating_type = 'manager'`; the `self` block's `final_score` key is always `null`, regardless of publish state.

## Everything else — implement exactly as planned, both converged
- `calibration_participant`'s RLS keys off the **specific plan's** `review_participant` (line manager of that exact employee), not blanket calibration-session membership — this is what makes "Ana sees Dara's row, not Sophea's row, even in the same session" hold.
- Band matching is half-open `[min_score, max_score)`, both `add_plan_to_calibration_session` and `adjust_calibration_participant` share one matching rule, and **no match raises loudly** (`23514`) rather than leaving `band_id` null — a config gap (e.g. a top band capped exactly at the scale max, missing a perfect score) is a facilitator error worth surfacing immediately. Seed bands must span above `overall_rating_scale_max` (e.g. top band `[4.5, 5.001)`, not `[4.5, 5)`) so a perfect `5.000` doesn't fall out.
- `original_score` is immutable once set, enforced by a `BEFORE UPDATE` trigger — including against HR, since HR is precisely who would otherwise be tempted to overwrite the pre-calibration snapshot. `calibrated_score` is the only adjustable field, only via `adjust_calibration_participant`, only while the session is `open`.
- `employee_review_summary`'s signature, `kra_ratings`/`objectives` shape, and existing keys are unchanged — `final_score` is purely additive, and the function is reachable by an employee about their own data without ever touching `calibration_participant` directly (a `SECURITY DEFINER` scalar helper bridges that, since employees can't read that table under Ruling — this was already in both plans, keep it).
- `publish_employee_goal_plan`: rejects if the plan has a `calibration_participant` row in a still-`open` session; allows publishing an uncalibrated plan once its status is `manager_reviewed` or `finalized`.

## Division of labor
Same split as Phase 1 and Phase 2 — Jcode owns the schema stream, Sol owns RLS/logic/verification.

**Jcode owns:**
- `supabase/migrations/0012_calibration_tables.sql` — `calibration_session`, `calibration_band`, `calibration_participant` tables, `employee_goal_plan.published_at` column, indexes, `set_updated_at` triggers, the `original_score` immutability trigger (schema-level guard, belongs with the DDL).
- `supabase/seed.sql` additions (append) — per the brief: one calibration session, 3-4 bands spanning above the scale max, Dara's plan added via a real `add_plan_to_calibration_session` call, one `adjust_calibration_participant` override, session finalized, Dara's plan published via `publish_employee_goal_plan` — real function calls, not hardcoded rows, same pattern as every prior phase's seed.

**Sol owns:**
- `supabase/migrations/0013_calibration_rls.sql` — the two read-scope helpers (per-participant and per-session), grants, RLS enable + policies on all three new tables.
- `supabase/migrations/0014_calibration_functions.sql` — `add_plan_to_calibration_session`, `adjust_calibration_participant`, `finalize_calibration_session`, `publish_employee_goal_plan`, the shared band-matching helper.
- `supabase/migrations/0015_review_summary_and_comp_export.sql` — `CREATE OR REPLACE employee_review_summary` (Ruling 2 applied) and `comp_export_rows` (Ruling 1's HR gate applied).
- `VERIFICATION.md` additions (append) — per the brief's list, plus explicit coverage of both rulings, and the Phase 1 regression guard (`compute_goal_plan_rating` still `4.220`/`3.580` for Dara's plan).

## Sequencing
`0012` → `0015` in order. Work in your own worktree; don't touch the other builder's files or anything in `0001`-`0011`. Do not run `supabase db reset` yet — Fable runs that at Gate 2.
