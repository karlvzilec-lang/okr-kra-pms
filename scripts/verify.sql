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
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
select public.unpublish_employee_goal_plan(
  '33333333-3333-4333-8333-00000000000a',
  'verification setup for open publish guard'
);
select public.unfinalize_calibration_session(
  '44444444-4444-4444-8444-000000000001',
  'verification setup for open publish guard'
);
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
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
select public.unpublish_employee_goal_plan(
  '33333333-3333-4333-8333-00000000000a',
  'verification setup for pre-publish summary'
);
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
  v_names text[];
  v_dara_manager text;
  v_expected_manager text;
  v_vuthy_manager text;
  v_dara_scale integer;
  v_expected_dara_scale integer;
  v_vuthy_scale integer;
  v_expected_vuthy_scale integer;
  v_dara_final numeric;
  v_dara_manager_score numeric;
  v_vuthy_final numeric;
  v_vuthy_manager_score numeric;
  v_dara_band text;
  v_vuthy_band text;
  v_empty_rows int;
begin
  -- Vuthy's manager-rated, uncalibrated plan is the second published row.
  perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000e');

  -- A manager-less employee is a distinct export case. Keep the fixture local
  -- to this transaction so the seed remains realistic and untouched.
  update public.profiles
  set manager_id = null
  where id = '11111111-1111-4111-8111-000000000008';

  select count(*), array_agg(export.full_name)
  into v_rows, v_names
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001') as export;

  if v_rows <> 2 then
    raise exception 'Expected HR to see exactly 2 comp export rows after publishing Vuthy, got %', v_rows;
  end if;
  if v_names is distinct from array['Dara Sok', 'Vuthy Long']::text[] then
    raise exception 'Expected comp export ordered by full_name, got %', v_names;
  end if;

  select
    export.manager_full_name,
    export.overall_rating_scale_max,
    export.final_score,
    export.band_label
  into v_dara_manager, v_dara_scale, v_dara_final, v_dara_band
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001') as export
  where export.employee_id = '11111111-1111-4111-8111-000000000004';

  select manager.full_name, plan.overall_rating_scale_max, rating.overall_score
  into v_expected_manager, v_expected_dara_scale, v_dara_manager_score
  from public.employee_goal_plan as plan
  join public.profiles as employee on employee.id = plan.employee_id
  left join public.profiles as manager on manager.id = employee.manager_id
  join public.goal_plan_rating as rating
    on rating.employee_goal_plan_id = plan.id
   and rating.rating_type = 'manager'::public.rating_type
  where plan.id = '33333333-3333-4333-8333-00000000000a';

  select
    export.manager_full_name,
    export.overall_rating_scale_max,
    export.final_score,
    export.band_label
  into v_vuthy_manager, v_vuthy_scale, v_vuthy_final, v_vuthy_band
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001') as export
  where export.employee_id = '11111111-1111-4111-8111-000000000008';

  select plan.overall_rating_scale_max, rating.overall_score
  into v_expected_vuthy_scale, v_vuthy_manager_score
  from public.employee_goal_plan as plan
  join public.goal_plan_rating as rating
    on rating.employee_goal_plan_id = plan.id
   and rating.rating_type = 'manager'::public.rating_type
  where plan.id = '33333333-3333-4333-8333-00000000000e';

  if v_dara_manager is distinct from v_expected_manager then
    raise exception 'Expected Dara manager %, got %', v_expected_manager, v_dara_manager;
  end if;
  if v_vuthy_manager is not null then
    raise exception 'Expected manager_full_name null for manager-less Vuthy fixture, got %', v_vuthy_manager;
  end if;

  if v_dara_scale is distinct from v_expected_dara_scale
     or v_vuthy_scale is distinct from v_expected_vuthy_scale then
    raise exception
      'Expected export scales to match each plan (% / %), got % / %',
      v_expected_dara_scale, v_expected_vuthy_scale, v_dara_scale, v_vuthy_scale;
  end if;

  if v_dara_final is distinct from 3.200::numeric
     or v_dara_final is not distinct from v_dara_manager_score then
    raise exception
      'Expected Dara calibrated score 3.200 to override manager score %, got %',
      v_dara_manager_score, v_dara_final;
  end if;
  if v_vuthy_final is distinct from v_vuthy_manager_score then
    raise exception
      'Expected uncalibrated Vuthy final score to use manager score %, got %',
      v_vuthy_manager_score, v_vuthy_final;
  end if;

  if v_dara_band is null then
    raise exception 'Expected calibrated Dara export row to have a band label';
  end if;
  if v_vuthy_band is not null then
    raise exception 'Expected uncalibrated Vuthy export row to have null band, got %', v_vuthy_band;
  end if;

  insert into public.review_cycle (id, name, start_date, end_date, status)
  values (
    '22222222-2222-4222-8222-0000000000ff',
    'Comp export empty-cycle fixture',
    '2027-01-01',
    '2027-12-31',
    'draft'
  );

  select count(*) into v_empty_rows
  from public.comp_export_rows('22222222-2222-4222-8222-0000000000ff');

  if v_empty_rows <> 0 then
    raise exception 'Expected a cycle with no published plans to return 0 rows, got %', v_empty_rows;
  end if;

  raise notice 'PASS: comp_export_rows multi-row ordering, managers, plan scales, score precedence, bands, and empty cycles';
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
    'created_at', 'id', 'last_unfinalize_reason', 'last_unfinalized_at',
    'last_unfinalized_by', 'name', 'review_cycle_id', 'review_cycle_name',
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
    'last_unpublish_reason', 'last_unpublished_at', 'last_unpublished_by',
    'manager_full_name', 'original_score', 'overall_rating_scale_max', 'published_at'
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
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
select public.unpublish_employee_goal_plan(
  '33333333-3333-4333-8333-00000000000a',
  'verification setup for eligible plan listing'
);

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
-- Admin UI Gate 1 (21a): a non-HR caller cannot revoke a scope grant, and HR
-- can. RLS coverage for revokeMatrixScopeAction's DELETE, added when the
-- matrix-scopes page gained a revoke control -- previously only INSERT into
-- review_participant_scope was ever exercised through the app, so the DELETE
-- branch of review_participant_scope_hr_all's `for all` policy had no
-- dedicated assertion of its own.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
declare
  v_rows integer;
begin
  delete from public.review_participant_scope
  where id = '99999999-9999-4999-8999-000000000001';
  get diagnostics v_rows = row_count;

  if v_rows <> 0 then
    raise exception 'Expected non-HR scope delete to affect 0 rows, got %', v_rows;
  end if;

  raise notice 'PASS: non-HR review_participant_scope delete is a silent zero-row no-op';
end $$;
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows integer;
begin
  delete from public.review_participant_scope
  where id = '99999999-9999-4999-8999-000000000001';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'Expected HR scope delete to affect 1 row, got %', v_rows;
  end if;

  raise notice 'PASS: HR review_participant_scope delete succeeds';
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

-- ============================================================================
-- Admin UI Gate 1 (23): INSERT ... RETURNING succeeds for a non-HR employee
-- inserting their own goal. This is the exact shape PostgREST issues for
-- `.insert().select().single()`, which goal-plan-editor.tsx's addGoal()
-- uses. Regression guard for a latent Phase 1 bug in goal_select_scoped
-- (fixed in 0021): its self-referencing can_read_goal()/is_goal_participant()
-- branch re-queries goal by id, which runs under a snapshot that predates
-- the row's own insertion when evaluated as part of the same statement's
-- RETURNING check, so a non-HR employee's own create-and-read-back failed
-- with a false RLS violation even though the row was correctly written.
-- Plain INSERT without RETURNING does not exercise this path, so a
-- dedicated RETURNING-based case is required to catch a regression.
-- ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000005', true);
do $$
declare
  v_id uuid;
begin
  insert into public.goal (
    kra_category_id, title, weight, rating_scale_max
  )
  values (
    '44444444-4444-4444-8444-00000000000d',
    'RETURNING regression fixture',
    0,
    5
  )
  returning id into v_id;

  if v_id is null then
    raise exception 'ASSERTION FAILED: INSERT ... RETURNING did not return the new goal id';
  end if;

  raise notice 'PASS: non-HR employee goal INSERT ... RETURNING succeeds';
end $$;
rollback;

-- ============================================================================
-- Calibration reversal Gate 1: grant tightening and the complete controlled
-- unpublish -> unfinalize -> adjust -> finalize -> publish round trip.
-- ============================================================================
do $$
begin
  if has_table_privilege('authenticated', 'public.calibration_session', 'INSERT')
     or has_table_privilege('authenticated', 'public.calibration_session', 'UPDATE')
     or has_table_privilege('authenticated', 'public.calibration_session', 'DELETE')
     or has_table_privilege('authenticated', 'public.calibration_band', 'INSERT')
     or has_table_privilege('authenticated', 'public.calibration_band', 'UPDATE')
     or has_table_privilege('authenticated', 'public.calibration_band', 'DELETE') then
    raise exception 'Authenticated still has a direct calibration session/band write grant';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and policyname in ('calibration_session_hr_all', 'calibration_band_hr_all')
  ) then
    raise exception 'Blanket HR calibration session/band policies still exist';
  end if;

  raise notice 'PASS: authenticated session/band write grants and blanket HR policies are removed';
end $$;

begin;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);

do $$
declare
  v_status public.calibration_session_status;
begin
  begin
    update public.calibration_session
    set status = 'open'
    where id = '44444444-4444-4444-8444-000000000001';
    raise exception 'ASSERTION FAILED: raw HR-context unfinalize should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  select status into v_status
  from public.calibration_session
  where id = '44444444-4444-4444-8444-000000000001';

  if v_status <> 'finalized'::public.calibration_session_status then
    raise exception 'Raw unfinalize changed the seeded session to %', v_status;
  end if;

  raise notice 'PASS: raw HR-context unfinalize raises 55000 and leaves the session finalized';
end $$;

set local role authenticated;
do $$
declare
  v_participant_id uuid;
begin
  select id into v_participant_id
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001'
    and employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a';

  begin
    perform public.adjust_calibration_participant(v_participant_id, 3.300, 'must remain locked');
    raise exception 'ASSERTION FAILED: published participant adjustment should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: adjustment remains blocked for Dara in the finalized published fixture';
end $$;

set local role service_role;
do $$
begin
  begin
    update public.calibration_session
    set status = 'open'
    where id = '44444444-4444-4444-8444-000000000001';
    raise exception 'ASSERTION FAILED: service_role raw unfinalize should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  perform set_config('app.calibration_unfinalize_token', 'on', true);
  begin
    update public.calibration_session
    set status = 'open'
    where id = '44444444-4444-4444-8444-000000000001';
    raise exception 'ASSERTION FAILED: forged static unfinalize token should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  begin
    update public.employee_goal_plan
    set published_at = null
    where id = '33333333-3333-4333-8333-00000000000a';
    raise exception 'ASSERTION FAILED: service_role raw unpublish should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  perform set_config('app.calibration_unpublish_token', 'on', true);
  begin
    update public.employee_goal_plan
    set published_at = null
    where id = '33333333-3333-4333-8333-00000000000a';
    raise exception 'ASSERTION FAILED: forged static unpublish token should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: service_role raw reversals and forged static GUC flags raise 55000';
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
begin
  begin
    perform public.unpublish_employee_goal_plan(
      '33333333-3333-4333-8333-00000000000a',
      'employee must not reverse publication'
    );
    raise exception 'ASSERTION FAILED: non-HR unpublish should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  begin
    perform public.unfinalize_calibration_session(
      '44444444-4444-4444-8444-000000000001',
      'employee must not reopen calibration'
    );
    raise exception 'ASSERTION FAILED: non-HR unfinalize should fail';
  exception
    when sqlstate '42501' then
      null;
  end;

  raise notice 'PASS: both reversal functions reject non-HR callers with 42501';
end $$;

select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_message text;
begin
  begin
    perform public.unfinalize_calibration_session(
      '44444444-4444-4444-8444-000000000001',
      'published participants still block reopening'
    );
    raise exception 'ASSERTION FAILED: published participant should block unfinalize';
  exception
    when sqlstate '55000' then
      get stacked diagnostics v_message = message_text;
      if v_message not like '%1 published participant%' then
        raise exception 'Unfinalize blocker message did not name participant count: %', v_message;
      end if;
  end;

  raise notice 'PASS: unfinalize reports the published participant count with 55000';
end $$;

do $$
begin
  begin
    perform public.unpublish_employee_goal_plan(
      '33333333-3333-4333-8333-00000000000a', ''
    );
    raise exception 'ASSERTION FAILED: blank unpublish reason should fail';
  exception
    when sqlstate '23514' then
      null;
  end;

  begin
    perform public.unpublish_employee_goal_plan(
      '33333333-3333-4333-8333-00000000000a', 'short'
    );
    raise exception 'ASSERTION FAILED: too-short unpublish reason should fail';
  exception
    when sqlstate '23514' then
      null;
  end;

  raise notice 'PASS: blank and too-short unpublish reasons raise 23514';
end $$;

do $$
declare
  v_published_at timestamptz;
  v_score numeric;
  v_band_id uuid;
  v_session_status public.calibration_session_status;
  v_reversed_at timestamptz;
  v_reversed_by uuid;
  v_reason text;
begin
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'published in error'
  );

  select published_at, last_unpublished_at, last_unpublished_by, last_unpublish_reason
  into v_published_at, v_reversed_at, v_reversed_by, v_reason
  from public.employee_goal_plan
  where id = '33333333-3333-4333-8333-00000000000a';

  select calibrated_score, band_id
  into v_score, v_band_id
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001'
    and employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a';

  select status into v_session_status
  from public.calibration_session
  where id = '44444444-4444-4444-8444-000000000001';

  if v_published_at is not null
     or v_score <> 3.200
     or v_band_id <> '55555555-5555-4555-8555-000000000002'::uuid
     or v_session_status <> 'finalized'::public.calibration_session_status
     or v_reversed_at is null
     or v_reversed_by <> '11111111-1111-4111-8111-000000000001'::uuid
     or v_reason <> 'published in error' then
    raise exception 'Unexpected post-unpublish state: published %, score %, band %, session %, metadata %/%/%',
      v_published_at, v_score, v_band_id, v_session_status,
      v_reversed_at, v_reversed_by, v_reason;
  end if;

  raise notice 'PASS: unpublish preserves calibration/session state and atomically records metadata';
end $$;

do $$
declare
  v_rows integer;
begin
  select count(*) into v_rows
  from public.comp_export_rows('22222222-2222-4222-8222-000000000001') as export
  where export.employee_id = '11111111-1111-4111-8111-000000000004';

  if v_rows <> 0 then
    raise exception 'Unpublished Dara still appears in compensation export';
  end if;

  raise notice 'PASS: unpublished plan disappears from comp_export_rows';
end $$;

do $$
begin
  perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');
  if not exists (
    select 1 from public.employee_goal_plan
    where id = '33333333-3333-4333-8333-00000000000a'
      and published_at is not null
  ) then
    raise exception 'Re-publish while finalized did not persist';
  end if;
  raise notice 'PASS: an unpublished plan can be re-published while its session remains finalized';
end $$;

do $$
begin
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'prepare session for rescoring'
  );

  begin
    perform public.unfinalize_calibration_session(
      '44444444-4444-4444-8444-000000000001', 'short'
    );
    raise exception 'ASSERTION FAILED: too-short unfinalize reason should fail';
  exception
    when sqlstate '23514' then
      null;
  end;

  perform public.unfinalize_calibration_session(
    '44444444-4444-4444-8444-000000000001',
    're-score after publication error'
  );

  if not exists (
    select 1
    from public.calibration_session
    where id = '44444444-4444-4444-8444-000000000001'
      and status = 'open'
      and last_unfinalized_at is not null
      and last_unfinalized_by = '11111111-1111-4111-8111-000000000001'
      and last_unfinalize_reason = 're-score after publication error'
  ) then
    raise exception 'Unfinalize did not set open status and complete metadata';
  end if;

  raise notice 'PASS: unfinalize returns the empty-of-publications session to open with metadata';
end $$;

do $$
declare
  v_participant_id uuid;
begin
  select id into v_participant_id
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001'
    and employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a';

  perform public.adjust_calibration_participant(v_participant_id, 3.300, 'reopened adjustment');

  if not exists (
    select 1 from public.calibration_participant
    where id = v_participant_id and calibrated_score = 3.300
  ) then
    raise exception 'Adjustment after unfinalize did not persist';
  end if;

  begin
    perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');
    raise exception 'ASSERTION FAILED: publish in reopened session should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: reopened participant is editable and publishing while open stays blocked';
end $$;

set local role service_role;
do $$
begin
  begin
    delete from public.calibration_band
    where id = '55555555-5555-4555-8555-000000000002';
    raise exception 'ASSERTION FAILED: assigned band delete in open session should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: service_role cannot delete an assigned band from an open session';
end $$;

set local role authenticated;
do $$
declare
  v_participant_id uuid;
begin
  select id into v_participant_id
  from public.calibration_participant
  where calibration_session_id = '44444444-4444-4444-8444-000000000001'
    and employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a';

  perform public.adjust_calibration_participant(v_participant_id, 3.200, 'restore seeded score');
  perform public.finalize_calibration_session('44444444-4444-4444-8444-000000000001');
end $$;

set local role service_role;
do $$
begin
  begin
    delete from public.calibration_band
    where id = '55555555-5555-4555-8555-000000000002';
    raise exception 'ASSERTION FAILED: assigned band delete in finalized session should fail';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: service_role cannot delete an assigned band from a finalized session';
end $$;

set local role authenticated;
do $$
begin
  perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');

  if not exists (
    select 1
    from public.calibration_session as cs
    join public.calibration_participant as cp
      on cp.calibration_session_id = cs.id
    join public.employee_goal_plan as egp
      on egp.id = cp.employee_goal_plan_id
    where cs.id = '44444444-4444-4444-8444-000000000001'
      and cs.status = 'finalized'
      and cp.calibrated_score = 3.200
      and cp.band_id = '55555555-5555-4555-8555-000000000002'
      and egp.published_at is not null
  ) then
    raise exception 'Calibration round trip did not restore the seeded functional state';
  end if;

  raise notice 'PASS: re-finalize and re-publish restore the seeded functional state';
end $$;

set local role service_role;
do $$
declare
  v_session_id uuid;
  v_band_id uuid;
begin
  v_session_id := public.create_calibration_session_with_bands(
    'Unreferenced band delete fixture',
    '22222222-2222-4222-8222-000000000001',
    '[{"label":"Temporary","min_score":0.000,"max_score":5.001,"sort_order":1}]'::jsonb
  );

  select id into v_band_id
  from public.calibration_band
  where calibration_session_id = v_session_id;

  delete from public.calibration_band where id = v_band_id;

  if exists (select 1 from public.calibration_band where id = v_band_id) then
    raise exception 'Unreferenced calibration band was not deleted';
  end if;

  raise notice 'PASS: an unreferenced calibration band deletes successfully';
end $$;
rollback;

-- The published-plan rejoin guard is pinned separately with Vuthy's fixture
-- so its exact existing message cannot drift while adding reversal support.
begin;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_session_id uuid;
  v_message text;
begin
  v_session_id := public.create_calibration_session_with_bands(
    'Vuthy published rejoin fixture',
    '22222222-2222-4222-8222-000000000001',
    '[{"label":"All scores","min_score":0.000,"max_score":5.001,"sort_order":1}]'::jsonb
  );

  perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000e');

  begin
    perform public.add_plan_to_calibration_session(
      v_session_id,
      '33333333-3333-4333-8333-00000000000e'
    );
    raise exception 'ASSERTION FAILED: published Vuthy plan should not rejoin calibration';
  exception
    when sqlstate '55000' then
      get stacked diagnostics v_message = message_text;
      if v_message <> 'Published employee goal plan 33333333-3333-4333-8333-00000000000e cannot be recalibrated without an unpublish step' then
        raise exception 'Published-plan rejection message changed: %', v_message;
      end if;
  end;

  raise notice 'PASS: Vuthy published-plan rejoin retains the exact 55000 message';
end $$;
rollback;

begin;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
begin
  begin
    insert into public.calibration_session (
      id, review_cycle_id, name, status
    ) values (
      'f2200000-0000-4000-8000-000000000001',
      '22222222-2222-4222-8222-000000000001',
      'Illegal finalized insert fixture',
      'finalized'
    );
    raise exception 'ASSERTION FAILED: calibration session insert must start open';
  exception
    when sqlstate '55000' then
      null;
  end;

  raise notice 'PASS: direct calibration_session INSERT with finalized status raises 55000';
end $$;
rollback;


-- ============================================================================
-- PAST REVIEW-CYCLE VISIBILITY — Dara's FY2025 history
--
-- Five assertions covering both halves of the guarantee: an employee can reach
-- their own closed cycle and its real computed ratings, an unrelated employee
-- can reach neither the cycle nor the summary, and HR's short-circuit branch
-- of review_cycle_select_scoped still works.
--
-- The RLS check and the RPC check are pinned separately on purpose.
-- employee_review_summary is `security invoker`, so it inherits the caller's
-- RLS rather than enforcing anything itself — proving the table policy hides
-- the row does not prove the function returns nothing, and vice versa. Both
-- are asserted so neither can regress behind the other.
-- ============================================================================

-- 1. Dara sees his own past cycle.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_status public.review_cycle_status;
begin
  select status into v_status
  from public.review_cycle
  where id = '22222222-2222-4222-8222-000000000002';

  if v_status is null then
    raise exception 'Expected Dara to see the FY2025 cycle, got no row';
  end if;
  if v_status <> 'closed'::public.review_cycle_status then
    raise exception 'Expected the FY2025 cycle to be closed, got %', v_status;
  end if;

  raise notice 'PASS: an employee sees their own past (closed) review cycle';
end $$;
rollback;

-- 2. Dara's FY2025 summary returns exactly one row carrying the plan's real
--    computed ratings. The expected values are read back out of
--    goal_plan_rating rather than hardcoded, so this cross-validates the
--    summary against what compute_goal_plan_rating actually stored instead of
--    asserting the same constant in two places.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows int;
  v_summary jsonb;
  v_self numeric;
  v_manager numeric;
  v_stored_self numeric;
  v_stored_manager numeric;
begin
  select count(*) into v_rows
  from public.employee_review_summary(
    '22222222-2222-4222-8222-000000000002',
    '11111111-1111-4111-8111-000000000004'
  );

  if v_rows <> 1 then
    raise exception 'Expected exactly 1 summary row for Dara''s FY2025 plan, got %', v_rows;
  end if;

  select summary into v_summary
  from public.employee_review_summary(
    '22222222-2222-4222-8222-000000000002',
    '11111111-1111-4111-8111-000000000004'
  );

  select (r->>'overall_score')::numeric into v_self
  from jsonb_array_elements(v_summary->'kra_ratings') as r
  where r->>'rating_type' = 'self';

  select (r->>'overall_score')::numeric into v_manager
  from jsonb_array_elements(v_summary->'kra_ratings') as r
  where r->>'rating_type' = 'manager';

  select overall_score into v_stored_self
  from public.goal_plan_rating
  where employee_goal_plan_id = '33333333-3333-4333-8333-000000000010'
    and rating_type = 'self'::public.rating_type;

  select overall_score into v_stored_manager
  from public.goal_plan_rating
  where employee_goal_plan_id = '33333333-3333-4333-8333-000000000010'
    and rating_type = 'manager'::public.rating_type;

  if v_self is distinct from v_stored_self then
    raise exception 'Summary self rating % does not match stored goal_plan_rating %',
      v_self, v_stored_self;
  end if;
  if v_manager is distinct from v_stored_manager then
    raise exception 'Summary manager rating % does not match stored goal_plan_rating %',
      v_manager, v_stored_manager;
  end if;

  -- The seed's hand-computed expectations, pinned against the stored rows so a
  -- silent change to the rollup or to the fixture's weights fails here.
  if v_stored_self <> 4.400 then
    raise exception 'Expected FY2025 self rollup 4.400, got %', v_stored_self;
  end if;
  if v_stored_manager <> 4.000 then
    raise exception 'Expected FY2025 manager rollup 4.000, got %', v_stored_manager;
  end if;

  raise notice 'PASS: Dara''s FY2025 summary returns his real computed 4.400 / 4.000';
end $$;
rollback;

-- 3. Sophea (Ben's report, no FY2025 participation) cannot see the cycle.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000007', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.review_cycle
  where id = '22222222-2222-4222-8222-000000000002';

  if v_rows <> 0 then
    raise exception 'Expected Sophea to see 0 FY2025 cycle rows, got %', v_rows;
  end if;

  raise notice 'PASS: an unrelated employee cannot see a cycle they never participated in';
end $$;
rollback;

-- 4. The same caller gets zero rows out of the summary RPC. Separate from
--    check 3: the function is security invoker, so this pins that it actually
--    leans on that RLS rather than reaching past it.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000007', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.employee_review_summary(
    '22222222-2222-4222-8222-000000000002',
    '11111111-1111-4111-8111-000000000004'
  );

  if v_rows <> 0 then
    raise exception 'Expected 0 FY2025 summary rows for an unrelated caller, got %', v_rows;
  end if;

  raise notice 'PASS: employee_review_summary returns nothing for an unrelated caller on a past cycle';
end $$;
rollback;

-- 5. HR still sees the past cycle through the is_hr_admin() short-circuit.
--    Cheap, and it catches the case where a change narrowing the participant
--    branch accidentally narrows the HR branch with it.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows
  from public.review_cycle
  where id = '22222222-2222-4222-8222-000000000002';

  if v_rows <> 1 then
    raise exception 'Expected HR to see the FY2025 cycle, got % rows', v_rows;
  end if;

  raise notice 'PASS: HR still sees the past cycle via the is_hr_admin short-circuit';
end $$;
rollback;


-- ============================================================================
-- Round 9: audit_log (0023)
--
-- The gap this section closes: the 0022 reversal columns are a SNAPSHOT of the
-- latest reversal only. A second unpublish overwrites the first, so "how many
-- times was this plan pulled back, and by whom" was unanswerable. Assertion
-- R9-18 is the regression test for exactly that.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- R9-1. Structural: RLS is enabled on audit_log.
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_class
    where relnamespace = 'public'::regnamespace
      and relname = 'audit_log'
      and relrowsecurity
  ) then
    raise exception 'RLS is not enabled on public.audit_log';
  end if;

  raise notice 'PASS: R9-1 RLS enabled on audit_log';
end $$;

-- ----------------------------------------------------------------------------
-- R9-2. Structural: exactly ONE policy on audit_log, and it is SELECT-only.
--       No blanket `for all`, no write policy for any role.
-- ----------------------------------------------------------------------------
do $$
declare
  v_total    int;
  v_non_read text;
begin
  select count(*) into v_total
  from pg_policies
  where schemaname = 'public' and tablename = 'audit_log';

  if v_total <> 1 then
    raise exception 'Expected exactly 1 policy on audit_log, found %', v_total;
  end if;

  select string_agg(policyname || ' (' || cmd || ')', ', ')
  into v_non_read
  from pg_policies
  where schemaname = 'public'
    and tablename = 'audit_log'
    and cmd <> 'SELECT';

  if v_non_read is not null then
    raise exception 'audit_log has non-SELECT policies: %', v_non_read;
  end if;

  raise notice 'PASS: R9-2 audit_log has exactly one policy and it is SELECT-only';
end $$;

-- ----------------------------------------------------------------------------
-- R9-3. Structural: neither authenticated nor service_role holds any
--       INSERT/UPDATE/DELETE grant. A leaked service key cannot erase history.
-- ----------------------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(grantee || ':' || privilege_type, ', ')
  into v_bad
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'audit_log'
    and grantee in ('authenticated', 'service_role', 'anon', 'PUBLIC')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_bad is not null then
    raise exception 'audit_log has write grants that must not exist: %', v_bad;
  end if;

  raise notice 'PASS: R9-3 no INSERT/UPDATE/DELETE grant on audit_log for any API role';
end $$;

-- ----------------------------------------------------------------------------
-- R9-4. THE EMPIRICAL ACTOR-CAPTURE PROOF (Gate 1 ruling: prove, do not
--       assume). SECURITY DEFINER swaps the executing ROLE; auth.uid() reads
--       the request.jwt.claim.sub GUC. Independent mechanisms -- pinned here so
--       a future Postgres/Supabase change that breaks it fails CI loudly rather
--       than silently writing anonymous history.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_actor_id   uuid;
  v_actor_name text;
begin
  update public.profiles
  set is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000008';  -- Vuthy

  select al.actor_id, al.actor_name
  into v_actor_id, v_actor_name
  from public.audit_log as al
  order by al.occurred_at desc, al.id desc
  limit 1;

  if v_actor_id is distinct from '11111111-1111-4111-8111-000000000001'::uuid then
    raise exception
      'R9-4 FAILED: auth.uid() inside a SECURITY DEFINER trigger captured % '
      'instead of the calling HR admin. Actor capture is broken.',
      coalesce(v_actor_id::text, '<NULL>');
  end if;

  if v_actor_name <> 'Maly Hor' then
    raise exception 'R9-4 FAILED: expected actor_name Maly Hor, got %', v_actor_name;
  end if;

  raise notice
    'PASS: R9-4 auth.uid() resolves to the CALLER (not the definer role) inside a SECURITY DEFINER trigger';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-5. The null-actor fallback (ruling point 3). A write with no JWT claim
--       must produce the visible literal, NOT an error and NOT a blank cell.
--       Run as owner: no `set local role`, no claim set.
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '', true);
do $$
declare
  v_actor_id   uuid;
  v_actor_name text;
begin
  update public.profiles
  set is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000008';

  select al.actor_id, al.actor_name
  into v_actor_id, v_actor_name
  from public.audit_log as al
  order by al.occurred_at desc, al.id desc
  limit 1;

  if v_actor_id is not null then
    raise exception 'R9-5 FAILED: expected a NULL actor_id with no JWT claim, got %', v_actor_id;
  end if;

  if v_actor_name <> 'system (service role)' then
    raise exception
      'R9-5 FAILED: expected the fallback literal, got %',
      coalesce(v_actor_name, '<NULL>');
  end if;

  raise notice
    'PASS: R9-5 an actorless write logs "system (service role)" rather than erroring or rendering blank';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-6. profile.manager_changed: exact old/new values, not just row presence.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  -- Dara moves from Ana to Ben.
  update public.profiles
  set manager_id = '11111111-1111-4111-8111-000000000003'
  where id = '11111111-1111-4111-8111-000000000004';

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'profile.manager_changed'::public.audit_event_type then
    raise exception 'R9-6 FAILED: expected profile.manager_changed, got %', v_row.event_type;
  end if;
  if v_row.target_type <> 'profile'
     or v_row.target_id <> '11111111-1111-4111-8111-000000000004'::uuid then
    raise exception 'R9-6 FAILED: wrong target %/%', v_row.target_type, v_row.target_id;
  end if;
  if v_row.target_label <> 'Dara Sok' then
    raise exception 'R9-6 FAILED: expected target_label Dara Sok, got %', v_row.target_label;
  end if;
  if v_row.old_values ->> 'manager_id' <> '11111111-1111-4111-8111-000000000002' then
    raise exception 'R9-6 FAILED: old manager_id was %', v_row.old_values ->> 'manager_id';
  end if;
  if v_row.old_values ->> 'manager_name' <> 'Ana Kim' then
    raise exception 'R9-6 FAILED: old manager_name was %', v_row.old_values ->> 'manager_name';
  end if;
  if v_row.new_values ->> 'manager_id' <> '11111111-1111-4111-8111-000000000003' then
    raise exception 'R9-6 FAILED: new manager_id was %', v_row.new_values ->> 'manager_id';
  end if;
  if v_row.new_values ->> 'manager_name' <> 'Ben Ly' then
    raise exception 'R9-6 FAILED: new manager_name was %', v_row.new_values ->> 'manager_name';
  end if;
  if v_row.summary not like '%Ana Kim%' or v_row.summary not like '%Ben Ly%' then
    raise exception 'R9-6 FAILED: summary does not name both managers: %', v_row.summary;
  end if;

  raise notice 'PASS: R9-6 profile.manager_changed records exact old/new manager and a readable summary';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-7. Clearing a manager to NULL still logs, with the '(none)' label rather
--       than a null hole in the payload.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  update public.profiles
  set manager_id = null
  where id = '11111111-1111-4111-8111-000000000004';

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.new_values ->> 'manager_id' is not null then
    raise exception 'R9-7 FAILED: expected a JSON null manager_id, got %',
      v_row.new_values ->> 'manager_id';
  end if;
  if v_row.new_values ->> 'manager_name' <> '(none)' then
    raise exception 'R9-7 FAILED: expected (none), got %', v_row.new_values ->> 'manager_name';
  end if;

  raise notice 'PASS: R9-7 clearing a manager logs an explicit (none) rather than a blank';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-8. profile.hr_admin_changed on grant.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  update public.profiles
  set is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000005';  -- Lina

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'profile.hr_admin_changed'::public.audit_event_type then
    raise exception 'R9-8 FAILED: expected profile.hr_admin_changed, got %', v_row.event_type;
  end if;
  if (v_row.old_values ->> 'is_hr_admin')::boolean is not false then
    raise exception 'R9-8 FAILED: old is_hr_admin was %', v_row.old_values ->> 'is_hr_admin';
  end if;
  if (v_row.new_values ->> 'is_hr_admin')::boolean is not true then
    raise exception 'R9-8 FAILED: new is_hr_admin was %', v_row.new_values ->> 'is_hr_admin';
  end if;
  if v_row.summary not like '%granted%' then
    raise exception 'R9-8 FAILED: summary should say granted: %', v_row.summary;
  end if;

  raise notice 'PASS: R9-8 profile.hr_admin_changed records the false -> true grant';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-9. Revoking HR admin logs the mirror event. Symmetry matters: a log that
--       only records grants cannot answer "when did they lose access".
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  update public.profiles
  set is_hr_admin = false
  where id = '11111111-1111-4111-8111-000000000001';  -- Maly demotes herself

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if (v_row.new_values ->> 'is_hr_admin')::boolean is not false then
    raise exception 'R9-9 FAILED: new is_hr_admin was %', v_row.new_values ->> 'is_hr_admin';
  end if;
  if v_row.summary not like '%revoked%' then
    raise exception 'R9-9 FAILED: summary should say revoked: %', v_row.summary;
  end if;

  raise notice 'PASS: R9-9 revoking HR admin logs the mirror event';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-10. Two sensitive fields changed in ONE update produce TWO independently
--        filterable rows, not one merged row (ruling: two independent events).
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_manager_rows int;
  v_hr_rows      int;
  v_total        int;
begin
  update public.profiles
  set manager_id  = '11111111-1111-4111-8111-000000000003',
      is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000004';

  select count(*) into v_total from public.audit_log;
  select count(*) into v_manager_rows from public.audit_log
   where event_type = 'profile.manager_changed'::public.audit_event_type;
  select count(*) into v_hr_rows from public.audit_log
   where event_type = 'profile.hr_admin_changed'::public.audit_event_type;

  if v_total <> 2 or v_manager_rows <> 1 or v_hr_rows <> 1 then
    raise exception
      'R9-10 FAILED: expected 2 rows (1 manager + 1 hr_admin), got % total / % manager / % hr',
      v_total, v_manager_rows, v_hr_rows;
  end if;

  raise notice 'PASS: R9-10 one UPDATE touching both sensitive fields emits two independent events';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-11. NEGATIVE: editing a non-audited profile column emits ZERO rows. The
--        log must stay a signal, not a change feed.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
begin
  update public.profiles
  set full_name = 'Dara Sok (renamed)'
  where id = '11111111-1111-4111-8111-000000000004';

  select count(*) into v_rows from public.audit_log;

  if v_rows <> 0 then
    raise exception 'R9-11 FAILED: a non-audited field edit emitted % audit rows', v_rows;
  end if;

  raise notice 'PASS: R9-11 a non-audited profile field edit emits zero audit rows';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-12. NEGATIVE: an UPDATE that sets manager_id to its existing value emits
--        nothing. `is distinct from`, not "the column appeared in the SET".
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
begin
  update public.profiles
  set manager_id = '11111111-1111-4111-8111-000000000002'  -- already Ana
  where id = '11111111-1111-4111-8111-000000000004';

  select count(*) into v_rows from public.audit_log;

  if v_rows <> 0 then
    raise exception 'R9-12 FAILED: a no-op manager write emitted % audit rows', v_rows;
  end if;

  raise notice 'PASS: R9-12 rewriting a sensitive field with its current value emits nothing';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-13. matrix_scope.granted, with the full multi-field payload that ruled out
--        a single old_value/new_value text pair.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  -- Nita additionally gets Delivery & Execution on Dara's plan.
  insert into public.review_participant_scope (review_participant_id, scope_type, scope_id)
  values (
    '88888888-8888-4888-8888-000000000001',
    'kra_category',
    '44444444-4444-4444-8444-00000000000a'
  );

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'matrix_scope.granted'::public.audit_event_type then
    raise exception 'R9-13 FAILED: expected matrix_scope.granted, got %', v_row.event_type;
  end if;
  if v_row.old_values <> '{}'::jsonb then
    raise exception 'R9-13 FAILED: a grant must have an empty old_values, got %', v_row.old_values;
  end if;
  if v_row.new_values ->> 'matrix_manager_name' <> 'Nita Sar' then
    raise exception 'R9-13 FAILED: matrix_manager_name was %',
      v_row.new_values ->> 'matrix_manager_name';
  end if;
  if v_row.new_values ->> 'employee_name' <> 'Dara Sok' then
    raise exception 'R9-13 FAILED: employee_name was %', v_row.new_values ->> 'employee_name';
  end if;
  if v_row.new_values ->> 'scope_type' <> 'kra_category' then
    raise exception 'R9-13 FAILED: scope_type was %', v_row.new_values ->> 'scope_type';
  end if;
  if v_row.new_values ->> 'scope_label' <> 'Delivery & Execution' then
    raise exception 'R9-13 FAILED: scope_label was %', v_row.new_values ->> 'scope_label';
  end if;
  if v_row.new_values ->> 'review_cycle_name' is null then
    raise exception 'R9-13 FAILED: review_cycle_name missing from payload';
  end if;

  raise notice
    'PASS: R9-13 matrix_scope.granted carries all seven payload fields (manager, plan, employee, cycle, scope type/id/label)';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-14. matrix_scope.revoked. This is the brutal-QA gap: before 0023 a revoke
--        deleted the row and left no trace whatsoever.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  delete from public.review_participant_scope
  where id = '99999999-9999-4999-8999-000000000001';

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'matrix_scope.revoked'::public.audit_event_type then
    raise exception 'R9-14 FAILED: expected matrix_scope.revoked, got %', v_row.event_type;
  end if;
  if v_row.new_values <> '{}'::jsonb then
    raise exception 'R9-14 FAILED: a revoke must have an empty new_values, got %', v_row.new_values;
  end if;
  if v_row.old_values ->> 'scope_label' <> 'Quality & Collaboration' then
    raise exception 'R9-14 FAILED: revoked scope_label was %', v_row.old_values ->> 'scope_label';
  end if;
  if v_row.old_values ->> 'matrix_manager_name' <> 'Nita Sar' then
    raise exception 'R9-14 FAILED: revoked matrix_manager_name was %',
      v_row.old_values ->> 'matrix_manager_name';
  end if;
  if v_row.summary not like '%lost access to%' then
    raise exception 'R9-14 FAILED: summary should read as a revocation: %', v_row.summary;
  end if;

  raise notice
    'PASS: R9-14 revoking a matrix scope leaves a full audit row (the deleted row is otherwise unrecoverable)';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-15. calibration.plan_unpublished, written by the AFTER UPDATE trigger
--        reading 0022's snapshot columns. 0022 itself is untouched.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'Panel re-review requested after a scoring dispute was raised by the employee.'
  );

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'calibration.plan_unpublished'::public.audit_event_type then
    raise exception 'R9-15 FAILED: expected calibration.plan_unpublished, got %', v_row.event_type;
  end if;
  if v_row.target_id <> '33333333-3333-4333-8333-00000000000a'::uuid then
    raise exception 'R9-15 FAILED: target_id was %', v_row.target_id;
  end if;
  if v_row.old_values ->> 'published_at' is null then
    raise exception 'R9-15 FAILED: old published_at should be the prior timestamp, got null';
  end if;
  if v_row.new_values ->> 'published_at' is not null then
    raise exception 'R9-15 FAILED: new published_at should be null, got %',
      v_row.new_values ->> 'published_at';
  end if;
  if v_row.new_values ->> 'last_unpublish_reason' not like 'Panel re-review%' then
    raise exception 'R9-15 FAILED: reason was %', v_row.new_values ->> 'last_unpublish_reason';
  end if;
  if v_row.actor_id <> '11111111-1111-4111-8111-000000000001'::uuid then
    raise exception 'R9-15 FAILED: actor was %', coalesce(v_row.actor_id::text, '<NULL>');
  end if;

  raise notice
    'PASS: R9-15 unpublishing a plan logs via the AFTER UPDATE trigger reading 0022 snapshot columns';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-16. calibration.session_unfinalized, same construction.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_row public.audit_log;
begin
  -- Session unfinalize requires zero published participants, so pull the plan
  -- back first. That emits its own row; we assert on the last one.
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'Unpublished so the calibration session can be reopened for a second pass.'
  );
  perform public.unfinalize_calibration_session(
    '44444444-4444-4444-8444-000000000001',
    'Reopening to re-moderate one participant after new evidence from the line manager.'
  );

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.event_type <> 'calibration.session_unfinalized'::public.audit_event_type then
    raise exception 'R9-16 FAILED: expected calibration.session_unfinalized, got %', v_row.event_type;
  end if;
  if v_row.old_values ->> 'status' <> 'finalized' then
    raise exception 'R9-16 FAILED: old status was %', v_row.old_values ->> 'status';
  end if;
  if v_row.new_values ->> 'status' <> 'open' then
    raise exception 'R9-16 FAILED: new status was %', v_row.new_values ->> 'status';
  end if;
  if v_row.target_label <> 'FY2026 Engineering Calibration' then
    raise exception 'R9-16 FAILED: target_label was %', v_row.target_label;
  end if;
  if v_row.new_values ->> 'last_unfinalize_reason' not like 'Reopening to re-moderate%' then
    raise exception 'R9-16 FAILED: reason was %', v_row.new_values ->> 'last_unfinalize_reason';
  end if;

  raise notice 'PASS: R9-16 unfinalizing a session logs status finalized -> open with the reason';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-17. NEGATIVE: a plan UPDATE that does not cross the publish boundary emits
--        nothing. The WHEN clause is the transition, not the table.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
begin
  update public.employee_goal_plan
  set overall_rating_scale_max = 5
  where id = '33333333-3333-4333-8333-00000000000a';

  select count(*) into v_rows from public.audit_log;

  if v_rows <> 0 then
    raise exception 'R9-17 FAILED: a non-reversal plan update emitted % audit rows', v_rows;
  end if;

  raise notice 'PASS: R9-17 a plan update that is not an unpublish emits zero audit rows';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-18. THE REGRESSION TEST THIS ROUND EXISTS FOR. 0022's snapshot triple only
--        ever holds the LATEST reversal: a second unpublish overwrites the
--        first and the earlier one is gone forever. Two reversals must leave
--        TWO audit rows, each carrying its own reason.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows          int;
  v_first_reason  text;
  v_second_reason text;
  v_snapshot      text;
begin
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'FIRST reversal: scoring dispute raised, pulling the plan back for review.'
  );
  perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');
  perform public.unpublish_employee_goal_plan(
    '33333333-3333-4333-8333-00000000000a',
    'SECOND reversal: a further correction was needed after the first re-review.'
  );

  select count(*) into v_rows
  from public.audit_log
  where event_type = 'calibration.plan_unpublished'::public.audit_event_type;

  if v_rows <> 2 then
    raise exception 'R9-18 FAILED: two reversals produced % audit rows, expected 2', v_rows;
  end if;

  -- Oldest first here, deliberately: the point is that the EARLIER one survived.
  select al.new_values ->> 'last_unpublish_reason'
  into v_first_reason
  from public.audit_log as al
  where al.event_type = 'calibration.plan_unpublished'::public.audit_event_type
  order by al.occurred_at asc, al.id asc
  limit 1;

  select al.new_values ->> 'last_unpublish_reason'
  into v_second_reason
  from public.audit_log as al
  where al.event_type = 'calibration.plan_unpublished'::public.audit_event_type
  order by al.occurred_at desc, al.id desc
  limit 1;

  if v_first_reason not like 'FIRST reversal%' then
    raise exception 'R9-18 FAILED: the first reversal reason was lost, got %', v_first_reason;
  end if;
  if v_second_reason not like 'SECOND reversal%' then
    raise exception 'R9-18 FAILED: the second reversal reason was wrong, got %', v_second_reason;
  end if;

  -- And prove the gap is real rather than hypothetical: the 0022 column now
  -- holds ONLY the second reason. Without audit_log the first is unrecoverable.
  select egp.last_unpublish_reason
  into v_snapshot
  from public.employee_goal_plan as egp
  where egp.id = '33333333-3333-4333-8333-00000000000a';

  if v_snapshot not like 'SECOND reversal%' then
    raise exception 'R9-18 FAILED: expected the 0022 snapshot to hold only the latest, got %', v_snapshot;
  end if;

  raise notice
    'PASS: R9-18 two reversals leave two audit rows while the 0022 snapshot retains only the latest — the exact gap this round closes';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-19. RLS positive: an HR admin can read the log.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_rows int;
begin
  update public.profiles
  set is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000005';

  select count(*) into v_rows from public.audit_log;

  if v_rows <> 1 then
    raise exception 'R9-19 FAILED: HR admin sees % audit rows, expected 1', v_rows;
  end if;

  raise notice 'PASS: R9-19 an HR admin can read audit_log';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-20. RLS negative: a non-HR employee sees ZERO rows even though the write
--        that produced them definitely happened.
-- ----------------------------------------------------------------------------
begin;
-- Produce a row as owner so its existence is not in doubt.
select set_config('request.jwt.claim.sub', '', true);
update public.profiles
set manager_id = '11111111-1111-4111-8111-000000000003'
where id = '11111111-1111-4111-8111-000000000004';

do $$
declare
  v_owner_rows int;
begin
  select count(*) into v_owner_rows from public.audit_log;
  if v_owner_rows <> 1 then
    raise exception 'R9-20 SETUP FAILED: expected 1 seeded audit row, got %', v_owner_rows;
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.audit_log;

  if v_rows <> 0 then
    raise exception 'R9-20 FAILED: a non-HR employee read % audit rows, expected 0', v_rows;
  end if;

  raise notice 'PASS: R9-20 a non-HR employee reads zero audit rows despite the row existing';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-21. Even a matrix manager (an elevated non-HR role) sees nothing. Pinned
--        separately from R9-20: the scope-join policies elsewhere in this
--        schema make "elevated but not HR" the easiest role to leak to.
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '', true);
update public.profiles
set is_hr_admin = true
where id = '11111111-1111-4111-8111-000000000008';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000009', true);
do $$
declare
  v_rows int;
begin
  select count(*) into v_rows from public.audit_log;

  if v_rows <> 0 then
    raise exception 'R9-21 FAILED: a matrix manager read % audit rows, expected 0', v_rows;
  end if;

  raise notice 'PASS: R9-21 a matrix manager reads zero audit rows';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-22. IMMUTABILITY: UPDATE is rejected even for the table owner, who is
--        exempt from RLS and holds every grant. This is the layer that catches
--        the case where privilege checks are bypassed rather than broken.
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '', true);
update public.profiles
set is_hr_admin = true
where id = '11111111-1111-4111-8111-000000000008';

do $$
declare
  v_raised boolean := false;
begin
  begin
    update public.audit_log set summary = 'tampered';
  exception
    when others then
      v_raised := true;
      if sqlerrm not like '%append-only%' then
        raise exception 'R9-22 FAILED: wrong error on UPDATE: %', sqlerrm;
      end if;
  end;

  if not v_raised then
    raise exception 'R9-22 FAILED: the table owner rewrote an audit_log row';
  end if;

  raise notice 'PASS: R9-22 UPDATE on audit_log is rejected even for the RLS-exempt table owner';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-23. IMMUTABILITY: DELETE is rejected the same way.
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '', true);
update public.profiles
set is_hr_admin = true
where id = '11111111-1111-4111-8111-000000000008';

do $$
declare
  v_raised boolean := false;
  v_rows   int;
begin
  begin
    delete from public.audit_log;
  exception
    when others then
      v_raised := true;
      if sqlerrm not like '%append-only%' then
        raise exception 'R9-23 FAILED: wrong error on DELETE: %', sqlerrm;
      end if;
  end;

  if not v_raised then
    raise exception 'R9-23 FAILED: the table owner deleted an audit_log row';
  end if;

  select count(*) into v_rows from public.audit_log;
  if v_rows <> 1 then
    raise exception 'R9-23 FAILED: the row is gone, % remain', v_rows;
  end if;

  raise notice 'PASS: R9-23 DELETE on audit_log is rejected and the row survives';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-24. An authenticated HR admin cannot INSERT a forged row. Read access is
--        not write access: without this, HR could fabricate history.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_raised boolean := false;
begin
  begin
    insert into public.audit_log (
      event_type, actor_name, target_type, target_id, target_label, summary
    )
    values (
      'profile.hr_admin_changed'::public.audit_event_type,
      'forged', 'profile',
      '11111111-1111-4111-8111-000000000004',
      'forged', 'forged entry'
    );
  exception
    when others then
      v_raised := true;
  end;

  if not v_raised then
    raise exception 'R9-24 FAILED: an HR admin forged an audit_log row';
  end if;

  raise notice 'PASS: R9-24 even an HR admin cannot INSERT a forged audit row';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-25. actor_id's FK is ON DELETE RESTRICT: deleting a profile that owns
--        history fails rather than silently orphaning or nulling the actor.
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
set local role authenticated;
update public.profiles
set is_hr_admin = true
where id = '11111111-1111-4111-8111-000000000005';
reset role;

do $$
declare
  v_raised boolean := false;
  v_message text;
begin
  begin
    delete from public.profiles where id = '11111111-1111-4111-8111-000000000001';
  exception
    when foreign_key_violation then
      v_raised := true;
      v_message := sqlerrm;
  end;

  if not v_raised then
    raise exception 'R9-25 FAILED: deleting an actor with history was allowed';
  end if;

  -- Pinned to audit_log specifically: profiles has several other FKs, and a
  -- violation from one of those would otherwise let this pass for the wrong
  -- reason without proving the restrict clause on actor_id works.
  if v_message not like '%audit_log%' then
    raise exception
      'R9-25 FAILED: the FK violation came from something other than audit_log: %',
      v_message;
  end if;

  raise notice 'PASS: R9-25 on delete restrict prevents erasing an actor who owns audit history';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-26. Ordering contract. (occurred_at desc, id desc) must be a TOTAL order:
--        rows written in one statement share now(), so without the id
--        tiebreaker pagination silently repeats or skips rows. Pinned here
--        because the frontend and web/lib/pagination.ts depend on this exact
--        direction.
-- ----------------------------------------------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);
do $$
declare
  v_distinct_ts int;
  v_page_one    uuid[];
  v_page_two    uuid[];
  v_all         uuid[];
begin
  -- One statement, two rows: same transaction timestamp by construction.
  update public.profiles
  set manager_id  = '11111111-1111-4111-8111-000000000003',
      is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000004';

  select count(distinct occurred_at) into v_distinct_ts from public.audit_log;
  if v_distinct_ts <> 1 then
    raise exception
      'R9-26 SETUP: expected both rows to share one occurred_at, got % distinct values',
      v_distinct_ts;
  end if;

  select array_agg(id order by occurred_at desc, id desc) into v_all from public.audit_log;

  select array_agg(t.id) into v_page_one from (
    select id from public.audit_log order by occurred_at desc, id desc limit 1 offset 0
  ) as t;
  select array_agg(t.id) into v_page_two from (
    select id from public.audit_log order by occurred_at desc, id desc limit 1 offset 1
  ) as t;

  if v_page_one[1] <> v_all[1] or v_page_two[1] <> v_all[2] then
    raise exception 'R9-26 FAILED: paging does not match the full ordering';
  end if;
  if v_page_one[1] = v_page_two[1] then
    raise exception 'R9-26 FAILED: the same row appeared on both pages';
  end if;

  raise notice
    'PASS: R9-26 (occurred_at desc, id desc) is a total order, so paging never repeats or skips a same-timestamp row';
end $$;
rollback;

-- ----------------------------------------------------------------------------
-- R9-27. jsonb object constraints hold: the structured columns cannot degrade
--        into scalars or arrays, which would break every ->> read above and
--        every frontend render.
-- ----------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(needed.name, ', ')
  into v_missing
  from (values
    ('audit_log_old_values_is_object'),
    ('audit_log_new_values_is_object'),
    ('audit_log_summary_not_blank'),
    ('audit_log_actor_name_not_blank')
  ) as needed(name)
  where not exists (
    select 1
    from pg_constraint as c
    where c.conrelid = 'public.audit_log'::regclass
      and c.conname = needed.name
  );

  if v_missing is not null then
    raise exception 'R9-27 FAILED: missing audit_log constraints: %', v_missing;
  end if;

  raise notice 'PASS: R9-27 audit_log payload and label constraints are present';
end $$;

-- ----------------------------------------------------------------------------
-- R9-28. The audit trigger must never block the underlying HR action. The
--        actor is deleted from profiles mid-flight so the name lookup misses;
--        the profile write must still succeed and the row must still land with
--        the fallback name (ruling point 3's whole justification).
-- ----------------------------------------------------------------------------
begin;
select set_config('request.jwt.claim.sub', '99999999-9999-4999-8999-00000000dead', true);
do $$
declare
  v_row public.audit_log;
begin
  -- A JWT sub with no matching profiles row: exactly the "audit layer has a gap
  -- it did not anticipate" case that NOT NULL would have turned into an outage.
  update public.profiles
  set is_hr_admin = true
  where id = '11111111-1111-4111-8111-000000000008';

  if not (
    select p.is_hr_admin from public.profiles as p
    where p.id = '11111111-1111-4111-8111-000000000008'
  ) then
    raise exception 'R9-28 FAILED: the HR action itself did not take effect';
  end if;

  select * into v_row
  from public.audit_log
  order by occurred_at desc, id desc
  limit 1;

  if v_row.actor_name <> 'system (service role)' then
    raise exception 'R9-28 FAILED: expected the fallback name, got %', v_row.actor_name;
  end if;

  raise notice
    'PASS: R9-28 an unresolvable actor never blocks the HR write; the row lands with the fallback name';
end $$;
rollback;

\echo 'ALL 149 CHECKS PASSED'
