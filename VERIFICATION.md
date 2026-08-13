# Phase 1 verification

Run these queries against a database containing migrations `0001` through `0004` and `supabase/seed.sql`. They use the seed's fixed UUIDs and simulate API users with `SET LOCAL ROLE authenticated` plus a JWT `sub` claim. Run each transaction separately so an expected error does not abort later checks.

## Seed identifiers

| Fixture | UUID |
| --- | --- |
| HR admin (Maly) | `11111111-1111-4111-8111-000000000001` |
| Manager (Ana) | `11111111-1111-4111-8111-000000000002` |
| Employee (Dara) | `11111111-1111-4111-8111-000000000004` |
| Employee (Rith) | `11111111-1111-4111-8111-000000000006` |
| Review cycle | `22222222-2222-4222-8222-000000000001` |
| Dara plan | `33333333-3333-4333-8333-00000000000a` |
| Ana plan | `33333333-3333-4333-8333-00000000000b` |
| Rith plan | `33333333-3333-4333-8333-00000000000d` |
| Ana parent goal | `55555555-5555-4555-8555-000000000006` |
| Rith child goal | `55555555-5555-4555-8555-000000000008` |

## RLS is enabled everywhere

Run as the database owner. All nine rows must return `rowsecurity = true`.

```sql
select relname, relrowsecurity as rowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in (
    'profiles', 'review_cycle', 'employee_goal_plan', 'kra_category',
    'goal', 'goal_cascade', 'goal_alignment', 'review_participant',
    'goal_plan_rating'
  )
order by relname;
```

## Profile, cycle, and plan visibility

Ana sees her own profile and her three direct reports, but not unrelated users. As a participant, Rith sees the cycle and only his own plan; he is not granted plan visibility merely because another plan belongs to his manager.

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);

select array_agg(email order by email)
from public.profiles;
-- Exactly: ana.manager@example.com, dara.sok@example.com,
--          lina.chan@example.com, rith.pen@example.com
rollback;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

select id from public.review_cycle;
-- Exactly the seeded review cycle.

select id from public.employee_goal_plan;
-- Exactly Rith's plan: 33333333-3333-4333-8333-00000000000d.

update public.review_cycle
set name = 'unauthorized change'
where id = '22222222-2222-4222-8222-000000000001';
-- UPDATE 0: cycle mutation is HR-only.
rollback;
```

As HR, all four seeded plans are visible and mutations are permitted.

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000001', true);

select count(*) from public.employee_goal_plan;
-- 4

update public.review_cycle
set name = name
where id = '22222222-2222-4222-8222-000000000001'
returning id;
-- 1 row
rollback;
```

## Employee and manager writes

Rith can edit a goal on his draft plan but cannot edit Ana's goal even though he can read it as his direct manager's goal.

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

select id from public.goal
where id in (
  '55555555-5555-4555-8555-000000000006',
  '55555555-5555-4555-8555-000000000008'
)
order by id;
-- 2 rows: Rith's goal and his direct manager Ana's goal.

update public.goal
set self_comment = 'RLS verification'
where id = '55555555-5555-4555-8555-000000000008'
returning id;
-- 1 row

update public.goal
set title = 'unauthorized change'
where id = '55555555-5555-4555-8555-000000000006'
returning id;
-- 0 rows
rollback;
```

To verify manager-only rating writes, temporarily put the cycle in `manager_eval`. Ana may change the manager fields on Dara's goal.

```sql
begin;
update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);

update public.goal
set manager_rating = 3.50,
    manager_comment = 'Manager verification'
where id = '55555555-5555-4555-8555-000000000001'
returning manager_rating, manager_comment;
-- 1 row
rollback;
```

The same manager cannot change any other goal column. This must raise `Line managers may update only manager_rating and manager_comment`.

```sql
begin;
update public.review_cycle
set status = 'manager_eval'
where id = '22222222-2222-4222-8222-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);

update public.goal
set title = 'forbidden manager edit'
where id = '55555555-5555-4555-8555-000000000001';
-- ERROR: Line managers may update only manager_rating and manager_comment
rollback;
```

## Ruling 3: upward alignment uses target-plan authority

The seed already contains Rith's upward alignment, so delete it inside a transaction, prove Rith has no participant row on Ana's plan, then recreate it as Rith. The insert must succeed because Rith can write his own draft child plan and can read his direct manager's parent goal. It must not require participation in Ana's plan.

```sql
begin;
delete from public.goal_alignment
where id = '77777777-7777-4777-8777-000000000001';

select not exists (
  select 1
  from public.review_participant
  where employee_goal_plan_id = '33333333-3333-4333-8333-00000000000b'
    and participant_id = '11111111-1111-4111-8111-000000000006'
) as rith_is_not_on_ana_plan;
-- true

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

select id
from public.goal
where id = '55555555-5555-4555-8555-000000000006';
-- 1 row: the parent is readable through the normal goal SELECT policy.

insert into public.goal_alignment (
  id, parent_goal_id, child_goal_id, created_by
)
values (
  '77777777-7777-4777-8777-000000000001',
  '55555555-5555-4555-8555-000000000006',
  '55555555-5555-4555-8555-000000000008',
  '11111111-1111-4111-8111-000000000006'
)
returning id;
-- 1 row: this is the required positive proof of the rejected "both plans" rule.
rollback;
```

Spoofing `created_by` must fail the insert policy.

```sql
begin;
delete from public.goal_alignment
where id = '77777777-7777-4777-8777-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

insert into public.goal_alignment (parent_goal_id, child_goal_id, created_by)
values (
  '55555555-5555-4555-8555-000000000006',
  '55555555-5555-4555-8555-000000000008',
  '11111111-1111-4111-8111-000000000002'
);
-- ERROR: new row violates row-level security policy
rollback;
```

An arbitrary readable-by-UUID parent is not enough. Dara's goal is neither on Rith's plan nor his manager's plan, so this must also fail.

```sql
begin;
delete from public.goal_alignment
where id = '77777777-7777-4777-8777-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);

insert into public.goal_alignment (parent_goal_id, child_goal_id, created_by)
values (
  '55555555-5555-4555-8555-000000000001',
  '55555555-5555-4555-8555-000000000008',
  '11111111-1111-4111-8111-000000000006'
);
-- ERROR: new row violates row-level security policy
rollback;
```

## Average Method rollup

The seeded Dara plan has valid weights and fully populated ratings. Compute each type as a participant. The independently hand-calculated expected scores from the seed are `4.220` for `self` and `3.580` for `manager`.

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'self'
);
-- 4.220
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000002', true);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'manager'
);
-- 3.580
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
select rating_type, overall_score
from public.goal_plan_rating
where employee_goal_plan_id = '33333333-3333-4333-8333-00000000000a'
order by rating_type;
-- manager | 3.580
-- self    | 4.220
rollback;
```

Direct participant writes to the stored rollup are blocked; population must go through the function (or HR administration).

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
insert into public.goal_plan_rating (
  employee_goal_plan_id, rating_type, overall_score
)
values (
  '33333333-3333-4333-8333-00000000000a', 'self', 0
);
-- ERROR: new row violates row-level security policy
rollback;
```

## Ruling 2: reject missing ratings and invalid weights

Set one rating to `NULL` as the database owner, then call the rollup as Dara. This must raise `Cannot compute self rating ... at least one goal is unrated`; it must never zero-fill the missing rating or upsert a score.

```sql
begin;
update public.goal
set self_rating = null
where id = '55555555-5555-4555-8555-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'self'
);
-- ERROR: Cannot compute self rating ... at least one goal is unrated
rollback;
```

Break a goal-weight total and validate again. This must raise that the category's goal weights do not sum to 100.

```sql
begin;
update public.goal
set weight = 50.01
where id = '55555555-5555-4555-8555-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
select public.validate_goal_plan_weights(
  '33333333-3333-4333-8333-00000000000a'
);
-- ERROR: Goal weights for category ... must sum to 100 (actual: 100.01)
rollback;
```

The corresponding category-weight test is the same shape: change one seeded category from `60.00` to `60.01`, call `validate_goal_plan_weights`, expect a category total of `100.01`, then roll back.
