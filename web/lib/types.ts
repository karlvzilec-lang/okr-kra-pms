export type KraRating = {
  rating_type: "self" | "manager";
  overall_score: number;
  computed_at: string;
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

export type ReviewSummary = {
  review_cycle_id: string;
  employee_id: string;
  employee_goal_plan_id: string | null;
  kra_ratings: KraRating[];
  objectives: Objective[];
};
