# Phase 1 verification

The automated gate in `scripts/verify.sql` runs **46 assertions** after a fresh
local database reset.

Run these queries against a database containing migrations `0001` through `0017` and `supabase/seed.sql`. They use the seed's fixed UUIDs and simulate API users with `SET LOCAL ROLE authenticated` plus a JWT `sub` claim. Run each transaction separately so an expected error does not abort later checks.

## Seed identifiers

| Fixture | UUID |
| --- | --- |
| HR admin (Maly) | `11111111-1111-4111-8111-000000000001` |
| Manager (Ana) | `11111111-1111-4111-8111-000000000002` |
| Employee (Dara) | `11111111-1111-4111-8111-000000000004` |
| Employee (Rith) | `11111111-1111-4111-8111-000000000006` |
| Employee (Vuthy) | `11111111-1111-4111-8111-000000000008` |
| Review cycle | `22222222-2222-4222-8222-000000000001` |
| Dara plan | `33333333-3333-4333-8333-00000000000a` |
| Ana plan | `33333333-3333-4333-8333-00000000000b` |
| Lina cascaded plan | `33333333-3333-4333-8333-00000000000c` |
| Rith plan | `33333333-3333-4333-8333-00000000000d` |
| Vuthy plan | `33333333-3333-4333-8333-00000000000e` |
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

# Phase 2 verification

Run these after migrations `0005` through `0010` and the Phase 2 seed additions.
As in Phase 1, run transactions containing an expected error separately so an
intentional RLS rejection does not abort later checks.

## RLS is enabled on every Phase 2 table

Run as the database owner. All six rows must return `rowsecurity = true`.

```sql
select relname, relrowsecurity as rowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in (
    'objective', 'key_result', 'check_in', 'objective_alignment',
    'review_participant_scope', 'goal_matrix_rating'
  )
order by relname;
```

## Matrix ratings require the exact participant-scope join

This positive case discovers the seeded matrix manager and their category grant,
temporarily moves the cycle to `manager_eval`, removes the seeded advisory row,
and recreates a rating as that matrix manager. It must return one row.

```sql
begin;
update public.review_cycle as rc
set status = 'manager_eval'
where rc.id = (
  select egp.review_cycle_id
  from public.review_participant as rp
  join public.review_participant_scope as rps
    on rps.review_participant_id = rp.id
  join public.employee_goal_plan as egp
    on egp.id = rp.employee_goal_plan_id
  where rp.role::text = 'matrix_manager'
    and rps.scope_type::text = 'kra_category'
  limit 1
);

delete from public.goal_matrix_rating as gmr
where gmr.participant_id = (
  select rp.participant_id
  from public.review_participant as rp
  join public.review_participant_scope as rps
    on rps.review_participant_id = rp.id
  where rp.role::text = 'matrix_manager'
    and rps.scope_type::text = 'kra_category'
  limit 1
);

select set_config(
  'request.jwt.claim.sub',
  (
    select rp.participant_id::text
    from public.review_participant as rp
    join public.review_participant_scope as rps
      on rps.review_participant_id = rp.id
    where rp.role::text = 'matrix_manager'
      and rps.scope_type::text = 'kra_category'
    limit 1
  ),
  true
);
set local role authenticated;

insert into public.goal_matrix_rating (
  goal_id, participant_id, rating, comment
)
select g.id, auth.uid(), 4.25, 'Scoped matrix verification'
from public.review_participant as rp
join public.review_participant_scope as rps
  on rps.review_participant_id = rp.id
join public.goal as g on g.kra_category_id = rps.scope_id
where rp.participant_id = auth.uid()
  and rp.role::text = 'matrix_manager'
  and rps.scope_type::text = 'kra_category'
order by g.id
limit 1
returning goal_id, participant_id, rating;
-- 1 row
rollback;
```

A goal in another category on the same plan must fail even though the caller
still has a bare `matrix_manager` participant row. This is the regression guard
for the exact `review_participant -> review_participant_scope` join.

```sql
begin;
update public.review_cycle as rc
set status = 'manager_eval'
where rc.id = (
  select egp.review_cycle_id
  from public.review_participant as rp
  join public.review_participant_scope as rps
    on rps.review_participant_id = rp.id
  join public.employee_goal_plan as egp
    on egp.id = rp.employee_goal_plan_id
  where rp.role::text = 'matrix_manager'
    and rps.scope_type::text = 'kra_category'
  limit 1
);

select set_config(
  'request.jwt.claim.sub',
  (
    select rp.participant_id::text
    from public.review_participant as rp
    where rp.role::text = 'matrix_manager'
    limit 1
  ),
  true
);
set local role authenticated;

insert into public.goal_matrix_rating (
  goal_id, participant_id, rating, comment
)
select g.id, auth.uid(), 4.00, 'Must be rejected: unscoped category'
from public.review_participant as rp
join public.review_participant_scope as rps
  on rps.review_participant_id = rp.id
join public.kra_category as scoped_category
  on scoped_category.id = rps.scope_id
join public.kra_category as other_category
  on other_category.employee_goal_plan_id = rp.employee_goal_plan_id
 and other_category.id <> scoped_category.id
join public.goal as g on g.kra_category_id = other_category.id
where rp.participant_id = auth.uid()
  and rp.role::text = 'matrix_manager'
  and rps.scope_type::text = 'kra_category'
order by g.id
limit 1;
-- ERROR: new row violates row-level security policy
rollback;
```

The scoped matrix manager also cannot write the line manager's columns on
`goal`. This must affect zero rows; their only rating write path is
`goal_matrix_rating`.

```sql
begin;
update public.review_cycle as rc
set status = 'manager_eval'
where rc.id = (
  select egp.review_cycle_id
  from public.review_participant as rp
  join public.review_participant_scope as rps
    on rps.review_participant_id = rp.id
  join public.employee_goal_plan as egp
    on egp.id = rp.employee_goal_plan_id
  where rp.role::text = 'matrix_manager'
    and rps.scope_type::text = 'kra_category'
  limit 1
);

select set_config(
  'request.jwt.claim.sub',
  (
    select rp.participant_id::text
    from public.review_participant as rp
    where rp.role::text = 'matrix_manager'
    limit 1
  ),
  true
);
set local role authenticated;

update public.goal as g
set manager_rating = 1.00
where g.id = (
  select scoped_goal.id
  from public.review_participant as rp
  join public.review_participant_scope as rps
    on rps.review_participant_id = rp.id
  join public.goal as scoped_goal on scoped_goal.kra_category_id = rps.scope_id
  where rp.participant_id = auth.uid()
    and rp.role::text = 'matrix_manager'
    and rps.scope_type::text = 'kra_category'
  order by scoped_goal.id
  limit 1
)
returning g.id;
-- UPDATE 0
rollback;
```

## Ruling 1: objective reads point upward

Dara can read Ana's objective because Dara's `manager_id` is Ana's id. Delete
the seeded alignment as owner, prove Dara is not a participant on Ana's plan,
then recreate the upward link as Dara. Child write authority plus parent read
authority is sufficient; participation in both plans is deliberately not
required.

```sql
begin;
delete from public.objective_alignment as oa
where oa.child_objective_id in (
  select o.id
  from public.objective as o
  where o.owner_id = '11111111-1111-4111-8111-000000000004'
);

select not exists (
  select 1
  from public.review_participant as rp
  where rp.employee_goal_plan_id = '33333333-3333-4333-8333-00000000000b'
    and rp.participant_id = '11111111-1111-4111-8111-000000000004'
) as dara_is_not_on_ana_plan;
-- true

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);

select o.id
from public.objective as o
where o.owner_id = '11111111-1111-4111-8111-000000000002';
-- Ana's parent objective is visible to Dara.

insert into public.objective_alignment (
  parent_objective_id, child_objective_id, created_by
)
select parent.id, child.id, auth.uid()
from public.objective as parent
cross join public.objective as child
where parent.owner_id = '11111111-1111-4111-8111-000000000002'
  and child.owner_id = '11111111-1111-4111-8111-000000000004'
order by parent.id, child.id
limit 1
returning id;
-- 1 row
rollback;
```

The reverse is not granted: Ana is Dara's manager, but Ruling 1 does not let a
caller read a direct report's objective merely because of that relationship.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);

select o.id
from public.objective as o
where o.owner_id = '11111111-1111-4111-8111-000000000004';
-- 0 rows
rollback;
```

## Check-ins propagate values and recompute scores

Insert a check-in at exactly 70% of a non-degenerate key result's range. The
AFTER INSERT trigger must update `current_value`; that update must fire the
BEFORE trigger and store a score of `0.700`.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);

insert into public.check_in (key_result_id, checked_in_by, new_value, note)
select
  kr.id,
  auth.uid(),
  kr.start_value + (0.7::numeric * (kr.target_value - kr.start_value)),
  '70 percent trigger verification'
from public.key_result as kr
join public.objective as o on o.id = kr.objective_id
where o.owner_id = auth.uid()
  and kr.target_value <> kr.start_value
order by kr.id
limit 1;

select
  kr.current_value =
    kr.start_value + (0.7::numeric * (kr.target_value - kr.start_value))
    as current_value_was_propagated,
  round(kr.score, 3) as score
from public.key_result as kr
join public.objective as o on o.id = kr.objective_id
where o.owner_id = auth.uid()
  and kr.target_value <> kr.start_value
order by kr.id
limit 1;
-- current_value_was_propagated | score
-- true                         | 0.700
rollback;
```

The degenerate `start_value = target_value` case must store `NULL`, never zero
or one.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);

update public.key_result as kr
set target_value = kr.start_value
where kr.id = (
  select candidate.id
  from public.key_result as candidate
  join public.objective as o on o.id = candidate.objective_id
  where o.owner_id = auth.uid()
  order by candidate.id
  limit 1
)
returning kr.score is null as score_is_null;
-- true
rollback;
```

## Ruling 2: nested STABLE SECURITY INVOKER table function

The catalog must show a set-returning (`proretset`) stable (`provolatile = 's'`)
function that is not `SECURITY DEFINER` (`prosecdef = false`). There must be no
view or table named `employee_review_summary`.

```sql
select
  p.proretset,
  p.provolatile = 's' as is_stable,
  not p.prosecdef as is_security_invoker,
  pg_get_function_result(p.oid) as result_shape
from pg_proc as p
join pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'employee_review_summary'
  and pg_get_function_identity_arguments(p.oid) = 'p_review_cycle_id uuid, p_employee_id uuid';
-- proretset | is_stable | is_security_invoker | result_shape
-- true      | true      | true                | TABLE(summary jsonb)

select to_regclass('public.employee_review_summary') is null
  as no_flat_summary_relation;
-- true
```

This transaction computes both KRA rows, then calls the summary as Dara. It must
return one nested JSON object containing two arrays. Each visible key result has
an `effective_score` derived from `coalesce(score_override, score)`.

```sql
begin;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);
set local role authenticated;
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'self'
);

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);
set local role authenticated;
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'manager'
);

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);
set local role authenticated;

select
  jsonb_typeof(summary) as summary_type,
  jsonb_typeof(summary -> 'kra_ratings') as kra_ratings_type,
  jsonb_array_length(summary -> 'kra_ratings') as kra_rating_count,
  jsonb_typeof(summary -> 'objectives') as objectives_type,
  summary -> 'objectives' as objectives
from public.employee_review_summary(
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000004'
);
-- summary_type | kra_ratings_type | kra_rating_count | objectives_type
-- object       | array            | 2                | array
rollback;
```

An unrelated caller gets no function row at all because the invoker cannot see
the employee's goal plan through RLS.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000003',
  true
);

select count(*)
from public.employee_review_summary(
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000004'
);
-- 0
rollback;
```

## Phase 1 rollup regression guard

Phase 2 must not change `compute_goal_plan_rating`. The original Dara plan must
still compute exactly `4.220` for self and `3.580` for manager.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'self'
);
-- 4.220
rollback;

begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'manager'
);
-- 3.580
rollback;
```

# Goal/rating creation workflow Gate 1 verification

Run these after `0017_goal_rating_workflow.sql`. The automated versions are
assertions 34 through 46 in `scripts/verify.sql`, bringing the full suite to
**46 assertions**.

The fixtures deliberately distinguish the two previously confused plans:
Lina's `...000c` plan contains the top-down cascaded copy, while Rith's
`...000d` plan contains his independently authored goal that was later aligned
upward.

## Employee write scope

The suite verifies all of the following as authenticated employees:

- Lina can insert a category and an unrated goal on her own draft plan.
- Rith can update `self_rating` and `self_comment` on his own draft goal.
- Rith's direct UPDATE of `manager_rating`/`manager_comment` raises `42501`.
- Rith cannot bypass the UPDATE trigger by inserting a new goal with manager
  fields already populated; the INSERT policy raises `42501`.
- Once an owner-created manager rating exists, Rith cannot change the goal's
  `rating_scale_max`; the trigger raises `42501`.
- A permitted draft-to-submitted status call cannot also change
  `review_cycle_id`; the plan column-scope trigger raises `42501`.

The employee goal trigger protects `id`, `kra_category_id`,
`manager_rating`, `manager_comment`, and `created_at`. The employee plan
trigger protects `id`, `review_cycle_id`, `employee_id`,
`overall_rating_scale_max`, `created_at`, and `published_at`. Both exempt HR
first and use `is distinct from` comparisons. `updated_at` is intentionally
excluded because the existing maintenance trigger owns it.

## Manager rating and review scope

During `manager_eval`, Ana can write manager assessment fields only when the
specific plan is `submitted`. An attempted rating on Rith's still-draft plan
affects zero rows through RLS, even though the cycle-wide manager window is
open.

For plan review, the suite proves:

- `submitted -> manager_reviewed` succeeds for that plan's `line_manager`
  participant, with `id`, `review_cycle_id`, `employee_id`,
  `overall_rating_scale_max`, `created_at`, and `published_at` unchanged.
- `submitted -> finalized` raises `42501`.
- The same review attempt outside `manager_eval` affects zero rows. This is an
  RLS-silent rejection, so callers must test returned-row presence rather than
  wait for an exception.

## Deferred weights and mixed-scale round trip

A separate assertion changes Rith's category total to 90 and confirms
`validate_goal_plan_weights` raises `23514`.

The final assertion creates a fresh plan inside one rollback-isolated
transaction. It builds valid 40/60 categories and three goals with mixed
5-point and 10-point rating scales, then executes the workflow in the required
order:

1. Employee writes every self rating, computes the self rollup, then submits.
2. Manager writes every manager rating, computes the manager rollup, then marks
   the plan reviewed.

The hand-computed normalized category scores are:

- Self: delivery `(4/5 * 50% + 6/10 * 50%) = 0.70`; quality `5/5 = 1.00`.
  Overall: `(0.70 * 40% + 1.00 * 60%) * 5 = 4.400`.
- Manager: delivery `(3/5 * 50% + 8/10 * 50%) = 0.70`; quality `4/5 = 0.80`.
  Overall: `(0.70 * 40% + 0.80 * 60%) * 5 = 3.800`.

The assertion requires both stored rollups to match exactly and the final plan
status to be `manager_reviewed`.

# Gate 1 facilitator verification

Run these after migration `0016_calibration_facilitator_views.sql` and the
Gate 1 seed addition. These are assertions 26 through 33 in
`scripts/verify.sql`; the later goal/rating workflow gate adds 13 more, so the
current suite total is **46**.

## All three new RPCs are HR-only

Use a non-HR caller and nonexistent identifiers. Each call must raise `42501`,
which also proves the authorization gate runs before any existence lookup.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);

select * from public.calibration_session_detail(
  'f1600000-0000-4000-8000-000000000001'
);
-- ERROR 42501: Only HR admins may view calibration session details
rollback;

begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);

select * from public.calibration_eligible_plans(
  'f1600000-0000-4000-8000-000000000002'
);
-- ERROR 42501: Only HR admins may view calibration-eligible plans
rollback;

begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);

select public.create_calibration_session_with_bands(
  'Must be denied',
  'f1600000-0000-4000-8000-000000000003',
  '[]'::jsonb
);
-- ERROR 42501: Only HR admins may create calibration sessions
rollback;
```

## Seeded session detail has the locked shape

As HR, the finalized seeded session returns one JSON object with a `session`
object, four ordered `bands`, and one Dara participant. The participant has
manager `Ana Kim`, original score `3.580`, calibrated score `3.200`, the
`Meets Expectations` band id, and a non-null publish timestamp. Both array
fields are JSON arrays, never JSON null.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select detail
from public.calibration_session_detail(
  '44444444-4444-4444-8444-000000000001'
);
rollback;
```

## Eligible plans are cycle-, publication-, and membership-safe

The automated transaction clears Dara's publish timestamp to isolate the
already-participating exclusion, temporarily gives published Ana a manager
score, and creates an unpublished manager-rated plan in a different cycle.
The RPC still returns exactly Vuthy's seeded plan:

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select *
from public.calibration_eligible_plans(
  '44444444-4444-4444-8444-000000000001'
);
-- 33333333-3333-4333-8333-00000000000e | Vuthy Long | 4.000
rollback;
```

## Published plans cannot be recalibrated

Create another open session for the seeded cycle, then try to add Dara's
published plan. `add_plan_to_calibration_session` must raise `55000` with an
actionable message explaining that an unpublish step is required.

```sql
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
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);
select public.add_plan_to_calibration_session(
  'f1600000-0000-4000-8000-000000000020',
  '33333333-3333-4333-8333-00000000000a'
);
-- ERROR 55000: Published employee goal plan ... cannot be recalibrated
--              without an unpublish step
rollback;
```

## Session and band creation is atomic

A valid payload returns an open session id with both ordered bands. An
overlapping payload raises the existing exclusion violation (`23P01`); when
that error is caught inside the test block, no session row with the failed
name remains, proving the session insert rolled back with its band inserts.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select public.create_calibration_session_with_bands(
  'Atomic creation success fixture',
  '22222222-2222-4222-8222-000000000001',
  '[
    {"label":"Lower","min_score":0,"max_score":3,"sort_order":1},
    {"label":"Upper","min_score":3,"max_score":5.001,"sort_order":2}
  ]'::jsonb
);
-- Returns the new calibration_session.id; both bands share that id.
rollback;

begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select public.create_calibration_session_with_bands(
  'Atomic creation rollback fixture',
  '22222222-2222-4222-8222-000000000001',
  '[
    {"label":"One","min_score":0,"max_score":3.5,"sort_order":1},
    {"label":"Two","min_score":3,"max_score":5.001,"sort_order":2}
  ]'::jsonb
);
-- ERROR 23P01: conflicting key value violates exclusion constraint
rollback;
```

## Password policy (forced rotation)

`profiles.password_changed_at` starts `NULL` for every seeded account, so first login redirects the frontend to `/change-password` (`web/lib/password.ts`'s `isPasswordExpired`, checked server-side in `web/app/review/page.tsx` on every load — not a client-only gate). It expires again 60 days after the last change.

A user may update their own `password_changed_at`, but nothing else on their `profiles` row — the `profiles_restrict_self_updates` trigger (0011) blocks any other column change from a non-HR self-update, exactly like the `restrict_manager_goal_updates` column guard from Phase 1.

```sql
-- Self-update succeeds for password_changed_at
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
update public.profiles set password_changed_at = now()
where id = '11111111-1111-4111-8111-000000000004';
-- UPDATE 1
rollback;

-- Self-update is rejected for any other column
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000004', true);
update public.profiles set full_name = 'Escalated Name'
where id = '11111111-1111-4111-8111-000000000004';
-- ERROR: You may only update your own password_changed_at timestamp
rollback;

-- A user cannot update anyone else's profile at all
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-000000000006', true);
update public.profiles set password_changed_at = now()
where id = '11111111-1111-4111-8111-000000000004';
-- UPDATE 0
rollback;
```

New passwords must be 10+ characters with upper/lower/digit/symbol (`supabase/config.toml`'s `[auth]` `password_requirements`), enforced by GoTrue on the actual `auth.updateUser` call — the frontend's live checklist is a UX convenience, not the real gate. Seeded demo passwords (`password123`) are exempt because `seed.sql` inserts pre-hashed rows directly, bypassing this check — that asymmetry is what makes the forced-first-login-change flow demoable at all.

# Phase 3 verification

Run these after migrations `0012` through `0015` and the Phase 3 seed
additions. As in the earlier phases, run each transaction containing an
expected error separately so that intentional rejection does not abort later
checks.

## RLS is enabled on all three calibration tables

Run as the database owner. All three rows must return `rowsecurity = true`.

```sql
select relname, relrowsecurity as rowsecurity
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in (
    'calibration_session', 'calibration_band', 'calibration_participant'
  )
order by relname;
```

## Line-manager scope is tied to the specific plan

This self-contained transaction creates one open session containing Dara's
plan (managed by Ana) and a temporary plan for Sophea (managed by Ben). Ana
must see only Dara's participant row, while Ben must see only Sophea's, even
though both plans are in the same session.

```sql
begin;

insert into public.employee_goal_plan (
  id, review_cycle_id, employee_id, status, overall_rating_scale_max
)
values (
  'f3000000-0000-4000-8000-000000000002',
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000007',
  'manager_reviewed',
  5
);

insert into public.review_participant (
  employee_goal_plan_id, participant_id, role
)
values
  (
    'f3000000-0000-4000-8000-000000000002',
    '11111111-1111-4111-8111-000000000007',
    'employee'
  ),
  (
    'f3000000-0000-4000-8000-000000000002',
    '11111111-1111-4111-8111-000000000003',
    'line_manager'
  ),
  (
    'f3000000-0000-4000-8000-000000000002',
    '11111111-1111-4111-8111-000000000001',
    'hr_admin'
  );

insert into public.goal_plan_rating (
  employee_goal_plan_id, rating_type, overall_score
)
values (
  'f3000000-0000-4000-8000-000000000002', 'manager', 3.200
);

insert into public.calibration_session (
  id, review_cycle_id, name
)
values (
  'f3000000-0000-4000-8000-000000000001',
  '22222222-2222-4222-8222-000000000001',
  'Manager scope verification'
);

insert into public.calibration_band (
  id, calibration_session_id, label, min_score, max_score, sort_order
)
values
  (
    'f3000000-0000-4000-8000-000000000003',
    'f3000000-0000-4000-8000-000000000001',
    'Lower', 0.000, 3.000, 1
  ),
  (
    'f3000000-0000-4000-8000-000000000004',
    'f3000000-0000-4000-8000-000000000001',
    'Upper', 3.000, 5.001, 2
  );

select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);
set local role authenticated;

select public.add_plan_to_calibration_session(
  'f3000000-0000-4000-8000-000000000001',
  '33333333-3333-4333-8333-00000000000a'
);
select public.add_plan_to_calibration_session(
  'f3000000-0000-4000-8000-000000000001',
  'f3000000-0000-4000-8000-000000000002'
);

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);
set local role authenticated;

select employee.email
from public.calibration_participant as cp
join public.employee_goal_plan as egp
  on egp.id = cp.employee_goal_plan_id
join public.profiles as employee on employee.id = egp.employee_id
where cp.calibration_session_id =
  'f3000000-0000-4000-8000-000000000001';
-- Exactly one row: dara.sok@example.com

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000003',
  true
);
set local role authenticated;

select employee.email
from public.calibration_participant as cp
join public.employee_goal_plan as egp
  on egp.id = cp.employee_goal_plan_id
join public.profiles as employee on employee.id = egp.employee_id
where cp.calibration_session_id =
  'f3000000-0000-4000-8000-000000000001';
-- Exactly one row: sophea.im@example.com

rollback;
```

An employee cannot read any calibration participant rows, including their own.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);

select count(*) from public.calibration_participant;
-- 0
rollback;
```

## Finalization freezes adjustments

The seed finalizes Dara's calibration session. A later adjustment must fail in
the function even though the caller is HR.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select public.adjust_calibration_participant(
  (
    select cp.id
    from public.calibration_participant as cp
    where cp.employee_goal_plan_id =
      '33333333-3333-4333-8333-00000000000a'
    order by cp.created_at, cp.id
    limit 1
  ),
  4.000,
  'Must be rejected after finalization'
);
-- ERROR: Calibration participant ... belongs to a finalized session
rollback;
```

## Open calibration blocks publication

Temporarily reopen Dara's seeded calibration session and clear the publish
timestamp as owner. The HR-only publish function must reject the plan while
that session is open.

```sql
begin;
update public.calibration_session as cs
set status = 'open'
where cs.id = (
  select cp.calibration_session_id
  from public.calibration_participant as cp
  where cp.employee_goal_plan_id =
    '33333333-3333-4333-8333-00000000000a'
  order by cp.created_at, cp.id
  limit 1
);

update public.employee_goal_plan
set published_at = null
where id = '33333333-3333-4333-8333-00000000000a';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select public.publish_employee_goal_plan(
  '33333333-3333-4333-8333-00000000000a'
);
-- ERROR: Employee goal plan ... cannot be published while calibration is open
rollback;
```

## Publish gate and Ruling 2: only the manager block gets final_score

Clear `published_at`, then call the summary as Dara. Both blocks contain the
additive `final_score` key, but both values are null before publication. After
HR republishes the plan, the manager block equals the calibrated value while
the self block remains null.

```sql
begin;
update public.employee_goal_plan
set published_at = null
where id = '33333333-3333-4333-8333-00000000000a';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);

select
  rating ->> 'rating_type' as rating_type,
  rating -> 'final_score' as final_score
from public.employee_review_summary(
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000004'
) as review
cross join lateral jsonb_array_elements(
  review.summary -> 'kra_ratings'
) as rating
order by rating_type;
-- manager | null
-- self    | null

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);
set local role authenticated;
select public.publish_employee_goal_plan(
  '33333333-3333-4333-8333-00000000000a'
);

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);
set local role authenticated;

select
  rating ->> 'rating_type' as rating_type,
  rating -> 'final_score' as final_score
from public.employee_review_summary(
  '22222222-2222-4222-8222-000000000001',
  '11111111-1111-4111-8111-000000000004'
) as review
cross join lateral jsonb_array_elements(
  review.summary -> 'kra_ratings'
) as rating
order by rating_type;
-- manager | the seeded calibrated_score
-- self    | null (always, including after publication)

reset role;
with review as (
  select summary
  from public.employee_review_summary(
    '22222222-2222-4222-8222-000000000001',
    '11111111-1111-4111-8111-000000000004'
  )
), ratings as (
  select rating
  from review
  cross join lateral jsonb_array_elements(
    review.summary -> 'kra_ratings'
  ) as rating
), expected as (
  select cp.calibrated_score
  from public.calibration_participant as cp
  where cp.employee_goal_plan_id =
    '33333333-3333-4333-8333-00000000000a'
  order by cp.updated_at desc, cp.created_at desc, cp.id
  limit 1
)
select
  (
    select (rating -> 'final_score') = to_jsonb(expected.calibrated_score)
    from ratings, expected
    where rating ->> 'rating_type' = 'manager'
  ) as manager_final_matches_calibration,
  (
    select jsonb_typeof(rating -> 'final_score') = 'null'
    from ratings
    where rating ->> 'rating_type' = 'self'
  ) as self_final_is_always_null;
-- true | true
rollback;
```

## Ruling 1: compensation export is explicitly HR-only

HR gets the published Dara row. Ana is Dara's legitimate line manager and can
read Dara's underlying day-to-day review rows, but the explicit
`profiles.is_hr_admin` caller gate still makes the purpose-built compensation
export return zero rows for her.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000001',
  true
);

select
  employee_id,
  full_name,
  email,
  manager_full_name,
  overall_rating_scale_max,
  final_score,
  band_label,
  published_at
from public.comp_export_rows(
  '22222222-2222-4222-8222-000000000001'
);
-- Includes exactly the seeded published Dara result for this cycle.

reset role;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);
set local role authenticated;

select count(*)
from public.comp_export_rows(
  '22222222-2222-4222-8222-000000000001'
);
-- 0
rollback;
```

## Phase 1 rollup regression guard

Phase 3 does not modify `compute_goal_plan_rating` or any input to its Average
Method. Dara's original plan must still compute exactly `4.220` for self and
`3.580` for manager.

```sql
begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000004',
  true
);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'self'
);
-- 4.220
rollback;

begin;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-000000000002',
  true
);
select public.compute_goal_plan_rating(
  '33333333-3333-4333-8333-00000000000a', 'manager'
);
-- 3.580
rollback;
```
