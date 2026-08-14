import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { GoalPlanEditor } from "@/components/goals/goal-plan-editor";
import { isPasswordExpired } from "@/lib/password";
import { loadGoalPlan } from "@/lib/goal-plan-queries";

export default async function GoalPlanPage({ params }: PageProps<"/goals/[planId]">) {
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
    .select("full_name, password_changed_at")
    .eq("id", user.id)
    .single();

  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  const plan = await loadGoalPlan(supabase, planId);

  // RLS hides plans the caller isn't a participant on, so "not visible" and
  // "doesn't exist" are the same 404 from here.
  if (!plan) {
    notFound();
  }

  // This editor is the employee's own view of their own plan. A manager who
  // lands here by URL is sent to the rating view instead, which is scoped to
  // the columns they're actually allowed to write.
  if (plan.employee_id !== user.id) {
    redirect(`/reports/${planId}`);
  }

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
            My goal plan
          </span>
        </div>
        <LogoutButton />
      </header>

      <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
        <Link
          href="/review"
          className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
          style={{ color: "var(--muted-foreground)" }}
        >
          <ArrowLeft size={16} weight="bold" aria-hidden="true" />
          Back to my review
        </Link>

        <div className="mb-8">
          <h1
            className="font-heading text-2xl font-semibold sm:text-3xl"
            style={{ color: "var(--foreground)" }}
          >
            Goals &amp; self-assessment
          </h1>
          <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
            Category weights total 100 across the plan, and goal weights total 100 inside each
            category. Leave a rating blank if you haven&apos;t assessed it yet — blank means unrated,
            and 0 is a real score.
          </p>
        </div>

        <GoalPlanEditor plan={plan} />
      </div>
    </main>
  );
}
