-- 0023_audit_log.sql
-- Round 9: a generic, append-only audit log for the five sensitive write paths
-- this app has that are not already self-documenting.
--
-- Design decisions here are Gate 1 rulings, not preferences:
--   1. The two calibration-reversal events are captured by AFTER UPDATE
--      triggers that READ the 0022 snapshot columns. Zero lines of 0022 change.
--      0022 already revoked every other write path to those two transitions, so
--      a trigger is not weaker than an in-function insert here.
--   2. old_values/new_values are jsonb, not a text pair: two of the six event
--      types are genuinely multi-field. The human-readable column is `summary`.
--   3. actor_id is NULLABLE with a not-null actor_name fallback literal. A gap
--      in the audit layer must never block the underlying HR action.
--   4. An immutability trigger sits ON TOP OF the revoked grants and the absent
--      RLS write policies -- defence in depth, matching 0022's private-schema
--      token layered over RLS.
--   5. target_type/target_id/target_label, no separate subject pair.
--   6. Ordering is (occurred_at desc, id desc) in the index, in every query,
--      and in the frontend, matching web/lib/pagination.ts's tiebreaker rule.
--
-- Scope deliberately excluded (both plans agreed, ruling confirmed): check-ins
-- (already append-only), rating edits (routine, already evidenced by
-- calibration_participant), goal cascade/alignment creation (already carries
-- created_by, and there is no unlink UI to audit).
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Event vocabulary. An enum, not free text: the frontend renders one label per
-- value and a typo in a trigger would otherwise ship a silently unrenderable
-- row. Adding a value later is an `alter type ... add value`, which is the
-- correct amount of friction for changing what this table promises.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'audit_event_type') then
    create type audit_event_type as enum (
      'profile.manager_changed',
      'profile.hr_admin_changed',
      'matrix_scope.granted',
      'matrix_scope.revoked',
      'calibration.plan_unpublished',
      'calibration.session_unfinalized'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- audit_log
--
-- actor_name/target_label are denormalised on purpose. This table is history:
-- if someone is later renamed, the log must still read the way it read when the
-- event happened. Joining live to profiles would silently rewrite the past.
-- ---------------------------------------------------------------------------

create table if not exists public.audit_log (
  id           uuid primary key default gen_random_uuid(),
  -- clock_timestamp(), NOT now(). now() is the TRANSACTION start time, so every
  -- event written in one transaction would share a timestamp exactly, and since
  -- id is a random uuid the tiebreaker below would then order them arbitrarily
  -- rather than chronologically. Two reversals of the same plan in one request,
  -- or a manager change and an HR-admin change from one form submit, must read
  -- back in the order they happened.
  occurred_at  timestamptz not null default clock_timestamp(),
  event_type   audit_event_type not null,

  -- Nullable per ruling point 3. actor_name always renders something.
  actor_id     uuid references public.profiles (id) on delete restrict,
  actor_name   text not null,

  target_type  text not null,
  target_id    uuid,
  target_label text not null,

  summary      text not null,

  old_values   jsonb not null default '{}'::jsonb,
  new_values   jsonb not null default '{}'::jsonb,

  constraint audit_log_actor_name_not_blank
    check (char_length(btrim(actor_name)) > 0),
  constraint audit_log_target_type_not_blank
    check (char_length(btrim(target_type)) > 0),
  constraint audit_log_target_label_not_blank
    check (char_length(btrim(target_label)) > 0),
  constraint audit_log_summary_not_blank
    check (char_length(btrim(summary)) > 0),
  constraint audit_log_old_values_is_object
    check (jsonb_typeof(old_values) = 'object'),
  constraint audit_log_new_values_is_object
    check (jsonb_typeof(new_values) = 'object')
);

comment on table public.audit_log is
  'Append-only history of sensitive administrative writes. No UPDATE or DELETE '
  'path exists for any role: no RLS write policy, no write grant, and '
  'audit_log_reject_mutation raises on any attempt.';

-- The ledger's only read pattern is newest-first, paged. id desc is the
-- tiebreaker for rows sharing an occurred_at (same statement, same now()),
-- matching web/lib/pagination.ts's convention. Direction must match the
-- frontend ORDER BY exactly or paging silently skips rows.
create index if not exists audit_log_occurred_at_idx
  on public.audit_log (occurred_at desc, id desc);

create index if not exists audit_log_event_type_idx
  on public.audit_log (event_type, occurred_at desc, id desc);

create index if not exists audit_log_target_idx
  on public.audit_log (target_type, target_id);

-- ---------------------------------------------------------------------------
-- RLS: exactly one SELECT policy, gated on is_hr_admin(). No INSERT/UPDATE/
-- DELETE policy for any role, and no blanket `for all` -- deliberately NOT the
-- older permissive pattern some earlier migrations used.
--
-- Writes reach this table only through the SECURITY DEFINER trigger functions
-- below, which run as the table owner and are exempt from RLS.
-- ---------------------------------------------------------------------------

alter table public.audit_log enable row level security;

revoke all on table public.audit_log from public, anon, authenticated, service_role;

-- service_role gets SELECT only, same as authenticated: a leaked service key
-- must not be able to erase history.
grant select on table public.audit_log to authenticated, service_role;

drop policy if exists audit_log_select_hr on public.audit_log;
create policy audit_log_select_hr
on public.audit_log
for select
to authenticated, service_role
using (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- Immutability (ruling point 4). RLS and grants are privilege checks; the
-- table owner and any future SECURITY DEFINER function bypass both. A table
-- whose entire purpose is being un-rewritable should not depend on privilege
-- grants never having a bug.
-- ---------------------------------------------------------------------------

create or replace function public.reject_audit_log_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'audit_log is append-only: % on audit log row % is not permitted',
    tg_op,
    coalesce(old.id::text, '<unknown>')
    using errcode = '55000';
end;
$$;

revoke all on function public.reject_audit_log_mutation() from public;

drop trigger if exists audit_log_reject_mutation on public.audit_log;
create trigger audit_log_reject_mutation
before update or delete on public.audit_log
for each row
execute function public.reject_audit_log_mutation();

-- ---------------------------------------------------------------------------
-- Shared writer. Every trigger below funnels through this so the actor
-- fallback rule (ruling point 3) is implemented exactly once.
--
-- Not exposed to any API role: no grant is issued, and `revoke all from public`
-- removes the default. Only the trigger functions (owner-run) can call it.
-- ---------------------------------------------------------------------------

create or replace function public.record_audit_event(
  p_event_type   audit_event_type,
  p_target_type  text,
  p_target_id    uuid,
  p_target_label text,
  p_summary      text,
  p_old_values   jsonb default '{}'::jsonb,
  p_new_values   jsonb default '{}'::jsonb,
  p_actor_id     uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed_id uuid := coalesce(p_actor_id, auth.uid());
  v_actor_id   uuid;
  v_actor_name text;
begin
  -- Name is snapshotted, never joined at read time.
  --
  -- The lookup also decides whether actor_id is stored at all. actor_id carries
  -- an FK to profiles, so writing a uuid with no profile row would raise a
  -- foreign_key_violation and take the underlying HR action down with it --
  -- precisely the coupling ruling point 3 rejects. A claim we cannot resolve is
  -- therefore recorded as the fallback name with a null actor_id, which is
  -- visible in the UI rather than fatal.
  if v_claimed_id is not null then
    select p.id, p.full_name
    into v_actor_id, v_actor_name
    from public.profiles as p
    where p.id = v_claimed_id;
  end if;

  -- Two distinct null cases collapse to one visible literal: no JWT claim at
  -- all (service role, migration, seed), and a claim whose profile row is
  -- missing. Either way the UI renders text rather than a blank cell, and the
  -- underlying HR write is never blocked.
  if v_actor_name is null or char_length(btrim(v_actor_name)) = 0 then
    v_actor_name := 'system (service role)';
  end if;

  insert into public.audit_log (
    event_type, actor_id, actor_name,
    target_type, target_id, target_label,
    summary, old_values, new_values
  )
  values (
    p_event_type, v_actor_id, v_actor_name,
    p_target_type, p_target_id, p_target_label,
    p_summary,
    coalesce(p_old_values, '{}'::jsonb),
    coalesce(p_new_values, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.record_audit_event(
  audit_event_type, text, uuid, text, text, jsonb, jsonb, uuid
) from public;

-- Small helper: a profile's display name at this instant, or an explicit
-- '(none)' for an unset manager. Keeps the payloads readable in psql.
create or replace function public.audit_profile_label(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.full_name from public.profiles as p where p.id = p_profile_id),
    case when p_profile_id is null then '(none)' else '(deleted profile)' end
  );
$$;

revoke all on function public.audit_profile_label(uuid) from public;

-- ---------------------------------------------------------------------------
-- Trigger 1 + 2: profiles.manager_id and profiles.is_hr_admin.
--
-- Two INDEPENDENT events from one UPDATE when both change. Collapsing them
-- into a single row would make "who was ever granted HR admin" unanswerable by
-- an event_type filter, which is the primary question this table exists for.
--
-- A change to any other profiles column (full_name, email, updated_at) emits
-- ZERO rows -- pinned by a negative assertion in verify.sql.
-- ---------------------------------------------------------------------------

create or replace function public.audit_profile_sensitive_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject_label text := coalesce(new.full_name, '(unnamed profile)');
begin
  if new.manager_id is distinct from old.manager_id then
    perform public.record_audit_event(
      'profile.manager_changed'::public.audit_event_type,
      'profile',
      new.id,
      v_subject_label,
      format(
        '%s: line manager changed from %s to %s',
        v_subject_label,
        public.audit_profile_label(old.manager_id),
        public.audit_profile_label(new.manager_id)
      ),
      jsonb_build_object(
        'manager_id', old.manager_id,
        'manager_name', public.audit_profile_label(old.manager_id)
      ),
      jsonb_build_object(
        'manager_id', new.manager_id,
        'manager_name', public.audit_profile_label(new.manager_id)
      )
    );
  end if;

  if new.is_hr_admin is distinct from old.is_hr_admin then
    perform public.record_audit_event(
      'profile.hr_admin_changed'::public.audit_event_type,
      'profile',
      new.id,
      v_subject_label,
      format(
        '%s: HR admin access %s',
        v_subject_label,
        case when new.is_hr_admin then 'granted' else 'revoked' end
      ),
      jsonb_build_object('is_hr_admin', old.is_hr_admin),
      jsonb_build_object('is_hr_admin', new.is_hr_admin)
    );
  end if;

  return null;
end;
$$;

revoke all on function public.audit_profile_sensitive_changes() from public;

drop trigger if exists profiles_audit_sensitive_changes on public.profiles;
create trigger profiles_audit_sensitive_changes
after update on public.profiles
for each row
when (
  old.manager_id is distinct from new.manager_id
  or old.is_hr_admin is distinct from new.is_hr_admin
)
execute function public.audit_profile_sensitive_changes();

-- ---------------------------------------------------------------------------
-- Trigger 3 + 4: review_participant_scope INSERT and DELETE.
--
-- Grant/revoke symmetry is the specific gap the brutal-QA round found: a grant
-- leaves a visible row, a revoke leaves nothing at all. Both are audited.
--
-- scope_id is polymorphic (kra_category.id or objective.id, validated by
-- 0007's trigger, deliberately no FK), so the label is resolved per scope_type.
-- On DELETE the referenced rows may already be gone via cascade, hence the
-- coalesce fallbacks -- the audit row must still be written.
-- ---------------------------------------------------------------------------

create or replace function public.audit_review_participant_scope_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row             public.review_participant_scope;
  v_event           public.audit_event_type;
  v_verb            text;
  v_scope_label     text;
  v_manager_id      uuid;
  v_manager_name    text;
  v_employee_id     uuid;
  v_employee_name   text;
  v_plan_id         uuid;
  v_cycle_id        uuid;
  v_cycle_name      text;
  v_payload         jsonb;
begin
  if tg_op = 'INSERT' then
    v_row   := new;
    v_event := 'matrix_scope.granted'::public.audit_event_type;
    v_verb  := 'granted';
  else
    v_row   := old;
    v_event := 'matrix_scope.revoked'::public.audit_event_type;
    v_verb  := 'revoked';
  end if;

  if v_row.scope_type = 'kra_category'::public.scope_type then
    select kc.name into v_scope_label
    from public.kra_category as kc
    where kc.id = v_row.scope_id;
  elsif v_row.scope_type = 'objective'::public.scope_type then
    select o.title into v_scope_label
    from public.objective as o
    where o.id = v_row.scope_id;
  end if;

  v_scope_label := coalesce(v_scope_label, '(removed scope target)');

  select
    rp.participant_id,
    manager_profile.full_name,
    egp.id,
    egp.employee_id,
    employee_profile.full_name,
    egp.review_cycle_id,
    rc.name
  into
    v_manager_id, v_manager_name,
    v_plan_id, v_employee_id, v_employee_name,
    v_cycle_id, v_cycle_name
  from public.review_participant as rp
  join public.employee_goal_plan as egp
    on egp.id = rp.employee_goal_plan_id
  join public.profiles as employee_profile
    on employee_profile.id = egp.employee_id
  join public.review_cycle as rc
    on rc.id = egp.review_cycle_id
  left join public.profiles as manager_profile
    on manager_profile.id = rp.participant_id
  where rp.id = v_row.review_participant_id;

  v_manager_name  := coalesce(v_manager_name, '(removed participant)');
  v_employee_name := coalesce(v_employee_name, '(removed employee)');

  -- Genuinely multi-field: this is the payload shape that ruled out a single
  -- old_value/new_value text pair.
  v_payload := jsonb_build_object(
    'review_participant_id', v_row.review_participant_id,
    'matrix_manager_id',     v_manager_id,
    'matrix_manager_name',   v_manager_name,
    'employee_goal_plan_id', v_plan_id,
    'employee_id',           v_employee_id,
    'employee_name',         v_employee_name,
    'review_cycle_id',       v_cycle_id,
    'review_cycle_name',     coalesce(v_cycle_name, '(removed cycle)'),
    'scope_type',            v_row.scope_type,
    'scope_id',              v_row.scope_id,
    'scope_label',           v_scope_label
  );

  perform public.record_audit_event(
    v_event,
    'review_participant_scope',
    v_row.id,
    format('%s on %s', v_scope_label, v_employee_name),
    format(
      'Matrix scope %s: %s %s %s on %s''s plan (%s)',
      v_verb,
      v_manager_name,
      case when v_verb = 'granted' then 'granted access to' else 'lost access to' end,
      v_scope_label,
      v_employee_name,
      coalesce(v_cycle_name, '(removed cycle)')
    ),
    case when tg_op = 'DELETE' then v_payload else '{}'::jsonb end,
    case when tg_op = 'INSERT' then v_payload else '{}'::jsonb end
  );

  return null;
end;
$$;

revoke all on function public.audit_review_participant_scope_change() from public;

drop trigger if exists review_participant_scope_audit_change
  on public.review_participant_scope;
create trigger review_participant_scope_audit_change
after insert or delete on public.review_participant_scope
for each row
execute function public.audit_review_participant_scope_change();

-- ---------------------------------------------------------------------------
-- Trigger 5: employee_goal_plan unpublish (published_at not null -> null).
--
-- Ruling point 1: this is an AFTER UPDATE trigger that READS 0022's
-- last_unpublished_by/at/reason snapshot columns. 0022 is not modified in any
-- way. Because 0022's BEFORE UPDATE guard already rejects this transition
-- unless it came through unpublish_employee_goal_plan (one-time token in a
-- private schema no API role can touch), by the time this AFTER trigger runs
-- the snapshot triple is guaranteed populated by that function.
--
-- The point of this row: the 0022 columns hold only the LATEST reversal.
-- Two successive unpublishes overwrite the first. This table keeps both --
-- pinned by the two-reversals-two-rows regression assertion in verify.sql,
-- which is this round's actual reason to exist.
--
-- Actor comes from last_unpublished_by, not auth.uid(): it is the value the
-- controlled function already captured for this exact transition, so the audit
-- row cannot disagree with the snapshot it is derived from.
-- ---------------------------------------------------------------------------

create or replace function public.audit_employee_goal_plan_unpublish()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_employee_name text;
  v_cycle_name    text;
begin
  select employee_profile.full_name, rc.name
  into v_employee_name, v_cycle_name
  from public.profiles as employee_profile
  join public.review_cycle as rc on rc.id = new.review_cycle_id
  where employee_profile.id = new.employee_id;

  v_employee_name := coalesce(v_employee_name, '(unknown employee)');
  v_cycle_name    := coalesce(v_cycle_name, '(unknown cycle)');

  perform public.record_audit_event(
    'calibration.plan_unpublished'::public.audit_event_type,
    'employee_goal_plan',
    new.id,
    format('%s - %s', v_employee_name, v_cycle_name),
    format(
      'Published goal plan for %s (%s) was unpublished. Reason: %s',
      v_employee_name,
      v_cycle_name,
      coalesce(new.last_unpublish_reason, '(no reason recorded)')
    ),
    jsonb_build_object(
      'published_at', old.published_at,
      'employee_id',  new.employee_id,
      'review_cycle_id', new.review_cycle_id
    ),
    jsonb_build_object(
      'published_at',        null,
      'last_unpublished_at', new.last_unpublished_at,
      'last_unpublished_by', new.last_unpublished_by,
      'last_unpublish_reason', new.last_unpublish_reason,
      'employee_id',         new.employee_id,
      'review_cycle_id',     new.review_cycle_id
    ),
    new.last_unpublished_by
  );

  return null;
end;
$$;

revoke all on function public.audit_employee_goal_plan_unpublish() from public;

drop trigger if exists employee_goal_plan_audit_unpublish
  on public.employee_goal_plan;
create trigger employee_goal_plan_audit_unpublish
after update on public.employee_goal_plan
for each row
when (old.published_at is not null and new.published_at is null)
execute function public.audit_employee_goal_plan_unpublish();

-- ---------------------------------------------------------------------------
-- Trigger 6: calibration_session unfinalize (finalized -> open).
-- Same construction and same reasoning as trigger 5, against
-- last_unfinalized_by/at/reason.
-- ---------------------------------------------------------------------------

create or replace function public.audit_calibration_session_unfinalize()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle_name text;
begin
  select rc.name
  into v_cycle_name
  from public.review_cycle as rc
  where rc.id = new.review_cycle_id;

  v_cycle_name := coalesce(v_cycle_name, '(unknown cycle)');

  perform public.record_audit_event(
    'calibration.session_unfinalized'::public.audit_event_type,
    'calibration_session',
    new.id,
    new.name,
    format(
      'Finalized calibration session "%s" (%s) was reopened. Reason: %s',
      new.name,
      v_cycle_name,
      coalesce(new.last_unfinalize_reason, '(no reason recorded)')
    ),
    jsonb_build_object(
      'status',          old.status,
      'review_cycle_id', new.review_cycle_id
    ),
    jsonb_build_object(
      'status',                 new.status,
      'last_unfinalized_at',    new.last_unfinalized_at,
      'last_unfinalized_by',    new.last_unfinalized_by,
      'last_unfinalize_reason', new.last_unfinalize_reason,
      'review_cycle_id',        new.review_cycle_id
    ),
    new.last_unfinalized_by
  );

  return null;
end;
$$;

revoke all on function public.audit_calibration_session_unfinalize() from public;

drop trigger if exists calibration_session_audit_unfinalize
  on public.calibration_session;
create trigger calibration_session_audit_unfinalize
after update on public.calibration_session
for each row
when (
  old.status = 'finalized'::public.calibration_session_status
  and new.status = 'open'::public.calibration_session_status
)
execute function public.audit_calibration_session_unfinalize();
