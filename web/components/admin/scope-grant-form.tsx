"use client";

import { useMemo, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ShieldCheck } from "@phosphor-icons/react/dist/csr/ShieldCheck";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { CheckCircle } from "@phosphor-icons/react/dist/csr/CheckCircle";
import { grantMatrixScopesAction } from "@/app/admin/actions";
import { validateScopeGrant } from "@/lib/admin";
import type { AdminPlanSummary, ProfileWithManager, ScopeTarget } from "@/lib/admin-queries";

type Props = {
  plans: AdminPlanSummary[];
  people: ProfileWithManager[];
  /** Scope targets per plan, resolved server-side so the picker never guesses. */
  targetsByPlanId: Record<string, { categories: ScopeTarget[]; objectives: ScopeTarget[] }>;
};

/**
 * Grant a matrix manager scoped access to parts of one person's plan.
 *
 * The sequencing here mirrors what the database actually requires, and the
 * order is not negotiable:
 *
 *   1. review_participant must hold a 'matrix_manager' row for that (plan,
 *      person) pair. enforce_scope_participant_is_matrix rejects a scope hung
 *      off any other role with 23514, so the participant row has to exist
 *      first. That step happens automatically as part of granting a scope,
 *      because "add participant, then grant scope" is one intent split across
 *      two records, not two decisions.
 *
 *   2. Only then can review_participant_scope rows be inserted.
 *
 * Both steps run inside grantMatrixScopesAction on the server, which
 * re-verifies auth, password expiry and HR status per call and revalidates the
 * admin pages afterwards. This component only collects the selection.
 *
 * The scope targets offered are always drawn from the selected plan, so a
 * category or objective belonging to someone else can't be picked. The
 * validate_scope_target_exists trigger only checks that the target exists at
 * all — it cannot tell whether it belongs to the right person — which is
 * exactly why the picker, and the server-side loader behind it, do that part.
 */
export function ScopeGrantForm({ plans, people, targetsByPlanId }: Props) {
  const router = useRouter();
  const [planId, setPlanId] = useState("");
  const [participantId, setParticipantId] = useState("");
  const [categoryIds, setCategoryIds] = useState<string[]>([]);
  const [objectiveIds, setObjectiveIds] = useState<string[]>([]);
  const [errors, setErrors] = useState<string[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const plan = useMemo(() => plans.find((p) => p.id === planId) ?? null, [plans, planId]);
  const targets = planId ? targetsByPlanId[planId] : undefined;

  // The plan's own employee is excluded: a matrix-manager grant over your own
  // plan is meaningless, and the row would sit alongside your 'employee'
  // participant row saying two different things about the same relationship.
  const candidates = useMemo(
    () => (plan ? people.filter((person) => person.id !== plan.employee_id) : []),
    [people, plan],
  );

  function resetSelection() {
    setCategoryIds([]);
    setObjectiveIds([]);
  }

  function toggle(list: string[], id: string): string[] {
    return list.includes(id) ? list.filter((entry) => entry !== id) : [...list, id];
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);
    setNotice(null);

    const problems = validateScopeGrant({ planId, participantId, categoryIds, objectiveIds });
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);

    const scopes = [
      ...categoryIds.map((id) => ({ scopeType: "kra_category" as const, scopeId: id })),
      ...objectiveIds.map((id) => ({ scopeType: "objective" as const, scopeId: id })),
    ];

    const result = await grantMatrixScopesAction({
      employeeGoalPlanId: planId,
      participantId,
      scopes,
    });

    if (!result.ok) {
      setErrors([result.message]);
      setPending(false);
      return;
    }

    setPending(false);
    setNotice(result.message);
    resetSelection();
    router.refresh();
  }

  if (plans.length === 0) {
    return (
      <p
        className="rounded-2xl border border-dashed p-6 text-sm"
        style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
      >
        There are no goal plans yet, so there&apos;s nothing to scope matrix access to.
      </p>
    );
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="rounded-2xl border p-5 sm:p-6"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      noValidate
    >
      <div className="flex items-center gap-2">
        <ShieldCheck size={16} weight="bold" style={{ color: "var(--accent)" }} aria-hidden="true" />
        <h2 className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
          Grant matrix access
        </h2>
      </div>
      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
        Matrix access is always scoped. Granting a scope also adds the person as a matrix manager on
        that plan if they aren&apos;t one already — that part happens automatically, there&apos;s no
        separate step for it.
      </p>

      <div className="mt-5 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="scope-plan"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            1. Whose plan
          </label>
          <select
            id="scope-plan"
            value={planId}
            onChange={(e) => {
              setPlanId(e.target.value);
              setParticipantId("");
              resetSelection();
              setNotice(null);
            }}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          >
            <option value="">Pick a plan</option>
            {plans.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {entry.employee_name} — {entry.review_cycle_name ?? "Unknown cycle"}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="scope-participant"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            2. Who gets access
          </label>
          <select
            id="scope-participant"
            value={participantId}
            onChange={(e) => setParticipantId(e.target.value)}
            disabled={!planId}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] disabled:opacity-60 sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          >
            <option value="">{planId ? "Pick a matrix manager" : "Pick a plan first"}</option>
            {candidates.map((person) => (
              <option key={person.id} value={person.id}>
                {person.full_name}
              </option>
            ))}
          </select>
        </div>

        <fieldset className="flex flex-col gap-2">
          <legend className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            3. What they can act on
          </legend>

          {!planId && (
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              Pick a plan to see its KRA categories and objectives.
            </p>
          )}

          {planId && targets && targets.categories.length === 0 && targets.objectives.length === 0 && (
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              This plan has no KRA categories and its owner has no objectives in this cycle yet, so
              there&apos;s nothing to grant.
            </p>
          )}

          {planId && targets && targets.categories.length > 0 && (
            <div className="flex flex-col gap-1.5">
              <p className="text-xs font-medium" style={{ color: "var(--muted-foreground)" }}>
                KRA categories
              </p>
              {targets.categories.map((target) => (
                <label
                  key={target.id}
                  className="flex min-h-11 items-center gap-2 text-sm"
                  style={{ color: "var(--foreground)" }}
                >
                  <input
                    type="checkbox"
                    checked={categoryIds.includes(target.id)}
                    onChange={() => setCategoryIds((c) => toggle(c, target.id))}
                    className="h-4 w-4"
                  />
                  {target.label}
                </label>
              ))}
            </div>
          )}

          {planId && targets && targets.objectives.length > 0 && (
            <div className="mt-2 flex flex-col gap-1.5">
              <p className="text-xs font-medium" style={{ color: "var(--muted-foreground)" }}>
                Objectives
              </p>
              {targets.objectives.map((target) => (
                <label
                  key={target.id}
                  className="flex min-h-11 items-center gap-2 text-sm"
                  style={{ color: "var(--foreground)" }}
                >
                  <input
                    type="checkbox"
                    checked={objectiveIds.includes(target.id)}
                    onChange={() => setObjectiveIds((c) => toggle(c, target.id))}
                    className="h-4 w-4"
                  />
                  {target.label}
                </label>
              ))}
            </div>
          )}
        </fieldset>
      </div>

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

      {notice && (
        <p
          role="status"
          className="mt-5 flex items-center gap-2 rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--accent) 12%, transparent)",
            color: "var(--foreground)",
          }}
        >
          <CheckCircle size={16} weight="bold" aria-hidden="true" />
          {notice}
        </p>
      )}

      <button
        type="submit"
        disabled={pending}
        className="mt-6 min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
        style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
      >
        {pending ? "Granting..." : "Grant access"}
      </button>
    </form>
  );
}
