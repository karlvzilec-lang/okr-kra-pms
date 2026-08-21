// Server-side loaders for the HR admin pages and the cascade / alignment link
// forms.
//
// These go through PostgREST rather than new RPCs, matching
// lib/goal-plan-queries.ts and lib/okr-queries.ts: everything read here is
// already reachable under the existing select policies, and each page's shape
// stays to one round trip where the nesting allows it.
//
// What these loaders read is scoped by RLS, not by these functions, and the
// difference matters in two places:
//
//   * loadAllProfiles() is only ever called from an HR-gated page. For a
//     non-HR caller profiles_select_scoped would quietly narrow the result to
//     themselves and their own reports rather than erroring, so the page gate
//     is what makes the list mean "everyone", not this query.
//
//   * loadCascadeSources() relies on can_read_goal's manager branch: an
//     employee can read the goals belonging to their own line manager's plan.
//     That read authority is exactly what the cascade RPC needs, so anything
//     this returns is by construction a legal cascade source.

import { redirect } from "next/navigation";
import type { SupabaseClient } from "@supabase/supabase-js";
import { isPasswordExpired } from "@/lib/password";
import { rangeFor, refetchIfClamped, type Paginated } from "@/lib/pagination";
import type {
  Goal,
  GoalPlanStatus,
  ObjectiveWithCycle,
  Profile,
  ReviewCycleStatus,
  ScopeType,
} from "@/lib/types";

const PROFILE_COLUMNS =
  "id, full_name, email, manager_id, is_hr_admin, password_changed_at, created_at, updated_at";

function firstOf<T>(value: T | T[] | null): T | null {
  if (!value) return null;
  return Array.isArray(value) ? (value[0] ?? null) : value;
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

/**
 * Auth + password-expiry + HR check, run by the layout AND independently by
 * every page beneath it.
 *
 * The repetition is deliberate and was found the hard way: in the App Router a
 * layout and the page inside it render CONCURRENTLY. A redirect() thrown in
 * the layout sets the 307 on the response, but it does not stop the page from
 * having already rendered — its loaders still run, and its output is still
 * serialized into the RSC flight payload of that redirect response. A probe of
 * GET /admin with no session cookie confirmed it: the status line said 307
 * /login while the body carried the rendered employee-directory markup.
 *
 * So a layout gate is a redirect, not an authorization boundary. RLS still
 * scopes every row (which is why this was a structure-and-queries exposure
 * rather than a data breach), but running privileged loaders for a caller who
 * was just redirected away is not a thing to leave in place. Calling this at
 * the top of each page stops execution before any query is issued.
 *
 * Password expiry is checked BEFORE the HR flag on purpose, matching
 * /calibration and /review-cycles: an expired credential must not be able to
 * probe who holds HR admin by telling a 403 apart from a redirect.
 */
export async function requireHrAdmin(supabase: SupabaseClient): Promise<void> {
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("is_hr_admin, password_changed_at")
    .eq("id", user.id)
    .single();

  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  if (!profile?.is_hr_admin) {
    redirect("/review");
  }
}

// ---------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------

export type ProfileWithManager = Profile & { manager_name: string | null };

type RawProfileRow = Profile & {
  manager: { full_name: string } | { full_name: string }[] | null;
};

/**
 * Every profile visible to the caller, by name. The manager join is aliased
 * directly off the `manager_id` column (`manager:manager_id(...)`), not off
 * `profiles!manager_id`. profiles self-references, and PostgREST resolves a
 * `!manager_id` hint against a self-join as the *reverse* one-to-many side
 * (rows whose manager_id points at this row, i.e. direct reports) rather
 * than the intended many-to-one (this row's own manager) -- confirmed
 * directly against the REST API: `profiles!manager_id` returned each
 * manager's list of reports, while `manager_id(full_name)` returns the one
 * row `manager_id` actually points to. The column-only form is unambiguous
 * because a single column can only be the "many" side of its own FK.
 *
 * UNBOUNDED on purpose. This is the list that feeds the manager <select> in
 * the create and edit forms, and a picker that silently omits candidates
 * because they happen to sort onto another page of the directory would be a
 * data-entry bug rather than a UX shortcoming — you would assign the wrong
 * manager, or conclude the right one doesn't exist. The directory's own
 * rendered rows come from loadProfilePage() instead; the two are separate
 * queries because they answer separate questions.
 */
export async function loadAllProfiles(
  supabase: SupabaseClient,
): Promise<ProfileWithManager[]> {
  const { data } = await supabase
    .from("profiles")
    .select(`${PROFILE_COLUMNS}, manager:manager_id(full_name)`)
    .order("full_name", { ascending: true })
    .order("id", { ascending: true });

  return ((data ?? []) as unknown as RawProfileRow[]).map(shapeProfile);
}

function shapeProfile(row: RawProfileRow): ProfileWithManager {
  return {
    id: row.id,
    full_name: row.full_name,
    email: row.email,
    manager_id: row.manager_id,
    is_hr_admin: row.is_hr_admin,
    password_changed_at: row.password_changed_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
    manager_name: firstOf(row.manager)?.full_name ?? null,
  };
}

/**
 * One page of the employee directory, plus the total.
 *
 * `id` is the tiebreaker after `full_name` because full_name carries no unique
 * constraint — two people genuinely can share a name, and without a unique
 * final sort key Postgres is free to order the tied rows differently between
 * the page-1 and page-2 queries, which would show one of them twice and drop
 * the other entirely.
 *
 * The count is `exact` and rides along on the same request as the rows, so it
 * counts what RLS actually exposes to this caller rather than the raw table.
 */
export async function loadProfilePage(
  supabase: SupabaseClient,
  page: number,
): Promise<Paginated<ProfileWithManager>> {
  const { from, to } = rangeFor(page);

  const { data, count } = await supabase
    .from("profiles")
    .select(`${PROFILE_COLUMNS}, manager:manager_id(full_name)`, { count: "exact" })
    .order("full_name", { ascending: true })
    .order("id", { ascending: true })
    .range(from, to);

  const total = count ?? 0;
  const rows = ((data ?? []) as unknown as RawProfileRow[]).map(shapeProfile);

  return refetchIfClamped(rows, total, page, (target) => loadProfilePage(supabase, target));
}

// ---------------------------------------------------------------------------
// Matrix-scope grant screen
// ---------------------------------------------------------------------------

export type AdminPlanSummary = {
  id: string;
  status: GoalPlanStatus;
  employee_id: string;
  employee_name: string;
  review_cycle_id: string;
  review_cycle_name: string | null;
  review_cycle_status: ReviewCycleStatus | null;
};

type RawAdminPlanRow = {
  id: string;
  status: GoalPlanStatus;
  employee_id: string;
  review_cycle_id: string;
  profiles: { full_name: string } | { full_name: string }[] | null;
  review_cycle:
    | { name: string; status: ReviewCycleStatus }
    | { name: string; status: ReviewCycleStatus }[]
    | null;
};

/**
 * Every goal plan visible to the caller, with whose it is and which cycle.
 *
 * The `profiles` embed must go through the `employee_id` column explicitly
 * (`profiles:employee_id(...)`, the same bare column-name form used for
 * `manager:manager_id` above): `employee_goal_plan` has carried a second FK to
 * `profiles` since 0022 added `last_unpublished_by`, so a bare `profiles(...)`
 * embed is ambiguous and PostgREST rejects the whole query with PGRST201. That
 * error was previously discarded silently (`const { data } = await ...`),
 * which made every plan on this page vanish - matrix-scope grants have been
 * effectively unusable since 0022 shipped, since the grant form has no plans
 * to offer once loadAdminPlans always returns empty.
 */
export async function loadAdminPlans(
  supabase: SupabaseClient,
): Promise<AdminPlanSummary[]> {
  const { data } = await supabase
    .from("employee_goal_plan")
    .select(
      "id, status, employee_id, review_cycle_id, profiles:employee_id(full_name), review_cycle(name, status)",
    );

  return ((data ?? []) as unknown as RawAdminPlanRow[])
    .map((row) => {
      const cycle = firstOf(row.review_cycle);
      return {
        id: row.id,
        status: row.status,
        employee_id: row.employee_id,
        employee_name: firstOf(row.profiles)?.full_name ?? "Unknown employee",
        review_cycle_id: row.review_cycle_id,
        review_cycle_name: cycle?.name ?? null,
        review_cycle_status: cycle?.status ?? null,
      };
    })
    .sort((a, b) => a.employee_name.localeCompare(b.employee_name));
}

export type ScopeTarget = {
  id: string;
  label: string;
  scope_type: ScopeType;
};

/**
 * The KRA categories on one plan and the objectives in that plan's cycle owned
 * by that plan's employee — i.e. exactly the things that plan's matrix manager
 * could legitimately be scoped to.
 *
 * The objective side is filtered by BOTH cycle and owner on purpose. Scoping
 * to a cycle alone would offer someone else's objectives from the same cycle,
 * which the scope trigger would accept (it only checks the objective exists)
 * while granting access nobody intended.
 */
export async function loadScopeTargets(
  supabase: SupabaseClient,
  planId: string,
  employeeId: string,
  reviewCycleId: string,
): Promise<{ categories: ScopeTarget[]; objectives: ScopeTarget[] }> {
  const [{ data: categories }, { data: objectives }] = await Promise.all([
    supabase
      .from("kra_category")
      .select("id, name")
      .eq("employee_goal_plan_id", planId)
      .order("name", { ascending: true }),
    supabase
      .from("objective")
      .select("id, title")
      .eq("review_cycle_id", reviewCycleId)
      .eq("owner_id", employeeId)
      .order("title", { ascending: true }),
  ]);

  return {
    categories: ((categories ?? []) as { id: string; name: string }[]).map((row) => ({
      id: row.id,
      label: row.name,
      scope_type: "kra_category" as const,
    })),
    objectives: ((objectives ?? []) as { id: string; title: string }[]).map((row) => ({
      id: row.id,
      label: row.title,
      scope_type: "objective" as const,
    })),
  };
}

export type ExistingScopeGrant = {
  id: string;
  scope_type: ScopeType;
  scope_id: string;
  participant_id: string;
  participant_name: string;
  employee_goal_plan_id: string;
  granted_at: string;
};

type RawScopeRow = {
  id: string;
  scope_type: ScopeType;
  scope_id: string;
  created_at: string;
  review_participant:
    | {
        participant_id: string;
        employee_goal_plan_id: string;
        profiles: { full_name: string } | { full_name: string }[] | null;
      }
    | {
        participant_id: string;
        employee_goal_plan_id: string;
        profiles: { full_name: string } | { full_name: string }[] | null;
      }[]
    | null;
};

const SCOPE_GRANT_SELECT =
  "id, scope_type, scope_id, created_at, " +
  "review_participant(participant_id, employee_goal_plan_id, profiles(full_name))";

function shapeScopeGrant(row: RawScopeRow): ExistingScopeGrant | null {
  const participant = firstOf(row.review_participant);
  if (!participant) return null;
  return {
    id: row.id,
    scope_type: row.scope_type,
    scope_id: row.scope_id,
    participant_id: participant.participant_id,
    participant_name: firstOf(participant.profiles)?.full_name ?? "Unknown",
    employee_goal_plan_id: participant.employee_goal_plan_id,
    granted_at: row.created_at,
  };
}

/**
 * One page of the scope grants already in place, so the screen shows state
 * rather than a blank form.
 *
 * Newest first, with `id` breaking ties on created_at — two grants issued in
 * the same transaction share a timestamp to the microsecond, and that is not a
 * hypothetical here: granting several scopes to one matrix manager in a single
 * sitting is the normal way this screen is used.
 *
 * The count is taken before the null-participant filter below, which is
 * correct: review_participant is a NOT NULL FK, so the embed is only null when
 * RLS hides the parent row, and PostgREST has already applied that same RLS to
 * the count. In practice the filter drops nothing and the count matches; it
 * stays as a type guard rather than as list surgery.
 */
export async function loadScopeGrantPage(
  supabase: SupabaseClient,
  page: number,
): Promise<Paginated<ExistingScopeGrant>> {
  const { from, to } = rangeFor(page);

  const { data, count } = await supabase
    .from("review_participant_scope")
    .select(SCOPE_GRANT_SELECT, { count: "exact" })
    .order("created_at", { ascending: false })
    .order("id", { ascending: true })
    .range(from, to);

  const total = count ?? 0;
  const rows = ((data ?? []) as unknown as RawScopeRow[])
    .map(shapeScopeGrant)
    .filter((row): row is ExistingScopeGrant => row !== null);

  return refetchIfClamped(rows, total, page, (target) => loadScopeGrantPage(supabase, target));
}

// ---------------------------------------------------------------------------
// Cascade / alignment sources
// ---------------------------------------------------------------------------

export type LinkableGoal = {
  id: string;
  title: string;
  description: string | null;
  target_metric: string | null;
  rating_scale_max: number;
  weight: number;
  owner_name: string | null;
  category_name: string;
};

type RawLinkableGoalRow = Pick<
  Goal,
  | "id"
  | "kra_category_id"
  | "title"
  | "description"
  | "target_metric"
  | "rating_scale_max"
  | "weight"
> & {
  kra_category:
    | {
        name: string;
        employee_goal_plan:
          | { employee_id: string; profiles: { full_name: string } | { full_name: string }[] | null }
          | { employee_id: string; profiles: { full_name: string } | { full_name: string }[] | null }[]
          | null;
      }
    | {
        name: string;
        employee_goal_plan:
          | { employee_id: string; profiles: { full_name: string } | { full_name: string }[] | null }
          | { employee_id: string; profiles: { full_name: string } | { full_name: string }[] | null }[]
          | null;
      }[]
    | null;
};

// employee_goal_plan's profiles embed is disambiguated the same way and for
// the same reason as loadAdminPlans above: two FKs to profiles since 0022,
// so a bare profiles(...) here is ambiguous and PGRST201s the whole query -
// which silently emptied both the cascade-source and alignment-parent
// pickers (loadAlignmentParents calls this same function) since 0022 shipped.
const LINKABLE_GOAL_SELECT =
  "id, title, description, target_metric, rating_scale_max, weight, " +
  "kra_category(name, employee_goal_plan(employee_id, profiles:employee_id(full_name)))";

function shapeLinkableGoal(row: RawLinkableGoalRow): LinkableGoal {
  const category = firstOf(row.kra_category);
  const plan = firstOf(category?.employee_goal_plan ?? null);
  return {
    id: row.id,
    title: row.title,
    description: row.description,
    target_metric: row.target_metric,
    rating_scale_max: row.rating_scale_max,
    weight: row.weight,
    owner_name: firstOf(plan?.profiles ?? null)?.full_name ?? null,
    category_name: category?.name ?? "Uncategorised",
  };
}

/**
 * Goals the signed-in employee may cascade FROM: everything readable under
 * can_read_goal that isn't already in their own plan.
 *
 * The exclusion is not cosmetic. goal_cascade_no_self_copy blocks copying a
 * goal onto itself, and copying a goal from one of your own categories into
 * another is a duplicate rather than a cascade — neither is what this control
 * is for, and both would look like the feature misbehaving.
 */
export async function loadCascadeSources(
  supabase: SupabaseClient,
  ownPlanId: string,
): Promise<LinkableGoal[]> {
  const { data } = await supabase.from("goal").select(LINKABLE_GOAL_SELECT);

  const ownCategoryIds = await loadOwnCategoryIds(supabase, ownPlanId);
  const own = new Set(ownCategoryIds);

  return ((data ?? []) as unknown as RawLinkableGoalRow[])
    .filter((row) => !own.has(row.kra_category_id))
    .map(shapeLinkableGoal)
    .sort((a, b) => a.title.localeCompare(b.title));
}

async function loadOwnCategoryIds(
  supabase: SupabaseClient,
  planId: string,
): Promise<string[]> {
  const { data } = await supabase
    .from("kra_category")
    .select("id")
    .eq("employee_goal_plan_id", planId);

  return ((data ?? []) as { id: string }[]).map((row) => row.id);
}

/**
 * Goals readable by the caller that could serve as an ALIGNMENT parent, with
 * the caller's own plan's goals excluded — goal_alignment_no_self_link blocks
 * linking a goal to itself, and aligning two goals inside one plan is a
 * within-plan relationship this schema doesn't model.
 */
export async function loadAlignmentParents(
  supabase: SupabaseClient,
  ownPlanId: string,
): Promise<LinkableGoal[]> {
  return loadCascadeSources(supabase, ownPlanId);
}

export type ExistingGoalLinks = {
  /** goal id -> the goal it was cascaded from */
  cascadeSourceByGoalId: Map<string, string>;
  /** goal id -> the goal it aligns up to */
  alignmentParentByGoalId: Map<string, string>;
};

/**
 * Which of these goals already carry a link. Read once for the whole plan
 * because both link tables are keyed on the TARGET column, which is unique —
 * so at most one row per goal exists in each, and the map is total.
 */
export async function loadGoalLinks(
  supabase: SupabaseClient,
  goalIds: string[],
): Promise<ExistingGoalLinks> {
  if (goalIds.length === 0) {
    return {
      cascadeSourceByGoalId: new Map(),
      alignmentParentByGoalId: new Map(),
    };
  }

  const [{ data: cascades }, { data: alignments }] = await Promise.all([
    supabase
      .from("goal_cascade")
      .select("source_goal_id, cascaded_goal_id")
      .in("cascaded_goal_id", goalIds),
    supabase
      .from("goal_alignment")
      .select("parent_goal_id, child_goal_id")
      .in("child_goal_id", goalIds),
  ]);

  return {
    cascadeSourceByGoalId: new Map(
      ((cascades ?? []) as { source_goal_id: string; cascaded_goal_id: string }[]).map((row) => [
        row.cascaded_goal_id,
        row.source_goal_id,
      ]),
    ),
    alignmentParentByGoalId: new Map(
      ((alignments ?? []) as { parent_goal_id: string; child_goal_id: string }[]).map((row) => [
        row.child_goal_id,
        row.parent_goal_id,
      ]),
    ),
  };
}

/** Titles for a set of goal ids, so an existing link can name what it points at. */
export async function loadGoalTitles(
  supabase: SupabaseClient,
  goalIds: string[],
): Promise<Map<string, string>> {
  if (goalIds.length === 0) return new Map();

  const { data } = await supabase.from("goal").select("id, title").in("id", goalIds);

  return new Map(((data ?? []) as { id: string; title: string }[]).map((r) => [r.id, r.title]));
}

// ---------------------------------------------------------------------------
// Objective alignment
// ---------------------------------------------------------------------------

/**
 * Objectives readable by the caller in the same cycle that they don't own —
 * the candidate parents for an alignment. Cross-cycle alignment is excluded
 * deliberately: an objective laddering up to a goal from a different review
 * period is a data-entry mistake far more often than an intent.
 */
export async function loadObjectiveAlignmentParents(
  supabase: SupabaseClient,
  reviewCycleId: string,
  ownerId: string,
  selfObjectiveId: string,
): Promise<ObjectiveWithCycle[]> {
  const { data } = await supabase
    .from("objective")
    .select("id, review_cycle_id, owner_id, title, description, status, created_at, updated_at")
    .eq("review_cycle_id", reviewCycleId)
    .neq("owner_id", ownerId)
    .neq("id", selfObjectiveId)
    .order("title", { ascending: true });

  return ((data ?? []) as Omit<
    ObjectiveWithCycle,
    "review_cycle_name" | "review_cycle_status" | "key_result_count"
  >[]).map((row) => ({
    ...row,
    review_cycle_name: null,
    review_cycle_status: null,
    key_result_count: 0,
  }));
}

export type ExistingObjectiveAlignment = {
  parent_objective_id: string;
  parent_title: string | null;
};

/** The alignment this objective already has, if any. Null means unlinked. */
export async function loadObjectiveAlignment(
  supabase: SupabaseClient,
  objectiveId: string,
): Promise<ExistingObjectiveAlignment | null> {
  const { data } = await supabase
    .from("objective_alignment")
    .select("parent_objective_id, objective!parent_objective_id(title)")
    .eq("child_objective_id", objectiveId)
    .maybeSingle();

  if (!data) return null;

  const row = data as unknown as {
    parent_objective_id: string;
    objective: { title: string } | { title: string }[] | null;
  };

  return {
    parent_objective_id: row.parent_objective_id,
    parent_title: firstOf(row.objective)?.title ?? null,
  };
}
