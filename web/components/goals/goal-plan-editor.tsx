"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { Trash } from "@phosphor-icons/react/dist/csr/Trash";
import { FloppyDisk } from "@phosphor-icons/react/dist/csr/FloppyDisk";
import { PaperPlaneTilt } from "@phosphor-icons/react/dist/csr/PaperPlaneTilt";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { CheckCircle } from "@phosphor-icons/react/dist/csr/CheckCircle";
import { createClient } from "@/lib/supabase/client";
import {
  BLOCKED_TRANSITION_MESSAGE,
  employeeCanEdit,
  formatRating,
  goalErrorMessage,
  hundredthsToNumber,
  parseRating,
  parseWeightToHundredths,
  PLAN_STATUS_LABEL,
  unratedGoals,
  validatePlanWeights,
} from "@/lib/goals";
import type { EmployeeGoalPlan, Goal, GoalPlanStatus, KraCategory } from "@/lib/types";

type Props = { plan: EmployeeGoalPlan };

/**
 * The employee's own goal plan: build categories and goals, weight them, and
 * self-rate. Deliberately never renders an input for manager_rating or
 * manager_comment — 0017 blocks those columns for the employee on both INSERT
 * (policy with check) and UPDATE (restrict_employee_goal_updates), so offering
 * the field would only produce a 42501 at save time.
 */
export function GoalPlanEditor({ plan }: Props) {
  const router = useRouter();
  const [categories, setCategories] = useState<KraCategory[]>(plan.categories);
  const [status, setStatus] = useState<GoalPlanStatus>(plan.status);
  const [errors, setErrors] = useState<string[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const editable = employeeCanEdit(status);
  const weightProblems = useMemo(() => validatePlanWeights(categories), [categories]);
  const missingSelf = useMemo(() => unratedGoals(categories, "self"), [categories]);

  function patchCategory(categoryId: string, patch: Partial<KraCategory>) {
    setCategories((current) =>
      current.map((c) => (c.id === categoryId ? { ...c, ...patch } : c)),
    );
  }

  function patchGoal(categoryId: string, goalId: string, patch: Partial<Goal>) {
    setCategories((current) =>
      current.map((c) =>
        c.id === categoryId
          ? { ...c, goals: c.goals.map((g) => (g.id === goalId ? { ...g, ...patch } : g)) }
          : c,
      ),
    );
  }

  async function addCategory() {
    setErrors([]);
    setPending(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("kra_category")
      .insert({
        employee_goal_plan_id: plan.id,
        name: "New KRA category",
        weight: 0,
      })
      .select("id, employee_goal_plan_id, name, description, weight")
      .single();

    if (error || !data) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      setPending(false);
      return;
    }

    setCategories((current) => [...current, { ...(data as Omit<KraCategory, "goals">), goals: [] }]);
    setPending(false);
  }

  async function removeCategory(categoryId: string) {
    setErrors([]);
    setPending(true);
    const supabase = createClient();
    const { error } = await supabase.from("kra_category").delete().eq("id", categoryId);

    if (error) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      setPending(false);
      return;
    }

    setCategories((current) => current.filter((c) => c.id !== categoryId));
    setPending(false);
  }

  async function addGoal(categoryId: string) {
    setErrors([]);
    setPending(true);
    const supabase = createClient();
    // manager_rating / manager_comment are intentionally absent from this
    // payload: goal_employee_insert's with check now requires both to be null.
    const { data, error } = await supabase
      .from("goal")
      .insert({
        kra_category_id: categoryId,
        title: "New goal",
        weight: 0,
        rating_scale_max: 5,
      })
      .select(
        "id, kra_category_id, title, description, weight, target_metric, rating_scale_max, self_rating, self_comment, manager_rating, manager_comment",
      )
      .single();

    if (error || !data) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      setPending(false);
      return;
    }

    setCategories((current) =>
      current.map((c) =>
        c.id === categoryId ? { ...c, goals: [...c.goals, data as Goal] } : c,
      ),
    );
    setPending(false);
  }

  async function removeGoal(categoryId: string, goalId: string) {
    setErrors([]);
    setPending(true);
    const supabase = createClient();
    const { error } = await supabase.from("goal").delete().eq("id", goalId);

    if (error) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      setPending(false);
      return;
    }

    setCategories((current) =>
      current.map((c) =>
        c.id === categoryId ? { ...c, goals: c.goals.filter((g) => g.id !== goalId) } : c,
      ),
    );
    setPending(false);
  }

  /** Persist every category and goal the employee is allowed to write. */
  async function persistAll(): Promise<string[]> {
    const supabase = createClient();
    const problems: string[] = [];

    for (const category of categories) {
      const { error } = await supabase
        .from("kra_category")
        .update({
          name: category.name,
          description: category.description,
          weight: category.weight,
        })
        .eq("id", category.id)
        .select("id")
        .single();

      if (error) {
        problems.push(
          `"${category.name}": ${goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE}`,
        );
        continue;
      }

      for (const goal of category.goals) {
        // Only employee-writable columns. rating_scale_max is included because
        // it's part of goal structure, but 0017 locks it once a manager rating
        // exists — the UI mirrors that below by rendering it read-only.
        const payload: Record<string, unknown> = {
          title: goal.title,
          description: goal.description,
          weight: goal.weight,
          target_metric: goal.target_metric,
          self_rating: goal.self_rating,
          self_comment: goal.self_comment,
        };
        if (goal.manager_rating === null) {
          payload.rating_scale_max = goal.rating_scale_max;
        }

        const { error: goalError } = await supabase
          .from("goal")
          .update(payload)
          .eq("id", goal.id)
          .select("id")
          .single();

        if (goalError) {
          problems.push(
            `"${goal.title}": ${goalErrorMessage(goalError) ?? BLOCKED_TRANSITION_MESSAGE}`,
          );
        }
      }
    }

    return problems;
  }

  function localValidation(): string[] {
    const problems: string[] = [];
    for (const category of categories) {
      if (category.name.trim().length === 0) {
        problems.push("Every KRA category needs a name.");
      }
      if (parseWeightToHundredths(String(category.weight)) === null) {
        problems.push(`"${category.name}" has a weight that isn't a valid 0-100 percentage.`);
      }
      for (const goal of category.goals) {
        if (goal.title.trim().length === 0) {
          problems.push(`A goal in "${category.name}" needs a title.`);
        }
        if (parseWeightToHundredths(String(goal.weight)) === null) {
          problems.push(`"${goal.title}" has a weight that isn't a valid 0-100 percentage.`);
        }
        if (
          goal.self_rating !== null &&
          (goal.self_rating < 0 || goal.self_rating > goal.rating_scale_max)
        ) {
          problems.push(`"${goal.title}" self-rating must be between 0 and ${goal.rating_scale_max}.`);
        }
      }
    }
    return problems;
  }

  async function handleSave() {
    setErrors([]);
    setNotice(null);

    const local = localValidation();
    if (local.length > 0) {
      setErrors(local);
      return;
    }

    setPending(true);
    const problems = await persistAll();
    setPending(false);

    if (problems.length > 0) {
      setErrors(problems);
      return;
    }
    setNotice("Saved.");
    router.refresh();
  }

  /**
   * Submit ordering is load-bearing: write the ratings, compute the rollup,
   * and only then flip status. Flipping first would strand the plan in
   * `submitted` with no self score if the rollup call failed.
   */
  async function handleSubmit() {
    setErrors([]);
    setNotice(null);

    const local = localValidation();
    if (local.length > 0) {
      setErrors(local);
      return;
    }
    if (weightProblems.length > 0) {
      setErrors(weightProblems.map((p) => p.message));
      return;
    }
    if (missingSelf.length > 0) {
      setErrors(
        missingSelf.map(
          (m) => `"${m.goalTitle}" in "${m.categoryName}" still needs a self-rating.`,
        ),
      );
      return;
    }

    setPending(true);

    // 1. Persist.
    const problems = await persistAll();
    if (problems.length > 0) {
      setErrors(problems);
      setPending(false);
      return;
    }

    const supabase = createClient();

    // 2. Roll up (idempotent upsert), before the status moves.
    const { error: rollupError } = await supabase.rpc("compute_goal_plan_rating", {
      p_plan_id: plan.id,
      p_rating_type: "self",
    });
    if (rollupError) {
      setErrors([
        goalErrorMessage(rollupError) ??
          "Couldn't compute your overall self rating. Nothing was submitted.",
      ]);
      setPending(false);
      return;
    }

    // 3. Flip status last, and confirm a row actually came back — an
    // RLS-blocked UPDATE returns zero rows silently rather than raising.
    const { data, error } = await supabase
      .from("employee_goal_plan")
      .update({ status: "submitted" })
      .eq("id", plan.id)
      .select("id,status")
      .single();

    setPending(false);

    if (error || !data) {
      setErrors([goalErrorMessage(error) ?? BLOCKED_TRANSITION_MESSAGE]);
      return;
    }

    setStatus(data.status as GoalPlanStatus);
    setNotice("Submitted for manager review.");
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
            Plan status
          </p>
          <p className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
            {PLAN_STATUS_LABEL[status]}
          </p>
        </div>
        {editable && (
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={handleSave}
              disabled={pending}
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <FloppyDisk size={16} weight="bold" aria-hidden="true" />
              {pending ? "Working..." : "Save"}
            </button>
            {status === "draft" && (
              <button
                type="button"
                onClick={handleSubmit}
                disabled={pending}
                className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
                style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
              >
                <PaperPlaneTilt size={16} weight="bold" aria-hidden="true" />
                Submit for manager review
              </button>
            )}
          </div>
        )}
      </div>

      {!editable && (
        <p
          className="rounded-2xl border border-dashed p-4 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          This plan is {PLAN_STATUS_LABEL[status].toLowerCase()}, so it&apos;s read-only. Talk to your
          manager or HR if something needs to change.
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

      {editable && weightProblems.length > 0 && (
        <div
          className="rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--destructive) 8%, transparent)",
            color: "var(--destructive)",
          }}
        >
          <ul className="flex flex-col gap-1">
            {weightProblems.map((problem) => (
              <li key={`${problem.scope}-${problem.categoryId ?? "plan"}-${problem.message}`}>
                {problem.message}
              </li>
            ))}
          </ul>
        </div>
      )}

      {categories.map((category) => (
        <section
          key={category.id}
          className="rounded-2xl border p-5"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
        >
          <div className="flex flex-wrap items-end gap-3">
            <div className="flex min-w-[12rem] flex-1 flex-col gap-1.5">
              <label
                htmlFor={`category-name-${category.id}`}
                className="text-xs"
                style={{ color: "var(--muted-foreground)" }}
              >
                KRA category
              </label>
              <input
                id={`category-name-${category.id}`}
                value={category.name}
                readOnly={!editable}
                onChange={(e) => patchCategory(category.id, { name: e.target.value })}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              />
            </div>
            <div className="flex w-28 flex-col gap-1.5">
              <label
                htmlFor={`category-weight-${category.id}`}
                className="text-xs"
                style={{ color: "var(--muted-foreground)" }}
              >
                Weight %
              </label>
              <input
                id={`category-weight-${category.id}`}
                inputMode="decimal"
                value={String(category.weight)}
                readOnly={!editable}
                onChange={(e) => {
                  const hundredths = parseWeightToHundredths(e.target.value);
                  patchCategory(category.id, {
                    weight: hundredths === null ? 0 : hundredthsToNumber(hundredths),
                  });
                }}
                className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              />
            </div>
            {editable && (
              <button
                type="button"
                onClick={() => removeCategory(category.id)}
                disabled={pending}
                aria-label={`Remove category ${category.name}`}
                className="inline-flex h-11 w-11 items-center justify-center rounded-lg border transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
                style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
              >
                <Trash size={16} weight="bold" aria-hidden="true" />
              </button>
            )}
          </div>

          <div className="mt-4 flex flex-col gap-4">
            {category.goals.map((goal) => (
              <div
                key={goal.id}
                className="rounded-xl border p-4"
                style={{ borderColor: "var(--border)" }}
              >
                <div className="flex flex-wrap items-end gap-3">
                  <div className="flex min-w-[12rem] flex-1 flex-col gap-1.5">
                    <label
                      htmlFor={`goal-title-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Goal
                    </label>
                    <input
                      id={`goal-title-${goal.id}`}
                      value={goal.title}
                      readOnly={!editable}
                      onChange={(e) => patchGoal(category.id, goal.id, { title: e.target.value })}
                      className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                      style={{
                        borderColor: "var(--border)",
                        backgroundColor: "var(--background)",
                        color: "var(--foreground)",
                      }}
                    />
                  </div>
                  <div className="flex w-24 flex-col gap-1.5">
                    <label
                      htmlFor={`goal-weight-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Weight %
                    </label>
                    <input
                      id={`goal-weight-${goal.id}`}
                      inputMode="decimal"
                      value={String(goal.weight)}
                      readOnly={!editable}
                      onChange={(e) => {
                        const hundredths = parseWeightToHundredths(e.target.value);
                        patchGoal(category.id, goal.id, {
                          weight: hundredths === null ? 0 : hundredthsToNumber(hundredths),
                        });
                      }}
                      className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                      style={{
                        borderColor: "var(--border)",
                        backgroundColor: "var(--background)",
                        color: "var(--foreground)",
                      }}
                    />
                  </div>
                  <div className="flex w-24 flex-col gap-1.5">
                    <label
                      htmlFor={`goal-scale-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Scale max
                    </label>
                    {/* Locked once a manager rating exists: changing the scale
                        after the fact would silently rescale what that rating
                        means. 0017 raises 42501 on the attempt. */}
                    <input
                      id={`goal-scale-${goal.id}`}
                      inputMode="numeric"
                      value={String(goal.rating_scale_max)}
                      readOnly={!editable || goal.manager_rating !== null}
                      onChange={(e) => {
                        const parsed = Number(e.target.value);
                        if (Number.isInteger(parsed) && parsed > 0) {
                          patchGoal(category.id, goal.id, { rating_scale_max: parsed });
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
                  {editable && (
                    <button
                      type="button"
                      onClick={() => removeGoal(category.id, goal.id)}
                      disabled={pending}
                      aria-label={`Remove goal ${goal.title}`}
                      className="inline-flex h-11 w-11 items-center justify-center rounded-lg border transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
                      style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
                    >
                      <Trash size={16} weight="bold" aria-hidden="true" />
                    </button>
                  )}
                </div>

                <div className="mt-3 flex flex-wrap items-end gap-3">
                  <div className="flex w-28 flex-col gap-1.5">
                    <label
                      htmlFor={`goal-self-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Self rating
                    </label>
                    {/* Blank means "not rated", never 0. */}
                    <input
                      id={`goal-self-${goal.id}`}
                      inputMode="decimal"
                      placeholder="—"
                      value={formatRating(goal.self_rating)}
                      readOnly={!editable}
                      onChange={(e) => {
                        const parsed = parseRating(e.target.value, goal.rating_scale_max);
                        if (parsed.ok) {
                          patchGoal(category.id, goal.id, { self_rating: parsed.value });
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
                      htmlFor={`goal-self-comment-${goal.id}`}
                      className="text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      Self comment
                    </label>
                    <input
                      id={`goal-self-comment-${goal.id}`}
                      value={goal.self_comment ?? ""}
                      readOnly={!editable}
                      onChange={(e) =>
                        patchGoal(category.id, goal.id, {
                          self_comment: e.target.value.length === 0 ? null : e.target.value,
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

                {goal.manager_rating !== null && (
                  <p className="mt-3 text-xs" style={{ color: "var(--muted-foreground)" }}>
                    Manager rating: <span className="font-data">{goal.manager_rating}</span> /{" "}
                    {goal.rating_scale_max}
                    {goal.manager_comment ? ` — ${goal.manager_comment}` : ""}
                  </p>
                )}
              </div>
            ))}

            {editable && (
              <button
                type="button"
                onClick={() => addGoal(category.id)}
                disabled={pending}
                className="inline-flex min-h-11 w-fit items-center gap-1.5 rounded-lg border px-3 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
                style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
              >
                <Plus size={14} weight="bold" aria-hidden="true" />
                Add goal
              </button>
            )}
          </div>
        </section>
      ))}

      {editable && (
        <button
          type="button"
          onClick={addCategory}
          disabled={pending}
          className="inline-flex min-h-11 w-fit items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          <Plus size={16} weight="bold" aria-hidden="true" />
          Add KRA category
        </button>
      )}
    </div>
  );
}
