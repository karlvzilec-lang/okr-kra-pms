export type KraRating = {
  rating_type: "self" | "manager";
  overall_score: number;
  computed_at: string;
  // Phase 3: the post-calibration, published score. Null until HR publishes
  // the plan; always null on the "self" block — self-assessments are never
  // a calibration input, only the manager rating is.
  final_score: number | null;
};

export type KeyResult = {
  id: string;
  title: string;
  metric_unit: string | null;
  start_value: number;
  target_value: number;
  current_value: number;
  score: number | null;
  score_override: number | null;
  effective_score: number | null;
  created_at: string;
  updated_at: string;
};

export type Objective = {
  id: string;
  title: string;
  description: string | null;
  status: "active" | "closed";
  created_at: string;
  updated_at: string;
  key_results: KeyResult[];
};

// ---------------------------------------------------------------------------
// Goal plan editing / manager rating (additive — the rollup types above are
// what /review depends on and are deliberately left untouched).
// ---------------------------------------------------------------------------

export type GoalPlanStatus = "draft" | "submitted" | "manager_reviewed" | "finalized";

export type ReviewCycleStatus =
  | "draft"
  | "active"
  | "self_eval"
  | "manager_eval"
  | "closed";

export type Goal = {
  id: string;
  kra_category_id: string;
  title: string;
  description: string | null;
  // numeric(6,2) — PostgREST hands these back as numbers; compare them via
  // lib/goals.ts in integer hundredths, never as floats.
  weight: number;
  target_metric: string | null;
  rating_scale_max: number;
  self_rating: number | null;
  self_comment: string | null;
  manager_rating: number | null;
  manager_comment: string | null;
};

export type KraCategory = {
  id: string;
  employee_goal_plan_id: string;
  name: string;
  description: string | null;
  weight: number;
  goals: Goal[];
};

export type EmployeeGoalPlan = {
  id: string;
  review_cycle_id: string;
  employee_id: string;
  status: GoalPlanStatus;
  overall_rating_scale_max: number;
  categories: KraCategory[];
};

/** A plan the signed-in user is a line_manager participant on. */
export type ManagerReportPlan = {
  id: string;
  status: GoalPlanStatus;
  employee_id: string;
  employee_name: string;
  review_cycle_id: string;
  review_cycle_name: string | null;
  review_cycle_status: ReviewCycleStatus | null;
  goal_count: number;
  manager_rated_count: number;
};

// ---------------------------------------------------------------------------
// Review cycle management / OKR authoring (additive — every type above is what
// /review, /goals and /calibration already depend on and is left untouched).
// ---------------------------------------------------------------------------

export type ReviewCycle = {
  id: string;
  name: string;
  start_date: string;
  end_date: string;
  status: ReviewCycleStatus;
  created_at: string;
  updated_at: string;
};

/** An append-only progress event on a key result. Never edited, never deleted. */
export type CheckIn = {
  id: string;
  key_result_id: string;
  checked_in_by: string;
  new_value: number;
  note: string | null;
  created_at: string;
};

/**
 * An objective as listed on /objectives: the row plus its cycle's name and
 * status, which together decide whether it is still writable — a closed cycle
 * freezes every OKR write at the database level, not just in this UI.
 */
export type ObjectiveWithCycle = {
  id: string;
  review_cycle_id: string;
  owner_id: string;
  title: string;
  description: string | null;
  status: "active" | "closed";
  created_at: string;
  updated_at: string;
  review_cycle_name: string | null;
  review_cycle_status: ReviewCycleStatus | null;
  key_result_count: number;
};

export type ReviewSummary = {
  review_cycle_id: string;
  employee_id: string;
  employee_goal_plan_id: string | null;
  kra_ratings: KraRating[];
  objectives: Objective[];
};
