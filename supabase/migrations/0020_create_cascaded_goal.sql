-- 0020_create_cascaded_goal.sql
-- Atomically copy a readable source goal into an employee-owned KRA category
-- and record the cascade event. SECURITY INVOKER is deliberate: the source
-- SELECT, goal INSERT, and goal_cascade INSERT all remain subject to the
-- caller's existing RLS authority.

create or replace function public.create_cascaded_goal(
  p_source_goal_id uuid,
  p_target_kra_category_id uuid,
  p_weight numeric default null
)
returns table (
  goal_id uuid,
  goal_cascade_id uuid
)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_source_goal public.goal%rowtype;
  v_goal_id uuid := gen_random_uuid();
  v_goal_cascade_id uuid := gen_random_uuid();
begin
  if v_actor_id is null then
    raise exception 'Authentication is required to cascade a goal'
      using errcode = '42501';
  end if;

  -- goal_select_scoped applies here. A nonexistent goal and a goal hidden by
  -- RLS intentionally have the same caller-visible failure.
  select source_goal.*
  into v_source_goal
  from public.goal as source_goal
  where source_goal.id = p_source_goal_id;

  if not found then
    raise exception 'The source goal does not exist or is not readable'
      using errcode = '42501';
  end if;

  -- Supplying the generated id avoids INSERT ... RETURNING and its extra
  -- SELECT-policy pass. The INSERT policy still proves that the chosen
  -- category belongs to an editable plan owned by the caller.
  insert into public.goal (
    id,
    kra_category_id,
    title,
    description,
    weight,
    target_metric,
    rating_scale_max,
    self_rating,
    self_comment,
    manager_rating,
    manager_comment
  )
  values (
    v_goal_id,
    p_target_kra_category_id,
    v_source_goal.title,
    v_source_goal.description,
    coalesce(p_weight, v_source_goal.weight),
    v_source_goal.target_metric,
    v_source_goal.rating_scale_max,
    null,
    null,
    null,
    null
  );

  insert into public.goal_cascade (
    id,
    source_goal_id,
    cascaded_goal_id,
    cascaded_by
  )
  values (
    v_goal_cascade_id,
    p_source_goal_id,
    v_goal_id,
    v_actor_id
  );

  return query
  select v_goal_id, v_goal_cascade_id;
end;
$$;

comment on function public.create_cascaded_goal(uuid, uuid, numeric) is
  'Copies a readable goal into a caller-owned KRA category and records the employee-authored cascade atomically.';

revoke all on function public.create_cascaded_goal(uuid, uuid, numeric) from public;
grant execute on function public.create_cascaded_goal(uuid, uuid, numeric)
to authenticated, service_role;
