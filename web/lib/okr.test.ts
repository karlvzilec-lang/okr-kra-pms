import assert from "node:assert/strict";
import test from "node:test";
import type { ReviewCycleStatus } from "./types.ts";
import {
  CYCLE_STATUS_ORDER,
  DEGENERATE_RANGE_MESSAGE,
  cycleIsClosed,
  defaultCycleId,
  formatMetricValue,
  nextCycleStatus,
  okrBlockedReason,
  okrErrorMessage,
  okrIsWritable,
  parseMetricValue,
  selectableCycles,
  validateCycleDraft,
  validateKeyResultDraft,
} from "./okr.ts";

test("nextCycleStatus walks the lifecycle one step forward and dead-ends at closed", () => {
  assert.equal(nextCycleStatus("draft"), "active");
  assert.equal(nextCycleStatus("active"), "self_eval");
  assert.equal(nextCycleStatus("self_eval"), "manager_eval");
  assert.equal(nextCycleStatus("manager_eval"), "closed");
  // Closing is final: there is no reopen path for any role.
  assert.equal(nextCycleStatus("closed"), null);

  // Walking the chain from the start reaches exactly the declared order.
  const walked: ReviewCycleStatus[] = ["draft"];
  let cursor = nextCycleStatus("draft");
  while (cursor) {
    walked.push(cursor);
    cursor = nextCycleStatus(cursor);
  }
  assert.deepEqual(walked, CYCLE_STATUS_ORDER);
});

test("nextCycleStatus returns null for a status outside the known order", () => {
  assert.equal(nextCycleStatus("archived" as ReviewCycleStatus), null);
});

test("selectableCycles and defaultCycleId never offer or default to a closed cycle", () => {
  const cycles = [
    { id: "closed-1", status: "closed" as ReviewCycleStatus },
    { id: "draft-1", status: "draft" as ReviewCycleStatus },
    { id: "active-1", status: "active" as ReviewCycleStatus },
  ];

  assert.deepEqual(
    selectableCycles(cycles).map((c) => c.id),
    ["draft-1", "active-1"],
  );

  // Active wins over a future draft cycle inserted for planning.
  assert.equal(defaultCycleId(cycles), "active-1");
  assert.equal(defaultCycleId([{ id: "closed-1", status: "closed" as ReviewCycleStatus }]), "");
  assert.equal(defaultCycleId([]), "");
  assert.equal(
    defaultCycleId([
      { id: "d", status: "draft" as ReviewCycleStatus },
      { id: "m", status: "manager_eval" as ReviewCycleStatus },
    ]),
    "m",
  );
});

test("validateCycleDraft rejects inverted dates before the CHECK constraint does", () => {
  assert.deepEqual(
    validateCycleDraft({ name: "Q1", start_date: "2026-01-01", end_date: "2026-03-31" }),
    [],
  );
  assert.deepEqual(
    validateCycleDraft({ name: "Q1", start_date: "2026-03-31", end_date: "2026-01-01" }),
    ["The end date can't fall before the start date."],
  );
  // Equal dates are a valid single-day cycle, not an inversion.
  assert.deepEqual(
    validateCycleDraft({ name: "Q1", start_date: "2026-01-01", end_date: "2026-01-01" }),
    [],
  );
  assert.equal(
    validateCycleDraft({ name: "   ", start_date: "", end_date: "" }).length,
    3,
  );
});

test("parseMetricValue converts to exact integer hundredths, never float arithmetic", () => {
  assert.deepEqual(parseMetricValue("0.1"), { ok: true, value: 0.1, hundredths: 10 });
  assert.deepEqual(parseMetricValue("0.2"), { ok: true, value: 0.2, hundredths: 20 });
  assert.deepEqual(parseMetricValue("12.34"), { ok: true, value: 12.34, hundredths: 1234 });
  // "1.3" and "1.30" are the same value; hundredths must agree exactly.
  assert.equal(
    (parseMetricValue("1.3") as { hundredths: number }).hundredths,
    (parseMetricValue("1.30") as { hundredths: number }).hundredths,
  );
  // A reduction target below zero is legitimate.
  assert.deepEqual(parseMetricValue("-5.25"), { ok: true, value: -5.25, hundredths: -525 });
  assert.deepEqual(parseMetricValue("0"), { ok: true, value: 0, hundredths: 0 });
});

test("parseMetricValue rejects blanks, junk, and more than two decimal places", () => {
  assert.deepEqual(parseMetricValue("   "), { ok: false, reason: "Enter a number." });
  assert.equal(parseMetricValue("abc").ok, false);
  assert.equal(parseMetricValue("1.234").ok, false);
  assert.equal(parseMetricValue("1e3").ok, false);
  assert.equal(parseMetricValue("--1").ok, false);
  // Surrounding whitespace is trimmed, not treated as junk.
  assert.equal(parseMetricValue("  7.5  ").ok, true);
});

test("formatMetricValue keeps null distinct from zero", () => {
  assert.equal(formatMetricValue(null), "—");
  assert.equal(formatMetricValue(undefined), "—");
  assert.equal(formatMetricValue(0), "0");
  assert.equal(formatMetricValue(12.5), "12.5");
});

test("validateKeyResultDraft blocks a degenerate start/target range that could never score", () => {
  // Same value written two ways: the hundredths comparison still catches it,
  // where float equality on the parsed numbers would be fragile.
  assert.ok(
    validateKeyResultDraft({
      title: "Reduce latency",
      metric_unit: "ms",
      start_value: "1.5",
      target_value: "1.50",
    }).includes(DEGENERATE_RANGE_MESSAGE),
  );

  assert.deepEqual(
    validateKeyResultDraft({
      title: "Reduce latency",
      metric_unit: "ms",
      start_value: "100",
      target_value: "50",
    }),
    [],
  );

  const problems = validateKeyResultDraft({
    title: "  ",
    metric_unit: "ms",
    start_value: "",
    target_value: "nope",
  });
  assert.equal(problems.length, 3);
  assert.ok(problems.some((p) => p.startsWith("Start value:")));
  assert.ok(problems.some((p) => p.startsWith("Target value:")));
});

test("okrIsWritable and okrBlockedReason freeze everything under a closed cycle", () => {
  assert.equal(cycleIsClosed("closed"), true);
  assert.equal(cycleIsClosed("active"), false);
  assert.equal(cycleIsClosed(null), false);

  assert.equal(okrIsWritable("active"), true);
  assert.equal(okrIsWritable(null), true);
  assert.equal(okrIsWritable("closed"), false);

  assert.equal(okrBlockedReason("active"), null);
  const reason = okrBlockedReason("closed");
  assert.ok(reason && reason.includes("no path to reopen"));
});

test("okrErrorMessage keeps lifecycle (55000) and permission (42501) failures distinguishable", () => {
  // Retrying as HR cannot help with 55000, so its fallback must not suggest it.
  const lifecycle = okrErrorMessage({ code: "55000" });
  assert.ok(lifecycle && lifecycle.includes("forward one step at a time"));
  assert.ok(lifecycle && !lifecycle.includes("permission"));

  // 42501 is the opposite: a different account legitimately could succeed.
  const denied = okrErrorMessage({ code: "42501" });
  assert.ok(denied && denied.includes("only HR can override"));

  assert.notEqual(lifecycle, denied);
});

test("okrErrorMessage surfaces server wording and never swallows unknown codes", () => {
  assert.equal(okrErrorMessage(null), null);
  // A server-supplied message beats the generic fallback.
  assert.equal(okrErrorMessage({ code: "55000", message: "Cycle is closed." }), "Cycle is closed.");
  // 22023/23503 are always reworded — the raw server text is unhelpful there.
  assert.equal(
    okrErrorMessage({ code: "22023", message: "raw" }),
    "That record no longer exists. Refresh and try again.",
  );
  // A silent RLS refusal returns zero rows, and PGRST116 is the only signal.
  const blocked = okrErrorMessage({ code: "PGRST116" });
  assert.ok(blocked && blocked.includes("rejected"));
  // Unrecognised codes fall through to the raw message rather than vanishing.
  assert.equal(okrErrorMessage({ code: "XX999", message: "disk on fire" }), "disk on fire");
  assert.equal(okrErrorMessage({ code: "XX999" }), "Something went wrong. Try again.");
});
