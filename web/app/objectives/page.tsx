import Link from "next/link";
import { redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { CaretRight } from "@phosphor-icons/react/dist/ssr/CaretRight";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { NewObjectiveForm } from "@/components/okr/new-objective-form";
import { CycleStatusPill } from "@/components/cycles/cycle-status-pill";
import { isPasswordExpired } from "@/lib/password";
import { loadOwnObjectives, loadReviewCycles } from "@/lib/okr-queries";
import { cycleIsClosed } from "@/lib/okr";

export default async function ObjectivesPage() {
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

  const [cycles, objectives] = await Promise.all([
    loadReviewCycles(supabase),
    loadOwnObjectives(supabase, user.id),
  ]);

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
      <ObjectivesHeader />

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
            My objectives
          </h1>
          <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
            Objectives are yours: you own them, you check in on them. Progress is recorded by
            checking in, never by editing a number directly, so the score always has an event
            behind it.
          </p>
        </div>

        <NewObjectiveForm cycles={cycles} />

        <section className="mt-8">
          <h2
            className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
            style={{ color: "var(--muted-foreground)" }}
          >
            All my objectives
          </h2>

          {objectives.length === 0 ? (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              You haven&apos;t set any objectives yet.
            </p>
          ) : (
            <ul className="flex flex-col gap-3">
              {objectives.map((objective) => (
                <li key={objective.id}>
                  <Link
                    href={`/objectives/${objective.id}`}
                    className="flex items-center justify-between gap-4 rounded-2xl border p-5 transition-colors hover:bg-[var(--muted)]"
                    style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                  >
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span
                          className="font-heading truncate text-sm font-semibold"
                          style={{ color: "var(--foreground)" }}
                        >
                          {objective.title}
                        </span>
                        {objective.review_cycle_status && (
                          <CycleStatusPill status={objective.review_cycle_status} />
                        )}
                      </div>
                      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                        {objective.review_cycle_name ?? "Unknown cycle"}
                        {" · "}
                        {objective.key_result_count}{" "}
                        {objective.key_result_count === 1 ? "key result" : "key results"}
                        {cycleIsClosed(objective.review_cycle_status) && " · frozen"}
                      </p>
                    </div>
                    <CaretRight
                      size={16}
                      weight="bold"
                      aria-hidden="true"
                      style={{ color: "var(--muted-foreground)" }}
                      className="shrink-0"
                    />
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}

function ObjectivesHeader() {
  return (
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
          My objectives
        </span>
      </div>
      <LogoutButton />
    </header>
  );
}
