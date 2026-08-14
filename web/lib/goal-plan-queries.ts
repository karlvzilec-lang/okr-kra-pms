// Server-side loaders shared by the employee editor and the manager views.
//
// These deliberately go through PostgREST rather than a new RPC: everything
// they read is already reachable under the existing select policies, and the
// nested select keeps the plan/category/goal shape in one round trip.

import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  EmployeeGoalPlan,
  Goal,
  GoalPlanStatus,
  KraCategory,
  ManagerReportPlan,
  ReviewCycleStatus,
} from "@/lib/types";

const PLAN_SELECT =
  "id, review_cycle_id, employee_id, status, overall_rating_scale_max, " +
  "kra_category(id, employee_goal_plan_id, name, description, weight, " +
  "goal(id, kra_category_id, title, description, weight, target_metric, rating_scale_max, " +
  "self_rating, self_comment, manager_rating, manager_comment))";

type RawPlan = {
  id: string;
  review_cycle_id: string;
  employee_id: string;
  status: GoalPlanStatus;
  overall_rating_scale_max: number;
  kra_category: (Omit<KraCategory, "goals"> & { goal: Goal[] | null })[] | null;
};

function shapePlan(raw: RawPlan): EmployeeGoalPlan {
  const categories: KraCategory[] = (raw.kra_category ?? [])
    .map(({ goal, ...category }) => ({
      ...category,
      goals: [...(goal ?? [])].sort((a, b) => a.title.localeCompare(b.title)),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));

  return {
    id: raw.id,
    review_cycle_id: raw.review_cycle_id,
    employee_id: raw.employee_id,
    status: raw.status,
    overall_rating_scale_max: raw.overall_rating_scale_max,
    categories,
  };
}

/** One plan with its categories and goals, or null when RLS hides it. */
export async function loadGoalPlan(
  supabase: SupabaseClient,
  planId: string,
): Promise<EmployeeGoalPlan | null> {
  const { data, error } = await supabase
    .from("employee_goal_plan")
    .select(PLAN_SELECT)
    .eq("id", planId)
    .maybeSingle();

  if (error || !data) return null;
  return shapePlan(data as unknown as RawPlan);
}

/**
 * Is this user a line_manager participant on this SPECIFIC plan? Being a
 * manager on some other plan grants nothing here, so the check is always
 * scoped to the plan being viewed, never to "is a manager somewhere".
 */
export async function isLineManagerOfPlan(
  supabase: SupabaseClient,
  planId: string,
  userId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("review_participant")
    .select("id")
    .eq("employee_goal_plan_id", planId)
    .eq("participant_id", userId)
    .eq("role", "line_manager")
    .maybeSingle();

  return Boolean(data);
}

/** Does this user hold at least one line_manager participant row anywhere? */
export async function hasAnyDirectReports(
  supabase: SupabaseClient,
  userId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("review_participant")
    .select("id")
    .eq("participant_id", userId)
    .eq("role", "line_manager")
    .limit(1);

  return (data?.length ?? 0) > 0;
}

/** The employee's own plan for a cycle, if one exists. */
export async function loadOwnPlanForCycle(
  supabase: SupabaseClient,
  cycleId: string,
  userId: string,
): Promise<{ id: string; status: GoalPlanStatus } | null> {
  const { data } = await supabase
    .from("employee_goal_plan")
    .select("id, status")
    .eq("review_cycle_id", cycleId)
    .eq("employee_id", userId)
    .maybeSingle();

  return (data as { id: string; status: GoalPlanStatus } | null) ?? null;
}

type RawReportRow = {
  employee_goal_plan_id: string;
  employee_goal_plan: {
    id: string;
    status: GoalPlanStatus;
    employee_id: string;
    review_cycle_id: string;
    profiles: { full_name: string } | { full_name: string }[] | null;
    review_cycle:
      | { name: string; status: ReviewCycleStatus }
      | { name: string; status: ReviewCycleStatus }[]
      | null;
    kra_category: { goal: { manager_rating: number | null }[] | null }[] | null;
  } | null;
};

function firstOf<T>(value: T | T[] | null): T | null {
  if (!value) return null;
  return Array.isArray(value) ? (value[0] ?? null) : value;
}

/** Every plan the signed-in user is a line_manager participant on. */
export async function loadManagerReports(
  supabase: SupabaseClient,
  userId: string,
): Promise<ManagerReportPlan[]> {
  const { data } = await supabase
    .from("review_participant")
    .select(
      "employee_goal_plan_id, employee_goal_plan(id, status, employee_id, review_cycle_id, " +
        "profiles(full_name), review_cycle(name, status), kra_category(goal(manager_rating)))",
    )
    .eq("participant_id", userId)
    .eq("role", "line_manager");

  const rows = (data ?? []) as unknown as RawReportRow[];

  return rows
    .map((row) => row.employee_goal_plan)
    .filter((plan): plan is NonNullable<RawReportRow["employee_goal_plan"]> => Boolean(plan))
    .map((plan) => {
      const goals = (plan.kra_category ?? []).flatMap((category) => category.goal ?? []);
      const cycle = firstOf(plan.review_cycle);

      return {
        id: plan.id,
        status: plan.status,
        employee_id: plan.employee_id,
        employee_name: firstOf(plan.profiles)?.full_name ?? "Unknown employee",
        review_cycle_id: plan.review_cycle_id,
        review_cycle_name: cycle?.name ?? null,
        review_cycle_status: cycle?.status ?? null,
        goal_count: goals.length,
        manager_rated_count: goals.filter((goal) => goal.manager_rating !== null).length,
      };
    })
    .sort((a, b) => a.employee_name.localeCompare(b.employee_name));
}
