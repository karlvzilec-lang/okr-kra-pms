"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { FloppyDisk } from "@phosphor-icons/react/dist/csr/FloppyDisk";
import { SealCheck } from "@phosphor-icons/react/dist/csr/SealCheck";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { CheckCircle } from "@phosphor-icons/react/dist/csr/CheckCircle";
import { createClient } from "@/lib/supabase/client";
import {
  BLOCKED_TRANSITION_MESSAGE,
  formatRating,
  goalErrorMessage,
  managerBlockedReason,
  managerCanRate,
  parseRating,
  PLAN_STATUS_LABEL,
  unratedGoals,
  validatePlanWeights,
} from "@/lib/goals";
import type { EmployeeGoalPlan, Goal, GoalPlanStatus, KraCategory } from "@/lib/types";

type Props = {
  plan: EmployeeGoalPlan;
  employeeName: string;
  cycleStatus: string | null;
};

/**
 * The line manager's rating surface. Writes only manager_rating and
 * manager_comment — every other column on `goal` is blocked for the manager by
 * restrict_manager_goal_updates, so nothing else is even rendered as an input.
 *
 * The whole form goes read-only unless the plan is `submitted` AND the cycle is
 * in `manager_eval`. That's the tightened can_manager_rate_goal rule: a draft
 * plan is closed even mid-window, and a manager_reviewed plan is closed to
 * further edits. Rendering read-only up front beats letting someone fill in a
 * form the database will reject.
 */
export function ManagerRatingForm({ plan, employeeName, cycleStatus }: Props) {
  const router = useRouter();
  const [categories, setCategories] = useState<KraCategory[]>(plan.categories);
  const [status, setStatus] = useState<GoalPlanStatus>(plan.status);
  const [errors, setErrors] = useState<string[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const canRate = managerCanRate(status, cycleStatus);
  const blockedReason = managerBlockedReason(status, cycleStatus);
  const weightProblems = useMemo(() => validatePlanWeights(categories), [categories]);
  const missingManager = useMemo(() => unratedGoals(categories, "manager"), [categories]);

  function patchGoal(categoryId: string, goalId: string, patch: Partial<Goal>) {
    setCategories((current) =>
      current.map((c) =>
        c.id === categoryId
          ? { ...c, goals: c.goals.map((g) => (g.id === goalId ? { ...g, ...patch } : g)) }
          : c,
      ),
    );
  }

  async function persistRatings(): Promise<string[]> {
    const supabase = createClient();
    const problems: string[] = [];

    for (const category of categories) {
      for (const goal of category.goals) {
        const { error } = await supabase
          .from("goal")
          .update({
            manager_rating: goal.manager_rating,
            manager_comment: goal.manager_comment,
          })
          .eq("id", goal.id)
          .select("id")
          .single();

        if (error) {
          problems.push(
            `"${goal.title}": ${goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE}`,
          );
        }
      }
    }

    return problems;
  }

  async function handleSave() {
    setErrors([]);
    setNotice(null);
    setPending(true);
    const problems = await persistRatings();
    setPending(false);

    if (problems.length > 0) {
      setErrors(problems);
      return;
    }
    setNotice("Ratings saved.");
    router.refresh();
  }

  /**
   * Same ordering rule as the employee submit, and it matters more here: once
   * status moves to manager_reviewed the plan is no longer manager-editable, so
   * flipping first and failing the rollup would strand it permanently with no
   * manager score. Persist, roll up, then transition — and confirm a row came
   * back, since an RLS-blocked transition returns zero rows without raising.
   */
  async function handleMarkReviewed() {
    setErrors([]);
    setNotice(null);

    if (weightProblems.length > 0) {
      setErrors(weightProblems.map((p) => p.message));
      return;
    }
    if (missingManager.length > 0) {
      setErrors(
        missingManager.map(
          (m) => `"${m.goalTitle}" in "${m.categoryName}" still needs a manager rating.`,
        ),
      );
      return;
    }

    setPending(true);

    const problems = await persistRatings();
    if (problems.length > 0) {
      setErrors(problems);
      setPending(false);
      return;
    }

    const supabase = createClient();

    const { error: rollupError } = await supabase.rpc("compute_goal_plan_rating", {
      p_plan_id: plan.id,
      p_rating_type: "manager",
    });
    if (rollupError) {
      setErrors([
        goalErrorMessage(rollupError) ??
          "Couldn't compute the overall manager rating. The plan was left as-is.",
      ]);
      setPending(false);
      return;
    }

    const { data, error } = await supabase
      .from("employee_goal_plan")
      .update({ status: "manager_reviewed" })
      .eq("id", plan.id)
      .select("id,status")
      .single();

    setPending(false);

    if (error || !data) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      return;
    }

    setStatus(data.status as GoalPlanStatus);
    setNotice("Marked as reviewed.");
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-6">
      <div
        className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border p-5"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <div>
          <p className="text-xs uppercase tracking-wide" style={{ color: "var(--muted-foreground)" }}>
            {employeeName}
          </p>
          <p className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
            {PLAN_STATUS_LABEL[status]}
          </p>
        </div>
        {canRate && (
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={handleSave}
              disabled={pending}
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <FloppyDisk size={16} weight="bold" aria-hidden="true" />
              {pending ? "Working..." : "Save ratings"}
            </button>
            <button
              type="button"
              onClick={handleMarkReviewed}
              disabled={pending}
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              <SealCheck size={16} weight="bold" aria-hidden="true" />
              Mark as reviewed
            </button>
          </div>
        )}
      </div>

      {blockedReason && (
        <p
          className="rounded-2xl border border-dashed p-4 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          {blockedReason}
        </p>
      )}

      {errors.length > 0 && (
        <div
          role="alert"
          className="flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)",
            color: "var(--destructive)",
          }}
        >
          <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
          <ul className="flex flex-col gap-1">
            {errors.map((message) => (
              <li key={message}>{message}</li>
            ))}
          </ul>
        </div>
      )}

      {notice && (
        <p
          role="status"
          className="inline-flex items-center gap-2 rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--accent) 12%, transparent)",
            color: "var(--foreground)",
          }}
        >
          <CheckCircle size={16} weight="bold" aria-hidden="true" />
          {notice}
        </p>
      )}

      {categories.map((category) => (
        <section
          key={category.id}
          className="rounded-2xl border p-5"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
        >
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
              {category.name}
            </h2>
            <span className="font-data text-xs" style={{ color: "var(--muted-foreground)" }}>
              {category.weight}% of plan
            </span>
          </div>

          <div className="mt-4 flex flex-col gap-4">
            {category.goals.map((goal) => (
              <div
                key={goal.id}
                className="rounded-xl border p-4"
                style={{ borderColor: "var(--border)" }}
              >
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <p className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                    {goal.title}
                  </p>
                  <span className="font-data text-xs" style={{ color: "var(--muted-foreground)" }}>
                    {goal.weight}% of category · scale 0-{goal.rating_scale_max}
                  </span>
                </div>

                {goal.description && (
                  <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
                    {goal.description}
                  </p>
                )}

                <p className="mt-2 text-xs" style={{ color: "var(--muted-foreground)" }}>
                  Self rating:{" "}
                  <span className="font-data">
                    {goal.self_rating === null ? "—" : goal.self_rating}
                  </span>
                  {goal.self_comment ? ` — ${goal.self_comment}` : ""}
                </p>

                <div className="mt-3 flex flex-wrap items-end gap-3">
                  <div className="flex w-28 flex-col gap-1.5">
                    <label
                      htmlFor={`manager-rating-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Manager rating
                    </label>
                    {/* Blank means "not rated yet", never 0. */}
                    <input
                      id={`manager-rating-${goal.id}`}
                      inputMode="decimal"
                      placeholder="—"
                      value={formatRating(goal.manager_rating)}
                      readOnly={!canRate}
                      onChange={(e) => {
                        const parsed = parseRating(e.target.value, goal.rating_scale_max);
                        if (parsed.ok) {
                          patchGoal(category.id, goal.id, { manager_rating: parsed.value });
                        }
                      }}
                      className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                      style={{
                        borderColor: "var(--border)",
                        backgroundColor: "var(--background)",
                        color: "var(--foreground)",
                      }}
                    />
                  </div>
                  <div className="flex min-w-[12rem] flex-1 flex-col gap-1.5">
                    <label
                      htmlFor={`manager-comment-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Manager comment
                    </label>
                    <input
                      id={`manager-comment-${goal.id}`}
                      value={goal.manager_comment ?? ""}
                      readOnly={!canRate}
                      onChange={(e) =>
                        patchGoal(category.id, goal.id, {
                          manager_comment: e.target.value.length === 0 ? null : e.target.value,
                        })
                      }
                      className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                      style={{
                        borderColor: "var(--border)",
                        backgroundColor: "var(--background)",
                        color: "var(--foreground)",
                      }}
                    />
                  </div>
                </div>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
