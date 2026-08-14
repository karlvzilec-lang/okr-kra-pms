import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { ManagerRatingForm } from "@/components/goals/manager-rating-form";
import { isPasswordExpired } from "@/lib/password";
import { isLineManagerOfPlan, loadGoalPlan } from "@/lib/goal-plan-queries";
import type { ReviewCycleStatus } from "@/lib/types";

export default async function ReportPlanPage({ params }: PageProps<"/reports/[planId]">) {
  const { planId } = await params;
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("password_changed_at")
    .eq("id", user.id)
    .single();

  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  // Authorization is scoped to THIS plan: being a line manager on some other
  // plan grants nothing here. Checked before the plan is rendered so a
  // non-manager participant (e.g. HR, or the employee themselves) never sees
  // the manager rating surface.
  const isManagerHere = await isLineManagerOfPlan(supabase, planId, user.id);
  if (!isManagerHere) {
    redirect("/reports");
  }

  const plan = await loadGoalPlan(supabase, planId);
  if (!plan) {
    notFound();
  }

  const [{ data: employee }, { data: cycle }] = await Promise.all([
    supabase.from("profiles").select("full_name").eq("id", plan.employee_id).maybeSingle(),
    supabase
      .from("review_cycle")
      .select("name, status")
      .eq("id", plan.review_cycle_id)
      .maybeSingle(),
  ]);

  const cycleStatus = (cycle?.status as ReviewCycleStatus | undefined) ?? null;

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
            Manager review
          </span>
        </div>
        <LogoutButton />
      </header>

      <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
        <Link
          href="/reports"
          className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
          style={{ color: "var(--muted-foreground)" }}
        >
          <ArrowLeft size={16} weight="bold" aria-hidden="true" />
          Back to my reports
        </Link>

        <div className="mb-8">
          <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
            {cycle?.name ?? "Unknown review cycle"}
          </p>
          <h1
            className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
            style={{ color: "var(--foreground)" }}
          >
            {employee?.full_name ?? "Employee"}&apos;s goal plan
          </h1>
        </div>

        <ManagerRatingForm
          plan={plan}
          employeeName={employee?.full_name ?? "Employee"}
          cycleStatus={cycleStatus}
        />
      </div>
    </main>
  );
}
