-- 0019_objective_select_returning_fix.sql
-- Fixes a latent Phase 2 bug in objective_select_scoped, surfaced for the
-- first time by Round 2's objective-creation UI.
--
-- can_read_objective()'s first branch re-queries public.objective by id to
-- check `owner_id = auth.uid()`. When that function is invoked as part of
-- the SELECT-policy check Postgres performs for INSERT ... RETURNING on the
-- same statement, the self-referencing subquery runs under the snapshot
-- taken at the start of that statement -- which predates the row's own
-- insertion -- so it never finds the row and the policy evaluates false.
-- A separate, later SELECT statement in the same transaction sees the row
-- fine (fresh snapshot), which is why this only broke `.insert().select()`
-- (PostgREST's default for a plain insert) and not a subsequent read.
--
-- No prior code exercised this path: before Round 2, the only writers to
-- `objective` were HR (whose can_read_objective() short-circuits on
-- is_hr_admin() before ever touching the self-referencing branch) and the
-- seed script (which never selects the row back). Round 2's UI is the first
-- non-HR caller to insert an objective and read it back in the same
-- request, which is what surfaced this.
--
-- Fix: check `owner_id = auth.uid()` directly against the row in the USING
-- clause before ever calling can_read_objective(), since a USING clause has
-- direct access to the row's own columns and needs no subquery for this
-- case. can_read_objective() remains the fallback for the manager/matrix
-- cases, which are not self-referential against a row that might not have
-- committed yet within the same statement.

drop policy if exists objective_select_scoped on public.objective;
create policy objective_select_scoped
on public.objective
for select
to authenticated
using (
  owner_id = auth.uid()
  or public.can_read_objective(id)
);
