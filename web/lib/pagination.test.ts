import assert from "node:assert/strict";
import test from "node:test";
import {
  PAGE_SIZE,
  clampPage,
  emptyPage,
  pageCountFor,
  paginated,
  parsePageParam,
  rangeFor,
  refetchIfClamped,
} from "./pagination.ts";

test("parsePageParam reads only positive integers, defaulting everything else to page 1", () => {
  assert.equal(parsePageParam("3"), 3);
  assert.equal(parsePageParam(undefined), 1);
  assert.equal(parsePageParam(""), 1);
  assert.equal(parsePageParam("abc"), 1);
  assert.equal(parsePageParam("0"), 1);
  assert.equal(parsePageParam("-3"), 1);
  assert.equal(parsePageParam("2.5"), 1);
  // Next hands over a string[] for a repeated ?page= param; the first wins.
  assert.equal(parsePageParam(["4", "9"]), 4);
});

test("pageCountFor reports at least one page so an empty list reads as 'page 1 of 1'", () => {
  assert.equal(pageCountFor(0), 1);
  assert.equal(pageCountFor(1), 1);
  assert.equal(pageCountFor(PAGE_SIZE), 1);
  // The boundary that matters: one row past a full page starts a second page.
  assert.equal(pageCountFor(PAGE_SIZE + 1), 2);
  assert.equal(pageCountFor(PAGE_SIZE * 2), 2);
});

test("clampPage pins a stale bookmark into the range that actually exists", () => {
  assert.equal(clampPage(99, PAGE_SIZE * 2), 2);
  assert.equal(clampPage(2, PAGE_SIZE * 2), 2);
  assert.equal(clampPage(0, PAGE_SIZE * 2), 1);
  // Rows deleted down to nothing: page 1 of 1, not page 0.
  assert.equal(clampPage(5, 0), 1);
});

test("rangeFor returns an inclusive [from, to] pair, not a JS-slice half-open one", () => {
  // PostgREST .range() is inclusive at BOTH ends: page 1 of 25 is (0, 24).
  assert.deepEqual(rangeFor(1), { from: 0, to: PAGE_SIZE - 1 });
  assert.deepEqual(rangeFor(2), { from: PAGE_SIZE, to: PAGE_SIZE * 2 - 1 });
  // Adjacent pages must abut exactly — no gap, no overlap.
  assert.equal(rangeFor(2).from, rangeFor(1).to + 1);
  assert.equal(rangeFor(3).to - rangeFor(3).from + 1, PAGE_SIZE);
});

test("paginated clamps the reported page while returning the rows it was handed", () => {
  const rows = ["a", "b"];
  assert.deepEqual(paginated(rows, PAGE_SIZE + 2, 99), {
    rows,
    total: PAGE_SIZE + 2,
    page: 2,
    pageCount: 2,
  });
});

test("emptyPage is a valid one-page result rather than a zero-page one", () => {
  assert.deepEqual(emptyPage(), { rows: [], total: 0, page: 1, pageCount: 1 });
});

test("refetchIfClamped re-queries once when a past-the-end page came back empty", async () => {
  const asked: number[] = [];
  const result = await refetchIfClamped<string>([], PAGE_SIZE + 1, 99, async (page) => {
    asked.push(page);
    return paginated(["real-row"], PAGE_SIZE + 1, page);
  });

  // Clamped to the last real page (2), refetched exactly once, no recursion.
  assert.deepEqual(asked, [2]);
  assert.deepEqual(result.rows, ["real-row"]);
  assert.equal(result.page, 2);
  assert.equal(result.pageCount, 2);
});

test("refetchIfClamped does not refetch on the normal path or on a genuinely empty table", async () => {
  let calls = 0;
  const refetch = async (page: number) => {
    calls += 1;
    return paginated<string>([], 0, page);
  };

  // In-range page with rows: no extra round trip.
  const inRange = await refetchIfClamped(["a"], PAGE_SIZE + 1, 1, refetch);
  assert.equal(calls, 0);
  assert.deepEqual(inRange.rows, ["a"]);

  // total === 0 is guarded, so the recursion cannot spin on an empty table.
  const empty = await refetchIfClamped<string>([], 0, 99, refetch);
  assert.equal(calls, 0);
  assert.deepEqual(empty, { rows: [], total: 0, page: 1, pageCount: 1 });
});
