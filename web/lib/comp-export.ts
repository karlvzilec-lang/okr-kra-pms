import type { CompExportRow } from "./types.ts";

export type PageRange = {
  page: number;
  pageCount: number;
  from: number;
  to: number;
};

const CSV_HEADERS = [
  "employee_id",
  "full_name",
  "email",
  "manager_full_name",
  "overall_rating_scale_max",
  "final_score",
  "band_label",
  "published_at",
] as const;

function requestedPage(value: string | string[] | undefined): number {
  const raw = Array.isArray(value) ? value[0] : value;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 1;
}

/** Return a 1-indexed, clamped page plus its inclusive PostgREST range. */
export function getPageRange(
  value: string | string[] | undefined,
  total: number,
  pageSize: number,
): PageRange {
  if (!Number.isSafeInteger(total) || total < 0) {
    throw new RangeError("total must be a non-negative integer");
  }
  if (!Number.isSafeInteger(pageSize) || pageSize < 1) {
    throw new RangeError("pageSize must be a positive integer");
  }

  const pageCount = Math.max(1, Math.ceil(total / pageSize));
  const page = Math.min(requestedPage(value), pageCount);
  const from = (page - 1) * pageSize;

  return {
    page,
    pageCount,
    from,
    to: total === 0 ? pageSize - 1 : Math.min(from + pageSize - 1, total - 1),
  };
}

/**
 * Collect a complete result through bounded, inclusive PostgREST-style ranges.
 * A short batch is the end marker; an exact multiple therefore needs one final
 * empty request so a server-side max_rows cap can never silently truncate CSV.
 */
export async function collectRangeBatches<T>(
  fetchRange: (from: number, to: number) => Promise<T[]>,
  batchSize: number,
): Promise<T[]> {
  if (!Number.isSafeInteger(batchSize) || batchSize < 1) {
    throw new RangeError("batchSize must be a positive integer");
  }

  const rows: T[] = [];

  for (let from = 0; ; from += batchSize) {
    const batch = await fetchRange(from, from + batchSize - 1);
    rows.push(...batch);

    if (batch.length < batchSize) {
      return rows;
    }
  }
}

function csvCell(value: string | number | null): string {
  if (value === null) return '""';

  let text = String(value);
  if (typeof value === "string" && /^[=+\-@\t\r\n]/.test(text)) {
    text = `'${text}`;
  }

  return `"${text.replaceAll('"', '""')}"`;
}

/** Build an Excel-friendly RFC 4180-style CSV body for every export row. */
export function buildCompExportCsv(rows: CompExportRow[]): string {
  const lines = [CSV_HEADERS.map(csvCell).join(",")];

  for (const row of rows) {
    lines.push(
      [
        row.employee_id,
        row.full_name,
        row.email,
        row.manager_full_name,
        row.overall_rating_scale_max,
        row.final_score === null ? null : row.final_score.toFixed(3),
        row.band_label,
        row.published_at,
      ]
        .map(csvCell)
        .join(","),
    );
  }

  return lines.join("\r\n");
}

export function compExportFilename(cycleName: string): string {
  const cycleSlug = cycleName
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return `${cycleSlug || "review-cycle"}-comp-export.csv`;
}
