import Link from "next/link";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { Pagination } from "@/components/pagination";
import { requireHrAdmin } from "@/lib/admin-queries";
import { loadAuditLogPage } from "@/lib/audit-log-queries";
import { parsePageParam } from "@/lib/pagination";
import { createClient } from "@/lib/supabase/server";

const occurredAtFormatter = new Intl.DateTimeFormat("en", {
  dateStyle: "medium",
  timeStyle: "short",
  timeZone: "UTC",
});

export default async function ActivityPage({
  searchParams,
}: {
  searchParams: Promise<{ page?: string | string[] }>;
}) {
  const supabase = await createClient();
  // Layouts and pages render concurrently, so the page must enforce the same
  // HR gate before loading a ledger row rather than relying on hidden nav.
  await requireHrAdmin(supabase);

  const { page: pageParam } = await searchParams;
  const activity = await loadAuditLogPage(supabase, parsePageParam(pageParam));

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
          Activity
        </h1>
        <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
          An immutable history of sensitive administration and calibration changes.
        </p>
      </div>

      <section>
        <h2
          className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
          style={{ color: "var(--muted-foreground)" }}
        >
          Recent activity ({activity.total})
        </h2>

        {activity.rows.length === 0 ? (
          <p
            className="rounded-2xl border border-dashed p-6 text-sm"
            style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
          >
            No activity has been recorded yet.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {activity.rows.map((row) => (
              <li
                key={row.id}
                className="rounded-2xl border p-5"
                style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
              >
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span
                    className="font-heading text-sm font-semibold"
                    style={{ color: "var(--foreground)" }}
                  >
                    {row.target_label}
                  </span>
                  <time
                    dateTime={row.occurred_at}
                    className="font-data text-xs"
                    style={{ color: "var(--muted-foreground)" }}
                  >
                    {occurredAtFormatter.format(new Date(row.occurred_at))} UTC
                  </time>
                </div>
                <p className="mt-2 text-sm" style={{ color: "var(--foreground)" }}>
                  {row.summary}
                </p>
                <p className="mt-2 text-xs" style={{ color: "var(--muted-foreground)" }}>
                  Actor: {row.actor_name}
                </p>
              </li>
            ))}
          </ul>
        )}

        <Pagination
          page={activity.page}
          pageCount={activity.pageCount}
          total={activity.total}
          basePath="/admin/activity"
          itemLabel="activity event"
        />
      </section>
    </div>
  );
}
