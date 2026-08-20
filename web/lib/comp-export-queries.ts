import type { SupabaseClient } from "@supabase/supabase-js";
import { collectRangeBatches, getPageRange } from "@/lib/comp-export";
import type { CompExportRow, ReviewCycle } from "@/lib/types";

export const COMP_EXPORT_PAGE_SIZE = 25;
const COMP_EXPORT_BATCH_SIZE = 500;
const REVIEW_CYCLE_COLUMNS = "id, name, start_date, end_date, status, created_at, updated_at";

export type PaginatedCompExportRows = {
  rows: CompExportRow[];
  total: number;
  page: number;
  pageCount: number;
};

function requestedPage(value: string | string[] | undefined): number {
  const raw = Array.isArray(value) ? value[0] : value;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 1;
}

function throwQueryError(error: { message: string } | null): void {
  if (error) throw new Error(`Couldn't load compensation export: ${error.message}`);
}

function orderedExportQuery(
  supabase: SupabaseClient,
  reviewCycleId: string,
  count?: "exact",
) {
  return supabase
    .rpc(
      "comp_export_rows",
      { p_review_cycle_id: reviewCycleId },
      count ? { count } : undefined,
    )
    .order("full_name", { ascending: true })
    .order("employee_id", { ascending: true });
}

/** The selected table page, with exact total and out-of-range clamping. */
export async function loadCompExportPage(
  supabase: SupabaseClient,
  reviewCycleId: string,
  pageValue: string | string[] | undefined,
): Promise<PaginatedCompExportRows> {
  const firstPage = requestedPage(pageValue);
  const firstFrom = (firstPage - 1) * COMP_EXPORT_PAGE_SIZE;
  const firstResult = await orderedExportQuery(supabase, reviewCycleId, "exact").range(
    firstFrom,
    firstFrom + COMP_EXPORT_PAGE_SIZE - 1,
  );

  throwQueryError(firstResult.error);

  const total = firstResult.count ?? 0;
  const range = getPageRange(pageValue, total, COMP_EXPORT_PAGE_SIZE);
  let rows = (firstResult.data ?? []) as CompExportRow[];

  // PostgREST still returns the exact count for an empty out-of-range request.
  // Re-read only when clamping changed the requested offset.
  if (range.from !== firstFrom) {
    const clampedResult = await orderedExportQuery(supabase, reviewCycleId).range(
      range.from,
      range.to,
    );
    throwQueryError(clampedResult.error);
    rows = (clampedResult.data ?? []) as CompExportRow[];
  }

  return {
    rows,
    total,
    page: range.page,
    pageCount: range.pageCount,
  };
}

/** Every published plan in a cycle, fetched below the PostgREST max_rows cap. */
export function loadCompleteCompExport(
  supabase: SupabaseClient,
  reviewCycleId: string,
): Promise<CompExportRow[]> {
  return collectRangeBatches(async (from, to) => {
    const result = await orderedExportQuery(supabase, reviewCycleId).range(from, to);
    throwQueryError(result.error);
    return (result.data ?? []) as CompExportRow[];
  }, COMP_EXPORT_BATCH_SIZE);
}

/** Every review cycle for the unpaged selector, fetched below max_rows. */
export function loadCompleteReviewCycles(
  supabase: SupabaseClient,
): Promise<ReviewCycle[]> {
  return collectRangeBatches(async (from, to) => {
    const { data, error } = await supabase
      .from("review_cycle")
      .select(REVIEW_CYCLE_COLUMNS)
      .order("start_date", { ascending: false })
      .order("id", { ascending: true })
      .range(from, to);

    if (error) throw new Error(`Couldn't load review cycles: ${error.message}`);
    return (data ?? []) as ReviewCycle[];
  }, COMP_EXPORT_BATCH_SIZE);
}
