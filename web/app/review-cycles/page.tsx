import Link from "next/link";
import { redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { NewCycleForm } from "@/components/cycles/new-cycle-form";
import { AdvanceCycleButton } from "@/components/cycles/advance-cycle-button";
import { CycleStatusPill } from "@/components/cycles/cycle-status-pill";
import { isPasswordExpired } from "@/lib/password";
import { loadReviewCycles } from "@/lib/okr-queries";

export default async function ReviewCyclesPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("is_hr_admin, password_changed_at")
    .eq("id", user.id)
    .single();

  // Password expiry is checked BEFORE the HR gate, matching /calibration: an
  // expired credential must not be able to probe who holds HR admin.
  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  if (!profile?.is_hr_admin) {
    return (
      <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
        <CyclesHeader />
        <div className="mx-auto w-full max-w-2xl flex-1 px-4 py-16 sm:px-8">
          <h1 className="font-heading text-2xl font-semibold" style={{ color: "var(--foreground)" }}>
            Review cycles are HR-only
          </h1>
          <p className="mt-2 text-sm" style={{ color: "var(--muted-foreground)" }}>
            HR opens each review cycle and moves it through its stages. Your own goals and
            objectives follow whichever cycle is currently open.
          </p>
          <Link
            href="/review"
            className="mt-6 inline-flex min-h-11 items-center rounded-lg px-4 text-sm font-semibold"
            style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
          >
            Back to my review
          </Link>
        </div>
      </main>
    );
  }

  const cycles = await loadReviewCycles(supabase);

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
      <CyclesHeader />

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
          <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
            HR administration
          </p>
          <h1
            className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
            style={{ color: "var(--foreground)" }}
          >
            Review cycles
          </h1>
          <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
            A cycle walks one way through draft, active, self evaluation, manager evaluation and
            closed. Stages can&apos;t be skipped or revisited, and a closed cycle is frozen for
            everyone — including HR.
          </p>
        </div>

        <NewCycleForm />

        <section className="mt-8">
          <h2
            className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
            style={{ color: "var(--muted-foreground)" }}
          >
            All cycles
          </h2>

          {cycles.length === 0 ? (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              No review cycles yet. Create one above to open the first review window.
            </p>
          ) : (
            <ul className="flex flex-col gap-3">
              {cycles.map((cycle) => (
                <li
                  key={cycle.id}
                  className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border p-5"
                  style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span
                        className="font-heading truncate text-sm font-semibold"
                        style={{ color: "var(--foreground)" }}
                      >
                        {cycle.name}
                      </span>
                      <CycleStatusPill status={cycle.status} />
                    </div>
                    <p
                      className="font-data mt-1 text-xs"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      {cycle.start_date} → {cycle.end_date}
                    </p>
                  </div>
                  <AdvanceCycleButton cycleId={cycle.id} status={cycle.status} />
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}

function CyclesHeader() {
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
          Review cycles
        </span>
      </div>
      <LogoutButton />
    </header>
  );
}
