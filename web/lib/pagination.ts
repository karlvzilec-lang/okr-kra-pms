// The one pagination contract every paginated loader and page in the app
// shares — the agreed shape from the ruling, in one place so the UI component
// is genuinely shared rather than reimplemented per page.
//
// Two things here are load-bearing and were decided deliberately:
//
//   * Every paginated query MUST order by a unique tiebreaker (id) after its
//     primary sort. full_name, created_at and start_date are none of them
//     unique, and Postgres gives no stable order among rows that tie. Without
//     the tiebreaker, two people sharing a name (or two sessions created in
//     the same millisecond) can straddle a page boundary such that one row
//     appears on both pages and another appears on neither. rangeFor() is the
//     only helper here that computes offsets; the .order() calls live at each
//     call site so the tiebreaker is visible in the query it protects.
//
//   * Out-of-range pages CLAMP rather than 404 or render empty. ?page=99 on a
//     two-page list is nearly always a stale bookmark or a link followed after
//     rows were deleted, and showing the last real page is more useful than an
//     error. clampPage() is applied AFTER the total is known, which is why
//     loaders issue the count query and the row query together.

/**
 * Rows per page, everywhere. One constant rather than a per-page option: these
 * are all admin/manager lists of the same rough density, and a single value
 * keeps "page 3" meaning the same amount of scrolling wherever you are.
 */
export const PAGE_SIZE = 25;

/** The result shape every paginated loader returns. */
export type Paginated<T> = {
  rows: T[];
  total: number;
  page: number;
  pageCount: number;
};

/**
 * The 1-indexed page a request is asking for, from `?page=N`.
 *
 * Anything that isn't a positive integer — absent, "abc", "0", "-3", "2.5",
 * or the string[] Next hands over for a repeated param — reads as page 1. A
 * malformed page number is a broken link, not something worth erroring over.
 * The upper bound isn't applied here because it depends on the total, which
 * isn't known until the query runs; clampPage() finishes the job.
 */
export function parsePageParam(raw: string | string[] | undefined): number {
  const value = Array.isArray(raw) ? raw[0] : raw;
  if (!value) return 1;

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) return 1;

  return parsed;
}

/** How many pages `total` rows fill. Always at least 1, so an empty list is "page 1 of 1". */
export function pageCountFor(total: number): number {
  return Math.max(1, Math.ceil(total / PAGE_SIZE));
}

/** A requested page pinned into the range that actually exists. */
export function clampPage(page: number, total: number): number {
  return Math.min(Math.max(1, page), pageCountFor(total));
}

/**
 * The inclusive [from, to] pair for PostgREST's .range().
 *
 * Note .range() is inclusive at BOTH ends, unlike a JS slice: page 1 of 25 is
 * range(0, 24), not range(0, 25).
 */
export function rangeFor(page: number): { from: number; to: number } {
  const from = (page - 1) * PAGE_SIZE;
  return { from, to: from + PAGE_SIZE - 1 };
}

/**
 * Assemble the result, re-clamping and re-fetching being the caller's job.
 *
 * `total` comes from PostgREST's exact count, which is the count of the
 * FILTERED set rather than the table — so it stays correct under RLS and under
 * whatever .eq()/.in() the loader applied.
 */
export function paginated<T>(rows: T[], total: number, page: number): Paginated<T> {
  return {
    rows,
    total,
    page: clampPage(page, total),
    pageCount: pageCountFor(total),
  };
}

/** An empty result, for the early returns where a query is skipped entirely. */
export function emptyPage<T>(): Paginated<T> {
  return { rows: [], total: 0, page: 1, pageCount: 1 };
}

/**
 * Finish a loader: return the page, or re-run it against the clamped page when
 * the request asked for one past the end.
 *
 * A .range() beyond the last row succeeds and returns zero rows, so without
 * this a stale `?page=99` renders an empty list under a caption claiming there
 * are 40 rows. Re-fetching is one extra round trip in a case that only happens
 * on a bad link, and it costs nothing on the normal path.
 *
 * The recursion terminates because clampPage() always returns a page within
 * [1, pageCount], so the retry either finds rows or the table is genuinely
 * empty (total === 0), which is guarded before recursing.
 */
export async function refetchIfClamped<T>(
  rows: T[],
  total: number,
  page: number,
  refetch: (page: number) => Promise<Paginated<T>>,
): Promise<Paginated<T>> {
  const clamped = clampPage(page, total);
  if (clamped !== page && rows.length === 0 && total > 0) {
    return refetch(clamped);
  }
  return paginated(rows, total, page);
}
