# Brief: Phase 3 — calibration, publish/close gate, comp export

## Context
Phase 1 (KRA scorecard + rollup) and Phase 2 (OKR overlay + matrix manager) are merged. This phase closes the loop: a human-facilitated calibration pass over manager ratings, a gate that hides the final/calibrated score from the employee until HR explicitly publishes it, and a read-only export surface for feeding a comp cycle. Per the original research (SAP, Workday, Lattice, Betterworks): **none of the mature vendors auto-enforce a forced distribution** — calibration is uniformly a facilitated, human-adjusted pass over a dashboard/matrix, never an algorithm. Build it that way: a starting snapshot the facilitator can override, not a curve-fit.

**Do not modify Phase 1 migrations (0001-0005) or Phase 2 migrations (0006-0011) or their behavior for existing data.** `compute_goal_plan_rating`'s output must stay unchanged. You may `CREATE OR REPLACE` the Phase 2 `employee_review_summary` function (0010) to add the new published/calibrated score — that function is explicitly meant to evolve, unlike the rollup.

## Part A — Calibration

- **calibration_session** — `id`, `review_cycle_id` (→ review_cycle), `name`, `status` (`open` / `finalized`, default `open`), timestamps.
- **calibration_band** — `id`, `calibration_session_id` (→ calibration_session), `label` (text, e.g. "Exceeds"), `min_score` (numeric), `max_score` (numeric), `sort_order` (int). A session owns an arbitrary number of bands (configurable-size matrix, per the Betterworks research finding that vendors don't restrict calibration to a fixed 3×3) — no hardcoded band count.
- **calibration_participant** — `id`, `calibration_session_id` (→ calibration_session), `employee_goal_plan_id` (→ employee_goal_plan, **unique per session** — a plan can only be calibrated once per session), `original_score` (numeric, **immutable once set** — the pre-calibration snapshot), `calibrated_score` (numeric, nullable, HR-adjustable — the post-calibration value), `band_id` (→ calibration_band, nullable, recomputed whenever `calibrated_score` changes), `facilitator_note` (text, nullable), timestamps. `original_score` and `calibrated_score` together **are** the audit trail — don't build a separate changelog table for this phase.

### Functions (all `SECURITY DEFINER`, HR-admin only — calibration is explicitly a facilitator/HR action per the research)
- `add_plan_to_calibration_session(p_session_id uuid, p_plan_id uuid)` — snapshots `original_score` from that plan's **manager** `goal_plan_rating.overall_score` (raise if it hasn't been computed yet — you can't calibrate a rating that doesn't exist), sets `calibrated_score` to the same value initially (calibration starts as "no change," matching every vendor researched — it's a starting point, not a blank slate), and assigns `band_id` by matching the score into a band's `[min_score, max_score)` range (raise if no band matches — that's a facilitator config error worth surfacing loudly, not silently leaving `band_id null`). Raise if the session is `finalized`.
- `adjust_calibration_participant(p_participant_id uuid, p_new_score numeric, p_note text default null)` — updates `calibrated_score` (never `original_score`) and recomputes `band_id`. Raise if the parent session is `finalized`.
- `finalize_calibration_session(p_session_id uuid)` — sets `status = 'finalized'`. Once finalized, `adjust_calibration_participant` must reject further changes for that session's participants (checked inside the function, not just by convention).

### RLS
- `calibration_session` / `calibration_band`: **readable** by HR admin or any line manager who has at least one report's plan in that session (via `calibration_participant` → `employee_goal_plan` → `review_participant` with role `line_manager`) — managers should be able to see the calibration context for their own reports. **Writable** (insert/update/delete) by HR admin only.
- `calibration_participant`: **readable** by HR admin, or the line manager of that specific plan's employee (via the same `review_participant` join as Phase 1's `can_manager_rate_goal` pattern) — **not** the employee themselves, and **not** other line managers in the same session. Writable only through the functions above (HR admin bypass in the functions covers this; no direct table INSERT/UPDATE policy for non-HR).

## Part B — Publish/close gate

- Add `published_at timestamptz` to `employee_goal_plan` (nullable, default null).
- `publish_employee_goal_plan(p_plan_id uuid)` — `SECURITY DEFINER`, HR-admin only. If the plan has a `calibration_participant` row, its parent `calibration_session.status` must be `finalized` (raise otherwise — you can't publish a mid-calibration score). If the plan has **no** calibration_participant row at all (never included in a session), publishing is allowed once the plan's `status` is `manager_reviewed` or `finalized` (a plan that was never calibrated can still be published on the manager's rating alone — not every plan needs calibration). Sets `published_at = now()`.
- The employee must **not** be able to see the calibrated/final score before `published_at` is set. Extend `employee_review_summary` (Phase 2, `0010`, `CREATE OR REPLACE`) to add a `final_score` field per KRA rating block: `null` while `published_at` is null, otherwise `coalesce(calibrated_score, manager overall_score)` — i.e. the calibrated value if this plan went through calibration, else just the already-visible manager rating, once published. Do not change the existing `kra_ratings`/`objectives` shape the frontend already consumes — add to it, don't restructure it (there's a live Next.js frontend reading this function's exact return shape right now).

## Part C — Comp export (read-only)

- `comp_export_rows(p_review_cycle_id uuid)` — `SECURITY INVOKER` (not definer — this must run under RLS as the caller, and only HR admins have any table access wide enough to make it return rows; a non-HR caller should get zero rows, not an authorization error, matching the isolation pattern `employee_review_summary` already uses), returning one row per **published** plan in the cycle: `employee_id`, `full_name`, `email`, `manager_full_name`, `overall_rating_scale_max`, `final_score`, `band_label` (nullable), `published_at`. Only plans with `published_at is not null` appear — this is explicitly an export of finished, published results, not a working view of in-progress ratings.
- No RLS policy changes needed beyond what Part A/B already require — this function just queries through existing table RLS as the invoker, so it's automatically correct if the underlying table policies are correct. Grant `execute` to `authenticated` same as the Phase 2 functions.

## Deliverables
1. New migrations in `supabase/migrations/`, numbered `0012` onward, applied after Phase 2's `0011`. Idempotent.
2. RLS on both new tables (`calibration_session`, `calibration_band`, `calibration_participant` — three tables).
3. Seed additions (append to `supabase/seed.sql`): one calibration session for the FY2026 cycle with 3-4 bands (e.g. "Needs Improvement", "Meets Expectations", "Exceeds Expectations", "Outstanding"), Dara's plan added to it via the real `add_plan_to_calibration_session` function call (not hardcoded — exercise the function, same pattern as Phase 1's rollup seeding), one `adjust_calibration_participant` call showing a facilitator override away from the original score, the session finalized, and Dara's plan published via `publish_employee_goal_plan`. This gives the frontend real end-to-end data to render Part B's new `final_score` field.
4. `VERIFICATION.md` additions (append) covering: RLS on the 3 new tables, a line manager can read their report's calibration_participant row but not another manager's, an employee cannot read any calibration_participant row at all, `adjust_calibration_participant` is rejected once the session is finalized, `publish_employee_goal_plan` is rejected for a plan whose calibration session isn't finalized yet, `employee_review_summary`'s new `final_score` is null pre-publish and the calibrated value post-publish, and `comp_export_rows` returns the published row for HR and zero rows for a non-HR caller.
5. `Regression guard`: re-verify `compute_goal_plan_rating` for Dara's plan still returns `4.220`/`3.580` — this phase must not touch that function or its inputs.

## Constraints
- Local Supabase stack only, same as Phase 1/2.
- Don't touch `0001`-`0009` or `0011`. `0010` may be replaced (see Part B).
- No calibration UI yet (drag-and-drop matrix) — that's a frontend follow-up, not this phase. This phase is schema + functions + the one new frontend-visible field.
