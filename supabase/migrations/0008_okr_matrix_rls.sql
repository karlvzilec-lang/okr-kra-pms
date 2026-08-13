-- 0008_okr_matrix_rls.sql
-- Phase 2 helper functions, grants, and row-level security for the OKR and
-- matrix-manager tables created by 0006 and 0007.

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER helpers
-- ---------------------------------------------------------------------------

-- Ruling 1 intentionally follows Phase 1 can_read_goal's upward direction:
-- a caller may read their own manager's objective, not a direct report's.
create or replace function public.can_read_objective(p_objective_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or exists (
      select 1
      from public.objective as o
      where o.id = p_objective_id
        and o.owner_id = auth.uid()
    )
    or exists (
      select 1
      from public.objective as o
      join public.profiles as caller on caller.id = auth.uid()
      where o.id = p_objective_id
        and o.owner_id = caller.manager_id
    )
    or exists (
      select 1
      from public.review_participant as rp
      join public.review_participant_scope as rps
        on rps.review_participant_id = rp.id
      where rp.participant_id = auth.uid()
        and rp.role::text = 'matrix_manager'
        and rps.scope_type::text = 'objective'
        and rps.scope_id = p_objective_id
    );
$$;

create or replace function public.can_write_objective(p_objective_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or exists (
      select 1
      from public.objective as o
      where o.id = p_objective_id
        and o.owner_id = auth.uid()
    );
$$;

create or replace function public.can_read_key_result(p_key_result_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.key_result as kr
    where kr.id = p_key_result_id
      and public.can_read_objective(kr.objective_id)
  );
$$;

create or replace function public.can_check_in_key_result(p_key_result_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or exists (
      select 1
      from public.key_result as kr
      join public.objective as o on o.id = kr.objective_id
      where kr.id = p_key_result_id
        and o.owner_id = auth.uid()
    );
$$;

-- The scope row must belong to the same review_participant row used to prove
-- the caller's matrix-manager role. A bare role match never grants access.
create or replace function public.can_matrix_rate_goal(p_goal_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.goal as g
    join public.kra_category as kc on kc.id = g.kra_category_id
    join public.employee_goal_plan as egp on egp.id = kc.employee_goal_plan_id
    join public.review_cycle as rc on rc.id = egp.review_cycle_id
    join public.review_participant as rp
      on rp.employee_goal_plan_id = egp.id
    join public.review_participant_scope as rps
      on rps.review_participant_id = rp.id
    where g.id = p_goal_id
      and rc.status::text = 'manager_eval'
      and rp.participant_id = auth.uid()
      and rp.role::text = 'matrix_manager'
      and rps.scope_type::text = 'kra_category'
      and rps.scope_id = g.kra_category_id
  );
$$;

create or replace function public.can_read_review_participant_scope(
  p_review_participant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or exists (
      select 1
      from public.review_participant as rp
      where rp.id = p_review_participant_id
        and (
          rp.participant_id = auth.uid()
          or public.is_goal_plan_participant(rp.employee_goal_plan_id)
        )
    );
$$;

-- Matrix ratings are advisory input for their author, the plan's line
-- manager, and HR. They are not exposed to unrelated plan participants.
create or replace function public.can_read_goal_matrix_rating(
  p_goal_id uuid,
  p_participant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or p_participant_id = auth.uid()
    or exists (
      select 1
      from public.goal as g
      join public.kra_category as kc on kc.id = g.kra_category_id
      where g.id = p_goal_id
        and public.is_goal_plan_participant(
          kc.employee_goal_plan_id,
          array['line_manager']
        )
    );
$$;

revoke all on function public.can_read_objective(uuid) from public;
revoke all on function public.can_write_objective(uuid) from public;
revoke all on function public.can_read_key_result(uuid) from public;
revoke all on function public.can_check_in_key_result(uuid) from public;
revoke all on function public.can_matrix_rate_goal(uuid) from public;
revoke all on function public.can_read_review_participant_scope(uuid) from public;
revoke all on function public.can_read_goal_matrix_rating(uuid, uuid) from public;

grant execute on function public.can_read_objective(uuid)
to authenticated, service_role;
grant execute on function public.can_write_objective(uuid)
to authenticated, service_role;
grant execute on function public.can_read_key_result(uuid)
to authenticated, service_role;
grant execute on function public.can_check_in_key_result(uuid)
to authenticated, service_role;
grant execute on function public.can_matrix_rate_goal(uuid)
to authenticated, service_role;
grant execute on function public.can_read_review_participant_scope(uuid)
to authenticated, service_role;
grant execute on function public.can_read_goal_matrix_rating(uuid, uuid)
to authenticated, service_role;

-- Explicit grants keep the tables usable through the local Data API while RLS
-- remains the authority for every row.
revoke all on table
  public.objective,
  public.key_result,
  public.check_in,
  public.objective_alignment,
  public.review_participant_scope,
  public.goal_matrix_rating
from anon;

grant select, insert, update, delete on table
  public.objective,
  public.key_result,
  public.check_in,
  public.objective_alignment,
  public.review_participant_scope,
  public.goal_matrix_rating
to authenticated;

grant all on table
  public.objective,
  public.key_result,
  public.check_in,
  public.objective_alignment,
  public.review_participant_scope,
  public.goal_matrix_rating
to service_role;

-- ---------------------------------------------------------------------------
-- Enable RLS on every Phase 2 table
-- ---------------------------------------------------------------------------

alter table public.objective enable row level security;
alter table public.key_result enable row level security;
alter table public.check_in enable row level security;
alter table public.objective_alignment enable row level security;
alter table public.review_participant_scope enable row level security;
alter table public.goal_matrix_rating enable row level security;

-- ---------------------------------------------------------------------------
-- objective
-- ---------------------------------------------------------------------------

drop policy if exists objective_select_scoped on public.objective;
create policy objective_select_scoped
on public.objective
for select
to authenticated
using (public.can_read_objective(id));

drop policy if exists objective_owner_insert on public.objective;
create policy objective_owner_insert
on public.objective
for insert
to authenticated
with check (owner_id = auth.uid());

drop policy if exists objective_owner_update on public.objective;
create policy objective_owner_update
on public.objective
for update
to authenticated
using (public.can_write_objective(id))
with check (owner_id = auth.uid());

drop policy if exists objective_owner_delete on public.objective;
create policy objective_owner_delete
on public.objective
for delete
to authenticated
using (public.can_write_objective(id));

drop policy if exists objective_hr_all on public.objective;
create policy objective_hr_all
on public.objective
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- key_result
-- ---------------------------------------------------------------------------

drop policy if exists key_result_select_scoped on public.key_result;
create policy key_result_select_scoped
on public.key_result
for select
to authenticated
using (public.can_read_objective(objective_id));

drop policy if exists key_result_owner_insert on public.key_result;
create policy key_result_owner_insert
on public.key_result
for insert
to authenticated
with check (public.can_write_objective(objective_id));

drop policy if exists key_result_owner_update on public.key_result;
create policy key_result_owner_update
on public.key_result
for update
to authenticated
using (public.can_write_objective(objective_id))
with check (public.can_write_objective(objective_id));

drop policy if exists key_result_owner_delete on public.key_result;
create policy key_result_owner_delete
on public.key_result
for delete
to authenticated
using (public.can_write_objective(objective_id));

drop policy if exists key_result_hr_all on public.key_result;
create policy key_result_hr_all
on public.key_result
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- check_in
-- ---------------------------------------------------------------------------

drop policy if exists check_in_select_scoped on public.check_in;
create policy check_in_select_scoped
on public.check_in
for select
to authenticated
using (public.can_read_key_result(key_result_id));

drop policy if exists check_in_owner_insert on public.check_in;
create policy check_in_owner_insert
on public.check_in
for insert
to authenticated
with check (
  checked_in_by = auth.uid()
  and public.can_check_in_key_result(key_result_id)
);

drop policy if exists check_in_hr_all on public.check_in;
create policy check_in_hr_all
on public.check_in
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- objective_alignment -- child write authority + parent read authority
-- ---------------------------------------------------------------------------

drop policy if exists objective_alignment_select_scoped on public.objective_alignment;
create policy objective_alignment_select_scoped
on public.objective_alignment
for select
to authenticated
using (
  public.can_read_objective(parent_objective_id)
  or public.can_read_objective(child_objective_id)
);

drop policy if exists objective_alignment_insert_child_authority on public.objective_alignment;
create policy objective_alignment_insert_child_authority
on public.objective_alignment
for insert
to authenticated
with check (
  public.is_hr_admin()
  or (
    public.can_write_objective(child_objective_id)
    and public.can_read_objective(parent_objective_id)
    and created_by = auth.uid()
  )
);

drop policy if exists objective_alignment_hr_update on public.objective_alignment;
create policy objective_alignment_hr_update
on public.objective_alignment
for update
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

drop policy if exists objective_alignment_hr_delete on public.objective_alignment;
create policy objective_alignment_hr_delete
on public.objective_alignment
for delete
to authenticated
using (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- review_participant_scope -- grants are administered by HR
-- ---------------------------------------------------------------------------

drop policy if exists review_participant_scope_select_scoped on public.review_participant_scope;
create policy review_participant_scope_select_scoped
on public.review_participant_scope
for select
to authenticated
using (public.can_read_review_participant_scope(review_participant_id));

drop policy if exists review_participant_scope_hr_all on public.review_participant_scope;
create policy review_participant_scope_hr_all
on public.review_participant_scope
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- goal_matrix_rating
-- ---------------------------------------------------------------------------

drop policy if exists goal_matrix_rating_select_scoped on public.goal_matrix_rating;
create policy goal_matrix_rating_select_scoped
on public.goal_matrix_rating
for select
to authenticated
using (public.can_read_goal_matrix_rating(goal_id, participant_id));

drop policy if exists goal_matrix_rating_matrix_insert on public.goal_matrix_rating;
create policy goal_matrix_rating_matrix_insert
on public.goal_matrix_rating
for insert
to authenticated
with check (
  participant_id = auth.uid()
  and public.can_matrix_rate_goal(goal_id)
);

drop policy if exists goal_matrix_rating_matrix_update on public.goal_matrix_rating;
create policy goal_matrix_rating_matrix_update
on public.goal_matrix_rating
for update
to authenticated
using (
  participant_id = auth.uid()
  and public.can_matrix_rate_goal(goal_id)
)
with check (
  participant_id = auth.uid()
  and public.can_matrix_rate_goal(goal_id)
);

drop policy if exists goal_matrix_rating_matrix_delete on public.goal_matrix_rating;
create policy goal_matrix_rating_matrix_delete
on public.goal_matrix_rating
for delete
to authenticated
using (
  participant_id = auth.uid()
  and public.can_matrix_rate_goal(goal_id)
);

drop policy if exists goal_matrix_rating_hr_all on public.goal_matrix_rating;
create policy goal_matrix_rating_hr_all
on public.goal_matrix_rating
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());
