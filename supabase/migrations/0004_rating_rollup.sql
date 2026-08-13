-- 0004_rating_rollup.sql
-- Deferred weight validation plus Oracle Average Method rollup. Missing
-- ratings are rejected; they are never treated as zero (Ruling 2).

create or replace function public.validate_goal_plan_weights(p_plan_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category_weight_total numeric;
  v_category record;
begin
  if not public.is_hr_admin()
    and not public.is_goal_plan_participant(p_plan_id)
  then
    raise exception 'Not authorized to access goal plan %', p_plan_id
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.employee_goal_plan as egp
    where egp.id = p_plan_id
  ) then
    raise exception 'Goal plan % does not exist', p_plan_id
      using errcode = '22023';
  end if;

  select coalesce(sum(kc.weight), 0::numeric)
  into v_category_weight_total
  from public.kra_category as kc
  where kc.employee_goal_plan_id = p_plan_id;

  if v_category_weight_total <> 100::numeric then
    raise exception
      'Category weights for goal plan % must sum to 100 (actual: %)',
      p_plan_id,
      v_category_weight_total
      using errcode = '23514';
  end if;

  for v_category in
    select
      kc.id,
      kc.name,
      coalesce(sum(g.weight), 0::numeric) as goal_weight_total
    from public.kra_category as kc
    left join public.goal as g on g.kra_category_id = kc.id
    where kc.employee_goal_plan_id = p_plan_id
    group by kc.id, kc.name
  loop
    if v_category.goal_weight_total <> 100::numeric then
      raise exception
        'Goal weights for category % (%) must sum to 100 (actual: %)',
        v_category.id,
        v_category.name,
        v_category.goal_weight_total
        using errcode = '23514';
    end if;
  end loop;
end;
$$;

create or replace function public.compute_goal_plan_rating(
  p_plan_id uuid,
  p_rating_type public.rating_type
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_score numeric;
  v_stored_score numeric;
begin
  if p_rating_type is null then
    raise exception 'rating_type must be self or manager'
      using errcode = '22004';
  end if;

  if not public.is_hr_admin()
    and not public.is_goal_plan_participant(p_plan_id)
  then
    raise exception 'Not authorized to access goal plan %', p_plan_id
      using errcode = '42501';
  end if;

  perform public.validate_goal_plan_weights(p_plan_id);

  if exists (
    select 1
    from public.goal as g
    join public.kra_category as kc on kc.id = g.kra_category_id
    where kc.employee_goal_plan_id = p_plan_id
      and case p_rating_type
        when 'self'::public.rating_type then g.self_rating is null
        when 'manager'::public.rating_type then g.manager_rating is null
      end
  ) then
    raise exception
      'Cannot compute % rating for goal plan %: at least one goal is unrated',
      p_rating_type::text,
      p_plan_id
      using errcode = '23514';
  end if;

  select
    sum(
      (
        case p_rating_type
          when 'self'::public.rating_type then g.self_rating
          when 'manager'::public.rating_type then g.manager_rating
        end
        / g.rating_scale_max::numeric
      )
      * (g.weight / 100::numeric)
      * (kc.weight / 100::numeric)
    )
    * egp.overall_rating_scale_max::numeric
  into v_score
  from public.employee_goal_plan as egp
  join public.kra_category as kc on kc.employee_goal_plan_id = egp.id
  join public.goal as g on g.kra_category_id = kc.id
  where egp.id = p_plan_id
  group by egp.overall_rating_scale_max;

  if v_score is null then
    raise exception 'Goal plan % has no goals to rate', p_plan_id
      using errcode = '23514';
  end if;

  insert into public.goal_plan_rating (
    employee_goal_plan_id,
    rating_type,
    overall_score,
    computed_at
  )
  values (
    p_plan_id,
    p_rating_type,
    v_score,
    now()
  )
  on conflict (employee_goal_plan_id, rating_type)
  do update
  set overall_score = excluded.overall_score,
      computed_at = excluded.computed_at
  returning overall_score into v_stored_score;

  return v_stored_score;
end;
$$;

revoke all on function public.validate_goal_plan_weights(uuid) from public;
revoke all on function public.compute_goal_plan_rating(uuid, public.rating_type) from public;

grant execute on function public.validate_goal_plan_weights(uuid)
to authenticated, service_role;

grant execute on function public.compute_goal_plan_rating(uuid, public.rating_type)
to authenticated, service_role;
