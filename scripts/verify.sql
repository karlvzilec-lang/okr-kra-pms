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

\echo 'ALL CHECKS PASSED'
