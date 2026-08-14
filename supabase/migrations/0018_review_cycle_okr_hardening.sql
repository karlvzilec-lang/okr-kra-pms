-- 0018_review_cycle_okr_hardening.sql
-- Review-cycle lifecycle and OKR write hardening.
--
-- SQLSTATE contract (consumed by web/lib/okr.ts):
--
--   55000 (object_not_in_prerequisite_state)
--     * review_cycle INSERT with any status other than draft;
--     * review_cycle UPDATE that skips, reverses, or reopens the exact
--       draft -> active -> self_eval -> manager_eval -> closed lifecycle;
--     * objective INSERT/UPDATE/DELETE when either the old or new cycle is
--       closed;
--     * key_result INSERT/UPDATE/DELETE when either the old or new parent
--       objective belongs to a closed cycle;
--     * check_in INSERT when its key result belongs to a closed cycle.
--
--   42501 (insufficient_privilege)
--     * RLS ownership/visibility failures, including forged objective.owner_id,
--       objective inserts into a cycle where the owner is not a participant,
--       non-owner key-result/check-in writes, and other existing scoped-policy
--       denials;
--     * owner key_result INSERT payloads that pre-populate current_value or
--       score_override instead of starting from a pristine progress state;
--     * direct key_result UPDATE attempts that change current_value or score
--       (including by HR), score_override by a non-HR caller, or identity/audit
--       columns by a non-HR caller.
--     check_in UPDATE/DELETE have no policies at all; PostgreSQL applies RLS
--     default-deny as a zero-row operation rather than raising 42501.
--
--   23514 (check_violation)
--     * table check constraints, including inverted review-cycle dates and
--       numeric score/range constraints. This migration does not remap them.
--
-- No lifecycle or closed-cycle trigger has an HR, service_role, or other role
-- bypass. Trigger functions are revoked from direct callers and run only via
-- their table triggers. Definitions are idempotent for local rebuilds.

-- ---------------------------------------------------------------------------
-- Review-cycle lifecycle: cycles are born in draft and advance exactly once
-- through each ordered status. Non-status edits remain valid at every stage.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_review_cycle_status_transition()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status is distinct from 'draft'::public.review_cycle_status then
      raise exception 'Review cycles must be inserted with draft status'
        using errcode = '55000';
    end if;

    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  if (old.status = 'draft'::public.review_cycle_status
        and new.status = 'active'::public.review_cycle_status)
     or (old.status = 'active'::public.review_cycle_status
        and new.status = 'self_eval'::public.review_cycle_status)
     or (old.status = 'self_eval'::public.review_cycle_status
        and new.status = 'manager_eval'::public.review_cycle_status)
     or (old.status = 'manager_eval'::public.review_cycle_status
        and new.status = 'closed'::public.review_cycle_status)
  then
    return new;
  end if;

  raise exception 'Invalid review-cycle status transition from % to %',
    old.status,
    new.status
    using errcode = '55000';
end;
$$;

revoke all on function public.restrict_review_cycle_status_transition()
from public;

drop trigger if exists review_cycle_restrict_status_transition
  on public.review_cycle;
create trigger review_cycle_restrict_status_transition
before insert or update on public.review_cycle
for each row
execute function public.restrict_review_cycle_status_transition();

-- ---------------------------------------------------------------------------
-- Closed cycles freeze the whole OKR evidence tree. SECURITY DEFINER is used
-- for the parent-state lookup so the gate does not depend on whether the
-- invoking role can select the parent row; there is still no role bypass.
-- UPDATE checks both the old and new parent paths so a row cannot be moved out
-- of or into a closed cycle to evade the freeze.
-- ---------------------------------------------------------------------------

create or replace function public.reject_closed_cycle_objective_writes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closed boolean;
begin
  if tg_op = 'INSERT' then
    select exists (
      select 1
      from public.review_cycle as rc
      where rc.id = new.review_cycle_id
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  elsif tg_op = 'UPDATE' then
    select exists (
      select 1
      from public.review_cycle as rc
      where rc.id in (old.review_cycle_id, new.review_cycle_id)
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  else
    select exists (
      select 1
      from public.review_cycle as rc
      where rc.id = old.review_cycle_id
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  end if;

  if v_closed then
    raise exception 'Objectives cannot be written after their review cycle is closed'
      using errcode = '55000';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

revoke all on function public.reject_closed_cycle_objective_writes()
from public;

drop trigger if exists objective_reject_closed_cycle_writes
  on public.objective;
create trigger objective_reject_closed_cycle_writes
before insert or update or delete on public.objective
for each row
execute function public.reject_closed_cycle_objective_writes();

create or replace function public.reject_closed_cycle_key_result_writes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closed boolean;
begin
  if tg_op = 'INSERT' then
    select exists (
      select 1
      from public.objective as o
      join public.review_cycle as rc on rc.id = o.review_cycle_id
      where o.id = new.objective_id
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  elsif tg_op = 'UPDATE' then
    select exists (
      select 1
      from public.objective as o
      join public.review_cycle as rc on rc.id = o.review_cycle_id
      where o.id in (old.objective_id, new.objective_id)
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  else
    select exists (
      select 1
      from public.objective as o
      join public.review_cycle as rc on rc.id = o.review_cycle_id
      where o.id = old.objective_id
        and rc.status = 'closed'::public.review_cycle_status
    ) into v_closed;
  end if;

  if v_closed then
    raise exception 'Key results cannot be written after their review cycle is closed'
      using errcode = '55000';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

revoke all on function public.reject_closed_cycle_key_result_writes()
from public;

drop trigger if exists key_result_reject_closed_cycle_writes
  on public.key_result;
create trigger key_result_reject_closed_cycle_writes
before insert or update or delete on public.key_result
for each row
execute function public.reject_closed_cycle_key_result_writes();

create or replace function public.reject_closed_cycle_check_in_inserts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closed boolean;
begin
  select exists (
    select 1
    from public.key_result as kr
    join public.objective as o on o.id = kr.objective_id
    join public.review_cycle as rc on rc.id = o.review_cycle_id
    where kr.id = new.key_result_id
      and rc.status = 'closed'::public.review_cycle_status
  ) into v_closed;

  if v_closed then
    raise exception 'Check-ins cannot be added after their review cycle is closed'
      using errcode = '55000';
  end if;

  return new;
end;
$$;

revoke all on function public.reject_closed_cycle_check_in_inserts()
from public;

drop trigger if exists check_in_reject_closed_cycle_insert
  on public.check_in;
create trigger check_in_reject_closed_cycle_insert
before insert on public.check_in
for each row
execute function public.reject_closed_cycle_check_in_inserts();

-- ---------------------------------------------------------------------------
-- Key-result owner UPDATE column scope.
--
-- Trigger names execute alphabetically. key_result_guard_owner_updates runs
-- before key_result_recompute_score, so it sees a client-supplied score change
-- before the scoring trigger normalizes it. A structural start/target change
-- passes the guard and may then legitimately recompute score.
--
-- apply_check_in_to_key_result issues a nested UPDATE from the check-in AFTER
-- INSERT trigger. pg_trigger_depth() is 2 for that path and 1 for a direct
-- client UPDATE; the verification suite pins both sides of that distinction.
-- ---------------------------------------------------------------------------

create or replace function public.restrict_key_result_owner_updates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_catalog.pg_trigger_depth() > 1 then
    return new;
  end if;

  if new.current_value is distinct from old.current_value
     or new.score is distinct from old.score
  then
    raise exception 'current_value and score may change only through check-in propagation'
      using errcode = '42501';
  end if;

  if not public.is_hr_admin()
     and (
       new.id is distinct from old.id
       or new.objective_id is distinct from old.objective_id
       or new.score_override is distinct from old.score_override
       or new.created_at is distinct from old.created_at
       or new.updated_at is distinct from old.updated_at
     )
  then
    raise exception 'Objective owners may update only key-result structural columns'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function public.restrict_key_result_owner_updates()
from public;

drop trigger if exists key_result_guard_owner_updates
  on public.key_result;
create trigger key_result_guard_owner_updates
before update on public.key_result
for each row
execute function public.restrict_key_result_owner_updates();

-- ---------------------------------------------------------------------------
-- Check-in actor/timestamp canonicalization and immutability.
-- The BEFORE INSERT trigger overwrites both client-controlled values before
-- the INSERT WITH CHECK policy runs. UPDATE/DELETE have no policies for any
-- role; HR retains an explicit SELECT-only policy.
-- ---------------------------------------------------------------------------

create or replace function public.set_check_in_actor_and_created_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.checked_in_by := auth.uid();
  new.created_at := pg_catalog.now();
  return new;
end;
$$;

revoke all on function public.set_check_in_actor_and_created_at()
from public;

drop trigger if exists check_in_enforce_actor_and_created_at
  on public.check_in;
create trigger check_in_enforce_actor_and_created_at
before insert on public.check_in
for each row
execute function public.set_check_in_actor_and_created_at();

drop policy if exists check_in_hr_all on public.check_in;
drop policy if exists check_in_hr_select on public.check_in;
create policy check_in_hr_select
on public.check_in
for select
to authenticated
using (public.is_hr_admin());

-- ---------------------------------------------------------------------------
-- Objective owners may create only inside a review cycle in which they are a
-- participant. objective_hr_all remains the separate HR administration path.
-- ---------------------------------------------------------------------------

drop policy if exists objective_owner_insert on public.objective;
create policy objective_owner_insert
on public.objective
for insert
to authenticated
with check (
  owner_id = auth.uid()
  and (
    public.is_hr_admin()
    or public.is_review_cycle_participant(review_cycle_id)
  )
);

-- ---------------------------------------------------------------------------
-- Owner-created key results start without derived progress or an HR override.
-- key_result_hr_all remains the separate HR path and can initialize an
-- override when required; score itself is still owned by the scoring trigger.
-- ---------------------------------------------------------------------------

drop policy if exists key_result_owner_insert on public.key_result;
create policy key_result_owner_insert
on public.key_result
for insert
to authenticated
with check (
  public.can_write_objective(objective_id)
  and (
    public.is_hr_admin()
    or (
      current_value is null
      and score is null
      and score_override is null
    )
  )
);
