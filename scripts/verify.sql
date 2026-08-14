-- scripts/verify.sql
-- Automated assertion suite. Run against a freshly-reset local Supabase
-- Postgres instance (after `supabase db reset`, which applies every
-- migration and supabase/seed.sql). Fails loudly and non-zero via
-- `psql -v ON_ERROR_STOP=1 -f scripts/verify.sql` if any assertion breaks.
--
-- This is the CI gate: every check here was first proven manually against a
-- live local stack before being encoded here (see VERIFICATION.md for the
-- narrative version with expected-result commentary).

\set ON_ERROR_STOP on

-- ============================================================================
-- RLS enabled on every table (Phase 1 + Phase 2)
-- ============================================================================
do $$
declare
  v_missing text;
begin
  select string_agg(relname, ', ')
  into v_missing
  from pg_class
  where relnamespace = 'public'::regnamespace
    and relkind = 'r'
    and relname in (
      'profiles', 'review_cycle', 'employee_goal_plan', 'kra_category', 'goal',
      'goal_cascade', 'goal_alignment', 'review_participant', 'goal_plan_rating',
      'objective', 'key_result', 'check_in', 'objective_alignment',
      'review_participant_scope', 'goal_matrix_rating'
    )
    and not relrowsecurity;

  if v_missing is not null then
    raise exception 'RLS not enabled on: %', v_missing;
  end if;

  raise notice 'PASS: RLS enabled on all 15 tables';
end $$;

-- ============================================================================
-- Phase 1: Average Method rollup matches the hand-computed seed values
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_self numeric;
  v_manager numeric;
begin
  select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'self') into v_self;
  select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'manager') into v_manager;

  if v_self <> 4.220 then
    raise exception 'Expected self rollup 4.220, got %', v_self;
  end if;
  if v_manager <> 3.580 then
    raise exception 'Expected manager rollup 3.580, got %', v_manager;
  end if;

  raise notice 'PASS: Phase 1 rollup = 4.220 (self) / 3.580 (manager)';
end $$;
rollback;

-- ============================================================================
-- Phase 1 Ruling 3: bottom-up alignment succeeds without both-plan participation
-- ============================================================================
begin;
delete from public.goal_alignment where id = '77777777-7777-4777-8777-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
declare
  v_id uuid;
begin
  insert into public.goal_alignment (id, parent_goal_id, child_goal_id, created_by)
  values (
    '77777777-7777-4777-8777-000000000001',
    '55555555-5555-4555-8555-000000000006',
    '55555555-5555-4555-8555-000000000008',
    '11111111-1111-4111-8111-000000000006'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'Ruling 3 alignment insert did not return a row';
  end if;

  raise notice 'PASS: Ruling 3 — Rith aligned up to Ana without participating on her plan';
end $$;
rollback;

-- ============================================================================
-- Phase 1: report cannot write a goal they can only read (Rith cannot edit Ana's goal)
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
declare
  v_rows int;
begin
  update public.goal set title = 'unauthorized change'
  where id = '55555555-5555-4555-8555-000000000006';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected 0 rows updated, got %', v_rows;
  end if;

  raise notice 'PASS: Rith cannot write Ana''s goal despite read access';
end $$;
rollback;

-- ============================================================================
-- Phase 2: key_result scores match the seed's hand-computed values, including
-- the deliberately decreasing-target case (cc...002)
-- ============================================================================
do $$
declare
  v_scores numeric[];
  v_expected numeric[] := array[0.700, 0.700, 0.300, 0.300];
begin
  select array_agg(score order by id)
  into v_scores
  from public.key_result
  where id in (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    'cccccccc-cccc-4ccc-8ccc-000000000002',
    'cccccccc-cccc-4ccc-8ccc-000000000003',
    'cccccccc-cccc-4ccc-8ccc-000000000004'
  );

  if v_scores <> v_expected then
    raise exception 'Expected key_result scores %, got %', v_expected, v_scores;
  end if;

  raise notice 'PASS: key_result scores = 0.700, 0.700, 0.300, 0.300 (incl. decreasing-target case)';
end $$;

-- ============================================================================
-- Phase 2: matrix manager can rate a goal in her granted category (positive)
-- ============================================================================
begin;
update public.review_cycle set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';
update public.review_cycle set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
declare
  v_rows int;
begin
  update public.goal_matrix_rating set comment = 'ci-verify positive'
  where goal_id = '55555555-5555-4555-8555-000000000004'
    and participant_id = '11111111-1111-4111-8111-000000000009';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected 1 row updated for in-scope matrix rating, got %', v_rows;
  end if;

  raise notice 'PASS: matrix manager can rate a goal in her granted category';
end $$;
rollback;

-- ============================================================================
-- Phase 2: matrix manager is denied on a goal OUTSIDE her granted category (negative)
-- ============================================================================
begin;
update public.review_cycle set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';
update public.review_cycle set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
begin
  begin
    insert into public.goal_matrix_rating (goal_id, participant_id, rating, comment)
    values (
      '55555555-5555-4555-8555-000000000001',
      '11111111-1111-4111-8111-000000000009',
      5,
      'should be denied'
    );
    raise exception 'ASSERTION FAILED: out-of-scope matrix insert should have been denied but succeeded';
  exception
    when sqlstate '42501' then
      raise notice 'PASS: matrix manager denied on out-of-scope category';
  end;
end $$;
rollback;

-- ============================================================================
-- Phase 2: matrix manager cannot write the line-manager-only column
-- ============================================================================
begin;
update public.review_cycle set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';
update public.review_cycle set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
declare
  v_rows int;
begin
  update public.goal set manager_rating = 5
  where id = '55555555-5555-4555-8555-000000000004';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected 0 rows updated (manager_rating is line-manager-only), got %', v_rows;
  end if;

  raise notice 'PASS: matrix manager cannot write goal.manager_rating';
end $$;
rollback;

-- ============================================================================
-- Phase 2: a check-in propagates to current_value and the score recomputes
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
begin
  insert into public.check_in (key_result_id, checked_in_by, new_value, note)
  values (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    '11111111-1111-4111-8111-000000000004',
    100,
    'ci-verify: hits target'
  );

  select current_value, score into v_current, v_score
  from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_current <> 100 then
    raise exception 'Expected current_value 100, got %', v_current;
  end if;
  if v_score <> 1.000 then
    raise exception 'Expected score 1.000 (clamped at target), got %', v_score;
  end if;

  raise notice 'PASS: check-in updates current_value and score recomputes (clamped at 1.0)';
end $$;
rollback;

-- ============================================================================
-- Phase 2 Ruling 1: objective_alignment resolves with the corrected upward
-- read-authority direction (Dara reads Ana's objective because Ana is his manager)
-- ============================================================================
begin;
delete from public.objective_alignment where id = 'eeeeeeee-eeee-4eee-8eee-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_id uuid;
begin
  insert into public.objective_alignment (id, parent_objective_id, child_objective_id, created_by)
  values (
    'eeeeeeee-eeee-4eee-8eee-000000000001',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
    '11111111-1111-4111-8111-000000000004'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'Ruling 1 objective_alignment insert did not return a row';
  end if;

  raise notice 'PASS: Ruling 1 — Dara aligned his objective up to Ana''s via the corrected direction';
end $$;
rollback;

-- ============================================================================
-- Phase 2: employee_review_summary isolates an unrelated caller
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000007', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.employee_review_summary(
    '22222222-2222-4222-8222-000000000001',
    '11111111-1111-4111-8111-000000000004'
  );

  if v_rows <> 0 then
    raise exception 'Expected 0 rows for an unrelated caller, got %', v_rows;
  end if;

  raise notice 'PASS: employee_review_summary isolates an unrelated caller';
end $$;
rollback;

-- ============================================================================
-- Password policy: a user may update their own password_changed_at
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows int;
begin
  update public.profiles set password_changed_at = now()
  where id = '11111111-1111-4111-8111-000000000004';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected 1 row updated (self password_changed_at), got %', v_rows;
  end if;

  raise notice 'PASS: user can update their own password_changed_at';
end $$;
rollback;

-- ============================================================================
-- Password policy: self-update cannot touch any other column
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    update public.profiles set full_name = 'Escalated Name'
    where id = '11111111-1111-4111-8111-000000000004';
    raise exception 'ASSERTION FAILED: self-update should not be able to change full_name';
  exception
    when sqlstate '42501' then
      raise notice 'PASS: self-update cannot change full_name (or any other column)';
  end;
end $$;
rollback;

-- ============================================================================
-- Password policy: a user cannot update someone else's profile at all
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
declare
  v_rows int;
begin
  update public.profiles set password_changed_at = now()
  where id = '11111111-1111-4111-8111-000000000004';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected 0 rows updated (cannot touch another user''s profile), got %', v_rows;
  end if;

  raise notice 'PASS: user cannot update another user''s profile';
end $$;
rollback;

-- ============================================================================
-- Phase 3: RLS enabled on all three calibration tables
-- ============================================================================
do $$
declare
  v_missing text;
begin
  select string_agg(relname, ', ')
  into v_missing
  from pg_class
  where relnamespace = 'public'::regnamespace
    and relkind = 'r'
    and relname in ('calibration_session', 'calibration_band', 'calibration_participant')
    and not relrowsecurity;

  if v_missing is not null then
    raise exception 'RLS not enabled on: %', v_missing;
  end if;

  raise notice 'PASS: RLS enabled on all 3 Phase 3 calibration tables';
end $$;

-- ============================================================================
-- Phase 3: calibration_participant reads are scoped to the specific plan's
-- line manager, not blanket session membership. Ana can read Dara's row; Ben
-- (no report in this session) reads zero; the employee reads zero.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001';

  if v_rows <> 1 then
    raise exception 'Expected Ana to see exactly 1 participant row (Dara''s), got %', v_rows;
  end if;

  raise notice 'PASS: line manager sees exactly their own report''s calibration_participant row';
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000003', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001';

  if v_rows <> 0 then
    raise exception 'Expected Ben (no report in this session) to see 0 rows, got %', v_rows;
  end if;

  raise notice 'PASS: a manager with no report in the session sees 0 calibration_participant rows';
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.calibration_participant;

  if v_rows <> 0 then
    raise exception 'Expected the employee to see 0 calibration_participant rows (including their own), got %', v_rows;
  end if;

  raise notice 'PASS: an employee sees 0 calibration_participant rows, including their own';
end $$;
rollback;

-- ============================================================================
-- Phase 3: adjust_calibration_participant is rejected once the session is
-- finalized, even for HR
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_participant_id uuid;
begin
  select id into v_participant_id
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001'
    and employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a';

  begin
    perform public.adjust_calibration_participant(v_participant_id, 4.000, 'should be rejected');
    raise exception 'ASSERTION FAILED: adjustment on a finalized session should have been rejected';
  exception
    when sqlstate '55000' then
      raise notice 'PASS: adjust_calibration_participant rejected on a finalized session';
  end;
end $$;
rollback;

-- ============================================================================
-- Phase 3: publish_employee_goal_plan is rejected while the plan's
-- calibration session is still open
-- ============================================================================
begin;
update public.calibration_session
set status = 'open'
where id = '44444444-4444-4444-8444-000000000001';
update public.employee_goal_plan
set published_at = null
where id = '33333333-3333-4333-8333-00000000000a';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');
    raise exception 'ASSERTION FAILED: publish should have been rejected while calibration is open';
  exception
    when sqlstate '55000' then
      raise notice 'PASS: publish_employee_goal_plan rejected while calibration session is open';
  end;
end $$;
rollback;

-- ============================================================================
-- Phase 3 Ruling 2: final_score populates only the manager KRA block; the
-- self block is always null, before AND after publication
-- ============================================================================
begin;
update public.employee_goal_plan
set published_at = null
where id = '33333333-3333-4333-8333-00000000000a';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_manager_final jsonb;
  v_self_final jsonb;
begin
  select rating -> 'final_score' into v_manager_final
  from public.employee_review_summary('22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000004') as review
  cross join lateral jsonb_array_elements(review.summary -> 'kra_ratings') as rating
  where rating ->> 'rating_type' = 'manager';

  select rating -> 'final_score' into v_self_final
  from public.employee_review_summary('22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000004') as review
  cross join lateral jsonb_array_elements(review.summary -> 'kra_ratings') as rating
  where rating ->> 'rating_type' = 'self';

  if v_manager_final is distinct from 'null'::jsonb then
    raise exception 'Expected manager final_score null pre-publish, got %', v_manager_final;
  end if;
  if v_self_final is distinct from 'null'::jsonb then
    raise exception 'Expected self final_score null pre-publish, got %', v_self_final;
  end if;

  raise notice 'PASS: final_score is null on both blocks before publication';
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_manager_final jsonb;
  v_self_final jsonb;
begin
  select rating -> 'final_score' into v_manager_final
  from public.employee_review_summary('22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000004') as review
  cross join lateral jsonb_array_elements(review.summary -> 'kra_ratings') as rating
  where rating ->> 'rating_type' = 'manager';

  select rating -> 'final_score' into v_self_final
  from public.employee_review_summary('22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000004') as review
  cross join lateral jsonb_array_elements(review.summary -> 'kra_ratings') as rating
  where rating ->> 'rating_type' = 'self';

  if v_manager_final is distinct from to_jsonb(3.200::numeric) then
    raise exception 'Expected manager final_score 3.200 post-publish, got %', v_manager_final;
  end if;
  if v_self_final is distinct from 'null'::jsonb then
    raise exception 'Expected self final_score to STAY null post-publish, got %', v_self_final;
  end if;

  raise notice 'PASS: post-publish, manager final_score = calibrated 3.200, self stays null';
end $$;
rollback;

-- ============================================================================
-- Phase 3 Ruling 1: comp_export_rows is explicitly HR-only, even though Ana
-- (Dara's line manager) can otherwise see Dara's day-to-day review data
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
  v_final_score numeric;
  v_band text;
begin
  select count(*) into v_rows
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001')
  where employee_id = '11111111-1111-4111-8111-000000000004';

  if v_rows <> 1 then
    raise exception 'Expected HR to see exactly 1 comp export row for Dara, got %', v_rows;
  end if;

  select final_score, band_label into v_final_score, v_band
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001')
  where employee_id = '11111111-1111-4111-8111-000000000004';

  if v_final_score <> 3.200 or v_band <> 'Meets Expectations' then
    raise exception 'Expected final_score 3.200 / band Meets Expectations, got % / %', v_final_score, v_band;
  end if;

  raise notice 'PASS: HR sees Dara''s comp export row with final_score 3.200 / Meets Expectations';
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001');

  if v_rows <> 0 then
    raise exception 'Expected Ana (non-HR) to see 0 comp export rows, got %', v_rows;
  end if;

  raise notice 'PASS: comp_export_rows returns 0 rows for a non-HR caller, even Dara''s own manager';
end $$;
rollback;

-- ============================================================================
-- Phase 3: Phase 1 rollup regression guard — unchanged by calibration
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_self numeric;
  v_manager numeric;
begin
  select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'self') into v_self;
  select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'manager') into v_manager;

  if v_self <> 4.220 then
    raise exception 'Expected self rollup 4.220 (Phase 3 regression guard), got %', v_self;
  end if;
  if v_manager <> 3.580 then
    raise exception 'Expected manager rollup 3.580 (Phase 3 regression guard), got %', v_manager;
  end if;

  raise notice 'PASS: Phase 1 rollup unchanged by Phase 3 calibration (4.220 / 3.580)';
end $$;
rollback;

-- ============================================================================
-- Gate 1: facilitator read RPCs reject non-HR callers before existence lookup
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
begin
  begin
    perform detail
    from public.calibration_session_detail(
      'f1600000-0000-4000-8000-000000000001'
    );
    raise exception 'ASSERTION FAILED: non-HR calibration_session_detail call should have been denied';
  exception
    when sqlstate '42501' then
      raise notice 'PASS: calibration_session_detail rejects non-HR before existence lookup';
  end;
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
begin
  begin
    perform plan_id
    from public.calibration_eligible_plans(
      'f1600000-0000-4000-8000-000000000002'
    );
    raise exception 'ASSERTION FAILED: non-HR calibration_eligible_plans call should have been denied';
  exception
    when sqlstate '42501' then
      raise notice 'PASS: calibration_eligible_plans rejects non-HR before existence lookup';
  end;
end $$;
rollback;

-- ============================================================================
-- Gate 1: atomic session creation RPC is HR-only
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
begin
  begin
    perform public.create_calibration_session_with_bands(
      'Must be denied',
      'f1600000-0000-4000-8000-000000000003',
      '[]'::jsonb
    );
    raise exception 'ASSERTION FAILED: non-HR session creation should have been denied';
  exception
    when sqlstate '42501' then
      raise notice 'PASS: create_calibration_session_with_bands rejects non-HR before other validation';
  end;
end $$;
rollback;

-- ============================================================================
-- Gate 1: HR session detail has the locked nested shape and seeded values
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_detail jsonb;
  v_outer_keys text[];
  v_session_keys text[];
  v_band_keys text[];
  v_participant_keys text[];
  v_band_labels text[];
  v_participant jsonb;
begin
  select detail into v_detail
  from public.calibration_session_detail(
    '44444444-4444-4444-8444-000000000001'
  );

  select array_agg(key order by key) into v_outer_keys
  from jsonb_object_keys(v_detail) as keys(key);

  select array_agg(key order by key) into v_session_keys
  from jsonb_object_keys(v_detail -> 'session') as keys(key);

  select array_agg(key order by key) into v_band_keys
  from jsonb_object_keys(v_detail -> 'bands' -> 0) as keys(key);

  select array_agg(key order by key) into v_participant_keys
  from jsonb_object_keys(v_detail -> 'participants' -> 0) as keys(key);

  select array_agg(item ->> 'label' order by ordinality) into v_band_labels
  from jsonb_array_elements(v_detail -> 'bands')
    with ordinality as bands(item, ordinality);

  v_participant := v_detail -> 'participants' -> 0;

  if v_outer_keys <> array['bands', 'participants', 'session']::text[] then
    raise exception 'Unexpected calibration detail keys: %', v_outer_keys;
  end if;
  if v_session_keys <> array[
    'created_at', 'id', 'name', 'review_cycle_id', 'review_cycle_name',
    'status', 'updated_at'
  ]::text[] then
    raise exception 'Unexpected calibration session keys: %', v_session_keys;
  end if;
  if v_band_keys <> array[
    'id', 'label', 'max_score', 'min_score', 'sort_order'
  ]::text[] then
    raise exception 'Unexpected calibration band keys: %', v_band_keys;
  end if;
  if v_participant_keys <> array[
    'band_id', 'calibrated_score', 'employee_email', 'employee_full_name',
    'employee_goal_plan_id', 'employee_id', 'facilitator_note', 'id',
    'manager_full_name', 'original_score', 'overall_rating_scale_max',
    'published_at'
  ]::text[] then
    raise exception 'Unexpected calibration participant keys: %', v_participant_keys;
  end if;

  if v_detail -> 'session' ->> 'id' <> '44444444-4444-4444-8444-000000000001'
     or v_detail -> 'session' ->> 'name' <> 'FY2026 Engineering Calibration'
     or v_detail -> 'session' ->> 'status' <> 'finalized'
     or v_detail -> 'session' ->> 'review_cycle_id' <> '22222222-2222-4222-8222-000000000001'
     or v_detail -> 'session' ->> 'review_cycle_name' <> 'FY2026 Annual Review'
     or jsonb_typeof(v_detail -> 'session' -> 'created_at') is distinct from 'string'
     or jsonb_typeof(v_detail -> 'session' -> 'updated_at') is distinct from 'string' then
    raise exception 'Unexpected seeded calibration session payload: %', v_detail -> 'session';
  end if;

  if jsonb_array_length(v_detail -> 'bands') <> 4
     or v_band_labels <> array[
       'Needs Improvement', 'Meets Expectations',
       'Exceeds Expectations', 'Outstanding'
     ]::text[] then
    raise exception 'Unexpected seeded calibration bands: %', v_detail -> 'bands';
  end if;

  if jsonb_array_length(v_detail -> 'participants') <> 1
     or v_participant ->> 'employee_goal_plan_id' <> '33333333-3333-4333-8333-00000000000a'
     or v_participant ->> 'employee_id' <> '11111111-1111-4111-8111-000000000004'
     or v_participant ->> 'employee_full_name' <> 'Dara Sok'
     or v_participant ->> 'employee_email' <> 'dara.sok@example.com'
     or v_participant ->> 'manager_full_name' <> 'Ana Kim'
     or (v_participant ->> 'original_score')::numeric <> 3.580
     or (v_participant ->> 'calibrated_score')::numeric <> 3.200
     or v_participant ->> 'band_id' <> '55555555-5555-4555-8555-000000000002'
     or (v_participant ->> 'overall_rating_scale_max')::integer <> 5
     or jsonb_typeof(v_participant -> 'published_at') is distinct from 'string' then
    raise exception 'Unexpected seeded calibration participant: %', v_participant;
  end if;

  raise notice 'PASS: calibration_session_detail returns the locked seeded session, band, and participant shape';
end $$;
rollback;

-- ============================================================================
-- Gate 1: eligible plans are same-cycle, manager-rated, unpublished, and not
-- already in this session. Each exclusion is isolated in this transaction.
-- ============================================================================
begin;
update public.employee_goal_plan
set published_at = null
where id = '33333333-3333-4333-8333-00000000000a';

insert into public.goal_plan_rating (
  employee_goal_plan_id, rating_type, overall_score
)
values (
  '33333333-3333-4333-8333-00000000000b', 'manager', 4.500
);

update public.employee_goal_plan
set published_at = now()
where id = '33333333-3333-4333-8333-00000000000b';

insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1600000-0000-4000-8000-000000000010',
  'Wrong-cycle eligibility fixture',
  '2027-01-01',
  '2027-12-31',
  'draft'
);

update public.review_cycle
set status = 'active'
where id = 'f1600000-0000-4000-8000-000000000010';

insert into public.employee_goal_plan (
  id, review_cycle_id, employee_id, status, overall_rating_scale_max
)
values (
  'f1600000-0000-4000-8000-000000000011',
  'f1600000-0000-4000-8000-000000000010',
  '11111111-1111-4111-8111-000000000007',
  'manager_reviewed',
  5
);

insert into public.goal_plan_rating (
  employee_goal_plan_id, rating_type, overall_score
)
values (
  'f1600000-0000-4000-8000-000000000011', 'manager', 3.750
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_plan_ids uuid[];
  v_employee_id uuid;
  v_employee_name text;
  v_employee_email text;
  v_manager_score numeric;
begin
  select
    array_agg(plan_id order by plan_id),
    (array_agg(employee_id order by plan_id))[1],
    (array_agg(employee_full_name order by plan_id))[1],
    (array_agg(employee_email order by plan_id))[1],
    (array_agg(manager_score order by plan_id))[1]
  into
    v_plan_ids,
    v_employee_id,
    v_employee_name,
    v_employee_email,
    v_manager_score
  from public.calibration_eligible_plans(
    '44444444-4444-4444-8444-000000000001'
  );

  if v_plan_ids <> array['33333333-3333-4333-8333-00000000000e'::uuid]
     or v_employee_id <> '11111111-1111-4111-8111-000000000008'::uuid
     or v_employee_name <> 'Vuthy Long'
     or v_employee_email <> 'vuthy.long@example.com'
     or v_manager_score <> 4.000 then
    raise exception
      'Expected only Vuthy plan e at manager score 4.000, got plans %, employee % / % / %, score %',
      v_plan_ids,
      v_employee_id,
      v_employee_name,
      v_employee_email,
      v_manager_score;
  end if;

  raise notice 'PASS: calibration_eligible_plans includes Vuthy and excludes participant, published, and wrong-cycle plans';
end $$;
rollback;

-- ============================================================================
-- Gate 1 Ruling 1: a published plan cannot enter another open session
-- ============================================================================
begin;
insert into public.calibration_session (id, review_cycle_id, name)
values (
  'f1600000-0000-4000-8000-000000000020',
  '22222222-2222-4222-8222-000000000001',
  'Published-plan guard fixture'
);

insert into public.calibration_band (
  id, calibration_session_id, label, min_score, max_score, sort_order
)
values (
  'f1600000-0000-4000-8000-000000000021',
  'f1600000-0000-4000-8000-000000000020',
  'All scores', 0.000, 5.001, 1
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_message text;
begin
  begin
    perform public.add_plan_to_calibration_session(
      'f1600000-0000-4000-8000-000000000020',
      '33333333-3333-4333-8333-00000000000a'
    );
    raise exception 'ASSERTION FAILED: published plan should not be recalibrated';
  exception
    when sqlstate '55000' then
      get stacked diagnostics v_message = message_text;
      if v_message not like '%cannot be recalibrated without an unpublish step%' then
        raise exception 'Published-plan rejection message was not actionable: %', v_message;
      end if;
      raise notice 'PASS: add_plan_to_calibration_session rejects a published plan with 55000';
  end;
end $$;
rollback;

-- ============================================================================
-- Gate 1: session and bands are created together by the atomic RPC
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_session_id uuid;
  v_session_status public.calibration_session_status;
  v_session_cycle_id uuid;
  v_band_labels text[];
begin
  v_session_id := public.create_calibration_session_with_bands(
    'Atomic creation success fixture',
    '22222222-2222-4222-8222-000000000001',
    '[
      {"label":"Lower","min_score":0.000,"max_score":3.000,"sort_order":1},
      {"label":"Upper","min_score":3.000,"max_score":5.001,"sort_order":2}
    ]'::jsonb
  );

  select status, review_cycle_id
  into v_session_status, v_session_cycle_id
  from public.calibration_session
  where id = v_session_id
    and name = 'Atomic creation success fixture';

  select array_agg(label order by sort_order, id)
  into v_band_labels
  from public.calibration_band
  where calibration_session_id = v_session_id;

  if v_session_id is null
     or v_session_status <> 'open'::public.calibration_session_status
     or v_session_cycle_id <> '22222222-2222-4222-8222-000000000001'::uuid
     or v_band_labels <> array['Lower', 'Upper']::text[] then
    raise exception
      'Atomic creation returned unexpected session %, status %, cycle %, bands %',
      v_session_id,
      v_session_status,
      v_session_cycle_id,
      v_band_labels;
  end if;

  raise notice 'PASS: create_calibration_session_with_bands creates the open session and ordered bands together';
end $$;
rollback;

-- ============================================================================
-- Gate 1: a band constraint failure rolls back the session insert too
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_orphan_count integer;
begin
  begin
    perform public.create_calibration_session_with_bands(
      'Atomic creation rollback fixture',
      '22222222-2222-4222-8222-000000000001',
      '[
        {"label":"Overlapping one","min_score":0.000,"max_score":3.500,"sort_order":1},
        {"label":"Overlapping two","min_score":3.000,"max_score":5.001,"sort_order":2}
      ]'::jsonb
    );
    raise exception 'ASSERTION FAILED: overlapping bands should have been rejected';
  exception
    when sqlstate '23P01' then
      null;
  end;

  select count(*) into v_orphan_count
  from public.calibration_session
  where name = 'Atomic creation rollback fixture';

  if v_orphan_count <> 0 then
    raise exception 'Expected no orphaned session after band failure, got %', v_orphan_count;
  end if;

  raise notice 'PASS: overlapping bands fail and roll back the entire session creation';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: an employee can extend their own draft plan with a
-- category and an unrated goal. Lina's ...000c plan is the cascaded fixture.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);

insert into public.kra_category (
  id, employee_goal_plan_id, name, description, weight
)
values (
  'f1700000-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-00000000000c',
  'Draft-plan extension',
  'Employee-authored category verification fixture.',
  25.00
);

insert into public.goal (
  id, kra_category_id, title, description, weight, target_metric,
  rating_scale_max
)
values (
  'f1700000-0000-4000-8000-000000000002',
  'f1700000-0000-4000-8000-000000000001',
  'Employee-authored goal',
  'Must be insertable without manager-side values.',
  100.00,
  'One verified draft goal',
  5
);

do $$
declare
  v_category_count integer;
  v_goal_count integer;
begin
  select count(*) into v_category_count
  from public.kra_category
  where id = 'f1700000-0000-4000-8000-000000000001';

  select count(*) into v_goal_count
  from public.goal
  where id = 'f1700000-0000-4000-8000-000000000002'
    and manager_rating is null
    and manager_comment is null;

  if v_category_count <> 1 or v_goal_count <> 1 then
    raise exception
      'Expected employee category and unrated goal inserts, got category count %, goal count %',
      v_category_count,
      v_goal_count;
  end if;

  raise notice 'PASS: employee inserts a category and unrated goal on Lina''s own draft cascaded plan';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: an employee may write only their self-assessment fields.
-- Rith's ...000d plan is the independently-authored upward-alignment fixture.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
declare
  v_rows integer;
  v_rating numeric;
  v_comment text;
begin
  update public.goal
  set self_rating = 4.50,
      self_comment = 'Self-assessment verification fixture.'
  where id = '55555555-5555-4555-8555-000000000008';
  get diagnostics v_rows = row_count;

  select self_rating, self_comment
  into v_rating, v_comment
  from public.goal
  where id = '55555555-5555-4555-8555-000000000008';

  if v_rows <> 1
     or v_rating <> 4.50
     or v_comment <> 'Self-assessment verification fixture.' then
    raise exception
      'Expected one self-assessment update, got rows %, rating %, comment %',
      v_rows,
      v_rating,
      v_comment;
  end if;

  raise notice 'PASS: employee writes self_rating and self_comment on Rith''s own draft aligned plan';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: employee UPDATE cannot write manager-only fields.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    update public.goal
    set manager_rating = 4.00,
        manager_comment = 'Employee must not be able to write this.'
    where id = '55555555-5555-4555-8555-000000000008';
    raise exception 'ASSERTION FAILED: employee manager-field UPDATE should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: employee direct UPDATE of manager_rating and manager_comment is rejected with 42501';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: employee INSERT cannot pre-populate manager fields.
-- This is the INSERT-side bypass regression guard.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.goal (
      id, kra_category_id, title, weight, rating_scale_max,
      manager_rating, manager_comment
    )
    values (
      'f1700000-0000-4000-8000-000000000003',
      '44444444-4444-4444-8444-00000000000e',
      'Pre-rated insert bypass attempt',
      0.00,
      5,
      4.00,
      'Employee must not be able to seed this.'
    );
    raise exception 'ASSERTION FAILED: employee pre-rated goal INSERT should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: employee INSERT with manager_rating pre-populated is rejected with 42501';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: rating_scale_max freezes once a manager rating exists.
-- ============================================================================
begin;
update public.goal
set manager_rating = 4.00,
    manager_comment = 'Owner-created prerequisite for scale-lock verification.'
where id = '55555555-5555-4555-8555-000000000008';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    update public.goal
    set rating_scale_max = 10
    where id = '55555555-5555-4555-8555-000000000008';
    raise exception 'ASSERTION FAILED: employee scale change after manager rating should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: employee cannot change rating_scale_max after a manager rating exists';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: an employee cannot smuggle review_cycle_id through a
-- permitted draft-to-submitted status update.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1700000-0000-4000-8000-000000000010',
  'Employee plan-column guard fixture',
  '2027-01-01',
  '2027-12-31',
  'draft'
);

update public.review_cycle
set status = 'active'
where id = 'f1700000-0000-4000-8000-000000000010';

update public.review_cycle
set status = 'self_eval'
where id = 'f1700000-0000-4000-8000-000000000010';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    update public.employee_goal_plan
    set status = 'submitted',
        review_cycle_id = 'f1700000-0000-4000-8000-000000000010'
    where id = '33333333-3333-4333-8333-00000000000d';
    raise exception 'ASSERTION FAILED: employee review_cycle_id change should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: employee cannot change review_cycle_id through a status-update call';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: a line manager can rate a submitted plan during the
-- manager_eval window.
-- ============================================================================
begin;
update public.review_cycle
set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.employee_goal_plan
set status = 'submitted'
where id = '33333333-3333-4333-8333-00000000000c';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows integer;
  v_rating numeric;
  v_comment text;
begin
  update public.goal
  set manager_rating = 4.25,
      manager_comment = 'Manager positive-path verification fixture.'
  where id = '55555555-5555-4555-8555-000000000007';
  get diagnostics v_rows = row_count;

  select manager_rating, manager_comment
  into v_rating, v_comment
  from public.goal
  where id = '55555555-5555-4555-8555-000000000007';

  if v_rows <> 1
     or v_rating <> 4.25
     or v_comment <> 'Manager positive-path verification fixture.' then
    raise exception
      'Expected one manager-rating update, got rows %, rating %, comment %',
      v_rows,
      v_rating,
      v_comment;
  end if;

  raise notice 'PASS: line manager writes manager_rating and manager_comment on a submitted plan during manager_eval';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: manager-rate access is plan-status scoped. Rith's draft
-- aligned plan stays unrated even while the cycle-wide manager window is open.
-- ============================================================================
begin;
update public.review_cycle
set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.employee_goal_plan
set status = 'draft'
where id = '33333333-3333-4333-8333-00000000000d';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows integer;
begin
  update public.goal
  set manager_rating = 4.00,
      manager_comment = 'Draft-plan rating must be invisible to the policy.'
  where id = '55555555-5555-4555-8555-000000000008';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected zero manager updates on a draft plan, got %', v_rows;
  end if;

  raise notice 'PASS: line manager cannot rate Rith''s draft plan even during manager_eval';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: submitted -> manager_reviewed succeeds in manager_eval,
-- and every protected plan column remains unchanged.
-- ============================================================================
begin;
update public.review_cycle
set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.employee_goal_plan
set status = 'submitted'
where id = '33333333-3333-4333-8333-00000000000c';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_old_id uuid;
  v_old_review_cycle_id uuid;
  v_old_employee_id uuid;
  v_old_scale integer;
  v_old_created_at timestamptz;
  v_old_published_at timestamptz;
  v_new_status public.goal_plan_status;
  v_new_id uuid;
  v_new_review_cycle_id uuid;
  v_new_employee_id uuid;
  v_new_scale integer;
  v_new_created_at timestamptz;
  v_new_published_at timestamptz;
  v_rows integer;
begin
  select id, review_cycle_id, employee_id, overall_rating_scale_max,
         created_at, published_at
  into v_old_id, v_old_review_cycle_id, v_old_employee_id, v_old_scale,
       v_old_created_at, v_old_published_at
  from public.employee_goal_plan
  where id = '33333333-3333-4333-8333-00000000000c';

  update public.employee_goal_plan
  set status = 'manager_reviewed'
  where id = '33333333-3333-4333-8333-00000000000c';
  get diagnostics v_rows = row_count;

  select status, id, review_cycle_id, employee_id, overall_rating_scale_max,
         created_at, published_at
  into v_new_status, v_new_id, v_new_review_cycle_id, v_new_employee_id,
       v_new_scale, v_new_created_at, v_new_published_at
  from public.employee_goal_plan
  where id = '33333333-3333-4333-8333-00000000000c';

  if v_rows <> 1
     or v_new_status <> 'manager_reviewed'::public.goal_plan_status
     or v_new_id is distinct from v_old_id
     or v_new_review_cycle_id is distinct from v_old_review_cycle_id
     or v_new_employee_id is distinct from v_old_employee_id
     or v_new_scale is distinct from v_old_scale
     or v_new_created_at is distinct from v_old_created_at
     or v_new_published_at is distinct from v_old_published_at then
    raise exception
      'Unexpected manager transition result: rows %, status %, id %, cycle %, employee %, scale %, created %, published %',
      v_rows,
      v_new_status,
      v_new_id,
      v_new_review_cycle_id,
      v_new_employee_id,
      v_new_scale,
      v_new_created_at,
      v_new_published_at;
  end if;

  raise notice 'PASS: manager transitions submitted to manager_reviewed without changing protected plan columns';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: the manager transition cannot skip directly to finalized.
-- ============================================================================
begin;
update public.review_cycle
set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

update public.employee_goal_plan
set status = 'submitted'
where id = '33333333-3333-4333-8333-00000000000c';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
begin
  begin
    update public.employee_goal_plan
    set status = 'finalized'
    where id = '33333333-3333-4333-8333-00000000000c';
    raise exception 'ASSERTION FAILED: manager submitted-to-finalized transition should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: manager cannot transition a plan directly from submitted to finalized';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: an out-of-window manager transition is an RLS-silent
-- no-op, so the assertion is row-count zero rather than an expected exception.
-- ============================================================================
begin;
update public.review_cycle
set status = 'active'
where id = '22222222-2222-4222-8222-000000000001';

update public.employee_goal_plan
set status = 'submitted'
where id = '33333333-3333-4333-8333-00000000000c';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows integer;
begin
  update public.employee_goal_plan
  set status = 'manager_reviewed'
  where id = '33333333-3333-4333-8333-00000000000c';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected zero out-of-window manager transitions, got %', v_rows;
  end if;

  raise notice 'PASS: manager transition outside manager_eval affects zero rows';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: deferred plan validation rejects a non-100 category sum.
-- ============================================================================
begin;
update public.kra_category
set weight = 90.00
where id = '44444444-4444-4444-8444-00000000000e';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    perform public.validate_goal_plan_weights('33333333-3333-4333-8333-00000000000d');
    raise exception 'ASSERTION FAILED: non-100 plan weights should have been rejected';
  exception
    when sqlstate '23514' then
      null;
  end;

  raise notice 'PASS: validate_goal_plan_weights rejects a non-100 category total with 23514';
end $$;
rollback;

-- ============================================================================
-- Goal/rating Gate 1: full isolated employee-to-manager round trip. The goals
-- intentionally mix 5-point and 10-point scales, so 4.400 and 3.800 prove
-- per-goal normalization rather than a hidden all-out-of-five assumption.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1700000-0000-4000-8000-000000000100',
  'Full goal-rating round-trip fixture',
  '2028-01-01',
  '2028-12-31',
  'draft'
);

update public.review_cycle
set status = 'active'
where id = 'f1700000-0000-4000-8000-000000000100';

update public.review_cycle
set status = 'self_eval'
where id = 'f1700000-0000-4000-8000-000000000100';

insert into public.employee_goal_plan (
  id, review_cycle_id, employee_id, status, overall_rating_scale_max
)
values (
  'f1700000-0000-4000-8000-000000000101',
  'f1700000-0000-4000-8000-000000000100',
  '11111111-1111-4111-8111-000000000006',
  'draft',
  5
);

insert into public.review_participant (
  employee_goal_plan_id, participant_id, role
)
values
  (
    'f1700000-0000-4000-8000-000000000101',
    '11111111-1111-4111-8111-000000000006',
    'employee'
  ),
  (
    'f1700000-0000-4000-8000-000000000101',
    '11111111-1111-4111-8111-000000000002',
    'line_manager'
  ),
  (
    'f1700000-0000-4000-8000-000000000101',
    '11111111-1111-4111-8111-000000000001',
    'hr_admin'
  );

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

insert into public.kra_category (
  id, employee_goal_plan_id, name, weight
)
values
  (
    'f1700000-0000-4000-8000-000000000102',
    'f1700000-0000-4000-8000-000000000101',
    'Mixed-scale delivery',
    40.00
  ),
  (
    'f1700000-0000-4000-8000-000000000103',
    'f1700000-0000-4000-8000-000000000101',
    'Mixed-scale quality',
    60.00
  );

insert into public.goal (
  id, kra_category_id, title, weight, rating_scale_max
)
values
  (
    'f1700000-0000-4000-8000-000000000104',
    'f1700000-0000-4000-8000-000000000102',
    'Five-point delivery goal',
    50.00,
    5
  ),
  (
    'f1700000-0000-4000-8000-000000000105',
    'f1700000-0000-4000-8000-000000000102',
    'Ten-point delivery goal',
    50.00,
    10
  ),
  (
    'f1700000-0000-4000-8000-000000000106',
    'f1700000-0000-4000-8000-000000000103',
    'Five-point quality goal',
    100.00,
    5
  );

do $$
declare
  v_rows integer;
  v_self numeric;
begin
  update public.goal
  set self_rating = case id
        when 'f1700000-0000-4000-8000-000000000104'::uuid then 4.00
        when 'f1700000-0000-4000-8000-000000000105'::uuid then 6.00
        when 'f1700000-0000-4000-8000-000000000106'::uuid then 5.00
      end,
      self_comment = 'Completed before employee submission.'
  where id in (
    'f1700000-0000-4000-8000-000000000104',
    'f1700000-0000-4000-8000-000000000105',
    'f1700000-0000-4000-8000-000000000106'
  );
  get diagnostics v_rows = row_count;

  if v_rows <> 3 then
    raise exception 'Expected three employee self-rating updates, got %', v_rows;
  end if;

  select public.compute_goal_plan_rating(
    'f1700000-0000-4000-8000-000000000101',
    'self'
  ) into v_self;

  if v_self <> 4.400 then
    raise exception 'Expected hand-computed mixed-scale self rollup 4.400, got %', v_self;
  end if;

  update public.employee_goal_plan
  set status = 'submitted'
  where id = 'f1700000-0000-4000-8000-000000000101';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected employee submit transition to affect one row, got %', v_rows;
  end if;
end $$;

reset role;
update public.review_cycle
set status = 'manager_eval'
where id = 'f1700000-0000-4000-8000-000000000100';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
do $$
declare
  v_rows integer;
  v_self numeric;
  v_manager numeric;
  v_status public.goal_plan_status;
  v_scales integer[];
begin
  update public.goal
  set manager_rating = case id
        when 'f1700000-0000-4000-8000-000000000104'::uuid then 3.00
        when 'f1700000-0000-4000-8000-000000000105'::uuid then 8.00
        when 'f1700000-0000-4000-8000-000000000106'::uuid then 4.00
      end,
      manager_comment = 'Completed before manager review transition.'
  where id in (
    'f1700000-0000-4000-8000-000000000104',
    'f1700000-0000-4000-8000-000000000105',
    'f1700000-0000-4000-8000-000000000106'
  );
  get diagnostics v_rows = row_count;

  if v_rows <> 3 then
    raise exception 'Expected three manager-rating updates, got %', v_rows;
  end if;

  select public.compute_goal_plan_rating(
    'f1700000-0000-4000-8000-000000000101',
    'manager'
  ) into v_manager;

  update public.employee_goal_plan
  set status = 'manager_reviewed'
  where id = 'f1700000-0000-4000-8000-000000000101';
  get diagnostics v_rows = row_count;

  select
    max(overall_score) filter (where rating_type = 'self'::public.rating_type),
    max(overall_score) filter (where rating_type = 'manager'::public.rating_type)
  into v_self, v_manager
  from public.goal_plan_rating
  where employee_goal_plan_id = 'f1700000-0000-4000-8000-000000000101';

  select status
  into v_status
  from public.employee_goal_plan
  where id = 'f1700000-0000-4000-8000-000000000101';

  select array_agg(distinct rating_scale_max order by rating_scale_max)
  into v_scales
  from public.goal
  where id in (
    'f1700000-0000-4000-8000-000000000104',
    'f1700000-0000-4000-8000-000000000105',
    'f1700000-0000-4000-8000-000000000106'
  );

  if v_rows <> 1
     or v_self <> 4.400
     or v_manager <> 3.800
     or v_status <> 'manager_reviewed'::public.goal_plan_status
     or v_scales <> array[5, 10]::integer[] then
    raise exception
      'Unexpected round trip: rows %, self %, manager %, status %, scales %',
      v_rows,
      v_self,
      v_manager,
      v_status,
      v_scales;
  end if;

  raise notice 'PASS: full mixed-scale round trip computes 4.400 self / 3.800 manager and reaches manager_reviewed';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (1): an owner can create an objective in a cycle
-- where they are a participant.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows integer;
begin
  insert into public.objective (
    id, review_cycle_id, owner_id, title, description
  )
  values (
    'f1800000-0000-4000-8000-000000000001',
    '22222222-2222-4222-8222-000000000001',
    '11111111-1111-4111-8111-000000000004',
    'Owner-created objective verification',
    'Positive objective insert path.'
  );
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected owner objective insert to affect one row, got %', v_rows;
  end if;

  raise notice 'PASS: objective owner inserts into their own review cycle';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (1b): INSERT ... RETURNING succeeds for a non-HR
-- owner. This is the exact shape PostgREST issues for `.insert().select()`,
-- which the app's create-objective form uses. Regression guard for a latent
-- Phase 2 bug in objective_select_scoped: its self-referencing branch
-- (re-querying objective by id to check owner_id = auth.uid()) ran under a
-- snapshot that predates the row's own insertion when evaluated as part of
-- the same INSERT statement's RETURNING check, so a non-HR owner's own
-- create-and-read-back failed with a false RLS violation even though the
-- row was correctly written and a separate, later SELECT saw it fine. Fixed
-- in 0019 by checking owner_id = auth.uid() directly in the USING clause
-- before falling back to can_read_objective(). Plain INSERT without
-- RETURNING (as in (1) above) does not exercise this path, which is why a
-- dedicated RETURNING-based case is required to catch a regression.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_id uuid;
begin
  insert into public.objective (
    review_cycle_id, owner_id, title, description
  )
  values (
    '22222222-2222-4222-8222-000000000001',
    '11111111-1111-4111-8111-000000000004',
    'RETURNING regression fixture',
    'Proves insert-and-read-back works for a non-HR owner.'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'ASSERTION FAILED: INSERT ... RETURNING did not return the new objective id';
  end if;

  raise notice 'PASS: non-HR owner objective INSERT ... RETURNING succeeds';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (2): owner_id cannot claim another profile.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    insert into public.objective (
      review_cycle_id, owner_id, title
    )
    values (
      '22222222-2222-4222-8222-000000000001',
      '11111111-1111-4111-8111-000000000006',
      'Forged objective owner'
    );
    raise exception 'ASSERTION FAILED: forged objective owner_id should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: objective insert rejects a forged owner_id with 42501';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (3): an owner cannot target an invisible cycle.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000003',
  'Invisible objective cycle fixture',
  '2029-01-01',
  '2029-12-31',
  'draft'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    insert into public.objective (review_cycle_id, owner_id, title)
    values (
      'f1800000-0000-4000-8000-000000000003',
      '11111111-1111-4111-8111-000000000004',
      'Invisible-cycle objective'
    );
    raise exception 'ASSERTION FAILED: invisible-cycle objective insert should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: objective insert rejects an invisible cycle with 42501';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (4): objective owner inserts a pristine key result.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
begin
  insert into public.key_result (
    id, objective_id, title, metric_unit, start_value, target_value
  )
  values (
    'f1800000-0000-4000-8000-000000000004',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
    'Pristine key result',
    'percent',
    0,
    100
  )
  returning current_value, score into v_current, v_score;

  if v_current is not null or v_score is not null then
    raise exception 'Expected initial current_value/score to be null, got % / %', v_current, v_score;
  end if;

  begin
    insert into public.key_result (
      objective_id, title, start_value, target_value, current_value
    )
    values (
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
      'Owner-forged initial current value',
      0,
      100,
      50
    );
    raise exception 'ASSERTION FAILED: owner-forged initial current_value should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  begin
    insert into public.key_result (
      objective_id, title, start_value, target_value, score_override
    )
    values (
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
      'Owner-forged initial score override',
      0,
      100,
      0.900
    );
    raise exception 'ASSERTION FAILED: owner-forged initial score_override should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: owner key-result insert starts pristine and rejects protected initial values';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (5): a non-owner cannot add a key result.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.key_result (
      objective_id, title, start_value, target_value
    )
    values (
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
      'Non-owner key result',
      0,
      100
    );
    raise exception 'ASSERTION FAILED: non-owner key-result insert should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: non-owner key-result insert is rejected with 42501';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (6): direct derived/HR-only key-result writes are
-- rejected for an owner, while HR can set score_override.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    update public.key_result
    set current_value = 88
    where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
    raise exception 'ASSERTION FAILED: owner direct current_value update should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  begin
    update public.key_result
    set score = 0.123
    where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
    raise exception 'ASSERTION FAILED: owner direct score update should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  begin
    update public.key_result
    set score_override = 0.900
    where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
    raise exception 'ASSERTION FAILED: owner score_override update should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: owner direct current_value, score, and score_override writes are rejected with 42501';
end $$;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows integer;
  v_override numeric;
begin
  begin
    update public.key_result
    set current_value = 88
    where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
    raise exception 'ASSERTION FAILED: HR direct current_value update should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  update public.key_result
  set score_override = 0.900
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
  get diagnostics v_rows = row_count;

  select score_override into v_override
  from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_rows <> 1 or v_override <> 0.900 then
    raise exception 'Expected HR score_override update, got rows % / override %', v_rows, v_override;
  end if;
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (7): owner structural key-result updates succeed.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows integer;
  v_title text;
  v_target numeric;
  v_score numeric;
begin
  update public.key_result
  set title = 'Structurally updated key result',
      target_value = 200
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
  get diagnostics v_rows = row_count;

  select title, target_value, score
  into v_title, v_target, v_score
  from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_rows <> 1
     or v_title <> 'Structurally updated key result'
     or v_target <> 200
     or v_score <> 0.350 then
    raise exception 'Unexpected structural update: rows %, title %, target %, score %',
      v_rows, v_title, v_target, v_score;
  end if;

  raise notice 'PASS: owner structural key-result update succeeds and recomputes score';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (8): check-in propagation crosses the direct-write
-- guard and updates both current_value and score.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
begin
  insert into public.check_in (key_result_id, checked_in_by, new_value, note)
  values (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    '11111111-1111-4111-8111-000000000004',
    55,
    'Propagation regression verification.'
  );

  select current_value, score into v_current, v_score
  from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_current <> 55 or v_score <> 0.550 then
    raise exception 'Expected propagated current_value/score 55/0.550, got %/%', v_current, v_score;
  end if;

  raise notice 'PASS: check-in propagation remains valid through the key-result guard';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (9): a non-owner/non-HR caller cannot check in.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.check_in (key_result_id, checked_in_by, new_value, note)
    values (
      'cccccccc-cccc-4ccc-8ccc-000000000003',
      '11111111-1111-4111-8111-000000000006',
      10,
      'Non-owner check-in must fail.'
    );
    raise exception 'ASSERTION FAILED: non-owner check-in should have been rejected';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: non-owner check-in is rejected with 42501';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (10): owner check-in UPDATE/DELETE are silent
-- zero-row operations because no corresponding policies exist.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows integer;
begin
  update public.check_in
  set note = 'Owner rewrite must not persist.'
  where id = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'Expected owner check-in UPDATE to affect zero rows, got %', v_rows;
  end if;

  delete from public.check_in
  where id = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'Expected owner check-in DELETE to affect zero rows, got %', v_rows;
  end if;

  raise notice 'PASS: owner check-in UPDATE/DELETE are immutable zero-row operations';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (11): HR also cannot UPDATE/DELETE check-ins; an
-- authenticated parent key-result delete still physically cascades to history.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows integer;
begin
  update public.check_in
  set note = 'HR rewrite must not persist.'
  where id = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'Expected HR check-in UPDATE to affect zero rows, got %', v_rows;
  end if;

  delete from public.check_in
  where id = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'Expected HR check-in DELETE to affect zero rows, got %', v_rows;
  end if;
end $$;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows integer;
begin
  delete from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected owner parent key-result delete to affect one row, got %', v_rows;
  end if;
end $$;

reset role;
do $$
declare
  v_children integer;
begin
  select count(*) into v_children
  from public.check_in
  where key_result_id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_children <> 0 then
    raise exception 'Expected key-result cascade to remove all check-ins, got %', v_children;
  end if;

  raise notice 'PASS: HR check-ins are immutable and parent cascade-delete still succeeds';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (12): checked_in_by payload spoofing is overwritten.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_id uuid;
  v_checked_in_by uuid;
begin
  insert into public.check_in (
    key_result_id, checked_in_by, new_value, note
  )
  values (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    '11111111-1111-4111-8111-000000000006',
    60,
    'Spoofed actor verification.'
  )
  returning id into v_id;

  select checked_in_by into v_checked_in_by
  from public.check_in
  where id = v_id;

  if v_checked_in_by <> '11111111-1111-4111-8111-000000000004'::uuid then
    raise exception 'Expected checked_in_by to be overwritten to Dara, got %', v_checked_in_by;
  end if;

  raise notice 'PASS: check-in actor spoof is overwritten with auth.uid()';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (13): created_at payload backdating is overwritten.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_created_at timestamptz;
begin
  insert into public.check_in (
    key_result_id, checked_in_by, new_value, note, created_at
  )
  values (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    '11111111-1111-4111-8111-000000000004',
    61,
    'Spoofed timestamp verification.',
    '2000-01-01 00:00:00+00'
  )
  returning created_at into v_created_at;

  if v_created_at < current_timestamp - interval '5 seconds' then
    raise exception 'Expected a now-ish created_at, got backdated value %', v_created_at;
  end if;

  raise notice 'PASS: check-in created_at spoof is overwritten with now()';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (14): review cycles must be born in draft.
-- ============================================================================
begin;
do $$
begin
  begin
    insert into public.review_cycle (name, start_date, end_date, status)
    values ('Invalid initial cycle status', '2030-01-01', '2030-12-31', 'active');
    raise exception 'ASSERTION FAILED: non-draft review-cycle insert should have been rejected';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: non-draft review-cycle insert is rejected with 55000';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (15): one exact forward lifecycle step succeeds.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000015',
  'Valid forward-cycle fixture',
  '2030-01-01',
  '2030-12-31',
  'draft'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows integer;
  v_status public.review_cycle_status;
  v_name text;
begin
  update public.review_cycle
  set status = 'active'
  where id = 'f1800000-0000-4000-8000-000000000015';
  get diagnostics v_rows = row_count;

  select status into v_status
  from public.review_cycle
  where id = 'f1800000-0000-4000-8000-000000000015';

  if v_rows <> 1 or v_status <> 'active'::public.review_cycle_status then
    raise exception 'Expected one valid forward transition to active, got rows % / status %', v_rows, v_status;
  end if;

  update public.review_cycle
  set name = 'Valid forward-cycle fixture renamed'
  where id = 'f1800000-0000-4000-8000-000000000015';
  get diagnostics v_rows = row_count;

  select name into v_name
  from public.review_cycle
  where id = 'f1800000-0000-4000-8000-000000000015';

  if v_rows <> 1 or v_name <> 'Valid forward-cycle fixture renamed' then
    raise exception 'Expected status-preserving cycle edit, got rows % / name %', v_rows, v_name;
  end if;

  raise notice 'PASS: exact next review-cycle transition and status-preserving edit succeed';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (16): lifecycle steps cannot be skipped.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000016',
  'Cycle skip fixture',
  '2030-01-01',
  '2030-12-31',
  'draft'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    update public.review_cycle
    set status = 'manager_eval'
    where id = 'f1800000-0000-4000-8000-000000000016';
    raise exception 'ASSERTION FAILED: review-cycle status skip should have been rejected';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: review-cycle status skip is rejected with 55000';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (17): lifecycle status cannot move backward.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000017',
  'Cycle backward fixture',
  '2030-01-01',
  '2030-12-31',
  'draft'
);
update public.review_cycle
set status = 'active'
where id = 'f1800000-0000-4000-8000-000000000017';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    update public.review_cycle
    set status = 'draft'
    where id = 'f1800000-0000-4000-8000-000000000017';
    raise exception 'ASSERTION FAILED: backward review-cycle transition should have been rejected';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: backward review-cycle transition is rejected with 55000';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (18): a closed cycle cannot be reopened.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000018',
  'Closed-cycle reopen fixture',
  '2030-01-01',
  '2030-12-31',
  'draft'
);
update public.review_cycle set status = 'active'
where id = 'f1800000-0000-4000-8000-000000000018';
update public.review_cycle set status = 'self_eval'
where id = 'f1800000-0000-4000-8000-000000000018';
update public.review_cycle set status = 'manager_eval'
where id = 'f1800000-0000-4000-8000-000000000018';
update public.review_cycle set status = 'closed'
where id = 'f1800000-0000-4000-8000-000000000018';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows integer;
begin
  update public.review_cycle
  set name = 'Closed-cycle non-status edit remains allowed'
  where id = 'f1800000-0000-4000-8000-000000000018';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected closed-cycle non-status edit to affect one row, got %', v_rows;
  end if;

  begin
    update public.review_cycle
    set status = 'active'
    where id = 'f1800000-0000-4000-8000-000000000018';
    raise exception 'ASSERTION FAILED: closed review cycle should not reopen';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: reopening a closed review cycle is rejected with 55000';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (19): non-HR cycle updates remain silent no-ops.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows integer;
begin
  update public.review_cycle
  set status = 'self_eval'
  where id = '22222222-2222-4222-8222-000000000001';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected non-HR review-cycle update to affect zero rows, got %', v_rows;
  end if;

  raise notice 'PASS: non-HR review-cycle update remains a zero-row RLS no-op';
end $$;
rollback;

-- ============================================================================
-- Shared closed-cycle fixture for assertions 20-22.
-- ============================================================================
begin;
insert into public.review_cycle (id, name, start_date, end_date, status)
values (
  'f1800000-0000-4000-8000-000000000020',
  'Closed OKR-write fixture',
  '2031-01-01',
  '2031-12-31',
  'draft'
);

insert into public.objective (
  id, review_cycle_id, owner_id, title
)
values (
  'f1800000-0000-4000-8000-000000000021',
  'f1800000-0000-4000-8000-000000000020',
  '11111111-1111-4111-8111-000000000004',
  'Objective created before close'
);

insert into public.key_result (
  id, objective_id, title, start_value, target_value
)
values (
  'f1800000-0000-4000-8000-000000000022',
  'f1800000-0000-4000-8000-000000000021',
  'Key result created before close',
  0,
  100
);

update public.review_cycle set status = 'active'
where id = 'f1800000-0000-4000-8000-000000000020';
update public.review_cycle set status = 'self_eval'
where id = 'f1800000-0000-4000-8000-000000000020';
update public.review_cycle set status = 'manager_eval'
where id = 'f1800000-0000-4000-8000-000000000020';
update public.review_cycle set status = 'closed'
where id = 'f1800000-0000-4000-8000-000000000020';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);

-- Review-cycle / OKR Gate 1 (20): closed-cycle objective INSERT/UPDATE/DELETE
-- all fail with lifecycle-state SQLSTATE, including for HR.
do $$
begin
  begin
    insert into public.objective (review_cycle_id, owner_id, title)
    values (
      'f1800000-0000-4000-8000-000000000020',
      '11111111-1111-4111-8111-000000000001',
      'HR closed-cycle insert'
    );
    raise exception 'ASSERTION FAILED: HR objective insert into closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  begin
    update public.objective
    set title = 'HR closed-cycle update'
    where id = 'f1800000-0000-4000-8000-000000000021';
    raise exception 'ASSERTION FAILED: HR objective update in closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  begin
    delete from public.objective
    where id = 'f1800000-0000-4000-8000-000000000021';
    raise exception 'ASSERTION FAILED: HR objective delete in closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: closed-cycle objective writes reject HR with 55000';
end $$;

-- Review-cycle / OKR Gate 1 (21): closed-cycle key-result INSERT/UPDATE/DELETE
-- all fail with lifecycle-state SQLSTATE, including for HR.
do $$
begin
  begin
    insert into public.key_result (objective_id, title, start_value, target_value)
    values (
      'f1800000-0000-4000-8000-000000000021',
      'HR closed-cycle key-result insert',
      0,
      100
    );
    raise exception 'ASSERTION FAILED: HR key-result insert into closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  begin
    update public.key_result
    set title = 'HR closed-cycle key-result update'
    where id = 'f1800000-0000-4000-8000-000000000022';
    raise exception 'ASSERTION FAILED: HR key-result update in closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  begin
    delete from public.key_result
    where id = 'f1800000-0000-4000-8000-000000000022';
    raise exception 'ASSERTION FAILED: HR key-result delete in closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: closed-cycle key-result writes reject HR with 55000';
end $$;

-- Review-cycle / OKR Gate 1 (22): closed-cycle check-ins reject HR too.
do $$
begin
  begin
    insert into public.check_in (key_result_id, checked_in_by, new_value, note)
    values (
      'f1800000-0000-4000-8000-000000000022',
      '11111111-1111-4111-8111-000000000001',
      50,
      'HR closed-cycle check-in'
    );
    raise exception 'ASSERTION FAILED: HR check-in on closed cycle should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: closed-cycle check-in rejects HR with 55000';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (23): score clamps to zero below start_value.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
begin
  insert into public.check_in (key_result_id, checked_in_by, new_value, note)
  values (
    'cccccccc-cccc-4ccc-8ccc-000000000001',
    '11111111-1111-4111-8111-000000000004',
    -25,
    'Below-start lower-clamp verification.'
  );

  select current_value, score into v_current, v_score
  from public.key_result
  where id = 'cccccccc-cccc-4ccc-8ccc-000000000001';

  if v_current <> -25 or v_score <> 0.000 then
    raise exception 'Expected below-start current_value/score -25/0.000, got %/%', v_current, v_score;
  end if;

  raise notice 'PASS: key-result score clamps to zero below start_value';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (24): degenerate ranges keep score null.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
begin
  insert into public.key_result (
    id, objective_id, title, start_value, target_value
  )
  values (
    'f1800000-0000-4000-8000-000000000024',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
    'Degenerate range key result',
    5,
    5
  );

  insert into public.check_in (key_result_id, checked_in_by, new_value, note)
  values (
    'f1800000-0000-4000-8000-000000000024',
    '11111111-1111-4111-8111-000000000004',
    10,
    'Degenerate range verification.'
  );

  select current_value, score into v_current, v_score
  from public.key_result
  where id = 'f1800000-0000-4000-8000-000000000024';

  if v_current <> 10 or v_score is not null then
    raise exception 'Expected degenerate current_value/score 10/null, got %/%', v_current, v_score;
  end if;

  raise notice 'PASS: degenerate key-result range yields null score without error';
end $$;
rollback;

-- ============================================================================
-- Review-cycle / OKR Gate 1 (25): sequential check-ins are last-write-wins.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_current numeric;
  v_score numeric;
  v_check_ins integer;
begin
  insert into public.key_result (
    id, objective_id, title, start_value, target_value
  )
  values (
    'f1800000-0000-4000-8000-000000000025',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
    'Last-write-wins key result',
    0,
    100
  );

  insert into public.check_in (key_result_id, checked_in_by, new_value, note)
  values
    (
      'f1800000-0000-4000-8000-000000000025',
      '11111111-1111-4111-8111-000000000004',
      80,
      'First sequential check-in.'
    ),
    (
      'f1800000-0000-4000-8000-000000000025',
      '11111111-1111-4111-8111-000000000004',
      25,
      'Second sequential check-in.'
    );

  select current_value, score into v_current, v_score
  from public.key_result
  where id = 'f1800000-0000-4000-8000-000000000025';

  select count(*) into v_check_ins
  from public.check_in
  where key_result_id = 'f1800000-0000-4000-8000-000000000025';

  if v_current <> 25 or v_score <> 0.250 or v_check_ins <> 2 then
    raise exception 'Expected last-write-wins current/score/count 25/0.250/2, got %/%/%',
      v_current, v_score, v_check_ins;
  end if;

  raise notice 'PASS: second sequential check-in wins even when progress decreases';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (1): HR provisions a profile through real RLS and the
-- password timestamp stays null, which activates first-login rotation.
-- ============================================================================
begin;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token
)
values (
  'a1400000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'gate1.employee@example.com',
  crypt('TempPassword!1', gen_salt('bf')), now(), now(), now(),
  '', '', '', '', '', '', ''
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_password_changed_at timestamptz;
begin
  insert into public.profiles (
    id, full_name, email, manager_id, is_hr_admin
  )
  values (
    'a1400000-0000-4000-8000-000000000001',
    'Gate One Employee',
    'gate1.employee@example.com',
    '11111111-1111-4111-8111-000000000002',
    false
  )
  returning password_changed_at into v_password_changed_at;

  if v_password_changed_at is not null then
    raise exception 'Expected password_changed_at to remain null, got %',
      v_password_changed_at;
  end if;

  raise notice 'PASS: HR profile insert succeeds with password_changed_at null';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (2): a non-HR profile INSERT is an RLS exception (42501),
-- not a silent zero-row result.
-- ============================================================================
begin;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token
)
values (
  'a1400000-0000-4000-8000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'gate1.denied@example.com',
  crypt('TempPassword!1', gen_salt('bf')), now(), now(), now(),
  '', '', '', '', '', '', ''
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.profiles (id, full_name, email, is_hr_admin)
    values (
      'a1400000-0000-4000-8000-000000000002',
      'Denied Profile',
      'gate1.denied@example.com',
      false
    );
    raise exception 'ASSERTION FAILED: non-HR profile insert should be denied';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: non-HR profile insert raises 42501';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (3): the manager self-reference check remains 23514.
-- ============================================================================
begin;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token
)
values (
  'a1400000-0000-4000-8000-000000000003',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'gate1.self-manager@example.com',
  crypt('TempPassword!1', gen_salt('bf')), now(), now(), now(),
  '', '', '', '', '', '', ''
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.profiles (id, full_name, email, manager_id)
    values (
      'a1400000-0000-4000-8000-000000000003',
      'Self Manager',
      'gate1.self-manager@example.com',
      'a1400000-0000-4000-8000-000000000003'
    );
    raise exception 'ASSERTION FAILED: a profile must not manage itself';
  exception
    when sqlstate '23514' then
      null;
  end;

  raise notice 'PASS: self-referencing manager_id raises 23514';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (4): profile email uniqueness remains 23505.
-- ============================================================================
begin;
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token
)
values (
  'a1400000-0000-4000-8000-000000000004',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'gate1.auth-only@example.com',
  crypt('TempPassword!1', gen_salt('bf')), now(), now(), now(),
  '', '', '', '', '', '', ''
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.profiles (id, full_name, email)
    values (
      'a1400000-0000-4000-8000-000000000004',
      'Duplicate Email',
      'dara.sok@example.com'
    );
    raise exception 'ASSERTION FAILED: duplicate profile email should fail';
  exception
    when sqlstate '23505' then
      null;
  end;

  raise notice 'PASS: duplicate profile email raises 23505';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (5): employee cascade creates the goal and link atomically,
-- copies source structure, applies the editable weight, and clears ratings.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
declare
  v_default_goal_id uuid;
  v_default_cascade_id uuid;
  v_goal_id uuid;
  v_cascade_id uuid;
  v_matches integer;
begin
  select result.goal_id, result.goal_cascade_id
  into v_default_goal_id, v_default_cascade_id
  from public.create_cascaded_goal(
    '55555555-5555-4555-8555-000000000006',
    '44444444-4444-4444-8444-00000000000d',
    null
  ) as result;

  select result.goal_id, result.goal_cascade_id
  into v_goal_id, v_cascade_id
  from public.create_cascaded_goal(
    '55555555-5555-4555-8555-000000000006',
    '44444444-4444-4444-8444-00000000000d',
    37.50
  ) as result;

  select count(*)
  into v_matches
  from public.goal as cascaded
  join public.goal as source
    on source.id = '55555555-5555-4555-8555-000000000006'
  join public.goal_cascade as link
    on link.id = v_cascade_id
   and link.source_goal_id = source.id
   and link.cascaded_goal_id = cascaded.id
  join public.kra_category as category
    on category.id = cascaded.kra_category_id
  join public.employee_goal_plan as plan
    on plan.id = category.employee_goal_plan_id
  where cascaded.id = v_goal_id
    and cascaded.kra_category_id = '44444444-4444-4444-8444-00000000000d'
    and cascaded.title is not distinct from source.title
    and cascaded.description is not distinct from source.description
    and cascaded.target_metric is not distinct from source.target_metric
    and cascaded.rating_scale_max is not distinct from source.rating_scale_max
    and cascaded.weight = 37.50
    and cascaded.self_rating is null
    and cascaded.self_comment is null
    and cascaded.manager_rating is null
    and cascaded.manager_comment is null
    and link.cascaded_by = '11111111-1111-4111-8111-000000000005'
    and plan.employee_id = '11111111-1111-4111-8111-000000000005';

  if v_matches <> 1 then
    raise exception 'Expected one correctly copied employee cascade, got %', v_matches;
  end if;

  if not exists (
    select 1
    from public.goal as cascaded
    join public.goal as source
      on source.id = '55555555-5555-4555-8555-000000000006'
    join public.goal_cascade as link
      on link.id = v_default_cascade_id
     and link.cascaded_goal_id = cascaded.id
     and link.source_goal_id = source.id
    where cascaded.id = v_default_goal_id
      and cascaded.weight = source.weight
  ) then
    raise exception 'Null p_weight did not prefill the source weight';
  end if;

  raise notice 'PASS: create_cascaded_goal prefills or overrides weight on pristine copies';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (6): an unreadable source is denied without leaking it.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
begin
  begin
    perform public.create_cascaded_goal(
      '55555555-5555-4555-8555-000000000001',
      '44444444-4444-4444-8444-00000000000d',
      null
    );
    raise exception 'ASSERTION FAILED: unreadable cascade source should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: create_cascaded_goal rejects an unreadable source';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (7): actor spoofing is structurally absent from the RPC;
-- an attempted actor-bearing overload is undefined (42883).
-- ============================================================================
do $$
declare
  v_arg_names text[];
begin
  select p.proargnames
  into v_arg_names
  from pg_proc as p
  where p.oid = 'public.create_cascaded_goal(uuid,uuid,numeric)'::regprocedure;

  if 'p_cascaded_by' = any (coalesce(v_arg_names, array[]::text[]))
    or 'p_actor_id' = any (coalesce(v_arg_names, array[]::text[]))
  then
    raise exception 'Cascade RPC must derive its actor from auth.uid(), got args %',
      v_arg_names;
  end if;

  begin
    perform public.create_cascaded_goal(
      '55555555-5555-4555-8555-000000000006',
      '44444444-4444-4444-8444-00000000000d',
      50,
      '11111111-1111-4111-8111-000000000006'
    );
    raise exception 'ASSERTION FAILED: actor-bearing cascade overload should not exist';
  exception
    when sqlstate '42883' then
      null;
  end;

  raise notice 'PASS: cascade actor spoofing is structurally impossible';
end $$;

-- ============================================================================
-- Admin UI Gate 1 (8): no target-plan argument exists, and choosing a category
-- outside the caller's own plan is rejected by the goal INSERT RLS policy.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
declare
  v_arg_names text[];
begin
  select p.proargnames
  into v_arg_names
  from pg_proc as p
  where p.oid = 'public.create_cascaded_goal(uuid,uuid,numeric)'::regprocedure;

  if 'p_target_plan_id' = any (coalesce(v_arg_names, array[]::text[]))
    or 'p_employee_goal_plan_id' = any (coalesce(v_arg_names, array[]::text[]))
  then
    raise exception 'Cascade RPC must derive the plan from its category, got args %',
      v_arg_names;
  end if;

  begin
    perform public.create_cascaded_goal(
      '55555555-5555-4555-8555-000000000006',
      '44444444-4444-4444-8444-00000000000e',
      50
    );
    raise exception 'ASSERTION FAILED: foreign target category should be denied';
  exception
    when sqlstate '42501' then
      null;
  end;
end $$;
reset role;
do $$
begin
  if exists (
    select 1
    from public.goal
    where kra_category_id = '44444444-4444-4444-8444-00000000000e'
      and title = 'Team ships payments platform v2'
  ) then
    raise exception 'Foreign-plan cascade left a goal behind';
  end if;

  raise notice 'PASS: cascade target plan is structurally derived and caller-owned';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (9): cascaded_goal_id stays unique (23505).
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
declare
  v_goal_id uuid;
begin
  select result.goal_id
  into v_goal_id
  from public.create_cascaded_goal(
    '55555555-5555-4555-8555-000000000006',
    '44444444-4444-4444-8444-00000000000d',
    50
  ) as result;

  begin
    insert into public.goal_cascade (
      source_goal_id, cascaded_goal_id, cascaded_by
    )
    values (
      '55555555-5555-4555-8555-000000000006',
      v_goal_id,
      '11111111-1111-4111-8111-000000000005'
    );
    raise exception 'ASSERTION FAILED: a goal cannot be cascaded twice';
  exception
    when sqlstate '23505' then
      null;
  end;

  raise notice 'PASS: second link to a cascaded goal raises 23505';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (10): a failed RPC call leaves neither a goal nor a link.
-- ============================================================================
begin;
create temporary table admin_gate_atomic_counts (
  goal_count bigint not null,
  cascade_count bigint not null
) on commit drop;
insert into admin_gate_atomic_counts
select
  (select count(*) from public.goal),
  (select count(*) from public.goal_cascade);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
begin
  begin
    perform public.create_cascaded_goal(
      '55555555-5555-4555-8555-000000000006',
      'a1400000-0000-4000-8000-000000000010',
      50
    );
    raise exception 'ASSERTION FAILED: invalid category cascade should fail';
  exception
    when sqlstate '42501' then
      null;
  end;
end $$;
reset role;
do $$
declare
  v_goal_before bigint;
  v_cascade_before bigint;
  v_goal_after bigint;
  v_cascade_after bigint;
begin
  select goal_count, cascade_count
  into v_goal_before, v_cascade_before
  from admin_gate_atomic_counts;

  select count(*) into v_goal_after from public.goal;
  select count(*) into v_cascade_after from public.goal_cascade;

  if v_goal_after <> v_goal_before or v_cascade_after <> v_cascade_before then
    raise exception 'Failed cascade changed goal/link counts from %/% to %/%',
      v_goal_before, v_cascade_before, v_goal_after, v_cascade_after;
  end if;

  raise notice 'PASS: failed cascade RPC leaves no partial rows';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (11): goal alignment rejects an unreadable parent.
-- ============================================================================
begin;
delete from public.goal_alignment
where child_goal_id = '55555555-5555-4555-8555-000000000008';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.goal_alignment (
      parent_goal_id, child_goal_id, created_by
    )
    values (
      '55555555-5555-4555-8555-000000000001',
      '55555555-5555-4555-8555-000000000008',
      '11111111-1111-4111-8111-000000000006'
    );
    raise exception 'ASSERTION FAILED: unreadable goal alignment parent should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: goal alignment rejects an unreadable parent';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (12): goal alignment rejects created_by spoofing.
-- ============================================================================
begin;
delete from public.goal_alignment
where child_goal_id = '55555555-5555-4555-8555-000000000008';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.goal_alignment (
      parent_goal_id, child_goal_id, created_by
    )
    values (
      '55555555-5555-4555-8555-000000000006',
      '55555555-5555-4555-8555-000000000008',
      '11111111-1111-4111-8111-000000000005'
    );
    raise exception 'ASSERTION FAILED: spoofed goal alignment actor should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: goal alignment rejects a spoofed created_by';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (13a): objective alignment rejects an unreadable parent.
-- ============================================================================
begin;
delete from public.objective_alignment
where child_objective_id = 'bbbbbbbb-bbbb-4bbb-8bbb-000000000001';
insert into public.objective (
  id, review_cycle_id, owner_id, title, description
)
values (
  'a1400000-0000-4000-8000-000000000013',
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000003',
  'Unreadable parent objective',
  'Owned by Ben, who is not Dara''s manager.'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    insert into public.objective_alignment (
      parent_objective_id, child_objective_id, created_by
    )
    values (
      'a1400000-0000-4000-8000-000000000013',
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
      '11111111-1111-4111-8111-000000000004'
    );
    raise exception 'ASSERTION FAILED: unreadable objective parent should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: objective alignment rejects an unreadable parent';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (13b): objective alignment rejects created_by spoofing.
-- ============================================================================
begin;
delete from public.objective_alignment
where child_objective_id = 'bbbbbbbb-bbbb-4bbb-8bbb-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    insert into public.objective_alignment (
      parent_objective_id, child_objective_id, created_by
    )
    values (
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
      '11111111-1111-4111-8111-000000000005'
    );
    raise exception 'ASSERTION FAILED: spoofed objective alignment actor should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: objective alignment rejects a spoofed created_by';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (14): HR inserts review_participant through real RLS.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_id uuid;
begin
  insert into public.review_participant (
    employee_goal_plan_id, participant_id, role
  )
  values (
    '33333333-3333-4333-8333-00000000000c',
    '11111111-1111-4111-8111-000000000009',
    'matrix_manager'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'HR review_participant insert returned no id';
  end if;

  raise notice 'PASS: HR inserts review_participant through RLS';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (15): non-HR review_participant INSERT raises 42501.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
do $$
begin
  begin
    insert into public.review_participant (
      employee_goal_plan_id, participant_id, role
    )
    values (
      '33333333-3333-4333-8333-00000000000d',
      '11111111-1111-4111-8111-000000000009',
      'matrix_manager'
    );
    raise exception 'ASSERTION FAILED: non-HR participant insert should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: non-HR review_participant insert raises 42501';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (16): HR grants a kra_category scope through real RLS.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_id uuid;
begin
  insert into public.review_participant_scope (
    review_participant_id, scope_type, scope_id
  )
  values (
    '88888888-8888-4888-8888-000000000001',
    'kra_category',
    '44444444-4444-4444-8444-00000000000a'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'HR kra_category scope insert returned no id';
  end if;

  raise notice 'PASS: HR grants a kra_category scope through RLS';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (17): HR grants the objective polymorphic scope branch.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_id uuid;
begin
  insert into public.review_participant_scope (
    review_participant_id, scope_type, scope_id
  )
  values (
    '88888888-8888-4888-8888-000000000001',
    'objective',
    'bbbbbbbb-bbbb-4bbb-8bbb-000000000001'
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'HR objective scope insert returned no id';
  end if;

  raise notice 'PASS: HR grants an objective scope through RLS';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (18): non-HR scope INSERT raises 42501.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
begin
  begin
    insert into public.review_participant_scope (
      review_participant_id, scope_type, scope_id
    )
    values (
      '88888888-8888-4888-8888-000000000001',
      'kra_category',
      '44444444-4444-4444-8444-00000000000a'
    );
    raise exception 'ASSERTION FAILED: non-HR scope insert should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: non-HR review_participant_scope insert raises 42501';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (19): a line-manager participant cannot receive a scope.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.review_participant_scope (
      review_participant_id, scope_type, scope_id
    )
    select
      rp.id,
      'kra_category'::public.scope_type,
      '44444444-4444-4444-8444-00000000000a'::uuid
    from public.review_participant as rp
    where rp.employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a'
      and rp.participant_id = '11111111-1111-4111-8111-000000000002'
      and rp.role = 'line_manager';
    raise exception 'ASSERTION FAILED: line-manager scope should fail';
  exception
    when sqlstate '23514' then
      null;
  end;

  raise notice 'PASS: line-manager participant scope raises 23514';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (20): a nonexistent polymorphic category raises 23503.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.review_participant_scope (
      review_participant_id, scope_type, scope_id
    )
    values (
      '88888888-8888-4888-8888-000000000001',
      'kra_category',
      'a1400000-0000-4000-8000-000000000020'
    );
    raise exception 'ASSERTION FAILED: nonexistent scope target should fail';
  exception
    when sqlstate '23503' then
      null;
  end;

  raise notice 'PASS: nonexistent category scope raises 23503';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (21): duplicate scope grants remain 23505.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.review_participant_scope (
      review_participant_id, scope_type, scope_id
    )
    values (
      '88888888-8888-4888-8888-000000000001',
      'kra_category',
      '44444444-4444-4444-8444-00000000000b'
    );
    raise exception 'ASSERTION FAILED: duplicate scope should fail';
  exception
    when sqlstate '23505' then
      null;
  end;

  raise notice 'PASS: duplicate scope grant raises 23505';
end $$;
rollback;

-- ============================================================================
-- Admin UI Gate 1 (22): non-HR goal_cascade UPDATE is a zero-row RLS no-op.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
declare
  v_rows integer;
begin
  update public.goal_cascade
  set cascaded_at = cascaded_at + interval '1 second'
  where id = '66666666-6666-4666-8666-000000000001';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected non-HR cascade UPDATE to affect 0 rows, got %', v_rows;
  end if;

  raise notice 'PASS: non-HR goal_cascade UPDATE is a silent zero-row no-op';
end $$;
rollback;

\echo 'ALL 95 CHECKS PASSED'
