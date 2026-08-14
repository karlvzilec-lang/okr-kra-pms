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
  'active'
);

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
  'self_eval'
);

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
  'self_eval'
);

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

\echo 'ALL 46 CHECKS PASSED'
