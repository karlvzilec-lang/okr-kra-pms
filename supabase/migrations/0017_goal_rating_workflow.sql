-- 0017_goal_rating_workflow.sql
-- Goal/rating creation workflow hardening and manager plan-review transition.
--
-- Dual-role edge case: if the same caller is both the employee and a
-- line_manager participant on one plan, both goal column-scope triggers apply
-- independently. The conservative result is that neither side's protected
-- goal columns can be changed during the overlapping window. Choosing role
-- precedence is a business decision and is intentionally out of scope here.
--
-- Idempotent: functions and policies are replaced, and triggers are dropped
-- before creation.

-- ---------------------------------------------------------------------------
-- Employee goal UPDATE column scope.
-- Employees own goal structure and self-assessment fields, never manager-side
-- assessment fields or row identity/audit fields.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_employee_goal_updates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_hr_admin() then
    return new;
  end if;

  if public.can_edit_goal_as_employee(old.id) then
    if new.rating_scale_max is distinct from old.rating_scale_max
      and old.manager_rating is not null
    then
      raise exception 'Employees may not change rating_scale_max after a manager rating exists'
        using errcode = '42501';
    end if;

    if new.id is distinct from old.id
      or new.kra_category_id is distinct from old.kra_category_id
      or new.manager_rating is distinct from old.manager_rating
      or new.manager_comment is distinct from old.manager_comment
      or new.created_at is distinct from old.created_at
    then
      raise exception 'Employees may not update goal identity or manager assessment fields'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_employee_goal_updates() from public;

drop trigger if exists goal_restrict_employee_updates on public.goal;
create trigger goal_restrict_employee_updates
before update on public.goal
for each row
execute function public.restrict_employee_goal_updates();

-- ---------------------------------------------------------------------------
-- Employee goal INSERT scope.
-- The employee policy must reject manager-side values at creation time; the
-- UPDATE trigger above cannot protect a row that is born pre-rated.
-- ---------------------------------------------------------------------------

drop policy if exists goal_employee_insert on public.goal;
create policy goal_employee_insert
on public.goal
for insert
to authenticated
with check (
  public.can_edit_kra_category_as_employee(kra_category_id)
  and manager_rating is null
  and manager_comment is null
);

-- ---------------------------------------------------------------------------
-- Employee plan UPDATE column scope.
-- The existing RLS policy constrains employee status values to draft/submitted;
-- this trigger ensures a permitted status update cannot carry other changes.
-- updated_at is excluded because the 0001 maintenance trigger changes it.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_employee_plan_status_updates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_hr_admin() then
    return new;
  end if;

  if public.can_edit_goal_plan_as_employee(old.id) then
    if new.id is distinct from old.id
      or new.review_cycle_id is distinct from old.review_cycle_id
      or new.employee_id is distinct from old.employee_id
      or new.overall_rating_scale_max is distinct from old.overall_rating_scale_max
      or new.created_at is distinct from old.created_at
      or new.published_at is distinct from old.published_at
    then
      raise exception 'Employees may update only employee goal plan status'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_employee_plan_status_updates() from public;

drop trigger if exists employee_goal_plan_restrict_employee_status_updates
  on public.employee_goal_plan;
create trigger employee_goal_plan_restrict_employee_status_updates
before update on public.employee_goal_plan
for each row
execute function public.restrict_employee_plan_status_updates();

-- ---------------------------------------------------------------------------
-- Manager goal-rating scope.
-- Cycle-wide manager_eval is necessary but not sufficient: the specific plan
-- must have been submitted and must still be awaiting manager review.
-- ---------------------------------------------------------------------------

create or replace function public.can_manager_rate_goal(p_goal_id uuid)
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
    where g.id = p_goal_id
      and egp.status = 'submitted'::public.goal_plan_status
      and rc.status = 'manager_eval'::public.review_cycle_status
      and rp.participant_id = auth.uid()
      and rp.role = 'line_manager'::public.participant_role
  );
$$;

revoke all on function public.can_manager_rate_goal(uuid) from public;
grant execute on function public.can_manager_rate_goal(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Manager plan-review transition scope.
-- A line_manager participant may reach only a submitted plan in that plan's
-- manager_eval cycle window. The trigger below owns the transition/column
-- contract; the RLS USING clause makes out-of-window attempts affect zero rows.
-- ---------------------------------------------------------------------------

create or replace function public.can_manager_mark_plan_reviewed(
  p_employee_goal_plan_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.employee_goal_plan as egp
    join public.review_cycle as rc on rc.id = egp.review_cycle_id
    join public.review_participant as rp
      on rp.employee_goal_plan_id = egp.id
    where egp.id = p_employee_goal_plan_id
      and egp.status = 'submitted'::public.goal_plan_status
      and rc.status = 'manager_eval'::public.review_cycle_status
      and rp.participant_id = auth.uid()
      and rp.role = 'line_manager'::public.participant_role
  );
$$;

revoke all on function public.can_manager_mark_plan_reviewed(uuid) from public;
grant execute on function public.can_manager_mark_plan_reviewed(uuid)
to authenticated, service_role;

drop policy if exists employee_goal_plan_manager_mark_reviewed
  on public.employee_goal_plan;
create policy employee_goal_plan_manager_mark_reviewed
on public.employee_goal_plan
for update
to authenticated
using (public.can_manager_mark_plan_reviewed(id))
with check (
  status = 'manager_reviewed'::public.goal_plan_status
  and public.can_manager_mark_plan_reviewed(id)
);

-- updated_at is excluded because the 0001 maintenance trigger changes it.
create or replace function public.restrict_manager_plan_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_hr_admin() then
    return new;
  end if;

  if public.can_manager_mark_plan_reviewed(old.id) then
    if old.status is distinct from 'submitted'::public.goal_plan_status
      or new.status is distinct from 'manager_reviewed'::public.goal_plan_status
      or new.id is distinct from old.id
      or new.review_cycle_id is distinct from old.review_cycle_id
      or new.employee_id is distinct from old.employee_id
      or new.overall_rating_scale_max is distinct from old.overall_rating_scale_max
      or new.created_at is distinct from old.created_at
      or new.published_at is distinct from old.published_at
    then
      raise exception 'Line managers may only transition submitted plans to manager_reviewed'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_manager_plan_status_transition() from public;

drop trigger if exists employee_goal_plan_restrict_manager_status_transition
  on public.employee_goal_plan;
create trigger employee_goal_plan_restrict_manager_status_transition
before update on public.employee_goal_plan
for each row
execute function public.restrict_manager_plan_status_transition();
