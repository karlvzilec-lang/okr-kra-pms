import { redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { Target } from "@phosphor-icons/react/dist/ssr/Target";
import { SlidersHorizontal } from "@phosphor-icons/react/dist/ssr/SlidersHorizontal";
import { Crosshair } from "@phosphor-icons/react/dist/ssr/Crosshair";
import { CalendarBlank } from "@phosphor-icons/react/dist/ssr/CalendarBlank";
import { UsersThree } from "@phosphor-icons/react/dist/ssr/UsersThree";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { KraStatCard, KraStatCardEmpty } from "@/components/kra-stat-card";
import { ObjectiveCard } from "@/components/objective-card";
import { isPasswordExpired } from "@/lib/password";
import { hasAnyDirectReports, loadOwnPlanForCycle } from "@/lib/goal-plan-queries";
import { employeeCanEdit } from "@/lib/goals";
import type { ReviewSummary } from "@/lib/types";

export default async function ReviewPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const [{ data: profile }, { data: cycle }] = await Promise.all([
    supabase.from("profiles").select("full_name, is_hr_admin, password_changed_at").eq("id", user.id).single(),
    supabase
      .from("review_cycle")
      .select("id, name, status")
      .order("start_date", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);

  // Forced rotation: never-changed or older than 60 days blocks access until
  // the user sets a new password that meets the (now stronger) policy.
  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  // Nav affordances, same conditional-link shape as the HR/calibration link:
  // shown only when the row that authorizes them actually exists.
  const [ownPlan, managesSomeone] = await Promise.all([
    cycle ? loadOwnPlanForCycle(supabase, cycle.id, user.id) : Promise.resolve(null),
    hasAnyDirectReports(supabase, user.id),
  ]);
  const canEditOwnPlan = ownPlan ? employeeCanEdit(ownPlan.status) : false;

  let summary: ReviewSummary | null = null;
  let summaryError: string | null = null;

  if (cycle) {
    const { data, error } = await supabase
      .rpc("employee_review_summary", {
        p_review_cycle_id: cycle.id,
        p_employee_id: user.id,
      })
      .single<{ summary: ReviewSummary }>();

    if (error) {
      summaryError = error.message;
    } else {
      summary = data?.summary ?? null;
    }
  }

  const kraByType = new Map(summary?.kra_ratings.map((r) => [r.rating_type, r]) ?? []);
  const scaleMax = 5;

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
      <header
        className="sticky top-0 z-10 flex h-16 items-center justify-between border-b px-4 sm:px-8"
        style={{ backgroundColor: "var(--background)", borderColor: "var(--border)" }}
      >
        <div className="flex items-center gap-2.5">
          <span
            className="flex h-8 w-8 items-center justify-center rounded-lg"
            style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
          >
            <ChartLineUp size={16} weight="bold" aria-hidden="true" />
          </span>
          <span className="font-heading text-sm font-semibold" style={{ color: "var(--foreground)" }}>
            Performance Review
          </span>
        </div>
        <div className="flex items-center gap-2">
          {canEditOwnPlan && ownPlan && (
            <Link
              href={`/goals/${ownPlan.id}`}
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <Target size={16} weight="bold" aria-hidden="true" />
              Edit my goals
            </Link>
          )}
          <Link
            href="/objectives"
            className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            <Crosshair size={16} weight="bold" aria-hidden="true" />
            My objectives
          </Link>
          {managesSomeone && (
            <Link
              href="/reports"
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <UsersThree size={16} weight="bold" aria-hidden="true" />
              My reports
            </Link>
          )}
          {profile?.is_hr_admin && (
            <Link
              href="/calibration"
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <SlidersHorizontal size={16} weight="bold" aria-hidden="true" />
              Calibration
            </Link>
          )}
          {profile?.is_hr_admin && (
            <Link
              href="/review-cycles"
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <CalendarBlank size={16} weight="bold" aria-hidden="true" />
              Manage review cycles
            </Link>
          )}
          <LogoutButton />
        </div>
      </header>

      <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
        <div className="mb-8">
          <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
            {cycle?.name ?? "No active review cycle"}
          </p>
          <h1 className="font-heading mt-1 text-2xl font-semibold sm:text-3xl" style={{ color: "var(--foreground)" }}>
            {profile?.full_name ?? "Your"} review summary
          </h1>
        </div>

        {!cycle && (
          <p className="rounded-2xl border border-dashed p-6 text-sm" style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}>
            No review cycle is visible to your account yet.
          </p>
        )}

        {summaryError && (
          <p
            className="rounded-2xl border p-4 text-sm"
            style={{ borderColor: "var(--border)", backgroundColor: "color-mix(in srgb, var(--destructive) 8%, transparent)", color: "var(--destructive)" }}
          >
            Couldn&apos;t load your review summary: {summaryError}
          </p>
        )}

        {cycle && !summaryError && (
          <div className="flex flex-col gap-10">
            <section>
              <h2 className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide" style={{ color: "var(--muted-foreground)" }}>
                KRA scorecard
              </h2>
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                {kraByType.get("self") ? (
                  <KraStatCard rating={kraByType.get("self")!} scaleMax={scaleMax} />
                ) : (
                  <KraStatCardEmpty label="Self rating" />
                )}
                {kraByType.get("manager") ? (
                  <KraStatCard rating={kraByType.get("manager")!} scaleMax={scaleMax} />
                ) : (
                  <KraStatCardEmpty label="Manager rating" />
                )}
              </div>
            </section>

            <section>
              <div className="mb-3 flex items-center gap-2">
                <Target size={16} weight="bold" style={{ color: "var(--muted-foreground)" }} aria-hidden="true" />
                <h2 className="font-heading text-sm font-semibold uppercase tracking-wide" style={{ color: "var(--muted-foreground)" }}>
                  Objectives &amp; key results
                </h2>
              </div>
              {summary?.objectives.length ? (
                <div className="flex flex-col gap-4">
                  {summary.objectives.map((objective) => (
                    <ObjectiveCard key={objective.id} objective={objective} />
                  ))}
                </div>
              ) : (
                <p className="rounded-2xl border border-dashed p-6 text-sm" style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}>
                  No objectives set for this cycle yet.
                </p>
              )}
            </section>
          </div>
        )}
      </div>
    </main>
  );
}
