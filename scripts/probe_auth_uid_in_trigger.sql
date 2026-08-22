-- scripts/probe_auth_uid_in_trigger.sql
--
-- Round 9, Gate 1 ruling, "Both, first, before either writes anything else":
-- prove empirically that auth.uid() inside a SECURITY DEFINER trigger function
-- still resolves to the *calling end user*, not to the function owner and not
-- to null.
--
-- Why this is in doubt at all: SECURITY DEFINER swaps the executing ROLE
-- (current_user becomes the function owner). auth.uid() does not read a role
-- at all -- it reads the request.jwt.claim.sub / request.jwt.claims GUCs, which
-- are session/transaction state set by set_config(). Those two are independent
-- mechanisms, so the expectation is that it works. This file exists because
-- "should work" is not evidence.
--
-- Run: psql -v ON_ERROR_STOP=1 -f scripts/probe_auth_uid_in_trigger.sql
-- Uses the same harness shape as scripts/verify.sql:
--   set local role authenticated + set_config('request.jwt.claim.sub', ...).
-- Creates its own throwaway objects and rolls everything back.

\set ON_ERROR_STOP on

\echo '=== PROBE: auth.uid() inside a SECURITY DEFINER trigger ==='

-- What is auth.uid() actually defined as on this stack? Printed so the probe
-- documents the mechanism it is testing, not just the outcome.
select pg_get_functiondef('auth.uid()'::regprocedure) as auth_uid_definition;

begin;

create table public.probe_source (
  id   integer primary key,
  note text
);

create table public.probe_capture (
  id                 integer generated always as identity primary key,
  captured_auth_uid  uuid,
  captured_current_user text not null,
  captured_session_user text not null,
  captured_claim_sub text
);

-- Deliberately mirrors the real 0023 trigger functions: plpgsql,
-- security definer, set search_path = ''.
create or replace function public.probe_capture_actor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.probe_capture (
    captured_auth_uid,
    captured_current_user,
    captured_session_user,
    captured_claim_sub
  )
  values (
    auth.uid(),
    current_user,
    session_user,
    nullif(current_setting('request.jwt.claim.sub', true), '')
  );
  return null;
end;
$$;

create trigger probe_source_capture
after insert on public.probe_source
for each row execute function public.probe_capture_actor();

-- The function is owned by the migration runner (postgres/supabase_admin),
-- which is NOT the role the insert runs as. That is the whole point.
grant insert on public.probe_source to authenticated;

-- ---------------------------------------------------------------------------
-- Case 1: a real authenticated end user with a JWT sub claim.
-- Expectation: auth.uid() = that claim, while current_user is the definer.
-- ---------------------------------------------------------------------------
savepoint case_one;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);

insert into public.probe_source (id, note) values (1, 'authenticated caller');

reset role;

do $$
declare
  v_uid   uuid;
  v_cuser text;
  v_suser text;
begin
  select captured_auth_uid, captured_current_user, captured_session_user
  into v_uid, v_cuser, v_suser
  from public.probe_capture
  order by id desc
  limit 1;

  raise notice 'CASE 1  auth.uid()      = %', coalesce(v_uid::text, '<NULL>');
  raise notice 'CASE 1  current_user    = %', v_cuser;
  raise notice 'CASE 1  session_user    = %', v_suser;

  if v_uid is null then
    raise exception
      'PROBE FAILED: auth.uid() was NULL inside a SECURITY DEFINER trigger. '
      'Actor capture must be redesigned (explicit p_actor argument or a GUC read).';
  end if;

  if v_uid <> '11111111-1111-4111-8111-000000000001'::uuid then
    raise exception
      'PROBE FAILED: auth.uid() returned % instead of the caller''s JWT sub', v_uid;
  end if;

  raise notice
    'PROBE CASE 1 PASS: auth.uid() resolved to the CALLER (%), not the definer role (%)',
    v_uid, v_cuser;
end $$;

-- ---------------------------------------------------------------------------
-- Case 2: no JWT sub claim at all (service_role / owner-run migration, the
-- exact case ruling point 3 says must NOT error and must NOT blank out).
-- Expectation: auth.uid() is NULL and does not raise.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '', true);

insert into public.probe_source (id, note) values (2, 'no claim');

do $$
declare
  v_uid  uuid;
  v_note text;
begin
  select captured_auth_uid into v_uid
  from public.probe_capture
  order by id desc
  limit 1;

  raise notice 'CASE 2  auth.uid()      = %', coalesce(v_uid::text, '<NULL>');

  if v_uid is not null then
    raise exception 'PROBE FAILED: expected NULL auth.uid() with no JWT claim, got %', v_uid;
  end if;

  raise notice
    'PROBE CASE 2 PASS: no JWT claim yields a NULL actor without raising -- '
    'so actor_id must be nullable with an actor_name fallback (ruling point 3).';
end $$;

-- ---------------------------------------------------------------------------
-- Case 3: nested one level deeper -- a SECURITY DEFINER *function* that
-- performs the write that fires the SECURITY DEFINER trigger. Two role swaps
-- between the JWT claim and auth.uid(). This is the real 0022 shape
-- (unpublish_employee_goal_plan -> UPDATE -> audit trigger).
-- ---------------------------------------------------------------------------
create or replace function public.probe_nested_writer(p_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.probe_source (id, note) values (p_id, 'via nested definer fn');
end;
$$;

grant execute on function public.probe_nested_writer(integer) to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
select public.probe_nested_writer(3);
reset role;

do $$
declare
  v_uid uuid;
begin
  select captured_auth_uid into v_uid
  from public.probe_capture
  order by id desc
  limit 1;

  raise notice 'CASE 3  auth.uid()      = %', coalesce(v_uid::text, '<NULL>');

  if v_uid is distinct from '11111111-1111-4111-8111-000000000002'::uuid then
    raise exception
      'PROBE FAILED: nested SECURITY DEFINER lost the actor (got %)',
      coalesce(v_uid::text, '<NULL>');
  end if;

  raise notice
    'PROBE CASE 3 PASS: actor survives function-definer -> trigger-definer nesting.';
end $$;

select
  id,
  coalesce(captured_auth_uid::text, '<NULL>') as auth_uid,
  captured_current_user,
  captured_session_user,
  coalesce(captured_claim_sub, '<NULL>') as claim_sub
from public.probe_capture
order by id;

rollback;

\echo '=== PROBE COMPLETE: all three cases passed, nothing persisted ==='
