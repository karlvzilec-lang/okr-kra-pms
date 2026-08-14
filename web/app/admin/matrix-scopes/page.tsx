import Link from "next/link";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { ScopeGrantForm } from "@/components/admin/scope-grant-form";
import { SCOPE_TYPE_LABEL } from "@/lib/admin";
import {
  loadAdminPlans,
  loadAllProfiles,
  loadExistingScopeGrants,
  loadScopeTargets,
  type ScopeTarget,
} from "@/lib/admin-queries";

/**
 * Grant matrix managers scoped access to specific sections of a plan.
 *
 * The scope targets for every plan are resolved HERE, server-side, and handed
 * to the form as a fixed map. That's the point of doing it this way rather
 * than letting the client fetch them on selection: validate_scope_target_exists
 * only checks that a category or objective exists, not that it belongs to the
 * plan being scoped, so "which targets are legitimate for this plan" has to be
 * decided somewhere that a client-supplied id can't influence.
 */
export default async function MatrixScopesPage() {
  const supabase = await createClient();

  const [people, plans, grants] = await Promise.all([
    loadAllProfiles(supabase),
    loadAdminPlans(supabase),
    loadExistingScopeGrants(supabase),
  ]);

  const targetEntries = await Promise.all(
    plans.map(async (plan) => {
      const targets = await loadScopeTargets(
        supabase,
        plan.id,
        plan.employee_id,
        plan.review_cycle_id,
      );
      return [plan.id, targets] as const;
    }),
  );
  const targetsByPlanId = Object.fromEntries(targetEntries) as Record<
    string,
    { categories: ScopeTarget[]; objectives: ScopeTarget[] }
  >;

  // Every scope target across every plan, so an existing grant can be named
  // rather than shown as a bare uuid.
  const labelByScopeId = new Map<string, string>();
  for (const [, targets] of targetEntries) {
    for (const target of [...targets.categories, ...targets.objectives]) {
      labelByScopeId.set(target.id, target.label);
    }
  }
  const planById = new Map(plans.map((plan) => [plan.id, plan]));

  return (
    <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
      <Link
        href="/admin"
        className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
        style={{ color: "var(--muted-foreground)" }}
      >
        <ArrowLeft size={16} weight="bold" aria-hidden="true" />
        Back to employees
      </Link>

      <div className="mb-8">
        <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
          HR administration
        </p>
        <h1
          className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
          style={{ color: "var(--foreground)" }}
        >
          Matrix access
        </h1>
        <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
          A matrix manager can only see and rate the specific KRA categories and objectives granted
          to them — never a whole plan. Their ratings are advisory and don&apos;t feed the overall
          score, which stays with the line manager.
        </p>
      </div>

      <ScopeGrantForm plans={plans} people={people} targetsByPlanId={targetsByPlanId} />

      <section className="mt-8">
        <h2
          className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
          style={{ color: "var(--muted-foreground)" }}
        >
          Current grants ({grants.length})
        </h2>

        {grants.length === 0 ? (
          <p
            className="rounded-2xl border border-dashed p-6 text-sm"
            style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
          >
            No matrix access has been granted yet.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {grants.map((grant) => {
              const plan = planById.get(grant.employee_goal_plan_id);
              return (
                <li
                  key={grant.id}
                  className="rounded-2xl border p-5"
                  style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                >
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <span
                      className="font-heading text-sm font-semibold"
                      style={{ color: "var(--foreground)" }}
                    >
                      {grant.participant_name}
                    </span>
                    <span
                      className="rounded-full px-2 py-0.5 text-xs font-medium"
                      style={{
                        backgroundColor: "var(--muted)",
                        color: "var(--muted-foreground)",
                      }}
                    >
                      {SCOPE_TYPE_LABEL[grant.scope_type]}
                    </span>
                  </div>
                  <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
                    {labelByScopeId.get(grant.scope_id) ?? "A section you can no longer see"}
                    {plan ? ` — on ${plan.employee_name}'s plan` : ""}
                  </p>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
