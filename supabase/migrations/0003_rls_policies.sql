-- 0003_rls_policies.sql
-- Phase 1 helper functions, grants, row-level security, and the manager-only
-- goal update guard. Tables and enum types are created by 0001 and 0002.

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_hr_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select p.is_hr_admin
    from public.profiles as p
    where p.id = auth.uid()
  ), false);
$$;

create or replace function public.is_goal_plan_participant(
  p_employee_goal_plan_id uuid,
  p_roles text[] default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.review_participant as rp
    where rp.employee_goal_plan_id = p_employee_goal_plan_id
      and rp.participant_id = auth.uid()
      and (p_roles is null or rp.role::text = any (p_roles))
  );
$$;

create or replace function public.is_review_cycle_participant(
  p_review_cycle_id uuid
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
    join public.review_participant as rp
      on rp.employee_goal_plan_id = egp.id
    where egp.review_cycle_id = p_review_cycle_id
      and rp.participant_id = auth.uid()
  );
$$;

create or replace function public.can_edit_goal_plan_as_employee(
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
    join public.review_participant as rp
      on rp.employee_goal_plan_id = egp.id
    where egp.id = p_employee_goal_plan_id
      and egp.employee_id = auth.uid()
      and egp.status::text in ('draft', 'submitted')
      and rp.participant_id = auth.uid()
      and rp.role::text = 'employee'
  );
$$;

create or replace function public.can_edit_kra_category_as_employee(
  p_kra_category_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.kra_category as kc
    where kc.id = p_kra_category_id
      and public.can_edit_goal_plan_as_employee(kc.employee_goal_plan_id)
  );
$$;

create or replace function public.can_edit_goal_as_employee(p_goal_id uuid)
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
    where g.id = p_goal_id
      and public.can_edit_goal_plan_as_employee(kc.employee_goal_plan_id)
  );
$$;

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
      and rc.status::text = 'manager_eval'
      and rp.participant_id = auth.uid()
      and rp.role::text = 'line_manager'
  );
$$;

create or replace function public.is_goal_participant(p_goal_id uuid)
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
    join public.review_participant as rp
      on rp.employee_goal_plan_id = kc.employee_goal_plan_id
    where g.id = p_goal_id
      and rp.participant_id = auth.uid()
  );
$$;

create or replace function public.can_read_goal(p_goal_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or public.is_goal_participant(p_goal_id)
    or exists (
      select 1
      from public.goal as g
      join public.kra_category as kc on kc.id = g.kra_category_id
      join public.employee_goal_plan as egp on egp.id = kc.employee_goal_plan_id
      join public.profiles as caller on caller.id = auth.uid()
      where g.id = p_goal_id
        and egp.employee_id = caller.manager_id
    );
$$;

-- Link-table inserts use write authority on the target/child plan only.
-- A line manager has write authority during manager_eval; the goal trigger
-- below still limits ordinary goal UPDATE statements to manager fields.
create or replace function public.can_write_goal(p_goal_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_hr_admin()
    or public.can_edit_goal_as_employee(p_goal_id)
    or public.can_manager_rate_goal(p_goal_id);
$$;

revoke all on function public.is_hr_admin() from public;
revoke all on function public.is_goal_plan_participant(uuid, text[]) from public;
revoke all on function public.is_review_cycle_participant(uuid) from public;
revoke all on function public.can_edit_goal_plan_as_employee(uuid) from public;
revoke all on function public.can_edit_kra_category_as_employee(uuid) from public;
revoke all on function public.can_edit_goal_as_employee(uuid) from public;
revoke all on function public.can_manager_rate_goal(uuid) from public;
revoke all on function public.is_goal_participant(uuid) from public;
revoke all on function public.can_read_goal(uuid) from public;
revoke all on function public.can_write_goal(uuid) from public;

grant execute on function public.is_hr_admin() to authenticated, service_role;
grant execute on function public.is_goal_plan_participant(uuid, text[]) to authenticated, service_role;
grant execute on function public.is_review_cycle_participant(uuid) to authenticated, service_role;
grant execute on function public.can_edit_goal_plan_as_employee(uuid) to authenticated, service_role;
grant execute on function public.can_edit_kra_category_as_employee(uuid) to authenticated, service_role;
grant execute on function public.can_edit_goal_as_employee(uuid) to authenticated, service_role;
grant execute on function public.can_manager_rate_goal(uuid) to authenticated, service_role;
grant execute on function public.is_goal_participant(uuid) to authenticated, service_role;
grant execute on function public.can_read_goal(uuid) to authenticated, service_role;
grant execute on function public.can_write_goal(uuid) to authenticated, service_role;

-- Explicit grants keep the tables usable through the local Data API while RLS
-- remains the authority for each row.
revoke all on table
  public.profiles,
  public.review_cycle,
  public.employee_goal_plan,
  public.kra_category,
  public.goal,
  public.goal_cascade,
  public.goal_alignment,
  public.review_participant,
  public.goal_plan_rating
from anon;

grant select, insert, update, delete on table
  public.profiles,
  public.review_cycle,
  public.employee_goal_plan,
  public.kra_category,
  public.goal,
  public.goal_cascade,
  public.goal_alignment,
  public.review_participant,
  public.goal_plan_rating
to authenticated;

grant all on table
  public.profiles,
  public.review_cycle,
  public.employee_goal_plan,
  public.kra_category,
  public.goal,
  public.goal_cascade,
  public.goal_alignment,
  public.review_participant,
  public.goal_plan_rating
to service_role;

grant usage on type
  public.review_cycle_status,
  public.goal_plan_status,
  public.participant_role,
  public.rating_type
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enable RLS on every Phase 1 table
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.review_cycle enable row level security;
alter table public.employee_goal_plan enable row level security;
alter table public.kra_category enable row level security;
alter table public.goal enable row level security;
alter table public.goal_cascade enable row level security;
alter table public.goal_alignment enable row level security;
alter table public.review_participant enable row level security;
alter table public.goal_plan_rating enable row level security;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

drop policy if exists profiles_select_scoped on public.profiles;
create policy profiles_select_scoped
on public.profiles
for select
to authenticated
using (
  public.is_hr_admin()
  or id = auth.uid()
  or manager_id = auth.uid()
);

drop policy if exists profiles_hr_all on public.profiles;
create policy profiles_hr_all
on public.profiles
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- review_cycle (Ruling 1)
-- ---------------------------------------------------------------------------

drop policy if exists review_cycle_select_scoped on public.review_cycle;
create policy review_cycle_select_scoped
on public.review_cycle
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_review_cycle_participant(id)
);

drop policy if exists review_cycle_hr_all on public.review_cycle;
create policy review_cycle_hr_all
on public.review_cycle
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- employee_goal_plan
-- ---------------------------------------------------------------------------

drop policy if exists employee_goal_plan_select_scoped on public.employee_goal_plan;
create policy employee_goal_plan_select_scoped
on public.employee_goal_plan
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_plan_participant(id)
);

drop policy if exists employee_goal_plan_employee_update on public.employee_goal_plan;
create policy employee_goal_plan_employee_update
on public.employee_goal_plan
for update
to authenticated
using (public.can_edit_goal_plan_as_employee(id))
with check (
  employee_id = auth.uid()
  and status::text in ('draft', 'submitted')
  and public.is_goal_plan_participant(id, array['employee'])
);

drop policy if exists employee_goal_plan_employee_delete on public.employee_goal_plan;
create policy employee_goal_plan_employee_delete
on public.employee_goal_plan
for delete
to authenticated
using (public.can_edit_goal_plan_as_employee(id));

drop policy if exists employee_goal_plan_hr_all on public.employee_goal_plan;
create policy employee_goal_plan_hr_all
on public.employee_goal_plan
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- kra_category
-- ---------------------------------------------------------------------------

drop policy if exists kra_category_select_scoped on public.kra_category;
create policy kra_category_select_scoped
on public.kra_category
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_plan_participant(employee_goal_plan_id)
);

drop policy if exists kra_category_employee_insert on public.kra_category;
create policy kra_category_employee_insert
on public.kra_category
for insert
to authenticated
with check (public.can_edit_goal_plan_as_employee(employee_goal_plan_id));

drop policy if exists kra_category_employee_update on public.kra_category;
create policy kra_category_employee_update
on public.kra_category
for update
to authenticated
using (public.can_edit_goal_plan_as_employee(employee_goal_plan_id))
with check (public.can_edit_goal_plan_as_employee(employee_goal_plan_id));

drop policy if exists kra_category_employee_delete on public.kra_category;
create policy kra_category_employee_delete
on public.kra_category
for delete
to authenticated
using (public.can_edit_goal_plan_as_employee(employee_goal_plan_id));

drop policy if exists kra_category_hr_all on public.kra_category;
create policy kra_category_hr_all
on public.kra_category
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- goal
-- ---------------------------------------------------------------------------

drop policy if exists goal_select_scoped on public.goal;
create policy goal_select_scoped
on public.goal
for select
to authenticated
using (public.can_read_goal(id));

drop policy if exists goal_employee_insert on public.goal;
create policy goal_employee_insert
on public.goal
for insert
to authenticated
with check (public.can_edit_kra_category_as_employee(kra_category_id));

drop policy if exists goal_participant_update on public.goal;
create policy goal_participant_update
on public.goal
for update
to authenticated
using (
  public.can_edit_goal_as_employee(id)
  or public.can_manager_rate_goal(id)
)
with check (
  public.can_edit_kra_category_as_employee(kra_category_id)
  or public.can_manager_rate_goal(id)
);

drop policy if exists goal_employee_delete on public.goal;
create policy goal_employee_delete
on public.goal
for delete
to authenticated
using (public.can_edit_goal_as_employee(id));

drop policy if exists goal_hr_all on public.goal;
create policy goal_hr_all
on public.goal
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- goal_cascade (Ruling 3)
-- ---------------------------------------------------------------------------

drop policy if exists goal_cascade_select_scoped on public.goal_cascade;
create policy goal_cascade_select_scoped
on public.goal_cascade
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_participant(source_goal_id)
  or public.is_goal_participant(cascaded_goal_id)
);

drop policy if exists goal_cascade_insert_target_plan on public.goal_cascade;
create policy goal_cascade_insert_target_plan
on public.goal_cascade
for insert
to authenticated
with check (
  public.is_hr_admin()
  or (
    public.can_write_goal(cascaded_goal_id)
    and public.can_read_goal(source_goal_id)
    and cascaded_by = auth.uid()
  )
);

drop policy if exists goal_cascade_hr_update on public.goal_cascade;
create policy goal_cascade_hr_update
on public.goal_cascade
for update
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

drop policy if exists goal_cascade_hr_delete on public.goal_cascade;
create policy goal_cascade_hr_delete
on public.goal_cascade
for delete
to authenticated
using (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- goal_alignment (Ruling 3)
-- ---------------------------------------------------------------------------

drop policy if exists goal_alignment_select_scoped on public.goal_alignment;
create policy goal_alignment_select_scoped
on public.goal_alignment
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_participant(parent_goal_id)
  or public.is_goal_participant(child_goal_id)
);

drop policy if exists goal_alignment_insert_target_plan on public.goal_alignment;
create policy goal_alignment_insert_target_plan
on public.goal_alignment
for insert
to authenticated
with check (
  public.is_hr_admin()
  or (
    public.can_write_goal(child_goal_id)
    and public.can_read_goal(parent_goal_id)
    and created_by = auth.uid()
  )
);

drop policy if exists goal_alignment_hr_update on public.goal_alignment;
create policy goal_alignment_hr_update
on public.goal_alignment
for update
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

drop policy if exists goal_alignment_hr_delete on public.goal_alignment;
create policy goal_alignment_hr_delete
on public.goal_alignment
for delete
to authenticated
using (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- review_participant
-- ---------------------------------------------------------------------------

drop policy if exists review_participant_select_scoped on public.review_participant;
create policy review_participant_select_scoped
on public.review_participant
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_plan_participant(employee_goal_plan_id)
);

drop policy if exists review_participant_hr_all on public.review_participant;
create policy review_participant_hr_all
on public.review_participant
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- goal_plan_rating
-- ---------------------------------------------------------------------------

drop policy if exists goal_plan_rating_select_scoped on public.goal_plan_rating;
create policy goal_plan_rating_select_scoped
on public.goal_plan_rating
for select
to authenticated
using (
  public.is_hr_admin()
  or public.is_goal_plan_participant(employee_goal_plan_id)
);

drop policy if exists goal_plan_rating_hr_all on public.goal_plan_rating;
create policy goal_plan_rating_hr_all
on public.goal_plan_rating
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- Managers may update only manager_rating and manager_comment on goal rows.
-- updated_at is excluded because the 0001 maintenance trigger changes it.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_manager_goal_updates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.is_hr_admin() then
    return new;
  end if;

  if public.can_manager_rate_goal(old.id) then
    if new.id is distinct from old.id
      or new.kra_category_id is distinct from old.kra_category_id
      or new.title is distinct from old.title
      or new.description is distinct from old.description
      or new.weight is distinct from old.weight
      or new.target_metric is distinct from old.target_metric
      or new.rating_scale_max is distinct from old.rating_scale_max
      or new.self_rating is distinct from old.self_rating
      or new.self_comment is distinct from old.self_comment
      or new.created_at is distinct from old.created_at
    then
      raise exception 'Line managers may update only manager_rating and manager_comment'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_manager_goal_updates() from public;

drop trigger if exists goal_restrict_manager_updates on public.goal;
create trigger goal_restrict_manager_updates
before update on public.goal
for each row
execute function public.restrict_manager_goal_updates();
