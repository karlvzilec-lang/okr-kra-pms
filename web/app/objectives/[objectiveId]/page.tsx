import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { ClockCounterClockwise } from "@phosphor-icons/react/dist/ssr/ClockCounterClockwise";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { CycleStatusPill } from "@/components/cycles/cycle-status-pill";
import { KeyResultEditor } from "@/components/okr/key-result-editor";
import { CheckInForm } from "@/components/okr/check-in-form";
import { ProgressBar } from "@/components/progress-bar";
import { ScoreBadge, ScoreValue } from "@/components/score-badge";
import { isPasswordExpired } from "@/lib/password";
import { loadCheckInsForKeyResults, loadObjectiveDetail } from "@/lib/okr-queries";
import { okrBlockedReason, okrIsWritable } from "@/lib/okr";

export default async function ObjectiveDetailPage({
  params,
}: PageProps<"/objectives/[objectiveId]">) {
  const { objectiveId } = await params;
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

  const objective = await loadObjectiveDetail(supabase, objectiveId);

  // RLS hides objectives the caller can't read, so "not visible" and "doesn't
  // exist" are the same 404 from here.
  if (!objective) {
    notFound();
  }

  // can_read_objective also exposes a manager's objectives upward. This page is
  // the owner's editing surface, so a reader who isn't the owner is sent back
  // to the review summary rather than shown forms every write would reject.
  if (objective.owner_id !== user.id) {
    redirect("/review");
  }

  const writable = okrIsWritable(objective.review_cycle_status);
  const blockedReason = okrBlockedReason(objective.review_cycle_status);

  const checkIns = await loadCheckInsForKeyResults(
    supabase,
    objective.key_results.map((kr) => kr.id),
  );
  const keyResultTitle = new Map(objective.key_results.map((kr) => [kr.id, kr.title]));

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
            Objective
          </span>
        </div>
        <LogoutButton />
      </header>

      <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
        <Link
          href="/objectives"
          className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
          style={{ color: "var(--muted-foreground)" }}
        >
          <ArrowLeft size={16} weight="bold" aria-hidden="true" />
          Back to my objectives
        </Link>

        <div className="mb-8">
          <div className="flex flex-wrap items-center gap-2">
            <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
              {objective.review_cycle_name ?? "Unknown cycle"}
            </p>
            {objective.review_cycle_status && (
              <CycleStatusPill status={objective.review_cycle_status} />
            )}
          </div>
          <h1
            className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
            style={{ color: "var(--foreground)" }}
          >
            {objective.title}
          </h1>
          {objective.description && (
            <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
              {objective.description}
            </p>
          )}
        </div>

        {blockedReason && (
          <p
            role="status"
            className="mb-8 rounded-2xl border p-4 text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--muted)",
              color: "var(--muted-foreground)",
            }}
          >
            {blockedReason}
          </p>
        )}

        <section className="mb-10">
          <h2
            className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
            style={{ color: "var(--muted-foreground)" }}
          >
            Key results
          </h2>

          {writable ? (
            <KeyResultEditor objectiveId={objective.id} keyResults={objective.key_results} />
          ) : objective.key_results.length === 0 ? (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              This objective has no key results, and the cycle is closed.
            </p>
          ) : (
            <div className="flex flex-col gap-3">
              {objective.key_results.map((kr) => (
                <div
                  key={kr.id}
                  className="rounded-2xl border p-4"
                  style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                        {kr.title}
                      </p>
                      <p
                        className="font-data mt-1 text-xs"
                        style={{ color: "var(--muted-foreground)" }}
                      >
                        {kr.current_value ?? kr.start_value} / {kr.target_value}{" "}
                        {kr.metric_unit ?? ""}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <ScoreValue score={kr.effective_score} />
                      <ScoreBadge score={kr.effective_score} />
                    </div>
                  </div>
                  <div className="mt-3">
                    <ProgressBar fraction={kr.effective_score} />
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>

        {writable && objective.key_results.length > 0 && (
          <section className="mb-10">
            <h2
              className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
              style={{ color: "var(--muted-foreground)" }}
            >
              Check in
            </h2>
            <div className="flex flex-col gap-4">
              {objective.key_results.map((kr) => (
                <CheckInForm key={kr.id} keyResult={kr} />
              ))}
            </div>
          </section>
        )}

        <section>
          <div className="mb-3 flex items-center gap-2">
            <ClockCounterClockwise
              size={16}
              weight="bold"
              style={{ color: "var(--muted-foreground)" }}
              aria-hidden="true"
            />
            <h2
              className="font-heading text-sm font-semibold uppercase tracking-wide"
              style={{ color: "var(--muted-foreground)" }}
            >
              Check-in history
            </h2>
          </div>

          {checkIns.length === 0 ? (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              No check-ins recorded yet.
            </p>
          ) : (
            <ul className="flex flex-col gap-2">
              {checkIns.map((entry) => (
                <li
                  key={entry.id}
                  className="rounded-2xl border p-4"
                  style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                >
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <span className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                      {keyResultTitle.get(entry.key_result_id) ?? "Key result"}
                    </span>
                    <span
                      className="font-data text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      {new Date(entry.created_at).toLocaleString()}
                    </span>
                  </div>
                  <p className="font-data mt-1 text-sm" style={{ color: "var(--foreground)" }}>
                    → {entry.new_value}
                  </p>
                  {entry.note && (
                    <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
                      {entry.note}
                    </p>
                  )}
                  <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                    {entry.author_name ?? "Unknown"}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}
