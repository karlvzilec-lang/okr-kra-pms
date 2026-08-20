import Link from "next/link";
import { redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { Users } from "@phosphor-icons/react/dist/ssr/Users";
import { CaretRight } from "@phosphor-icons/react/dist/ssr/CaretRight";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { NewSessionForm } from "@/components/calibration/new-session-form";
import { SessionStatusPill } from "@/components/calibration/session-status-pill";
import { Pagination } from "@/components/pagination";
import { isPasswordExpired } from "@/lib/password";
import { clampPage, pageCountFor, parsePageParam, rangeFor } from "@/lib/pagination";
import type {
  CalibrationSessionListItem,
  CalibrationSessionStatus,
  ReviewCycleOption,
} from "@/lib/calibration";

type SessionRow = {
  id: string;
  name: string;
  status: CalibrationSessionStatus;
  review_cycle_id: string;
  created_at: string;
  review_cycle: { name: string } | { name: string }[] | null;
  calibration_participant: { count: number }[] | null;
};

function cycleName(row: SessionRow): string | null {
  if (!row.review_cycle) return null;
  return Array.isArray(row.review_cycle)
    ? (row.review_cycle[0]?.name ?? null)
    : row.review_cycle.name;
}

/**
 * The session index.
 *
 * The session list is paginated; the review-cycle list feeding NewSessionForm's
 * <select> is not. A cycle you cannot pick because it fell onto another page of
 * an unrelated list would make sessions uncreatable for that cycle, and cycles
 * are low-cardinality anyway.
 */
export default async function CalibrationIndexPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: string | string[] }>;
}) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("full_name, is_hr_admin, password_changed_at")
    .eq("id", user.id)
    .single();

  // Password expiry is checked BEFORE the HR gate: an expired credential must
  // not be able to probe whether a given account is an HR admin.
  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  if (!profile?.is_hr_admin) {
    return (
      <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
        <CalibrationHeader />
        <div className="mx-auto w-full max-w-2xl flex-1 px-4 py-16 sm:px-8">
          <h1 className="font-heading text-2xl font-semibold" style={{ color: "var(--foreground)" }}>
            Calibration is HR-only
          </h1>
          <p className="mt-2 text-sm" style={{ color: "var(--muted-foreground)" }}>
            Calibration sessions are facilitated by HR. If you manage someone whose rating is being
            calibrated, their outcome shows up on your report&apos;s review page once HR publishes it.
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

  const requestedPage = parsePageParam((await searchParams).page);
  const { from, to } = rangeFor(requestedPage);

  const [
    { data: sessionRows, count: sessionCount, error: sessionsError },
    { data: cycleRows },
  ] = await Promise.all([
    supabase
      .from("calibration_session")
      .select(
        "id, name, status, review_cycle_id, created_at, review_cycle(name), calibration_participant(count)",
        { count: "exact" },
      )
      // id breaks the tie on created_at: sessions seeded or created in one
      // transaction share a timestamp exactly, and an untiebroken sort can
      // order them differently between the page-1 and page-2 requests, showing
      // one session twice and hiding another entirely.
      .order("created_at", { ascending: false })
      .order("id", { ascending: true })
      .range(from, to),
    supabase
      .from("review_cycle")
      .select("id, name")
      .order("start_date", { ascending: false }),
  ]);

  const sessions: CalibrationSessionListItem[] = ((sessionRows ?? []) as SessionRow[]).map(
    (row) => ({
      id: row.id,
      name: row.name,
      status: row.status,
      review_cycle_id: row.review_cycle_id,
      review_cycle_name: cycleName(row),
      participant_count: row.calibration_participant?.[0]?.count ?? 0,
      created_at: row.created_at,
    }),
  );

  const cycles: ReviewCycleOption[] = (cycleRows ?? []) as ReviewCycleOption[];

  const sessionTotal = sessionCount ?? 0;
  const page = clampPage(requestedPage, sessionTotal);
  const pageCount = pageCountFor(sessionTotal);

  // A .range() past the last row succeeds and returns nothing, so a stale
  // ?page=99 would otherwise render an empty list under a caption claiming
  // there are 40 sessions. The paginated loaders in lib/ re-fetch at the
  // clamped page; this query is inline, so it redirects instead — the URL then
  // matches the page actually shown, which is the better of the two outcomes.
  if (page !== requestedPage && sessions.length === 0 && sessionTotal > 0) {
    redirect(page <= 1 ? "/calibration" : `/calibration?page=${page}`);
  }

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
      <CalibrationHeader />

      <div className="mx-auto w-full max-w-5xl flex-1 px-4 py-10 sm:px-8">
        <div className="mb-8">
          <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
            HR facilitator
          </p>
          <h1
            className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
            style={{ color: "var(--foreground)" }}
          >
            Calibration sessions
          </h1>
          <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
            A calibration pass is facilitated, not computed. Each session starts from manager
            ratings exactly as they were submitted; every change you make is recorded against that
            original snapshot.
          </p>
        </div>

        <NewSessionForm cycles={cycles} />

        {sessionsError && (
          <p
            role="alert"
            className="mt-8 rounded-2xl border p-4 text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "color-mix(in srgb, var(--destructive) 8%, transparent)",
              color: "var(--destructive)",
            }}
          >
            Couldn&apos;t load calibration sessions: {sessionsError.message}
          </p>
        )}

        <section className="mt-8">
          <h2
            className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
            style={{ color: "var(--muted-foreground)" }}
          >
            All sessions
          </h2>

          {sessionTotal === 0 && !sessionsError ? (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              No calibration sessions yet. Create one above to start a facilitated pass over a
              review cycle.
            </p>
          ) : (
            <ul className="flex flex-col gap-3">
              {sessions.map((session) => (
                <li key={session.id}>
                  <Link
                    href={`/calibration/${session.id}`}
                    className="flex items-center justify-between gap-4 rounded-2xl border p-5 transition-colors hover:bg-[var(--muted)]"
                    style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
                  >
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span
                          className="font-heading truncate text-sm font-semibold"
                          style={{ color: "var(--foreground)" }}
                        >
                          {session.name}
                        </span>
                        <SessionStatusPill status={session.status} />
                      </div>
                      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                        {session.review_cycle_name ?? "Unknown cycle"}
                        {" · "}
                        <span className="inline-flex items-center gap-1 align-middle">
                          <Users size={12} weight="bold" aria-hidden="true" />
                          {session.participant_count}{" "}
                          {session.participant_count === 1 ? "participant" : "participants"}
                        </span>
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

          <Pagination
            page={page}
            pageCount={pageCount}
            total={sessionTotal}
            basePath="/calibration"
            itemLabel="session"
          />
        </section>
      </div>
    </main>
  );
}

function CalibrationHeader() {
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
          Calibration
        </span>
      </div>
      <LogoutButton />
    </header>
  );
}
