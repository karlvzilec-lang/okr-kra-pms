-- 0015_review_summary_and_comp_export.sql
-- Adds the publish-gated manager final_score to the existing nested review
-- summary and exposes an explicitly HR-only, RLS-respecting comp export.

-- ---------------------------------------------------------------------------
-- Publish-gated scalar bridge
-- ---------------------------------------------------------------------------

-- Employees cannot select calibration_participant rows. This narrowly scoped
-- helper bridges only the published final scalar into employee_review_summary,
-- after independently proving the caller may read the plan.
create or replace function public.published_goal_plan_final_score(
  p_plan_id uuid
)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when egp.published_at is null then null::numeric
    else coalesce(
      (
        select cp.calibrated_score
        from public.calibration_participant as cp
        where cp.employee_goal_plan_id = egp.id
        order by cp.updated_at desc, cp.created_at desc, cp.id
        limit 1
      ),
      (
        select gpr.overall_score
        from public.goal_plan_rating as gpr
        where gpr.employee_goal_plan_id = egp.id
          and gpr.rating_type = 'manager'::public.rating_type
      )
    )
  end
  from public.employee_goal_plan as egp
  where egp.id = p_plan_id
    and (
      public.is_hr_admin()
      or public.is_goal_plan_participant(egp.id)
    );
$$;

revoke all on function public.published_goal_plan_final_score(uuid) from public;
grant execute on function public.published_goal_plan_final_score(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Existing Phase 2 review summary, with final_score added in place
-- ---------------------------------------------------------------------------

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
          'computed_at', gpr.computed_at,
          -- Ruling 2: self-assessments are not calibration inputs. Their
          -- final_score key is always JSON null, even after publication.
          'final_score', case
            when gpr.rating_type = 'manager'::public.rating_type
              then public.published_goal_plan_final_score(egp.id)
            else null::numeric
          end
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

-- ---------------------------------------------------------------------------
-- Published compensation-cycle export
-- ---------------------------------------------------------------------------

create or replace function public.comp_export_rows(
  p_review_cycle_id uuid
)
returns table (
  employee_id uuid,
  full_name text,
  email text,
  manager_full_name text,
  overall_rating_scale_max integer,
  final_score numeric,
  band_label text,
  published_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    egp.employee_id,
    employee.full_name,
    employee.email,
    manager.full_name as manager_full_name,
    egp.overall_rating_scale_max,
    coalesce(calibration.calibrated_score, manager_rating.overall_score)
      as final_score,
    calibration.band_label,
    egp.published_at
  from public.employee_goal_plan as egp
  -- Ruling 1: this explicit purpose gate is required even though every other
  -- table continues to apply its own RLS policy under SECURITY INVOKER.
  join public.profiles as caller
    on caller.id = auth.uid()
   and caller.is_hr_admin
  join public.profiles as employee on employee.id = egp.employee_id
  left join public.profiles as manager on manager.id = employee.manager_id
  left join public.goal_plan_rating as manager_rating
    on manager_rating.employee_goal_plan_id = egp.id
   and manager_rating.rating_type = 'manager'::public.rating_type
  left join lateral (
    select
      cp.calibrated_score,
      cb.label as band_label
    from public.calibration_participant as cp
    left join public.calibration_band as cb on cb.id = cp.band_id
    where cp.employee_goal_plan_id = egp.id
    order by cp.updated_at desc, cp.created_at desc, cp.id
    limit 1
  ) as calibration on true
  where egp.review_cycle_id = p_review_cycle_id
    and egp.published_at is not null
  order by employee.full_name, egp.employee_id;
$$;

revoke all on function public.comp_export_rows(uuid) from public;
grant execute on function public.comp_export_rows(uuid)
to authenticated, service_role;
