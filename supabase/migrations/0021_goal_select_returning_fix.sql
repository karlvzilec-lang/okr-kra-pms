-- 0021_goal_select_returning_fix.sql
-- Fixes a latent Phase 1 bug in goal_select_scoped, surfaced for the first
-- time by Round 3's "Add goal" action (goal-plan-editor.tsx's addGoal()) --
-- the first-ever caller to insert a plain goal row and read it back
-- (`.insert(...).select(...).single()`) as a non-HR employee.
--
-- Same root cause as 0019's objective_select_scoped fix: can_read_goal()'s
-- is_goal_participant() branch re-queries public.goal by id to check
-- whether the caller holds a review_participant row on the plan that owns
-- it. When that check runs as part of the SELECT-policy pass INSERT ...
-- RETURNING performs for the same statement, the self-referencing subquery
-- sees the snapshot taken at the start of that statement -- before the row
-- being inserted exists -- so it never finds a match and the policy
-- evaluates false, even though the row was correctly written and any
-- separate, later SELECT sees it fine. Reproduced directly:
--
--   insert into public.goal (kra_category_id, title, weight, rating_scale_max)
--   values (<lina's own category>, 'x', 0, 5)
--   returning id;
--   -- ERROR: new row violates row-level security policy for table "goal"
--
-- despite can_read_goal() returning true for the same employee against an
-- already-committed goal in the same category.
--
-- Fix: add a direct, non-self-referencing "I am the employee who owns this
-- goal's plan" check to the USING clause, ahead of can_read_goal(). It joins
-- kra_category -> employee_goal_plan using the row's own kra_category_id
-- (available directly in a USING clause, no subquery against goal needed)
-- rather than re-querying goal by id, so it isn't snapshot-fragile the way
-- the self-referencing branch is. can_read_goal() remains the fallback for
-- every other case (HR, the goal's own line/matrix manager, a manager
-- reading a report's goal) -- none of those needed a fix, since checking
-- can_read_goal(id) is only fragile against a NOT-YET-COMMITTED row, and
-- those cases only ever apply to goals that already existed before the
-- caller's own statement.
--
-- key_result_select_scoped and check_in_select_scoped were checked for the
-- same pattern during Round 2 and don't have it -- both key off their
-- *parent* row's id (objective_id / key_result_id), which already exists
-- under any snapshot. kra_category_select_scoped was checked here too: its
-- is_goal_plan_participant() branch queries review_participant only, never
-- kra_category itself, so it isn't self-referencing and isn't affected.

drop policy if exists goal_select_scoped on public.goal;
create policy goal_select_scoped
on public.goal
for select
to authenticated
using (
  exists (
    select 1
    from public.kra_category as kc
    join public.employee_goal_plan as egp on egp.id = kc.employee_goal_plan_id
    where kc.id = goal.kra_category_id
      and egp.employee_id = auth.uid()
  )
  or public.can_read_goal(id)
);
