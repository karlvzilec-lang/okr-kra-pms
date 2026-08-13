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

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('11111111-1111-4111-8111-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hr.admin@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana.manager@example.com',crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ben.manager@example.com',crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dara.sok@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lina.chan@example.com',  crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000006', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rith.pen@example.com',   crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000007', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sophea.im@example.com',  crypt('password123', gen_salt('bf')), now(), now(), now()),
  ('11111111-1111-4111-8111-000000000008', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'vuthy.long@example.com', crypt('password123', gen_salt('bf')), now(), now(), now())
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
  ('22222222-2222-4222-8222-000000000001', 'FY2026 Annual Review', '2026-01-01', '2026-12-31', 'active')
on conflict (id) do nothing;

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
