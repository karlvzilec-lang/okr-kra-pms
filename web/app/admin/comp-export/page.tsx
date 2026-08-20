import Link from "next/link";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { requireHrAdmin } from "@/lib/admin-queries";
import {
  loadCompleteCompExport,
  loadCompleteReviewCycles,
  loadCompExportPage,
} from "@/lib/comp-export-queries";
import { buildCompExportCsv, compExportFilename } from "@/lib/comp-export";
import { CompExportDownload } from "@/components/admin/comp-export-download";

const publishedAtFormatter = new Intl.DateTimeFormat("en", {
  dateStyle: "medium",
  timeStyle: "short",
  timeZone: "UTC",
});

function pageHref(cycleId: string, page: number): string {
  const query = new URLSearchParams({ cycle: cycleId, page: String(page) });
  return `/admin/comp-export?${query}`;
}

export default async function CompExportPage(props: PageProps<"/admin/comp-export">) {
  const supabase = await createClient();
  await requireHrAdmin(supabase);

  const query = await props.searchParams;
  const cycles = await loadCompleteReviewCycles(supabase);
  const requestedCycle = Array.isArray(query.cycle) ? query.cycle[0] : query.cycle;
  const selectedCycle = cycles.find((cycle) => cycle.id === requestedCycle) ?? cycles[0] ?? null;

  if (!selectedCycle) {
    return (
      <div className="mx-auto w-full max-w-6xl flex-1 px-4 py-10 sm:px-8">
        <PageHeading />
        <p
          className="rounded-2xl border border-dashed p-6 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          No review cycles exist yet. Create a cycle before exporting compensation results.
        </p>
      </div>
    );
  }

  const [table, completeRows] = await Promise.all([
    loadCompExportPage(supabase, selectedCycle.id, query.page),
    loadCompleteCompExport(supabase, selectedCycle.id),
  ]);

  return (
    <div className="mx-auto w-full max-w-6xl flex-1 px-4 py-10 sm:px-8">
      <PageHeading />

      <section
        className="mb-6 flex flex-wrap items-end justify-between gap-4 rounded-2xl border p-5"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <form method="get" className="flex min-w-64 flex-1 flex-wrap items-end gap-3">
          <label className="flex min-w-60 flex-1 flex-col gap-1.5 text-sm font-medium">
            Review cycle
            <select
              name="cycle"
              defaultValue={selectedCycle.id}
              className="min-h-11 rounded-lg border bg-transparent px-3 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              {cycles.map((cycle) => (
                <option key={cycle.id} value={cycle.id}>
                  {cycle.name}
                </option>
              ))}
            </select>
          </label>
          <button
            type="submit"
            className="min-h-11 rounded-lg border px-4 text-sm font-semibold transition-transform active:scale-[0.98]"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            View cycle
          </button>
        </form>
        <div className="flex flex-col items-start gap-1 sm:items-end">
          <CompExportDownload
            csv={buildCompExportCsv(completeRows)}
            filename={compExportFilename(selectedCycle.name)}
            rowCount={completeRows.length}
          />
          <span className="text-xs" style={{ color: "var(--muted-foreground)" }}>
            Includes all {completeRows.length} published {completeRows.length === 1 ? "plan" : "plans"}
          </span>
        </div>
      </section>

      <section>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <h2
            className="font-heading text-sm font-semibold uppercase tracking-wide"
            style={{ color: "var(--muted-foreground)" }}
          >
            Published results ({table.total})
          </h2>
          <span className="font-data text-xs" style={{ color: "var(--muted-foreground)" }}>
            Page {table.page} of {table.pageCount}
          </span>
        </div>

        {table.rows.length === 0 ? (
          <p
            className="rounded-2xl border border-dashed p-6 text-sm"
            style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
          >
            This cycle has no published compensation results yet.
          </p>
        ) : (
          <div
            className="overflow-x-auto rounded-2xl border"
            style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          >
            <table className="w-full min-w-[980px] border-collapse text-left text-sm">
              <thead style={{ backgroundColor: "var(--muted)" }}>
                <tr>
                  {[
                    "Employee",
                    "Manager",
                    "Scale",
                    "Final score",
                    "Band",
                    "Published",
                  ].map((heading) => (
                    <th
                      key={heading}
                      scope="col"
                      className="px-4 py-3 text-xs font-semibold uppercase tracking-wide"
                      style={{ color: "var(--muted-foreground)" }}
                    >
                      {heading}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {table.rows.map((row) => (
                  <tr key={row.employee_id} className="border-t" style={{ borderColor: "var(--border)" }}>
                    <td className="px-4 py-3">
                      <p className="font-heading font-semibold" style={{ color: "var(--foreground)" }}>
                        {row.full_name}
                      </p>
                      <p className="font-data mt-0.5 text-xs" style={{ color: "var(--muted-foreground)" }}>
                        {row.email}
                      </p>
                    </td>
                    <td className="px-4 py-3" style={{ color: "var(--foreground)" }}>
                      {row.manager_full_name ?? "—"}
                    </td>
                    <td className="font-data px-4 py-3" style={{ color: "var(--foreground)" }}>
                      {row.overall_rating_scale_max}
                    </td>
                    <td className="font-data px-4 py-3 font-semibold" style={{ color: "var(--foreground)" }}>
                      {row.final_score === null ? "—" : row.final_score.toFixed(3)}
                    </td>
                    <td className="px-4 py-3" style={{ color: "var(--foreground)" }}>
                      {row.band_label ?? "—"}
                    </td>
                    <td className="font-data px-4 py-3 text-xs" style={{ color: "var(--muted-foreground)" }}>
                      {publishedAtFormatter.format(new Date(row.published_at))} UTC
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <nav className="mt-4 flex flex-wrap items-center justify-between gap-3" aria-label="Compensation export pages">
          <Link
            href={pageHref(selectedCycle.id, Math.max(1, table.page - 1))}
            aria-disabled={table.page === 1}
            className="inline-flex min-h-11 items-center rounded-lg border px-4 text-sm font-semibold transition-transform active:scale-[0.98] aria-disabled:pointer-events-none aria-disabled:opacity-50"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            Previous
          </Link>
          <form method="get" className="flex items-center gap-2">
            <input type="hidden" name="cycle" value={selectedCycle.id} />
            <label className="text-sm" style={{ color: "var(--muted-foreground)" }}>
              Go to page
              <input
                name="page"
                type="number"
                min={1}
                max={table.pageCount}
                defaultValue={table.page}
                className="ml-2 h-11 w-20 rounded-lg border bg-transparent px-3 font-data"
                style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
              />
            </label>
            <button
              type="submit"
              className="min-h-11 rounded-lg border px-3 text-sm font-semibold transition-transform active:scale-[0.98]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              Go
            </button>
          </form>
          <Link
            href={pageHref(selectedCycle.id, Math.min(table.pageCount, table.page + 1))}
            aria-disabled={table.page === table.pageCount}
            className="inline-flex min-h-11 items-center rounded-lg border px-4 text-sm font-semibold transition-transform active:scale-[0.98] aria-disabled:pointer-events-none aria-disabled:opacity-50"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            Next
          </Link>
        </nav>
      </section>
    </div>
  );
}

function PageHeading() {
  return (
    <>
      <Link
        href="/review"
        className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium transition-transform active:scale-[0.98]"
        style={{ color: "var(--muted-foreground)" }}
      >
        <ArrowLeft size={16} weight="bold" aria-hidden="true" />
        Back to my review
      </Link>
      <div className="mb-8">
        <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
          HR administration
        </p>
        <h1 className="font-heading mt-1 text-2xl font-semibold sm:text-3xl" style={{ color: "var(--foreground)" }}>
          Compensation export
        </h1>
        <p className="mt-2 max-w-3xl text-sm" style={{ color: "var(--muted-foreground)" }}>
          Review published final scores and calibration bands by cycle. The table is paged for review;
          the CSV always contains the complete selected cycle.
        </p>
      </div>
    </>
  );
}
