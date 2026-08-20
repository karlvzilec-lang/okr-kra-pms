-- 0022_calibration_reversal_controls.sql
-- Controlled calibration unpublish/unfinalize workflows, reversal metadata,
-- direct-write guards, band-history protection, and session/band grant tightening.

-- ---------------------------------------------------------------------------
-- Latest-reversal metadata. These triples are snapshots, not audit logs.
-- ---------------------------------------------------------------------------

alter table public.calibration_session
  add column last_unfinalized_at timestamptz,
  add column last_unfinalized_by uuid references public.profiles (id),
  add column last_unfinalize_reason text,
  add constraint calibration_session_unfinalize_metadata_complete check (
    (
      last_unfinalized_at is null
      and last_unfinalized_by is null
      and last_unfinalize_reason is null
    )
    or
    (
      last_unfinalized_at is not null
      and last_unfinalized_by is not null
      and last_unfinalize_reason is not null
    )
  );

alter table public.employee_goal_plan
  add column last_unpublished_at timestamptz,
  add column last_unpublished_by uuid references public.profiles (id),
  add column last_unpublish_reason text,
  add constraint employee_goal_plan_unpublish_metadata_complete check (
    (
      last_unpublished_at is null
      and last_unpublished_by is null
      and last_unpublish_reason is null
    )
    or
    (
      last_unpublished_at is not null
      and last_unpublished_by is not null
      and last_unpublish_reason is not null
    )
  );

-- ---------------------------------------------------------------------------
-- One-time authorization tokens for guarded reversal UPDATEs.
--
-- A GUC by itself is caller-settable. The SECURITY DEFINER functions register
-- each random token here for one transaction/backend/action/target, then the
-- corresponding trigger consumes it. No API role can inspect or write this
-- schema, so setting the same GUC name to a guessed value cannot authorize a
-- raw UPDATE.
-- ---------------------------------------------------------------------------

create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;

create table private.calibration_reversal_token (
  backend_pid integer not null,
  transaction_id bigint not null,
  action text not null,
  target_id uuid not null,
  token uuid not null,
  primary key (backend_pid, transaction_id, action, target_id, token),
  constraint calibration_reversal_token_action check (
    action in ('unfinalize', 'unpublish')
  )
);

revoke all on table private.calibration_reversal_token
from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Session state transitions. No role bypasses this trigger.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_calibration_session_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_text text;
  v_token uuid;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'open'::public.calibration_session_status then
      raise exception 'Calibration sessions must be created with open status'
        using errcode = '55000';
    end if;
    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'open'::public.calibration_session_status
     and new.status = 'finalized'::public.calibration_session_status then
    return new;
  end if;

  if old.status = 'finalized'::public.calibration_session_status
     and new.status = 'open'::public.calibration_session_status then
    v_token_text := nullif(
      current_setting('app.calibration_unfinalize_token', true),
      ''
    );

    begin
      v_token := v_token_text::uuid;
    exception
      when invalid_text_representation then
        v_token := null;
    end;

    if v_token is not null then
      delete from private.calibration_reversal_token as token
      where token.backend_pid = pg_backend_pid()
        and token.transaction_id = txid_current()
        and token.action = 'unfinalize'
        and token.target_id = old.id
        and token.token = v_token;

      if found then
        return new;
      end if;
    end if;

    raise exception
      'Finalized calibration session % can only be reopened through unfinalize_calibration_session',
      old.id
      using errcode = '55000';
  end if;

  raise exception 'Invalid calibration session status transition from % to %',
    old.status,
    new.status
    using errcode = '55000';
end;
$$;

revoke all on function public.restrict_calibration_session_status_transition()
from public;

drop trigger if exists calibration_session_restrict_status_transition
  on public.calibration_session;
create trigger calibration_session_restrict_status_transition
before insert or update on public.calibration_session
for each row
execute function public.restrict_calibration_session_status_transition();

-- ---------------------------------------------------------------------------
-- Published-plan reversal guard. The controlled function supplies a one-time
-- token; direct not-null -> null updates fail for every role.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_employee_goal_plan_published_reversal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_text text;
  v_token uuid;
begin
  if old.published_at is not null and new.published_at is null then
    v_token_text := nullif(
      current_setting('app.calibration_unpublish_token', true),
      ''
    );

    begin
      v_token := v_token_text::uuid;
    exception
      when invalid_text_representation then
        v_token := null;
    end;

    if v_token is not null then
      delete from private.calibration_reversal_token as token
      where token.backend_pid = pg_backend_pid()
        and token.transaction_id = txid_current()
        and token.action = 'unpublish'
        and token.target_id = old.id
        and token.token = v_token;

      if found then
        return new;
      end if;
    end if;

    raise exception
      'Published employee goal plan % can only be unpublished through unpublish_employee_goal_plan',
      old.id
      using errcode = '55000';
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_employee_goal_plan_published_reversal()
from public;

drop trigger if exists employee_goal_plan_restrict_published_reversal
  on public.employee_goal_plan;
create trigger employee_goal_plan_restrict_published_reversal
before update on public.employee_goal_plan
for each row
execute function public.restrict_employee_goal_plan_published_reversal();

-- ---------------------------------------------------------------------------
-- A band referenced by any participant is historical calibration data and
-- cannot be deleted, regardless of session status or caller role.
-- ---------------------------------------------------------------------------

create or replace function public.reject_assigned_calibration_band_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.calibration_participant as cp
    where cp.band_id = old.id
  ) then
    raise exception
      'Calibration band % cannot be deleted while calibration participants reference it',
      old.id
      using errcode = '55000';
  end if;

  return old;
end;
$$;

revoke all on function public.reject_assigned_calibration_band_delete()
from public;

drop trigger if exists calibration_band_reject_assigned_delete
  on public.calibration_band;
create trigger calibration_band_reject_assigned_delete
before delete on public.calibration_band
for each row
execute function public.reject_assigned_calibration_band_delete();

-- ---------------------------------------------------------------------------
-- Employee and manager plan UPDATE scopes must also protect the three new
-- metadata columns. published_at remains protected as it was in 0017.
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
      or new.last_unpublished_at is distinct from old.last_unpublished_at
      or new.last_unpublished_by is distinct from old.last_unpublished_by
      or new.last_unpublish_reason is distinct from old.last_unpublish_reason
    then
      raise exception 'Employees may update only employee goal plan status'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

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
      or new.last_unpublished_at is distinct from old.last_unpublished_at
      or new.last_unpublished_by is distinct from old.last_unpublished_by
      or new.last_unpublish_reason is distinct from old.last_unpublish_reason
    then
      raise exception 'Line managers may only transition submitted plans to manager_reviewed'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Adjustments require both an open session and an unpublished plan.
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
  v_published_at timestamptz;
  v_stored_score numeric(6,3);
  v_band_id uuid;
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may adjust calibration participants'
      using errcode = '42501';
  end if;

  select cp.calibration_session_id, cs.status, egp.published_at
  into v_session_id, v_session_status, v_published_at
  from public.calibration_participant as cp
  join public.calibration_session as cs
    on cs.id = cp.calibration_session_id
  join public.employee_goal_plan as egp
    on egp.id = cp.employee_goal_plan_id
  where cp.id = p_participant_id
  for update of cp, cs, egp;

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

  if v_published_at is not null then
    raise exception
      'Published calibration participant % must be unpublished before adjustment',
      p_participant_id
      using errcode = '55000';
  end if;

  v_stored_score := p_new_score;
  v_band_id := public.calibration_band_for_score(v_session_id, v_stored_score);

  update public.calibration_participant
  set calibrated_score = v_stored_score,
      band_id = v_band_id,
      facilitator_note = p_note
  where id = p_participant_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Publish locks every related session before locking the plan. This matches
-- unfinalize's session-first ordering, so their precondition checks serialize
-- instead of both observing stale state.
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

  perform cs.id
  from public.calibration_session as cs
  join public.calibration_participant as cp
    on cp.calibration_session_id = cs.id
  where cp.employee_goal_plan_id = p_plan_id
  order by cs.id
  for update of cs;

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
  ) into v_has_calibration;

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

-- ---------------------------------------------------------------------------
-- Controlled plan unpublish. Calibration values and session state are left
-- untouched; only publication visibility and latest-reversal metadata change.
-- ---------------------------------------------------------------------------

create or replace function public.unpublish_employee_goal_plan(
  p_plan_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_published_at timestamptz;
  v_token uuid := gen_random_uuid();
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may unpublish employee goal plans'
      using errcode = '42501';
  end if;

  if p_reason is null or char_length(btrim(p_reason)) < 10 then
    raise exception 'Unpublish reason must contain at least 10 non-blank characters'
      using errcode = '23514';
  end if;

  select egp.published_at
  into v_published_at
  from public.employee_goal_plan as egp
  where egp.id = p_plan_id
  for update;

  if not found then
    raise exception 'Employee goal plan % does not exist', p_plan_id
      using errcode = 'P0002';
  end if;

  if v_published_at is null then
    raise exception 'Employee goal plan % is not published', p_plan_id
      using errcode = '55000';
  end if;

  insert into private.calibration_reversal_token (
    backend_pid, transaction_id, action, target_id, token
  ) values (
    pg_backend_pid(), txid_current(), 'unpublish', p_plan_id, v_token
  );

  perform set_config('app.calibration_unpublish_token', v_token::text, true);
  update public.employee_goal_plan
  set published_at = null,
      last_unpublished_at = now(),
      last_unpublished_by = auth.uid(),
      last_unpublish_reason = btrim(p_reason)
  where id = p_plan_id;

  perform set_config('app.calibration_unpublish_token', '', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Controlled session unfinalize. A session-first row lock serializes this
-- participant publication check against publish_employee_goal_plan.
-- ---------------------------------------------------------------------------

create or replace function public.unfinalize_calibration_session(
  p_session_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.calibration_session_status;
  v_published_count integer;
  v_token uuid := gen_random_uuid();
begin
  if not public.is_hr_admin() then
    raise exception 'Only HR admins may unfinalize calibration sessions'
      using errcode = '42501';
  end if;

  if p_reason is null or char_length(btrim(p_reason)) < 10 then
    raise exception 'Unfinalize reason must contain at least 10 non-blank characters'
      using errcode = '23514';
  end if;

  select cs.status
  into v_status
  from public.calibration_session as cs
  where cs.id = p_session_id
  for update;

  if not found then
    raise exception 'Calibration session % does not exist', p_session_id
      using errcode = 'P0002';
  end if;

  if v_status <> 'finalized'::public.calibration_session_status then
    raise exception 'Calibration session % is not finalized', p_session_id
      using errcode = '55000';
  end if;

  select count(*)
  into v_published_count
  from public.calibration_participant as cp
  join public.employee_goal_plan as egp
    on egp.id = cp.employee_goal_plan_id
  where cp.calibration_session_id = p_session_id
    and egp.published_at is not null;

  if v_published_count > 0 then
    raise exception
      'Calibration session % cannot be unfinalized while % published participant(s) remain',
      p_session_id,
      v_published_count
      using errcode = '55000';
  end if;

  insert into private.calibration_reversal_token (
    backend_pid, transaction_id, action, target_id, token
  ) values (
    pg_backend_pid(), txid_current(), 'unfinalize', p_session_id, v_token
  );

  perform set_config('app.calibration_unfinalize_token', v_token::text, true);
  update public.calibration_session
  set status = 'open'::public.calibration_session_status,
      last_unfinalized_at = now(),
      last_unfinalized_by = auth.uid(),
      last_unfinalize_reason = btrim(p_reason)
  where id = p_session_id;

  perform set_config('app.calibration_unfinalize_token', '', true);
end;
$$;

revoke all on function public.unpublish_employee_goal_plan(uuid, text)
from public;
revoke all on function public.unfinalize_calibration_session(uuid, text)
from public;

grant execute on function public.unpublish_employee_goal_plan(uuid, text)
to authenticated, service_role;
grant execute on function public.unfinalize_calibration_session(uuid, text)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Facilitator detail now emits all six latest-reversal fields explicitly.
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
      'last_unfinalized_at', cs.last_unfinalized_at,
      'last_unfinalized_by', cs.last_unfinalized_by,
      'last_unfinalize_reason', cs.last_unfinalize_reason,
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
            'published_at', participant.published_at,
            'last_unpublished_at', participant.last_unpublished_at,
            'last_unpublished_by', participant.last_unpublished_by,
            'last_unpublish_reason', participant.last_unpublish_reason
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
            egp.last_unpublished_at,
            egp.last_unpublished_by,
            egp.last_unpublish_reason,
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
-- Session/band reads stay scoped; all authenticated direct writes are removed.
-- SECURITY DEFINER RPCs remain the supported mutation boundary.
-- ---------------------------------------------------------------------------

drop policy if exists calibration_session_hr_all
  on public.calibration_session;
drop policy if exists calibration_band_hr_all
  on public.calibration_band;

revoke insert, update, delete on table
  public.calibration_session,
  public.calibration_band
from authenticated;

