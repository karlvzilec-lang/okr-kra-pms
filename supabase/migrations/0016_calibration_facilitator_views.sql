-- 0016_calibration_facilitator_views.sql
-- HR-only facilitator reads, atomic session setup, and the published-plan
-- recalibration guard required by the Gate 1 calibration UI contract.

-- ---------------------------------------------------------------------------
-- Nested session detail for the facilitator board
-- ---------------------------------------------------------------------------

create or replace function public.calibration_session_detail(
  p_session_id uuid
)
returns table (detail jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may view calibration session details'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.calibration_session as cs
    where cs.id = p_session_id
  ) then
    raise exception 'Calibration session % does not exist', p_session_id
      using errcode = 'P0002';
  end if;

  return query
  select jsonb_build_object(
    'session', jsonb_build_object(
      'id', cs.id,
      'name', cs.name,
      'status', cs.status,
      'review_cycle_id', cs.review_cycle_id,
      'review_cycle_name', rc.name,
      'created_at', cs.created_at,
      'updated_at', cs.updated_at
    ),
    'bands', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', cb.id,
            'label', cb.label,
            'min_score', cb.min_score,
            'max_score', cb.max_score,
            'sort_order', cb.sort_order
          )
          order by cb.sort_order, cb.id
        )
        from public.calibration_band as cb
        where cb.calibration_session_id = cs.id
      ),
      '[]'::jsonb
    ),
    'participants', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', participant.id,
            'employee_goal_plan_id', participant.employee_goal_plan_id,
            'employee_id', participant.employee_id,
            'employee_full_name', participant.employee_full_name,
            'employee_email', participant.employee_email,
            'manager_full_name', participant.manager_full_name,
            'original_score', participant.original_score,
            'calibrated_score', participant.calibrated_score,
            'band_id', participant.band_id,
            'facilitator_note', participant.facilitator_note,
            'overall_rating_scale_max', participant.overall_rating_scale_max,
            'published_at', participant.published_at
          )
          order by
            participant.band_sort_order nulls last,
            participant.employee_full_name,
            participant.id
        )
        from (
          select
            cp.id,
            cp.employee_goal_plan_id,
            egp.employee_id,
            employee.full_name as employee_full_name,
            employee.email as employee_email,
            manager.manager_full_name,
            cp.original_score,
            cp.calibrated_score,
            cp.band_id,
            cp.facilitator_note,
            egp.overall_rating_scale_max,
            egp.published_at,
            cb.sort_order as band_sort_order
          from public.calibration_participant as cp
          join public.employee_goal_plan as egp
            on egp.id = cp.employee_goal_plan_id
          join public.profiles as employee
            on employee.id = egp.employee_id
          left join public.calibration_band as cb
            on cb.id = cp.band_id
          left join lateral (
            select manager_profile.full_name as manager_full_name
            from public.review_participant as rp
            join public.profiles as manager_profile
              on manager_profile.id = rp.participant_id
            where rp.employee_goal_plan_id = egp.id
              and rp.role = 'line_manager'::public.participant_role
            order by rp.created_at, rp.id
            limit 1
          ) as manager on true
          where cp.calibration_session_id = cs.id
        ) as participant
      ),
      '[]'::jsonb
    )
  )
  from public.calibration_session as cs
  join public.review_cycle as rc on rc.id = cs.review_cycle_id
  where cs.id = p_session_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Plans that can be added to an existing session
-- ---------------------------------------------------------------------------

create or replace function public.calibration_eligible_plans(
  p_session_id uuid
)
returns table (
  plan_id uuid,
  employee_id uuid,
  employee_full_name text,
  employee_email text,
  manager_score numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_review_cycle_id uuid;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may view calibration-eligible plans'
      using errcode = '42501';
  end if;

  select cs.review_cycle_id
  into v_review_cycle_id
  from public.calibration_session as cs
  where cs.id = p_session_id;

  if not found then
    raise exception 'Calibration session % does not exist', p_session_id
      using errcode = 'P0002';
  end if;

  return query
  select
    egp.id as plan_id,
    egp.employee_id,
    employee.full_name as employee_full_name,
    employee.email as employee_email,
    gpr.overall_score as manager_score
  from public.employee_goal_plan as egp
  join public.profiles as employee on employee.id = egp.employee_id
  join public.goal_plan_rating as gpr
    on gpr.employee_goal_plan_id = egp.id
   and gpr.rating_type = 'manager'::public.rating_type
  where egp.review_cycle_id = v_review_cycle_id
    and egp.published_at is null
    and not exists (
      select 1
      from public.calibration_participant as cp
      where cp.calibration_session_id = p_session_id
        and cp.employee_goal_plan_id = egp.id
    )
  order by employee.full_name, egp.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Atomic session and band creation
-- ---------------------------------------------------------------------------

create or replace function public.create_calibration_session_with_bands(
  p_name text,
  p_review_cycle_id uuid,
  p_bands jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session_id uuid;
  v_band jsonb;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may create calibration sessions'
      using errcode = '42501';
  end if;

  insert into public.calibration_session (name, review_cycle_id)
  values (p_name, p_review_cycle_id)
  returning id into v_session_id;

  for v_band in
    select band.value
    from jsonb_array_elements(p_bands) as band(value)
  loop
    insert into public.calibration_band (
      calibration_session_id,
      label,
      min_score,
      max_score,
      sort_order
    )
    values (
      v_session_id,
      v_band ->> 'label',
      (v_band ->> 'min_score')::numeric,
      (v_band ->> 'max_score')::numeric,
      (v_band ->> 'sort_order')::integer
    );
  end loop;

  return v_session_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Published plans are immutable calibration outputs until an explicit
-- unpublish workflow exists. Keep the 0014 behavior otherwise unchanged.
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
  v_plan_published_at timestamptz;
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
  select egp.review_cycle_id, egp.published_at
  into v_plan_cycle_id, v_plan_published_at
  from public.employee_goal_plan as egp
  where egp.id = p_plan_id
  for update;

  if not found then
    raise exception 'Employee goal plan % does not exist', p_plan_id
      using errcode = 'P0002';
  end if;

  if v_plan_published_at is not null then
    raise exception
      'Published employee goal plan % cannot be recalibrated without an unpublish step',
      p_plan_id
      using errcode = '55000';
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

revoke all on function public.calibration_session_detail(uuid) from public;
revoke all on function public.calibration_eligible_plans(uuid) from public;
revoke all on function public.create_calibration_session_with_bands(text, uuid, jsonb) from public;
revoke all on function public.add_plan_to_calibration_session(uuid, uuid) from public;

grant execute on function public.calibration_session_detail(uuid)
to authenticated, service_role;
grant execute on function public.calibration_eligible_plans(uuid)
to authenticated, service_role;
grant execute on function public.create_calibration_session_with_bands(text, uuid, jsonb)
to authenticated, service_role;
grant execute on function public.add_plan_to_calibration_session(uuid, uuid)
to authenticated, service_role;
