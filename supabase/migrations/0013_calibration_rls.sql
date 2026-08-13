-- 0013_calibration_rls.sql
-- Phase 3 calibration read scopes, table grants, and row-level security.
-- Calibration writes are facilitated: HR may administer sessions and bands
-- directly, while participant changes only go through the SECURITY DEFINER
-- functions in 0014.

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER read-scope helpers
-- ---------------------------------------------------------------------------

-- A line manager can read only a participant row attached to a plan on which
-- that caller is the explicit line_manager review participant.
create or replace function public.can_read_calibration_participant(
  p_calibration_participant_id uuid
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
      from public.calibration_participant as cp
      join public.employee_goal_plan as egp
        on egp.id = cp.employee_goal_plan_id
      join public.review_participant as rp
        on rp.employee_goal_plan_id = egp.id
      where cp.id = p_calibration_participant_id
        and rp.participant_id = auth.uid()
        and rp.role::text = 'line_manager'
    );
$$;

-- Session and band context is visible to a line manager only when the session
-- contains at least one plan for which that caller is the line manager.
create or replace function public.can_read_calibration_session(
  p_calibration_session_id uuid
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
      from public.calibration_participant as cp
      join public.employee_goal_plan as egp
        on egp.id = cp.employee_goal_plan_id
      join public.review_participant as rp
        on rp.employee_goal_plan_id = egp.id
      where cp.calibration_session_id = p_calibration_session_id
        and rp.participant_id = auth.uid()
        and rp.role::text = 'line_manager'
    );
$$;

revoke all on function public.can_read_calibration_participant(uuid) from public;
revoke all on function public.can_read_calibration_session(uuid) from public;

grant execute on function public.can_read_calibration_participant(uuid)
to authenticated, service_role;
grant execute on function public.can_read_calibration_session(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Table grants
-- ---------------------------------------------------------------------------

revoke all on table
  public.calibration_session,
  public.calibration_band,
  public.calibration_participant
from anon;

grant select, insert, update, delete on table
  public.calibration_session,
  public.calibration_band
to authenticated;

-- No direct participant writes for authenticated callers, including HR.
-- The 0014 facilitator functions own the only supported mutation path.
grant select on table public.calibration_participant to authenticated;

grant all on table
  public.calibration_session,
  public.calibration_band,
  public.calibration_participant
to service_role;

-- ---------------------------------------------------------------------------
-- Enable RLS
-- ---------------------------------------------------------------------------

alter table public.calibration_session enable row level security;
alter table public.calibration_band enable row level security;
alter table public.calibration_participant enable row level security;

-- ---------------------------------------------------------------------------
-- calibration_session
-- ---------------------------------------------------------------------------

drop policy if exists calibration_session_select_scoped
  on public.calibration_session;
create policy calibration_session_select_scoped
on public.calibration_session
for select
to authenticated
using (public.can_read_calibration_session(id));

drop policy if exists calibration_session_hr_all
  on public.calibration_session;
create policy calibration_session_hr_all
on public.calibration_session
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- calibration_band
-- ---------------------------------------------------------------------------

drop policy if exists calibration_band_select_scoped
  on public.calibration_band;
create policy calibration_band_select_scoped
on public.calibration_band
for select
to authenticated
using (public.can_read_calibration_session(calibration_session_id));

drop policy if exists calibration_band_hr_all
  on public.calibration_band;
create policy calibration_band_hr_all
on public.calibration_band
for all
to authenticated
using (public.is_hr_admin())
with check (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- calibration_participant
-- ---------------------------------------------------------------------------

drop policy if exists calibration_participant_select_scoped
  on public.calibration_participant;
create policy calibration_participant_select_scoped
on public.calibration_participant
for select
to authenticated
using (public.can_read_calibration_participant(id));

-- Deliberately no INSERT/UPDATE/DELETE policy on calibration_participant.
-- HR mutations go through 0014's SECURITY DEFINER functions, and line managers
-- have read-only access to the rows for their exact reports.
