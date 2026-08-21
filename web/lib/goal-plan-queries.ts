// Server-side loaders shared by the employee editor and the manager views.
//
// These deliberately go through PostgREST rather than a new RPC: everything
// they read is already reachable under the existing select policies, and the
// nested select keeps the plan/category/goal shape in one round trip.

import type { SupabaseClient } from "@supabase/supabase-js";
import { rangeFor, refetchIfClamped, type Paginated } from "@/lib/pagination";
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
};

function firstOf<T>(value: T | T[] | null): T | null {
  if (!value) return null;
  return Array.isArray(value) ? (value[0] ?? null) : value;
}

/**
 * Every plan the signed-in user is a line_manager participant on, one page at
 * a time.
 *
 * This drives FROM employee_goal_plan and filters by an INNER-joined
 * review_participant, rather than the reverse (selecting review_participant
 * rows and reading the plan out of the embed). The inversion is what makes
 * pagination correct, and it was verified against the running PostgREST rather
 * than assumed:
 *
 *   * The old shape returned one row per PARTICIPANT record and then dropped
 *     any whose embedded plan came back null, plus sorted by employee_name in
 *     JS after the fetch. Both steps happen AFTER the rows arrive, so a
 *     .range() bolted onto it would have paginated the pre-filter, pre-sort
 *     set: page 1 could return fewer than PAGE_SIZE rendered rows while later
 *     pages still existed, and the alphabetical order would only hold WITHIN a
 *     page, not across the list — page 2 could open with a name earlier than
 *     the one page 1 ended on. That is a page control that lies about where
 *     you are, so it could not ship as-is.
 *
 *   * Sorting the old shape in SQL instead was not available either: PostgREST
 *     rejects an order key that reaches through two embeds
 *     (`order=employee_goal_plan(profiles(full_name)).asc` → PGRST100,
 *     "failed to parse order"). Confirmed by request.
 *
 *   * Driving from employee_goal_plan with `review_participant!inner` moves
 *     both the filter and the sort into the query. `profiles!inner(full_name)`
 *     is orderable as a single-level embed, `count=exact` then counts the
 *     joined-and-filtered set, and .range() slices the same final row set the
 *     page renders. Verified: the inverted query returned content-range
 *     `0-2/3` unpaged and `0-1/3` with Range 0-1 — the total is the filtered
 *     total, and the slice is a true slice of it.
 *
 * The `!inner` on review_participant is load-bearing: without it PostgREST
 * left-joins, and a plan with no matching participant row would come back with
 * an empty embed instead of being excluded — every plan RLS lets you see,
 * rather than only the ones you line-manage.
 */
export async function loadManagerReportPage(
  supabase: SupabaseClient,
  userId: string,
  page: number,
): Promise<Paginated<ManagerReportPlan>> {
  const { from, to } = rangeFor(page);

  const { data, count } = await supabase
    .from("employee_goal_plan")
    .select(
      // profiles:employee_id, not a bare profiles!inner: employee_goal_plan
      // has carried a second FK to profiles since 0022 (last_unpublished_by),
      // so an undisambiguated embed is ambiguous and PGRST201s the whole
      // query - which silently emptied this page for every manager since
      // 0022 shipped, since the caught error path here also drops it.
      "id, status, employee_id, review_cycle_id, profiles:employee_id!inner(full_name), " +
        "review_cycle(name, status), kra_category(goal(manager_rating)), " +
        "review_participant!inner(participant_id, role)",
      { count: "exact" },
    )
    .eq("review_participant.participant_id", userId)
    .eq("review_participant.role", "line_manager")
    .order("full_name", { ascending: true, referencedTable: "profiles" })
    .order("id", { ascending: true })
    .range(from, to);

  const total = count ?? 0;
  const rows = ((data ?? []) as unknown as RawReportRow[]).map((plan) => {
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
  });

  return refetchIfClamped(rows, total, page, (target) =>
    loadManagerReportPage(supabase, userId, target),
  );
}
