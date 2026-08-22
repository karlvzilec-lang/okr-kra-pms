import type { SupabaseClient } from "@supabase/supabase-js";
import { rangeFor, refetchIfClamped, type Paginated } from "./pagination.ts";

export type AuditEventType =
  | "profile.manager_changed"
  | "profile.hr_admin_changed"
  | "matrix_scope.granted"
  | "matrix_scope.revoked"
  | "calibration.plan_unpublished"
  | "calibration.session_unfinalized";

export type AuditLogRow = {
  id: string;
  occurred_at: string;
  event_type: AuditEventType;
  actor_id: string | null;
  actor_name: string;
  target_type: string;
  target_id: string | null;
  target_label: string;
  summary: string;
  old_values: Record<string, unknown>;
  new_values: Record<string, unknown>;
};

const AUDIT_LOG_COLUMNS =
  "id, occurred_at, event_type, actor_id, actor_name, target_type, target_id, target_label, summary, old_values, new_values";

/** Load the immutable activity ledger in the same order as its paging index. */
export async function loadAuditLogPage(
  supabase: SupabaseClient,
  page: number,
): Promise<Paginated<AuditLogRow>> {
  const { from, to } = rangeFor(page);

  const { data, count } = await supabase
    .from("audit_log")
    .select(AUDIT_LOG_COLUMNS, { count: "exact" })
    .order("occurred_at", { ascending: false })
    .order("id", { ascending: false })
    .range(from, to);

  const rows = (data ?? []) as AuditLogRow[];
  const total = count ?? 0;

  return refetchIfClamped(rows, total, page, (target) => loadAuditLogPage(supabase, target));
}
