// Shared, framework-free helpers for the goal-plan editor and the manager
// rating view. Everything here is pure so both the employee side and the
// manager side agree exactly on what "valid" means before anything is sent to
// the database.
//
// Two rules in this file are load-bearing and are NOT stylistic preferences:
//
//   1. Weights are compared as integers in hundredths (100.00 -> 10000). The
//      columns are numeric(6,2), so the DB's notion of "sums to 100" is exact
//      decimal arithmetic. Float equality (0.1 + 0.2 !== 0.3) would let the UI
//      say "valid" on a plan the DB then rejects with 23514, or vice versa.
//
//   2. An empty rating input means null, not 0. Zero is a legitimate rating —
//      "did not deliver this goal" — and is distinct from "not rated yet".
//      compute_goal_plan_rating refuses to roll up a plan with any unrated
//      goal, so conflating the two would silently turn "unrated" into a real,
//      score-lowering zero.

import type { GoalPlanStatus, KraCategory } from "@/lib/types";

// ---------------------------------------------------------------------------
// Exact decimal weights
// ---------------------------------------------------------------------------

/** numeric(6,2) => two decimal places. */
const WEIGHT_SCALE = 100;

/** 100.00 percent expressed in hundredths, i.e. what a valid group must total. */
export const WEIGHT_TOTAL_HUNDREDTHS = 100 * WEIGHT_SCALE;

/**
 * Parse a user-typed weight into integer hundredths, or null when the text
 * isn't a weight the DB would accept (blank, non-numeric, negative, over 100,
 * or finer than two decimal places).
 */
export function parseWeightToHundredths(raw: string): number | null {
  const text = raw.trim();
  if (text.length === 0) return null;
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(text)) return null;

  const [whole, fraction = ""] = text.split(".");
  const padded = (fraction + "00").slice(0, 2);
  const hundredths = Number(whole) * WEIGHT_SCALE + Number(padded);

  if (!Number.isSafeInteger(hundredths)) return null;
  if (hundredths < 0 || hundredths > WEIGHT_TOTAL_HUNDREDTHS) return null;
  return hundredths;
}

/** Render integer hundredths back as the decimal string the DB stores. */
export function formatHundredths(hundredths: number): string {
  const sign = hundredths < 0 ? "-" : "";
  const abs = Math.abs(hundredths);
  return `${sign}${Math.floor(abs / WEIGHT_SCALE)}.${String(abs % WEIGHT_SCALE).padStart(2, "0")}`;
}

/** Weight as a number safe to send to PostgREST (two decimal places, exact). */
export function hundredthsToNumber(hundredths: number): number {
  return hundredths / WEIGHT_SCALE;
}

/** Convert a value already read back from the DB into integer hundredths. */
export function weightFromDb(value: number | string): number {
  return parseWeightToHundredths(String(value)) ?? 0;
}

// ---------------------------------------------------------------------------
// Ratings
// ---------------------------------------------------------------------------

export type RatingParse =
  | { ok: true; value: number | null }
  | { ok: false; reason: string };

/**
 * Parse a rating input against its goal's scale. Blank is a deliberate null
 * ("not rated"), never 0. Mirrors the goal_self_rating_range /
 * goal_manager_rating_range CHECKs so the UI rejects before the DB has to.
 */
export function parseRating(raw: string, scaleMax: number): RatingParse {
  const text = raw.trim();
  if (text.length === 0) return { ok: true, value: null };
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(text)) {
    return { ok: false, reason: "Ratings are numbers with at most two decimal places." };
  }

  const value = Number(text);
  if (!Number.isFinite(value)) {
    return { ok: false, reason: "That isn't a number." };
  }
  if (value < 0 || value > scaleMax) {
    return { ok: false, reason: `Ratings run from 0 to ${scaleMax}.` };
  }
  return { ok: true, value };
}

/** Render a nullable rating for display without turning null into 0. */
export function formatRating(value: number | null): string {
  return value === null || value === undefined ? "" : String(value);
}

// ---------------------------------------------------------------------------
// Plan-shaped validation
// ---------------------------------------------------------------------------

export type WeightProblem = {
  scope: "plan" | "category";
  categoryId: string | null;
  message: string;
};

/**
 * The exact check validate_goal_plan_weights performs, run client-side so the
 * employee sees the problem while they can still fix it: category weights sum
 * to 100 across the plan, and goal weights sum to 100 inside every category.
 * Categories with no goals are a problem too — the DB counts them as 0.
 */
export function validatePlanWeights(categories: KraCategory[]): WeightProblem[] {
  const problems: WeightProblem[] = [];

  if (categories.length === 0) {
    problems.push({
      scope: "plan",
      categoryId: null,
      message: "Add at least one KRA category before submitting.",
    });
    return problems;
  }

  const categoryTotal = categories.reduce(
    (sum, category) => sum + weightFromDb(category.weight),
    0,
  );
  if (categoryTotal !== WEIGHT_TOTAL_HUNDREDTHS) {
    problems.push({
      scope: "plan",
      categoryId: null,
      message: `Category weights must total 100.00 (currently ${formatHundredths(categoryTotal)}).`,
    });
  }

  for (const category of categories) {
    const goalTotal = category.goals.reduce((sum, goal) => sum + weightFromDb(goal.weight), 0);
    if (goalTotal !== WEIGHT_TOTAL_HUNDREDTHS) {
      problems.push({
        scope: "category",
        categoryId: category.id,
        message:
          category.goals.length === 0
            ? `"${category.name}" has no goals, so its goal weights total 0.00 instead of 100.00.`
            : `Goal weights in "${category.name}" must total 100.00 (currently ${formatHundredths(goalTotal)}).`,
      });
    }
  }

  return problems;
}

/** Goals still missing the given rating — the rollup refuses to run with any. */
export function unratedGoals(
  categories: KraCategory[],
  ratingType: "self" | "manager",
): { categoryName: string; goalTitle: string }[] {
  const missing: { categoryName: string; goalTitle: string }[] = [];
  for (const category of categories) {
    for (const goal of category.goals) {
      const value = ratingType === "self" ? goal.self_rating : goal.manager_rating;
      if (value === null || value === undefined) {
        missing.push({ categoryName: category.name, goalTitle: goal.title });
      }
    }
  }
  return missing;
}

// ---------------------------------------------------------------------------
// Status gates
// ---------------------------------------------------------------------------

/**
 * The employee owns the plan's contents only while it's draft or submitted.
 * Once a manager has reviewed it, the structure and the self-ratings are
 * frozen. Checked up-front so the UI renders read-only rather than letting
 * someone fill in a form that RLS will reject on save.
 */
export function employeeCanEdit(status: GoalPlanStatus): boolean {
  return status === "draft" || status === "submitted";
}

/**
 * A manager may write manager_rating/manager_comment only while the cycle is
 * in manager_eval AND this specific plan is submitted. The second half is the
 * tightened rule in can_manager_rate_goal: a draft plan (never submitted) and
 * an already-reviewed plan are both closed to manager rating even mid-window.
 */
export function managerCanRate(
  planStatus: GoalPlanStatus,
  cycleStatus: string | null | undefined,
): boolean {
  return planStatus === "submitted" && cycleStatus === "manager_eval";
}

/** Human-readable reason a manager can't rate right now. */
export function managerBlockedReason(
  planStatus: GoalPlanStatus,
  cycleStatus: string | null | undefined,
): string | null {
  if (managerCanRate(planStatus, cycleStatus)) return null;
  if (planStatus === "draft") {
    return "This plan hasn't been submitted yet. You can rate it once the employee submits it for review.";
  }
  if (planStatus === "manager_reviewed") {
    return "You've already marked this plan as reviewed. Ratings are locked from here.";
  }
  if (planStatus === "finalized") {
    return "This plan is finalized. Ratings are locked.";
  }
  if (cycleStatus !== "manager_eval") {
    return "The review cycle isn't in its manager evaluation window, so manager ratings are closed.";
  }
  return "Manager ratings aren't open for this plan right now.";
}

export const PLAN_STATUS_LABEL: Record<GoalPlanStatus, string> = {
  draft: "Draft",
  submitted: "Submitted",
  manager_reviewed: "Manager reviewed",
  finalized: "Finalized",
};

// ---------------------------------------------------------------------------
// Error surfacing
// ---------------------------------------------------------------------------

type PostgrestLikeError = {
  code?: string | null;
  message?: string | null;
};

/**
 * Map the SQLSTATEs the goal-plan triggers and functions raise onto plain
 * language. Unrecognised codes fall through to the raw message rather than
 * being swallowed behind a generic failure.
 */
export function goalErrorMessage(error: PostgrestLikeError | null): string | null {
  if (!error) return null;

  switch (error.code) {
    case "42501":
      return (
        error.message ??
        "You aren't allowed to change that field at this point in the review."
      );
    case "23514":
      return error.message ?? "That value falls outside what the plan allows.";
    case "22023":
      return "That goal plan no longer exists. Refresh and try again.";
    case "PGRST116":
      // Zero rows came back from a write that expected one. RLS blocks are
      // silent — no exception, no rows — so this is the only signal that a
      // status transition was refused.
      return "That change was rejected. You may no longer have permission to make it, or someone else moved this plan forward first.";
    default:
      return error.message ?? "Something went wrong. Try again.";
  }
}

/**
 * Shared wording for the "the write succeeded but no row came back" case,
 * which is what an RLS-blocked UPDATE looks like from the client.
 */
export const BLOCKED_TRANSITION_MESSAGE =
  "That transition didn't go through. The database refused it — refresh the page to see the plan's current state.";
