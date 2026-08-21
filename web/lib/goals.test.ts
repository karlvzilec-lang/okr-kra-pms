import assert from "node:assert/strict";
import test from "node:test";
import {
  managerCanRate,
  parseRating,
  parseWeightToHundredths,
  unratedGoals,
  validatePlanWeights,
} from "./goals.ts";
import type { Goal, KraCategory } from "./types.ts";

function goal(
  id: string,
  categoryId: string,
  weight: number,
  selfRating: number | null = null,
  managerRating: number | null = null,
): Goal {
  return {
    id,
    kra_category_id: categoryId,
    title: `Goal ${id}`,
    description: null,
    weight,
    target_metric: null,
    rating_scale_max: 5,
    self_rating: selfRating,
    self_comment: null,
    manager_rating: managerRating,
    manager_comment: null,
  };
}

function category(
  id: string,
  name: string,
  weight: number,
  goals: Goal[],
): KraCategory {
  return {
    id,
    employee_goal_plan_id: "plan-1",
    name,
    description: null,
    weight,
    goals,
  };
}

test("parseWeightToHundredths performs exact two-decimal parsing", () => {
  assert.equal(parseWeightToHundredths("33.33"), 3333);
  assert.equal(parseWeightToHundredths("100"), 10000);
  assert.equal(parseWeightToHundredths(" 25.5 "), 2550);
  assert.equal(parseWeightToHundredths("100.01"), null);
  assert.equal(parseWeightToHundredths("33.333"), null);
});

test("validatePlanWeights requires both plan-level and per-category totals of exactly 100.00", () => {
  const deliveryGoals = [
    goal("delivery-1", "delivery", 33.33),
    goal("delivery-2", "delivery", 66.67),
  ];
  const growthGoals = [
    goal("growth-1", "growth", 50),
    goal("growth-2", "growth", 50),
  ];

  assert.deepEqual(
    validatePlanWeights([
      category("delivery", "Delivery", 60, deliveryGoals),
      category("growth", "Growth", 40, growthGoals),
    ]),
    [],
  );
  assert.deepEqual(
    validatePlanWeights([
      category("delivery", "Delivery", 60, deliveryGoals),
      category("growth", "Growth", 39.99, growthGoals),
    ]),
    [
      {
        scope: "plan",
        categoryId: null,
        message: "Category weights must total 100.00 (currently 99.99).",
      },
    ],
  );
  assert.deepEqual(
    validatePlanWeights([category("empty", "Empty category", 100, [])]),
    [
      {
        scope: "category",
        categoryId: "empty",
        message: '"Empty category" has no goals, so its goal weights total 0.00 instead of 100.00.',
      },
    ],
  );
});

test("parseRating preserves the distinction between blank and zero", () => {
  assert.deepEqual(parseRating("   ", 5), { ok: true, value: null });
  assert.deepEqual(parseRating("0", 5), { ok: true, value: 0 });
});

test("unratedGoals does not report a zero rating as missing", () => {
  const categories = [
    category("delivery", "Delivery", 100, [
      goal("rated-zero", "delivery", 50, 0, 0),
      goal("unrated", "delivery", 50, null, null),
    ]),
  ];

  assert.deepEqual(unratedGoals(categories, "self"), [
    { categoryName: "Delivery", goalTitle: "Goal unrated" },
  ]);
  assert.deepEqual(unratedGoals(categories, "manager"), [
    { categoryName: "Delivery", goalTitle: "Goal unrated" },
  ]);
});

test("managerCanRate permits only submitted plans during manager_eval", () => {
  assert.equal(managerCanRate("submitted", "manager_eval"), true);
  assert.equal(managerCanRate("draft", "manager_eval"), false);
  assert.equal(managerCanRate("manager_reviewed", "manager_eval"), false);
  assert.equal(managerCanRate("finalized", "manager_eval"), false);
  assert.equal(managerCanRate("submitted", "self_eval"), false);
  assert.equal(managerCanRate("submitted", null), false);
});
