import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { PAGE_SIZE } from "./pagination.ts";
import { loadAuditLogPage, type AuditLogRow } from "./audit-log-queries.ts";

const row: AuditLogRow = {
  id: "00000000-0000-0000-0000-000000000001",
  occurred_at: "2026-08-22T10:00:00.000Z",
  event_type: "profile.manager_changed",
  actor_id: "00000000-0000-0000-0000-000000000002",
  actor_name: "HR Admin",
  target_type: "profile",
  target_id: "00000000-0000-0000-0000-000000000003",
  target_label: "Employee One",
  summary: "Employee One: line manager changed from A to B",
  old_values: { manager_name: "A" },
  new_values: { manager_name: "B" },
};

type Result = { data: AuditLogRow[]; count: number | null };

function auditLogClient(results: Result[]) {
  const calls = {
    tables: [] as string[],
    selects: [] as Array<{ columns: string; options: { count: string } }>,
    orders: [] as Array<{ column: string; options: { ascending: boolean } }>,
    ranges: [] as Array<{ from: number; to: number }>,
  };

  const query = {
    select(columns: string, options: { count: string }) {
      calls.selects.push({ columns, options });
      return query;
    },
    order(column: string, options: { ascending: boolean }) {
      calls.orders.push({ column, options });
      return query;
    },
    async range(from: number, to: number) {
      calls.ranges.push({ from, to });
      const result = results.shift();
      assert.ok(result, "the loader made more requests than the test supplied");
      return result;
    },
  };

  const client = {
    from(table: string) {
      calls.tables.push(table);
      return query;
    },
  } as unknown as SupabaseClient;

  return { client, calls };
}

test("loadAuditLogPage selects the full contract with exact count and index-matching order", async () => {
  const { client, calls } = auditLogClient([{ data: [row], count: PAGE_SIZE + 1 }]);

  const result = await loadAuditLogPage(client, 2);

  assert.deepEqual(calls.tables, ["audit_log"]);
  assert.deepEqual(calls.selects, [
    {
      columns:
        "id, occurred_at, event_type, actor_id, actor_name, target_type, target_id, target_label, summary, old_values, new_values",
      options: { count: "exact" },
    },
  ]);
  assert.deepEqual(calls.orders, [
    { column: "occurred_at", options: { ascending: false } },
    { column: "id", options: { ascending: false } },
  ]);
  assert.deepEqual(calls.ranges, [{ from: PAGE_SIZE, to: PAGE_SIZE * 2 - 1 }]);
  assert.deepEqual(result, { rows: [row], total: PAGE_SIZE + 1, page: 2, pageCount: 2 });
});

test("loadAuditLogPage refetches the last real page when the requested page is stale", async () => {
  const { client, calls } = auditLogClient([
    { data: [], count: PAGE_SIZE + 1 },
    { data: [row], count: PAGE_SIZE + 1 },
  ]);

  const result = await loadAuditLogPage(client, 99);

  assert.deepEqual(calls.ranges, [
    { from: PAGE_SIZE * 98, to: PAGE_SIZE * 99 - 1 },
    { from: PAGE_SIZE, to: PAGE_SIZE * 2 - 1 },
  ]);
  assert.deepEqual(result.rows, [row]);
  assert.equal(result.page, 2);
});
