-- 0014_calibration_functions.sql
-- Phase 3 facilitator actions and publish gate. Every public mutation is
-- SECURITY DEFINER and checks the caller's profiles.is_hr_admin flag.

-- ---------------------------------------------------------------------------
-- Shared half-open band matcher: [min_score, max_score)
-- ---------------------------------------------------------------------------

create or replace function public.calibration_band_for_score(
  p_session_id uuid,
  p_score numeric
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_score numeric(6,3);
  v_band_id uuid;
begin
  -- Match the exact value that the numeric(6,3) participant columns store.
  v_score := p_score;

  select cb.id
  into v_band_id
  from public.calibration_band as cb
  where cb.calibration_session_id = p_session_id
    and v_score >= cb.min_score
    and v_score < cb.max_score
  order by cb.sort_order, cb.id
  limit 1;

  if v_band_id is null then
    raise exception
      'No calibration band in session % matches score % using [min_score, max_score)',
      p_session_id,
      v_score
      using errcode = '23514';
  end if;

  return v_band_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Add a manager rating snapshot to an open calibration session
-- ---------------------------------------------------------------------------

create or replace function public.add_plan_to_calibration_session(
  p_session_id uuid,
  p_plan_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session_cycle_id uuid;
  v_session_status public.calibration_session_status;
  v_plan_cycle_id uuid;
  v_manager_score numeric(6,3);
  v_band_id uuid;
  v_participant_id uuid;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may add plans to calibration sessions'
      using errcode = '42501';
  end if;

  select cs.review_cycle_id, cs.status
  into v_session_cycle_id, v_session_status
  from public.calibration_session as cs
  where cs.id = p_session_id
  for update;

  if not found then
    raise exception 'Calibration session % does not exist', p_session_id
      using errcode = 'P0002';
  end if;

  if v_session_status = 'finalized'::public.calibration_session_status then
    raise exception 'Calibration session % is finalized', p_session_id
      using errcode = '55000';
  end if;

  -- The plan lock serializes adding a participant against publishing the same
  -- plan, and the cycle check prevents cross-cycle calibration membership.
  select egp.review_cycle_id
  into v_plan_cycle_id
  from public.employee_goal_plan as egp
  where egp.id = p_plan_id
  for update;

  if not found then
    raise exception 'Employee goal plan % does not exist', p_plan_id
      using errcode = 'P0002';
  end if;

  if v_plan_cycle_id <> v_session_cycle_id then
    raise exception
      'Employee goal plan % and calibration session % belong to different review cycles',
      p_plan_id,
      p_session_id
      using errcode = '23514';
  end if;

  select gpr.overall_score
  into v_manager_score
  from public.goal_plan_rating as gpr
  where gpr.employee_goal_plan_id = p_plan_id
    and gpr.rating_type = 'manager'::public.rating_type;

  if not found then
    raise exception
      'Employee goal plan % has no computed manager rating to calibrate',
      p_plan_id
      using errcode = '23514';
  end if;

  v_band_id := public.calibration_band_for_score(
    p_session_id,
    v_manager_score
  );

  insert into public.calibration_participant (
    calibration_session_id,
    employee_goal_plan_id,
    original_score,
    calibrated_score,
    band_id
  )
  values (
    p_session_id,
    p_plan_id,
    v_manager_score,
    v_manager_score,
    v_band_id
  )
  returning id into v_participant_id;

  return v_participant_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Adjust the calibrated value while preserving the original snapshot
-- ---------------------------------------------------------------------------

create or replace function public.adjust_calibration_participant(
  p_participant_id uuid,
  p_new_score numeric,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session_id uuid;
  v_session_status public.calibration_session_status;
  v_stored_score numeric(6,3);
  v_band_id uuid;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may adjust calibration participants'
      using errcode = '42501';
  end if;

  select cp.calibration_session_id, cs.status
  into v_session_id, v_session_status
  from public.calibration_participant as cp
  join public.calibration_session as cs
    on cs.id = cp.calibration_session_id
  where cp.id = p_participant_id
  for update of cp, cs;

  if not found then
    raise exception 'Calibration participant % does not exist', p_participant_id
      using errcode = 'P0002';
  end if;

  if v_session_status = 'finalized'::public.calibration_session_status then
    raise exception
      'Calibration participant % belongs to a finalized session',
      p_participant_id
      using errcode = '55000';
  end if;

  -- Round before matching so band_id always describes calibrated_score as it
  -- is actually persisted by the numeric(6,3) column.
  v_stored_score := p_new_score;
  v_band_id := public.calibration_band_for_score(
    v_session_id,
    v_stored_score
  );

  update public.calibration_participant
  set calibrated_score = v_stored_score,
      band_id = v_band_id,
      facilitator_note = p_note
  where id = p_participant_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Finalize a session
-- ---------------------------------------------------------------------------

create or replace function public.finalize_calibration_session(
  p_session_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may finalize calibration sessions'
      using errcode = '42501';
  end if;

  update public.calibration_session
  set status = 'finalized'::public.calibration_session_status
  where id = p_session_id;

  if not found then
    raise exception 'Calibration session % does not exist', p_session_id
      using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Publish the employee goal plan
-- ---------------------------------------------------------------------------

create or replace function public.publish_employee_goal_plan(
  p_plan_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_status public.goal_plan_status;
  v_has_calibration boolean;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may publish employee goal plans'
      using errcode = '42501';
  end if;

  select egp.status
  into v_plan_status
  from public.employee_goal_plan as egp
  where egp.id = p_plan_id
  for update;

  if not found then
    raise exception 'Employee goal plan % does not exist', p_plan_id
      using errcode = 'P0002';
  end if;

  select exists (
    select 1
    from public.calibration_participant as cp
    where cp.employee_goal_plan_id = p_plan_id
  )
  into v_has_calibration;

  if v_has_calibration and exists (
    select 1
    from public.calibration_participant as cp
    join public.calibration_session as cs
      on cs.id = cp.calibration_session_id
    where cp.employee_goal_plan_id = p_plan_id
      and cs.status = 'open'::public.calibration_session_status
  ) then
    raise exception
      'Employee goal plan % cannot be published while calibration is open',
      p_plan_id
      using errcode = '55000';
  end if;

  if not v_has_calibration
     and v_plan_status not in (
       'manager_reviewed'::public.goal_plan_status,
       'finalized'::public.goal_plan_status
     ) then
    raise exception
      'Uncalibrated employee goal plan % must be manager_reviewed or finalized before publishing',
      p_plan_id
      using errcode = '55000';
  end if;

  update public.employee_goal_plan
  set published_at = now()
  where id = p_plan_id;
end;
$$;

revoke all on function public.calibration_band_for_score(uuid, numeric) from public;
revoke all on function public.add_plan_to_calibration_session(uuid, uuid) from public;
revoke all on function public.adjust_calibration_participant(uuid, numeric, text) from public;
revoke all on function public.finalize_calibration_session(uuid) from public;
revoke all on function public.publish_employee_goal_plan(uuid) from public;

-- The matcher is an internal implementation detail. SECURITY DEFINER mutation
-- functions execute it as their owner; authenticated callers cannot invoke it.
grant execute on function public.calibration_band_for_score(uuid, numeric)
to service_role;

grant execute on function public.add_plan_to_calibration_session(uuid, uuid)
to authenticated, service_role;
grant execute on function public.adjust_calibration_participant(uuid, numeric, text)
to authenticated, service_role;
grant execute on function public.finalize_calibration_session(uuid)
to authenticated, service_role;
grant execute on function public.publish_employee_goal_plan(uuid)
to authenticated, service_role;
