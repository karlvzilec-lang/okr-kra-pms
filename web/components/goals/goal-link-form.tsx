"use client";

import { useMemo, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ArrowsDownUp } from "@phosphor-icons/react/dist/csr/ArrowsDownUp";
import { ArrowBendUpRight } from "@phosphor-icons/react/dist/csr/ArrowBendUpRight";
import { LockSimple } from "@phosphor-icons/react/dist/csr/LockSimple";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { CheckCircle } from "@phosphor-icons/react/dist/csr/CheckCircle";
import { createClient } from "@/lib/supabase/client";
import {
  ADMIN_BLOCKED_MESSAGE,
  adminErrorMessage,
  ALIGNMENT_EXPLAINER,
  CASCADE_EXPLAINER,
  LINK_IS_PERMANENT_MESSAGE,
  validateCascadeDraft,
} from "@/lib/admin";
import {
  employeeCanEdit,
  formatHundredths,
  hundredthsToNumber,
  parseWeightToHundredths,
} from "@/lib/goals";
import type { LinkableGoal } from "@/lib/admin-queries";
import type { EmployeeGoalPlan } from "@/lib/types";

type Props = {
  plan: EmployeeGoalPlan;
  /** Goals the signed-in employee may read but doesn't own — the link sources. */
  sources: LinkableGoal[];
  /** goal id -> source goal id, for goals already cascaded into this plan. */
  cascadeSourceByGoalId: Map<string, string>;
  /** goal id -> parent goal id, for goals already aligned upward. */
  alignmentParentByGoalId: Map<string, string>;
  /** Titles for every id referenced above, so a link can name what it points at. */
  linkedTitleById: Map<string, string>;
};

/**
 * Cascade a readable goal into this plan, or align one of this plan's goals
 * upward to a readable goal.
 *
 * The actor here is the EMPLOYEE, not the manager, and that isn't a UI
 * preference — it's what RLS permits. goal_employee_insert is employee-only,
 * and can_write_goal grants a manager write access to a report's goal only
 * during the rating window, so a manager cannot put a goal into a report's
 * plan at goal-setting time at all. What an employee can do is read their own
 * manager's goals (can_read_goal's manager branch) and write their own — which
 * is exactly the pair of authorities both link types need.
 *
 * The two controls stay separate because they are different events:
 *
 *   Cascade  CREATES a new goal in this plan, copied from the source, and
 *            records the copy. It goes through one RPC so the goal and the
 *            link land together — a half-created goal with no link would be
 *            indistinguishable from an ordinary goal, with no way to tell it
 *            was meant to be a cascade.
 *
 *   Align    LINKS two goals that already exist. Nothing is created, so a
 *            plain insert is enough and there's no atomicity to protect.
 *
 * Both links are one-shot: the target column is UNIQUE in both tables, and
 * UPDATE/DELETE are HR-only. An already-linked goal therefore renders as
 * read-only state, and the copy says plainly that HR is the only route to
 * change it, rather than letting someone find that out through a failed save.
 *
 * Creating either link also requires the plan to still be employee-editable.
 * can_edit_goal_plan_as_employee is false once a plan reaches manager_reviewed
 * or finalized, so on those plans BOTH inserts are refused with 42501 --
 * verified against the real policies, not assumed. Existing links stay visible
 * (they are history, and history does not stop being true when a plan closes),
 * but the controls that could only fail are not rendered.
 */
export function GoalLinkForm({
  plan,
  sources,
  cascadeSourceByGoalId,
  alignmentParentByGoalId,
  linkedTitleById,
}: Props) {
  const router = useRouter();

  const goals = useMemo(
    () => plan.categories.flatMap((category) => category.goals.map((goal) => ({ category, goal }))),
    [plan.categories],
  );

  // Only goals with no link at all are offered as alignment children. A
  // cascaded goal already records where it came from; aligning it upward as
  // well would assert two different origins for one goal.
  const alignableGoals = useMemo(
    () =>
      goals.filter(
        ({ goal }) =>
          !cascadeSourceByGoalId.has(goal.id) && !alignmentParentByGoalId.has(goal.id),
      ),
    [goals, cascadeSourceByGoalId, alignmentParentByGoalId],
  );

  const linkedGoals = useMemo(
    () =>
      goals.filter(
        ({ goal }) =>
          cascadeSourceByGoalId.has(goal.id) || alignmentParentByGoalId.has(goal.id),
      ),
    [goals, cascadeSourceByGoalId, alignmentParentByGoalId],
  );

  // A reviewed or finalized plan is frozen for the employee at the database
  // level, so no new link can be created on it.
  const canLink = employeeCanEdit(plan.status);

  const [mode, setMode] = useState<"cascade" | "align" | null>(null);
  const [sourceGoalId, setSourceGoalId] = useState("");
  const [targetCategoryId, setTargetCategoryId] = useState("");
  const [weight, setWeight] = useState("");
  const [childGoalId, setChildGoalId] = useState("");
  const [errors, setErrors] = useState<string[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const selectedSource = sources.find((s) => s.id === sourceGoalId) ?? null;

  function chooseSource(id: string) {
    setSourceGoalId(id);
    // Prefill the weight from the source, matching the rest of the copy, but
    // leave it editable: weight balances against the OTHER goals in this
    // plan's category, which the source knows nothing about.
    const source = sources.find((s) => s.id === id);
    setWeight(source ? formatHundredths(parseWeightToHundredths(String(source.weight)) ?? 0) : "");
  }

  function reset() {
    setMode(null);
    setSourceGoalId("");
    setTargetCategoryId("");
    setWeight("");
    setChildGoalId("");
    setErrors([]);
  }

  async function handleCascade(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);
    setNotice(null);

    const problems = validateCascadeDraft({ sourceGoalId, targetCategoryId, weight });
    const weightHundredths = parseWeightToHundredths(weight);
    if (weightHundredths === null) {
      problems.push("Weight is a number from 0 to 100 with at most two decimal places.");
    }
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();

    // One call, one transaction: the new goal and the goal_cascade row land
    // together or not at all. The RPC is SECURITY INVOKER, so it runs under
    // this employee's own RLS and grants nothing the two separate inserts
    // wouldn't have — what it adds is atomicity, not authority.
    //
    // It returns a set of {goal_id, goal_cascade_id} rather than a bare id, so
    // an empty result set is a real failure mode and is treated as one.
    const { data, error } = await supabase.rpc("create_cascaded_goal", {
      p_source_goal_id: sourceGoalId,
      p_target_kra_category_id: targetCategoryId,
      p_weight: hundredthsToNumber(weightHundredths!),
    });

    if (error) {
      setErrors([adminErrorMessage(error) ?? "Couldn't cascade that goal."]);
      setPending(false);
      return;
    }

    const created = (data as { goal_id: string; goal_cascade_id: string }[] | null)?.[0];
    if (!created) {
      setErrors([ADMIN_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setPending(false);
    setNotice("Goal cascaded into your plan. Reweight it if the category no longer totals 100.");
    reset();
    router.refresh();
  }

  async function handleAlign(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);
    setNotice(null);

    const problems: string[] = [];
    if (!childGoalId) problems.push("Pick which of your goals is being aligned.");
    if (!sourceGoalId) problems.push("Pick the higher-level goal it ladders up to.");
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setErrors(["Your session has expired. Sign in again to record links."]);
      setPending(false);
      return;
    }

    const { data, error } = await supabase
      .from("goal_alignment")
      .insert({
        parent_goal_id: sourceGoalId,
        child_goal_id: childGoalId,
        // Read from the session, never from a hidden input — a payload naming
        // someone else is refused anyway, and offering the field would imply
        // it was a choice.
        created_by: user.id,
      })
      .select("id")
      .maybeSingle();

    if (error) {
      setErrors([adminErrorMessage(error) ?? "Couldn't record that alignment."]);
      setPending(false);
      return;
    }
    if (!data) {
      setErrors([ADMIN_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setPending(false);
    setNotice("Alignment recorded.");
    reset();
    router.refresh();
  }

  return (
    <section className="mt-10">
      <h2
        className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
        style={{ color: "var(--muted-foreground)" }}
      >
        Cascade &amp; alignment
      </h2>

      {linkedGoals.length > 0 && (
        <ul className="mb-4 flex flex-col gap-2">
          {linkedGoals.map(({ goal, category }) => {
            const cascadeSource = cascadeSourceByGoalId.get(goal.id);
            const alignmentParent = alignmentParentByGoalId.get(goal.id);
            const linkedId = cascadeSource ?? alignmentParent ?? "";
            return (
              <li
                key={goal.id}
                className="rounded-2xl border p-4"
                style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
              >
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                    {goal.title}
                  </span>
                  <span
                    className="inline-flex items-center gap-1 text-xs"
                    style={{ color: "var(--muted-foreground)" }}
                  >
                    <LockSimple size={12} weight="bold" aria-hidden="true" />
                    {cascadeSource ? "Cascaded from" : "Aligned to"}
                  </span>
                </div>
                <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
                  {category.name} → {linkedTitleById.get(linkedId) ?? "a goal you can no longer see"}
                </p>
              </li>
            );
          })}
          <li className="text-xs" style={{ color: "var(--muted-foreground)" }}>
            {LINK_IS_PERMANENT_MESSAGE}
          </li>
        </ul>
      )}

      {!canLink ? (
        <p
          className="rounded-2xl border border-dashed p-6 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          {linkedGoals.length > 0
            ? "This plan is no longer editable, so no further links can be added."
            : "This plan is no longer editable, so cascading and alignment are closed. Links can only be recorded while the plan is still a draft or awaiting review."}
        </p>
      ) : sources.length === 0 ? (
        <p
          className="rounded-2xl border border-dashed p-6 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          There are no higher-level goals visible to you yet. Once your line manager has goals of
          their own, you can cascade one into your plan or align a goal upward to it.
        </p>
      ) : mode === null ? (
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => setMode("cascade")}
            className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] cursor-pointer"
            style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
          >
            <ArrowsDownUp size={16} weight="bold" aria-hidden="true" />
            Cascade a goal to me
          </button>
          <button
            type="button"
            onClick={() => setMode("align")}
            disabled={alignableGoals.length === 0}
            className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            <ArrowBendUpRight size={16} weight="bold" aria-hidden="true" />
            Align an existing goal
          </button>
        </div>
      ) : mode === "cascade" ? (
        <form
          onSubmit={handleCascade}
          className="rounded-2xl border p-5 sm:p-6"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          noValidate
        >
          <h3
            className="font-heading text-base font-semibold"
            style={{ color: "var(--foreground)" }}
          >
            Cascade a goal into my plan
          </h3>
          <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
            {CASCADE_EXPLAINER}
          </p>

          <div className="mt-4 flex flex-col gap-4">
            <div className="flex flex-col gap-1.5">
              <label
                htmlFor="cascade-source"
                className="text-sm font-medium"
                style={{ color: "var(--foreground)" }}
              >
                Goal to copy
              </label>
              <select
                id="cascade-source"
                value={sourceGoalId}
                onChange={(e) => chooseSource(e.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              >
                <option value="">Pick a goal</option>
                {sources.map((source) => (
                  <option key={source.id} value={source.id}>
                    {source.title}
                    {source.owner_name ? ` — ${source.owner_name}` : ""}
                  </option>
                ))}
              </select>
            </div>

            {selectedSource && (
              <div
                className="rounded-lg border px-3 py-2 text-sm"
                style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
              >
                <p style={{ color: "var(--foreground)" }}>{selectedSource.title}</p>
                {selectedSource.description && (
                  <p className="mt-1">{selectedSource.description}</p>
                )}
                <p className="font-data mt-1 text-xs">
                  Target: {selectedSource.target_metric ?? "—"} · Scale 0–
                  {selectedSource.rating_scale_max}
                </p>
              </div>
            )}

            <div className="flex flex-col gap-1.5">
              <label
                htmlFor="cascade-category"
                className="text-sm font-medium"
                style={{ color: "var(--foreground)" }}
              >
                Land it in
              </label>
              <select
                id="cascade-category"
                value={targetCategoryId}
                onChange={(e) => setTargetCategoryId(e.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              >
                <option value="">Pick one of your KRA categories</option>
                {plan.categories.map((category) => (
                  <option key={category.id} value={category.id}>
                    {category.name}
                  </option>
                ))}
              </select>
              {plan.categories.length === 0 && (
                <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
                  Add a KRA category to your plan first — cascading places a goal inside an existing
                  category, it doesn&apos;t create one.
                </p>
              )}
            </div>

            <div className="flex flex-col gap-1.5">
              <label
                htmlFor="cascade-weight"
                className="text-sm font-medium"
                style={{ color: "var(--foreground)" }}
              >
                Weight
              </label>
              <input
                id="cascade-weight"
                value={weight}
                onChange={(e) => setWeight(e.target.value)}
                inputMode="decimal"
                className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              />
              <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
                Prefilled from the source, but it&apos;s yours to set — goal weights have to total
                100.00 inside the category you drop it into.
              </p>
            </div>
          </div>

          <LinkFormFooter
            pending={pending}
            errors={errors}
            submitLabel={pending ? "Cascading..." : "Cascade into my plan"}
            onCancel={reset}
          />
        </form>
      ) : (
        <form
          onSubmit={handleAlign}
          className="rounded-2xl border p-5 sm:p-6"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          noValidate
        >
          <h3
            className="font-heading text-base font-semibold"
            style={{ color: "var(--foreground)" }}
          >
            Align an existing goal
          </h3>
          <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
            {ALIGNMENT_EXPLAINER}
          </p>

          <div className="mt-4 flex flex-col gap-4">
            <div className="flex flex-col gap-1.5">
              <label
                htmlFor="align-child"
                className="text-sm font-medium"
                style={{ color: "var(--foreground)" }}
              >
                My goal
              </label>
              <select
                id="align-child"
                value={childGoalId}
                onChange={(e) => setChildGoalId(e.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              >
                <option value="">Pick one of your goals</option>
                {alignableGoals.map(({ goal, category }) => (
                  <option key={goal.id} value={goal.id}>
                    {category.name} — {goal.title}
                  </option>
                ))}
              </select>
            </div>

            <div className="flex flex-col gap-1.5">
              <label
                htmlFor="align-parent"
                className="text-sm font-medium"
                style={{ color: "var(--foreground)" }}
              >
                Ladders up to
              </label>
              <select
                id="align-parent"
                value={sourceGoalId}
                onChange={(e) => setSourceGoalId(e.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{
                  borderColor: "var(--border)",
                  backgroundColor: "var(--background)",
                  color: "var(--foreground)",
                }}
              >
                <option value="">Pick a higher-level goal</option>
                {sources.map((source) => (
                  <option key={source.id} value={source.id}>
                    {source.title}
                    {source.owner_name ? ` — ${source.owner_name}` : ""}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <LinkFormFooter
            pending={pending}
            errors={errors}
            submitLabel={pending ? "Recording..." : "Record alignment"}
            onCancel={reset}
          />
        </form>
      )}

      {notice && (
        <p
          role="status"
          className="mt-4 flex items-center gap-2 rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--accent) 12%, transparent)",
            color: "var(--foreground)",
          }}
        >
          <CheckCircle size={16} weight="bold" aria-hidden="true" />
          {notice}
        </p>
      )}
    </section>
  );
}

function LinkFormFooter({
  pending,
  errors,
  submitLabel,
  onCancel,
}: {
  pending: boolean;
  errors: string[];
  submitLabel: string;
  onCancel: () => void;
}) {
  return (
    <>
      {errors.length > 0 && (
        <div
          role="alert"
          className="mt-5 flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
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

      <p className="mt-4 text-xs" style={{ color: "var(--muted-foreground)" }}>
        {LINK_IS_PERMANENT_MESSAGE}
      </p>

      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={pending}
          className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          {submitLabel}
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={pending}
          className="min-h-11 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          Cancel
        </button>
      </div>
    </>
  );
}
