import assert from "node:assert/strict";
import test from "node:test";
import {
  buildCompExportCsv,
  collectRangeBatches,
  compExportFilename,
  getPageRange,
} from "./comp-export.ts";
import type { CompExportRow } from "./types.ts";

const dara: CompExportRow = {
  employee_id: "11111111-1111-4111-8111-000000000004",
  full_name: "Dara Sok",
  email: "dara.sok@example.com",
  manager_full_name: "Ana Kim",
  overall_rating_scale_max: 5,
  final_score: 3.2,
  band_label: "Meets Expectations",
  published_at: "2026-08-14T12:30:00+00:00",
};

test("collectRangeBatches requests bounded inclusive ranges until a short batch", async () => {
  const source = ["a", "b", "c", "d", "e"];
  const requestedRanges: Array<[number, number]> = [];

  const rows = await collectRangeBatches(async (from, to) => {
    requestedRanges.push([from, to]);
    return source.slice(from, to + 1);
  }, 2);

  assert.deepEqual(rows, source);
  assert.deepEqual(requestedRanges, [
    [0, 1],
    [2, 3],
    [4, 5],
  ]);
});

test("collectRangeBatches makes a final empty request for an exact batch multiple", async () => {
  const source = ["a", "b", "c", "d"];
  const requestedRanges: Array<[number, number]> = [];

  const rows = await collectRangeBatches(async (from, to) => {
    requestedRanges.push([from, to]);
    return source.slice(from, to + 1);
  }, 2);

  assert.deepEqual(rows, source);
  assert.deepEqual(requestedRanges, [
    [0, 1],
    [2, 3],
    [4, 5],
  ]);
});

test("getPageRange clamps malformed, negative, and out-of-range pages", () => {
  assert.deepEqual(getPageRange("not-a-page", 61, 25), {
    page: 1,
    pageCount: 3,
    from: 0,
    to: 24,
  });
  assert.deepEqual(getPageRange("-4", 61, 25), {
    page: 1,
    pageCount: 3,
    from: 0,
    to: 24,
  });
  assert.deepEqual(getPageRange("99", 61, 25), {
    page: 3,
    pageCount: 3,
    from: 50,
    to: 60,
  });
  assert.deepEqual(getPageRange("4", 0, 25), {
    page: 1,
    pageCount: 1,
    from: 0,
    to: 24,
  });
});

test("buildCompExportCsv emits every field and escapes spreadsheet-active text", () => {
  const csv = buildCompExportCsv([
    dara,
    {
      ...dara,
      employee_id: "11111111-1111-4111-8111-000000000008",
      full_name: "Long, Vuthy",
      email: "=HYPERLINK(\"https://example.test\")",
      manager_full_name: null,
      final_score: 4,
      band_label: null,
    },
  ]);

  assert.equal(
    csv,
    [
      '"employee_id","full_name","email","manager_full_name","overall_rating_scale_max","final_score","band_label","published_at"',
      '"11111111-1111-4111-8111-000000000004","Dara Sok","dara.sok@example.com","Ana Kim","5","3.200","Meets Expectations","2026-08-14T12:30:00+00:00"',
      '"11111111-1111-4111-8111-000000000008","Long, Vuthy","\'=HYPERLINK(""https://example.test"")","","5","4.000","","2026-08-14T12:30:00+00:00"',
    ].join("\r\n"),
  );
});

test("buildCompExportCsv neutralizes every spreadsheet-active leading character", () => {
  const dangerous = ["=1+1", "+1+1", "-1+1", "@SUM(A1)", "\t=1+1", "\r=1+1", "\n=1+1"];
  const rows = dangerous.map((email, index) => ({
    ...dara,
    employee_id: `11111111-1111-4111-8111-${String(index).padStart(12, "0")}`,
    email,
  }));

  const csv = buildCompExportCsv(rows);

  for (const value of dangerous) {
    const escaped = `'${value}`.replaceAll('"', '""');
    assert.match(csv, new RegExp(`"${escaped.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`));
  }
});

test("compExportFilename produces a filesystem-safe cycle-specific name", () => {
  assert.equal(compExportFilename("FY2026 / Annual Review"), "fy2026-annual-review-comp-export.csv");
  assert.equal(compExportFilename("  "), "review-cycle-comp-export.csv");
});
