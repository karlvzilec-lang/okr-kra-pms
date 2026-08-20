-- seed.sql
-- Realistic Phase 1 sample data: 1 HR admin, 2 line managers, 5 employees,
-- 1 active review cycle, a fully-detailed plan for one employee, plus one
-- goal_cascade and one goal_alignment example.
--
-- Fixed UUIDs + ON CONFLICT DO NOTHING so this is safe to re-run.
--
-- Hand-check of the Average Method rollup for Dara Sok's plan
-- (compute_goal_plan_rating lands in 0004; these are the expected outputs):
--
--   categories: Delivery & Execution 60%, Quality & Collaboration 40%
--   item_score = rating / rating_scale_max (all scales are 5)
--
--   SELF ratings   4, 5, 3 (Delivery 50/30/20) and 4, 5 (Quality 60/40)
--     Delivery = (0.8*50 + 1.0*30 + 0.6*20) / 100 = 82/100  = 0.82
--     Quality  = (0.8*60 + 1.0*40)          / 100 = 88/100  = 0.88
--     Overall  = (0.82*60 + 0.88*40)        / 100 = 84.4/100 = 0.844
--     Rescaled onto scale max 5            => 0.844 * 5     = 4.220
--
--   MANAGER ratings 3, 4, 3 (Delivery) and 4, 4 (Quality)
--     Delivery = (0.6*50 + 0.8*30 + 0.6*20) / 100 = 66/100  = 0.66
--     Quality  = (0.8*60 + 0.8*40)          / 100 = 80/100  = 0.80
--     Overall  = (0.66*60 + 0.80*40)        / 100 = 71.6/100 = 0.716
--     Rescaled onto scale max 5            => 0.716 * 5     = 3.580
--
-- goal_plan_rating is intentionally NOT seeded — it is produced by calling
-- compute_goal_plan_rating(plan, 'self') and (plan, 'manager').

-- ---------------------------------------------------------------------------
-- auth.users (local stack only; password hashes are placeholders)
-- ---------------------------------------------------------------------------

-- Note: confirmation_token/recovery_token/email_change*/phone_change* are
-- explicitly '' rather than left to default NULL — GoTrue's Go client scans
-- these as non-nullable strings and returns "converting NULL to string is
-- unsupported" (500) on any auth call for a user row that omits them.
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current, phone_change, phone_change_token
)
values
  ('11111111-1111-4111-8111-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hr.admin@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana.manager@example.com',crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ben.manager@example.com',crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dara.sok@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lina.chan@example.com',  crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000006', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rith.pen@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000007', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sophea.im@example.com',  crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', ''),
  ('11111111-1111-4111-8111-000000000008', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'vuthy.long@example.com', crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', '')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- profiles — HR admin, 2 line managers, 5 employees split across the managers
-- ---------------------------------------------------------------------------

insert into public.profiles (id, full_name, email, manager_id, is_hr_admin)
values
  ('11111111-1111-4111-8111-000000000001', 'Maly Hor',   'hr.admin@example.com',    null,                                   true),
  ('11111111-1111-4111-8111-000000000002', 'Ana Kim',    'ana.manager@example.com', null,                                   false),
  ('11111111-1111-4111-8111-000000000003', 'Ben Ly',     'ben.manager@example.com', null,                                   false),
  -- Ana's reports
  ('11111111-1111-4111-8111-000000000004', 'Dara Sok',   'dara.sok@example.com',    '11111111-1111-4111-8111-000000000002', false),
  ('11111111-1111-4111-8111-000000000005', 'Lina Chan',  'lina.chan@example.com',   '11111111-1111-4111-8111-000000000002', false),
  ('11111111-1111-4111-8111-000000000006', 'Rith Pen',   'rith.pen@example.com',    '11111111-1111-4111-8111-000000000002', false),
  -- Ben's reports
  ('11111111-1111-4111-8111-000000000007', 'Sophea Im',  'sophea.im@example.com',   '11111111-1111-4111-8111-000000000003', false),
  ('11111111-1111-4111-8111-000000000008', 'Vuthy Long', 'vuthy.long@example.com',  '11111111-1111-4111-8111-000000000003', false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- review_cycle — one active cycle
-- ---------------------------------------------------------------------------

insert into public.review_cycle (id, name, start_date, end_date, status)
values
  ('22222222-2222-4222-8222-000000000001', 'FY2026 Annual Review', '2026-01-01', '2026-12-31', 'draft')
on conflict (id) do nothing;

-- Exercise the real lifecycle trigger rather than relying on table-owner
-- privileges to seed a non-draft status directly.
update public.review_cycle
set status = 'active'
where id = '22222222-2222-4222-8222-000000000001'
  and status = 'draft';

-- ---------------------------------------------------------------------------
-- employee_goal_plan
--   plan A: Dara Sok    — the fully-rated plan the rollup is checked against
--   plan B: Ana Kim     — manager's own plan; source of the cascade + the
--                         alignment parent (Ana is the EMPLOYEE on this plan)
--   plan C: Lina Chan   — receives the cascaded goal
--   plan D: Rith Pen    — bottom-up alignment up to Ana's goal
-- ---------------------------------------------------------------------------

insert into public.employee_goal_plan (id, review_cycle_id, employee_id, status, overall_rating_scale_max)
values
  ('33333333-3333-4333-8333-00000000000a', '22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000004', 'manager_reviewed', 5),
  ('33333333-3333-4333-8333-00000000000b', '22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000002', 'submitted',        5),
  ('33333333-3333-4333-8333-00000000000c', '22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000005', 'draft',            5),
  ('33333333-3333-4333-8333-00000000000d', '22222222-2222-4222-8222-000000000001', '11111111-1111-4111-8111-000000000006', 'draft',            5)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- review_participant — RLS keys off these rows, so every plan gets its
-- employee, its line manager, and the HR admin
-- ---------------------------------------------------------------------------

insert into public.review_participant (employee_goal_plan_id, participant_id, role)
values
  -- plan A (Dara, manager Ana)
  ('33333333-3333-4333-8333-00000000000a', '11111111-1111-4111-8111-000000000004', 'employee'),
  ('33333333-3333-4333-8333-00000000000a', '11111111-1111-4111-8111-000000000002', 'line_manager'),
  ('33333333-3333-4333-8333-00000000000a', '11111111-1111-4111-8111-000000000001', 'hr_admin'),
  -- plan B (Ana's own plan; no line manager above her in this seed)
  ('33333333-3333-4333-8333-00000000000b', '11111111-1111-4111-8111-000000000002', 'employee'),
  ('33333333-3333-4333-8333-00000000000b', '11111111-1111-4111-8111-000000000001', 'hr_admin'),
  -- plan C (Lina, manager Ana)
  ('33333333-3333-4333-8333-00000000000c', '11111111-1111-4111-8111-000000000005', 'employee'),
  ('33333333-3333-4333-8333-00000000000c', '11111111-1111-4111-8111-000000000002', 'line_manager'),
  ('33333333-3333-4333-8333-00000000000c', '11111111-1111-4111-8111-000000000001', 'hr_admin'),
  -- plan D (Rith, manager Ana)
  ('33333333-3333-4333-8333-00000000000d', '11111111-1111-4111-8111-000000000006', 'employee'),
  ('33333333-3333-4333-8333-00000000000d', '11111111-1111-4111-8111-000000000002', 'line_manager'),
  ('33333333-3333-4333-8333-00000000000d', '11111111-1111-4111-8111-000000000001', 'hr_admin')
on conflict (employee_goal_plan_id, participant_id, role) do nothing;

-- ---------------------------------------------------------------------------
-- kra_category — category weights sum to 100 within each plan
-- ---------------------------------------------------------------------------

insert into public.kra_category (id, employee_goal_plan_id, name, description, weight)
values
  -- plan A: 60 + 40 = 100
  ('44444444-4444-4444-8444-00000000000a', '33333333-3333-4333-8333-00000000000a', 'Delivery & Execution',    'Shipping committed work on schedule and to spec.', 60.00),
  ('44444444-4444-4444-8444-00000000000b', '33333333-3333-4333-8333-00000000000a', 'Quality & Collaboration', 'Code quality, review participation, teamwork.',     40.00),
  -- plan B: 100
  ('44444444-4444-4444-8444-00000000000c', '33333333-3333-4333-8333-00000000000b', 'Team Outcomes',           'Outcomes Ana owns for the whole team.',            100.00),
  -- plan C: 100
  ('44444444-4444-4444-8444-00000000000d', '33333333-3333-4333-8333-00000000000c', 'Delivery & Execution',    'Shipping committed work on schedule and to spec.',  100.00),
  -- plan D: 100
  ('44444444-4444-4444-8444-00000000000e', '33333333-3333-4333-8333-00000000000d', 'Platform Reliability',    'Keeping the platform stable and observable.',       100.00)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- goal — goal weights sum to 100 within each category
-- ---------------------------------------------------------------------------

insert into public.goal (
  id, kra_category_id, title, description, weight, target_metric, rating_scale_max,
  self_rating, self_comment, manager_rating, manager_comment
)
values
  -- plan A / Delivery & Execution: 50 + 30 + 20 = 100
  ('55555555-5555-4555-8555-000000000001', '44444444-4444-4444-8444-00000000000a',
   'Ship the payments migration',
   'Move billing off the legacy processor with no customer-visible downtime.',
   50.00, 'Migration complete by Q3, zero P1 incidents', 5,
   4.00, 'Shipped on time; one rollback needed in staging.',
   3.00, 'Delivered, but the staging rollback cost the team a week.'),

  ('55555555-5555-4555-8555-000000000002', '44444444-4444-4444-8444-00000000000a',
   'Reduce checkout p95 latency',
   'Bring checkout p95 under 400ms sustained.',
   30.00, 'p95 < 400ms for 30 consecutive days', 5,
   5.00, 'Hit 310ms p95, sustained for 6 weeks.',
   4.00, 'Strong result; target was comfortably met.'),

  ('55555555-5555-4555-8555-000000000003', '44444444-4444-4444-8444-00000000000a',
   'Close the Q2 bug backlog',
   'Clear all P2+ bugs carried over from Q2.',
   20.00, 'Zero P2+ bugs older than 60 days', 5,
   3.00, 'Cleared most, 4 P2s still open at year end.',
   3.00, 'Partially met; backlog is smaller but not cleared.'),

  -- plan A / Quality & Collaboration: 60 + 40 = 100
  ('55555555-5555-4555-8555-000000000004', '44444444-4444-4444-8444-00000000000b',
   'Raise test coverage on billing',
   'Bring the billing module to meaningful coverage of critical paths.',
   60.00, 'Critical-path coverage >= 80%', 5,
   4.00, 'Reached 83% on critical paths.',
   4.00, 'Met the target, good discipline here.'),

  ('55555555-5555-4555-8555-000000000005', '44444444-4444-4444-8444-00000000000b',
   'Mentor one junior engineer',
   'Weekly pairing and structured feedback for one junior teammate.',
   40.00, 'Weekly sessions sustained across two quarters', 5,
   5.00, 'Weekly pairing sustained all year; mentee promoted.',
   4.00, 'Genuinely valuable mentoring, consistent all year.'),

  -- plan B / Team Outcomes: 100 (Ana's own goal — cascade source + align parent)
  ('55555555-5555-4555-8555-000000000006', '44444444-4444-4444-8444-00000000000c',
   'Team ships payments platform v2',
   'Whole-team outcome: v2 of the payments platform live for all customers.',
   100.00, 'v2 live for 100% of customers by Q4', 5,
   4.00, 'Team delivered v2 to all customers in Q4.',
   null, null),

  -- plan C / Delivery & Execution: 100 (the CASCADED copy of Ana's goal)
  ('55555555-5555-4555-8555-000000000007', '44444444-4444-4444-8444-00000000000d',
   'Team ships payments platform v2',
   'Cascaded from Ana Kim: own the ledger service portion of payments v2.',
   100.00, 'Ledger service live in v2 by Q4', 5,
   null, null, null, null),

  -- plan D / Platform Reliability: 100 (independently authored, then ALIGNED up)
  ('55555555-5555-4555-8555-000000000008', '44444444-4444-4444-8444-00000000000e',
   'Cut payment webhook failure rate',
   'Independently authored by Rith, later aligned upward to Ana''s team goal.',
   100.00, 'Webhook failure rate < 0.1%', 5,
   null, null, null, null)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- goal_cascade — TOP-DOWN: Ana's goal was copied into Lina's plan.
-- Ana is the cascader; the copy is the cascaded_goal.
-- ---------------------------------------------------------------------------

insert into public.goal_cascade (id, source_goal_id, cascaded_goal_id, cascaded_by)
values
  ('66666666-6666-4666-8666-000000000001',
   '55555555-5555-4555-8555-000000000006',  -- Ana's team goal
   '55555555-5555-4555-8555-000000000007',  -- the copy in Lina's plan
   '11111111-1111-4111-8111-000000000002')  -- cascaded by Ana
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- goal_alignment — BOTTOM-UP: Rith's pre-existing goal is linked upward to
-- Ana's goal. Nothing was copied, and Rith is not a participant on Ana's own
-- plan — this is the case Ruling 3 protects.
-- ---------------------------------------------------------------------------

insert into public.goal_alignment (id, parent_goal_id, child_goal_id, created_by)
values
  ('77777777-7777-4777-8777-000000000001',
   '55555555-5555-4555-8555-000000000006',  -- Ana's team goal (parent)
   '55555555-5555-4555-8555-000000000008',  -- Rith's own goal (child)
   '11111111-1111-4111-8111-000000000006')  -- created by Rith himself
on conflict (id) do nothing;

-- ===========================================================================
-- PHASE 2 ADDITIONS — OKR overlay + matrix manager
-- Everything above this line is Phase 1 seed data and is left untouched.
-- Fixed UUIDs + ON CONFLICT DO NOTHING, same as above: safe to re-run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Matrix manager — a NEW person who is nobody's line manager in this seed.
-- Nita Sar has no manager_id relationship to Dara at all; her only access is
-- the explicit review_participant + review_participant_scope grant below.
-- That is exactly the case the scope join must protect.
-- ---------------------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current, phone_change, phone_change_token
)
values
  ('11111111-1111-4111-8111-000000000009', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'nita.sar@example.com', crypt('password123', gen_salt('bf')), now(), now(), now(), '', '', '', '', '', '', '')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, email, manager_id, is_hr_admin)
values
  ('11111111-1111-4111-8111-000000000009', 'Nita Sar', 'nita.sar@example.com', null, false)
on conflict (id) do nothing;

-- Nita joins Dara's plan (plan A) as a matrix manager. Fixed id so the scope
-- row below can reference it without a lookup.
insert into public.review_participant (id, employee_goal_plan_id, participant_id, role)
values
  ('88888888-8888-4888-8888-000000000001',
   '33333333-3333-4333-8333-00000000000a',  -- Dara's plan
   '11111111-1111-4111-8111-000000000009',  -- Nita
   'matrix_manager')
on conflict (employee_goal_plan_id, participant_id, role) do nothing;

-- Scope grant: ONE category only — Quality & Collaboration. Nita has no grant
-- on Delivery & Execution (44...00a), so goals 55...001/002/003 must stay
-- unwritable for her.
insert into public.review_participant_scope (id, review_participant_id, scope_type, scope_id)
values
  ('99999999-9999-4999-8999-000000000001',
   '88888888-8888-4888-8888-000000000001',
   'kra_category',
   '44444444-4444-4444-8444-00000000000b')  -- Quality & Collaboration
on conflict (id) do nothing;

-- Advisory rating on a goal INSIDE the granted category. Separate table from
-- goal.manager_rating, which stays Ana's alone.
--
-- Note for verification: the RLS write path additionally requires the plan's
-- cycle to be in 'manager_eval'; the seeded cycle is 'active', and seeding
-- runs as the table owner (RLS-exempt). Flip the cycle status inside the test
-- to exercise the policy rather than relying on seed state.
insert into public.goal_matrix_rating (id, goal_id, participant_id, rating, comment)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000001',
   '55555555-5555-4555-8555-000000000004',  -- Raise test coverage on billing
   '11111111-1111-4111-8111-000000000009',  -- Nita
   4.00,
   'Partnered with my team on billing test coverage; consistently thorough. Advisory input only.')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Objectives — 2 objectives x 2 key results.
--   Objective 1 (Dara)  — ON TRACK, both key results score ~0.70
--   Objective 2 (Ana)   — BEHIND,   both key results score ~0.30
-- Ana's is the alignment PARENT, Dara's the CHILD (see the alignment note).
-- ---------------------------------------------------------------------------

insert into public.objective (id, review_cycle_id, owner_id, title, description, status)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
   '22222222-2222-4222-8222-000000000001',
   '11111111-1111-4111-8111-000000000004',  -- Dara
   'Make checkout fast and boring',
   'Reduce latency and failure noise in checkout so it stops being a weekly topic.',
   'active'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
   '22222222-2222-4222-8222-000000000001',
   '11111111-1111-4111-8111-000000000002',  -- Ana
   'Payments platform v2 adopted org-wide',
   'Team-level outcome Ana owns; Dara''s objective aligns upward to this one.',
   'active')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- key_result — current_value is seeded explicitly and matches the LAST
-- check-in below, so the 0009 check-in trigger re-deriving current_value is a
-- no-op rather than a contradiction.
--
-- Expected scores from clamp((current - start) / nullif(target - start, 0), 0, 1):
--   cc...001  (70 - 0)     / (100 - 0)     = 0.700
--   cc...002  (330 - 400)  / (300 - 400)   = 0.700   (a DECREASING metric)
--   cc...003  (6 - 0)      / (20 - 0)      = 0.300
--   cc...004  (300 - 0)    / (1000 - 0)    = 0.300
-- cc...002 is deliberately a downward target: it proves the formula handles
-- target < start without a special case, since both sides go negative.
-- ---------------------------------------------------------------------------

insert into public.key_result (
  id, objective_id, title, metric_unit, start_value, target_value, current_value, score_override
)
values
  -- Objective 1 (Dara) — on track, ~0.70
  ('cccccccc-cccc-4ccc-8ccc-000000000001',
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
   'Checkout success rate on retried payments', '%',
   0, 100, 70, null),

  ('cccccccc-cccc-4ccc-8ccc-000000000002',
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
   'Checkout p95 latency', 'ms',
   400, 300, 330, null),

  -- Objective 2 (Ana) — behind, ~0.30
  ('cccccccc-cccc-4ccc-8ccc-000000000003',
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
   'Teams migrated to payments v2', 'teams',
   0, 20, 6, null),

  ('cccccccc-cccc-4ccc-8ccc-000000000004',
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
   'Transactions served by v2 per day', 'txn/day',
   0, 1000, 300, null)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- check_in — two check-ins on ONE key result showing progression 0 -> 40 -> 70.
-- The insert trigger owns checked_in_by and created_at, so the seed sets Dara's
-- authenticated identity and does not attempt to backdate either event. The
-- later row leaves current_value at 70, which is what cc...001 already holds,
-- so score stays 0.700.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', false);

insert into public.check_in (id, key_result_id, checked_in_by, new_value, note)
values
  ('dddddddd-dddd-4ddd-8ddd-000000000001',
   'cccccccc-cccc-4ccc-8ccc-000000000001',
   '11111111-1111-4111-8111-000000000004',  -- Dara, the objective owner
   40,
   'Retry queue shipped; early numbers look right but sample is small.'),

  ('dddddddd-dddd-4ddd-8ddd-000000000002',
   'cccccccc-cccc-4ccc-8ccc-000000000001',
   '11111111-1111-4111-8111-000000000004',
   70,
   'Backoff tuning landed. Holding steady at 70% across a full month.')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- objective_alignment — BOTTOM-UP, created by DARA.
--
-- Per Ruling 3 (Phase 1) the CHILD-side write-authority holder creates the
-- link, so Dara — who owns the child objective — is created_by, not Ana.
-- Per Ruling 1's corrected direction, read authority on the PARENT runs
-- UPWARD: a caller may read an objective whose owner_id equals their own
-- manager_id. Dara's manager_id is Ana, and Ana owns the parent objective, so
-- Dara satisfies the parent-read half. Both halves check out with Dara as the
-- creator; under the brief's original (backwards) wording this row would have
-- failed authorization.
-- ---------------------------------------------------------------------------

insert into public.objective_alignment (id, parent_objective_id, child_objective_id, created_by)
values
  ('eeeeeeee-eeee-4eee-8eee-000000000001',
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',  -- Ana's objective (parent)
   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',  -- Dara's objective (child)
   '11111111-1111-4111-8111-000000000004')  -- created by Dara
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Populate goal_plan_rating by calling the real compute_goal_plan_rating
-- function rather than hardcoding scores, so the seed exercises the rollup
-- itself and the demo UI shows real KRA numbers on first load. Run as HR
-- admin via the same request.jwt.claim.sub GUC trick VERIFICATION.md uses.
-- is_local=false (session-level, not transaction-local) because seed.sql
-- runs as one autocommit session with no surrounding BEGIN/COMMIT.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', false);
select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'self');
select public.compute_goal_plan_rating('33333333-3333-4333-8333-00000000000a', 'manager');

-- ===========================================================================
-- GATE 1 FACILITATOR FIXTURE — Vuthy's unpublished manager-rated plan
--
-- This plan deliberately has no calibration_participant row. It is the
-- positive eligibility fixture for calibration_eligible_plans: same cycle,
-- manager score computed, and not yet published or assigned to a session.
-- ===========================================================================

insert into public.employee_goal_plan (
  id, review_cycle_id, employee_id, status, overall_rating_scale_max
)
values (
  '33333333-3333-4333-8333-00000000000e',
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000008',
  'manager_reviewed',
  5
)
on conflict (id) do nothing;

insert into public.review_participant (
  employee_goal_plan_id, participant_id, role
)
values
  (
    '33333333-3333-4333-8333-00000000000e',
    '11111111-1111-4111-8111-000000000008',
    'employee'
  ),
  (
    '33333333-3333-4333-8333-00000000000e',
    '11111111-1111-4111-8111-000000000003',
    'line_manager'
  ),
  (
    '33333333-3333-4333-8333-00000000000e',
    '11111111-1111-4111-8111-000000000001',
    'hr_admin'
  )
on conflict (employee_goal_plan_id, participant_id, role) do nothing;

insert into public.kra_category (
  id, employee_goal_plan_id, name, description, weight
)
values (
  '44444444-4444-4444-8444-00000000000f',
  '33333333-3333-4333-8333-00000000000e',
  'Customer Reliability',
  'Keep customer-facing services dependable and recovery work disciplined.',
  100.00
)
on conflict (id) do nothing;

insert into public.goal (
  id, kra_category_id, title, description, weight, target_metric,
  rating_scale_max, self_rating, self_comment, manager_rating, manager_comment
)
values (
  '55555555-5555-4555-8555-000000000009',
  '44444444-4444-4444-8444-00000000000f',
  'Reduce customer-impacting incidents',
  'Improve prevention and recovery for the services Vuthy owns.',
  100.00,
  'No repeat P1 incidents and median recovery under 30 minutes',
  5,
  4.50,
  'Prevented repeat incidents and improved the operational runbooks.',
  4.00,
  'Strong reliability work with clear, measurable recovery improvements.'
)
on conflict (id) do nothing;

select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000e',
  'manager'
);

-- ===========================================================================
-- PHASE 3 — calibration, publish gate
--
-- Everything below is appended by Phase 3 and touches nothing above it.
--
-- The participant row, its band assignment, the facilitator override and the
-- published_at stamp are all produced by REAL function calls, not hardcoded
-- inserts — same pattern as the compute_goal_plan_rating calls above. The
-- calibration functions are SECURITY DEFINER + HR-admin-only, so the session
-- GUC set above (HR admin, ...0001) is still in effect and carries through;
-- it is re-set here explicitly so this block reads correctly on its own and
-- survives any later reordering.
-- ===========================================================================

select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', false);

-- ---------------------------------------------------------------------------
-- calibration_session — one facilitated pass over the FY2026 cycle.
-- Inserted as 'open' on purpose: the seed then exercises the real lifecycle
-- in order — add participant, adjust, finalize, publish.
-- ---------------------------------------------------------------------------

insert into public.calibration_session (id, review_cycle_id, name, status)
values
  ('44444444-4444-4444-8444-000000000001',
   '22222222-2222-4222-8222-000000000001',
   'FY2026 Engineering Calibration',
   'open')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- calibration_band — four bands, half-open [min_score, max_score).
--
-- The top band ends at 5.001, NOT 5.000, deliberately: matching is half-open,
-- so a perfect 5.000 on this plan's overall_rating_scale_max of 5 would fall
-- out of a band capped at exactly 5 and raise 23514. Spanning above the scale
-- max is the fix, and it is why band count and edges are seed config rather
-- than anything hardcoded in the schema.
-- ---------------------------------------------------------------------------

insert into public.calibration_band
  (id, calibration_session_id, label, min_score, max_score, sort_order)
values
  ('55555555-5555-4555-8555-000000000001',
   '44444444-4444-4444-8444-000000000001', 'Needs Improvement',    0.000, 2.500, 1),
  ('55555555-5555-4555-8555-000000000002',
   '44444444-4444-4444-8444-000000000001', 'Meets Expectations',   2.500, 3.500, 2),
  ('55555555-5555-4555-8555-000000000003',
   '44444444-4444-4444-8444-000000000001', 'Exceeds Expectations', 3.500, 4.500, 3),
  ('55555555-5555-4555-8555-000000000004',
   '44444444-4444-4444-8444-000000000001', 'Outstanding',          4.500, 5.001, 4)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Add Dara's plan to the session via the real function.
--
-- Snapshots original_score from the MANAGER rating (3.580 — the self rating of
-- 4.220 is never a calibration input), sets calibrated_score to the same value
-- (calibration starts as "no change"), and lands band_id on
-- 'Exceeds Expectations' since 3.580 falls in [3.500, 4.500).
--
-- Guarded so a re-run is a no-op rather than an error. Unlike the inserts
-- above, these are function calls with no `on conflict` to absorb a second
-- run: add_ would hit the unique (session, plan) constraint and adjust_/
-- finalize_ would raise 'session is finalized' the second time through. Every
-- other block in this file is re-runnable, so these match that contract.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from public.calibration_participant
     where calibration_session_id = '44444444-4444-4444-8444-000000000001'
       and employee_goal_plan_id  = '33333333-3333-4333-8333-00000000000a'
  ) then
    perform public.add_plan_to_calibration_session(
      '44444444-4444-4444-8444-000000000001',
      '33333333-3333-4333-8333-00000000000a'
    );

    -- Facilitator override — a human moderating in the room, which is the
    -- entire point of a calibration pass. 3.580 -> 3.200 also crosses a band
    -- edge, so band_id is recomputed from 'Exceeds Expectations' down to
    -- 'Meets Expectations' and the frontend has a real band change to render.
    -- original_score stays 3.580; the pair of scores is the audit trail.
    --
    -- Inside the same guard as the add: the adjust must happen while the
    -- session is still 'open', and only on the row the add just created.
    perform public.adjust_calibration_participant(
      cp.id,
      3.200,
      'Calibration panel: strong delivery, but scope was narrower than peers rated at this level. Moderated down for cross-team consistency.'
    )
    from public.calibration_participant as cp
    where cp.calibration_session_id = '44444444-4444-4444-8444-000000000001'
      and cp.employee_goal_plan_id  = '33333333-3333-4333-8333-00000000000a';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Finalize, then publish. The order matters and is enforced, not conventional:
-- publish_employee_goal_plan rejects a plan whose calibration session is still
-- 'open', and adjust_calibration_participant rejects any further change once
-- the session is finalized.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (
    select 1 from public.calibration_session
     where id = '44444444-4444-4444-8444-000000000001'
       and status = 'open'
  ) then
    perform public.finalize_calibration_session('44444444-4444-4444-8444-000000000001');
  end if;

  if exists (
    select 1 from public.employee_goal_plan
     where id = '33333333-3333-4333-8333-00000000000a'
       and published_at is null
  ) then
    perform public.publish_employee_goal_plan('33333333-3333-4333-8333-00000000000a');
  end if;
end $$;

-- ===========================================================================
-- PAST REVIEW-CYCLE FIXTURE — Dara Sok's FY2025 history
--
-- Purpose: prove an employee can open a review cycle that has already ended
-- and read their own historical ratings. Everything above this line is left
-- untouched; this block is additive, fixed-UUID and re-runnable like the rest.
--
-- Deliberately DIFFERENT in shape from Dara's FY2026 plan rather than a second
-- copy of it. FY2026 is calibrated and published, so it already covers the
-- "final score after moderation" path. FY2025 stops at manager_reviewed and is
-- never published, which is the case the published fixture cannot exercise:
-- an employee seeing their own manager rating from a closed cycle that never
-- went through calibration at all.
--
-- Vuthy Long deliberately gets NO FY2025 row. He is the negative fixture: a
-- cycle he never participated in must stay invisible to him.
--
-- Hand-check of the Average Method rollup (one category at 100%, scale max 5):
--
--   SELF     4.0 (weight 60) and 5.0 (weight 40)
--     Category = (0.8*60 + 1.0*40) / 100 = 88/100 = 0.88
--     Overall  = 0.88 * 100/100          = 0.88
--     Rescaled onto scale max 5          = 0.88 * 5 = 4.400
--
--   MANAGER  4.0 (weight 60) and 4.0 (weight 40)
--     Category = (0.8*60 + 0.8*40) / 100 = 80/100 = 0.80
--     Overall  = 0.80 * 100/100          = 0.80
--     Rescaled onto scale max 5          = 0.80 * 5 = 4.000
--
-- goal_plan_rating is NOT inserted directly here, same as every other plan in
-- this file: it is produced by calling the real compute_goal_plan_rating, so
-- the numbers above are checked by the database rather than asserted by hand.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- review_cycle — inserted as draft and then walked through every real
-- transition to closed. The lifecycle trigger rejects both a non-draft INSERT
-- and any status skip, so a past cycle can only be produced by actually
-- living through the sequence, which is what the guarded updates below do.
-- ---------------------------------------------------------------------------

insert into public.review_cycle (id, name, start_date, end_date, status)
values
  ('22222222-2222-4222-8222-000000000002', 'FY2025 Annual Review', '2025-01-01', '2025-12-31', 'draft')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- The plan and its ratings are created while the cycle is still open. The
-- close happens last, after the rollup has been computed, so the fixture is
-- built the way a real cycle would have been rather than back-filled into a
-- frozen one.
-- ---------------------------------------------------------------------------

insert into public.employee_goal_plan (id, review_cycle_id, employee_id, status, overall_rating_scale_max)
values
  ('33333333-3333-4333-8333-000000000010',
   '22222222-2222-4222-8222-000000000002',
   '11111111-1111-4111-8111-000000000004',  -- Dara
   'manager_reviewed',
   5)
on conflict (id) do nothing;

-- review_participant is what RLS actually keys off — without these rows the
-- cycle itself would be invisible to all three of them.
insert into public.review_participant (employee_goal_plan_id, participant_id, role)
values
  ('33333333-3333-4333-8333-000000000010', '11111111-1111-4111-8111-000000000004', 'employee'),
  ('33333333-3333-4333-8333-000000000010', '11111111-1111-4111-8111-000000000002', 'line_manager'),
  ('33333333-3333-4333-8333-000000000010', '11111111-1111-4111-8111-000000000001', 'hr_admin')
on conflict (employee_goal_plan_id, participant_id, role) do nothing;

insert into public.kra_category (id, employee_goal_plan_id, name, description, weight)
values
  ('44444444-4444-4444-8444-000000000010',
   '33333333-3333-4333-8333-000000000010',
   'Operational Excellence',
   'Keeping the money-movement systems correct, reconciled and quiet.',
   100.00)
on conflict (id) do nothing;

insert into public.goal (
  id, kra_category_id, title, description, weight, target_metric, rating_scale_max,
  self_rating, self_comment, manager_rating, manager_comment
)
values
  ('55555555-5555-4555-8555-000000000010', '44444444-4444-4444-8444-000000000010',
   'Stabilize payment reconciliation',
   'Bring the daily reconciliation job to a clean, unattended run.',
   60.00, 'Zero unexplained breaks for 90 consecutive days', 5,
   4.00, 'Breaks down to zero from October onward; two manual interventions earlier in the year.',
   4.00, 'Solid, sustained improvement. The two early interventions were reasonable calls.'),

  ('55555555-5555-4555-8555-000000000011', '44444444-4444-4444-8444-000000000010',
   'Automate month-end exception reporting',
   'Replace the hand-built month-end exception spreadsheet with a generated report.',
   40.00, 'Report generated unattended for two consecutive quarters', 5,
   5.00, 'Fully automated from Q3; finance stopped asking for the spreadsheet entirely.',
   4.00, 'Genuinely useful automation. Landed a quarter later than planned.')
on conflict (id) do nothing;

-- Compute the rollup through the real function, as HR admin (the same GUC
-- trick the blocks above use). Expected: self 4.400, manager 4.000.
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', false);
select public.compute_goal_plan_rating('33333333-3333-4333-8333-000000000010', 'self');
select public.compute_goal_plan_rating('33333333-3333-4333-8333-000000000010', 'manager');

-- ---------------------------------------------------------------------------
-- Now walk the cycle to closed, one legal step at a time. Each update is
-- guarded on the current status so a re-run is a no-op instead of a 55000
-- from re-attempting a transition that already happened.
--
-- The plan is left UNPUBLISHED on purpose. It never enters a calibration
-- session, so there is no final_score to read — only the manager's own
-- rating, which is exactly the historical case being proven.
-- ---------------------------------------------------------------------------

update public.review_cycle set status = 'active'
where id = '22222222-2222-4222-8222-000000000002' and status = 'draft';
update public.review_cycle set status = 'self_eval'
where id = '22222222-2222-4222-8222-000000000002' and status = 'active';
update public.review_cycle set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000002' and status = 'self_eval';
update public.review_cycle set status = 'closed'
where id = '22222222-2222-4222-8222-000000000002' and status = 'manager_eval';
