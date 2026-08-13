-- 0010_employee_review_summary.sql
-- Ruling 2: nested, parameterized, read-only review detail. SECURITY INVOKER
-- keeps every underlying table's RLS policy in force.

create or replace function public.employee_review_summary(
  p_review_cycle_id uuid,
  p_employee_id uuid
)
returns table (summary jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'review_cycle_id', egp.review_cycle_id,
    'employee_id', egp.employee_id,
    'employee_goal_plan_id', egp.id,
    'kra_ratings', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'rating_type', gpr.rating_type::text,
          'overall_score', gpr.overall_score,
          'computed_at', gpr.computed_at
        )
        order by gpr.rating_type::text
      )
      from public.goal_plan_rating as gpr
      where gpr.employee_goal_plan_id = egp.id
    ), '[]'::jsonb),
    'objectives', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'title', o.title,
          'description', o.description,
          'status', o.status::text,
          'created_at', o.created_at,
          'updated_at', o.updated_at,
          'key_results', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id', kr.id,
                'title', kr.title,
                'metric_unit', kr.metric_unit,
                'start_value', kr.start_value,
                'target_value', kr.target_value,
                'current_value', kr.current_value,
                'score', kr.score,
                'score_override', kr.score_override,
                'effective_score', coalesce(kr.score_override, kr.score),
                'created_at', kr.created_at,
                'updated_at', kr.updated_at
              )
              order by kr.created_at, kr.id
            )
            from public.key_result as kr
            where kr.objective_id = o.id
          ), '[]'::jsonb)
        )
        order by o.created_at, o.id
      )
      from public.objective as o
      where o.review_cycle_id = p_review_cycle_id
        and o.owner_id = p_employee_id
    ), '[]'::jsonb)
  ) as summary
  from public.employee_goal_plan as egp
  where egp.review_cycle_id = p_review_cycle_id
    and egp.employee_id = p_employee_id;
$$;

revoke all on function public.employee_review_summary(uuid, uuid) from public;

grant execute on function public.employee_review_summary(uuid, uuid)
to authenticated, service_role;
