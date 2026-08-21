import assert from "node:assert/strict";
import test from "node:test";
import {
  PASSWORD_ROTATION_DAYS,
  isPasswordExpired,
  passwordChecks,
  passwordMeetsPolicy,
} from "./password.ts";

const DAY_MS = 24 * 60 * 60 * 1000;

test("passwordChecks reports each policy rule independently", () => {
  const checks = passwordChecks("Sh0rt!");
  assert.deepEqual(
    checks.map((c) => c.passed),
    // 6 chars: length fails, the other four rules pass.
    [false, true, true, true, true],
  );
  assert.equal(checks.length, 5);
  assert.equal(checks[0].label, "At least 10 characters");
});

test("passwordMeetsPolicy requires all five rules together", () => {
  assert.equal(passwordMeetsPolicy("Str0ng!Pass1"), true);
  assert.equal(passwordMeetsPolicy("nouppercase1!"), false);
  assert.equal(passwordMeetsPolicy("NOLOWERCASE1!"), false);
  assert.equal(passwordMeetsPolicy("NoDigitsHere!"), false);
  assert.equal(passwordMeetsPolicy("NoSymbols123"), false);
  assert.equal(passwordMeetsPolicy(""), false);
});

test("passwordMeetsPolicy counts characters, not bytes, at the length boundary", () => {
  // Exactly 10 characters passes; 9 does not. `>=` not `>`.
  assert.equal(passwordMeetsPolicy("Ab1!efghij"), true);
  assert.equal(passwordMeetsPolicy("Ab1!efghi"), false);
  // A space counts as the required symbol.
  assert.equal(passwordMeetsPolicy("Ab1 efghij"), true);
});

test("isPasswordExpired treats a never-set change date as already expired", () => {
  // Fail closed: an unknown rotation date must force a reset, not skip one.
  assert.equal(isPasswordExpired(null), true);
});

test("isPasswordExpired flips exactly at the rotation-day boundary", (t) => {
  // Time is frozen: without this, the wall clock advances by a millisecond or
  // two between computing the timestamp and isPasswordExpired reading
  // Date.now(), which pushes the "exactly 60 days" case a hair over the line
  // and makes the boundary assertion flaky rather than exact.
  const frozen = Date.parse("2026-06-01T12:00:00.000Z");
  t.mock.timers.enable({ apis: ["Date"], now: frozen });

  const exactly = new Date(frozen - PASSWORD_ROTATION_DAYS * DAY_MS).toISOString();
  const oneMsPast = new Date(frozen - PASSWORD_ROTATION_DAYS * DAY_MS - 1).toISOString();
  const oneMsShort = new Date(frozen - PASSWORD_ROTATION_DAYS * DAY_MS + 1).toISOString();

  // Strictly greater-than: day 60 to the millisecond is still valid, one
  // millisecond older is expired.
  assert.equal(isPasswordExpired(exactly), false);
  assert.equal(isPasswordExpired(oneMsPast), true);
  assert.equal(isPasswordExpired(oneMsShort), false);
});

test("isPasswordExpired accepts a fresh password and rejects a long-stale one", () => {
  assert.equal(isPasswordExpired(new Date().toISOString()), false);
  assert.equal(isPasswordExpired(new Date(Date.now() - 365 * DAY_MS).toISOString()), true);
  // A future timestamp (clock skew) is not expired.
  assert.equal(isPasswordExpired(new Date(Date.now() + DAY_MS).toISOString()), false);
});

test("isPasswordExpired fails closed on an unparseable timestamp", () => {
  // NaN comparisons are always false, so a garbage date would otherwise slip
  // past the age check and read as NOT expired. isPasswordExpired guards
  // this explicitly so a malformed value forces rotation, same as null.
  assert.equal(isPasswordExpired("not-a-date"), true);
});

test("PASSWORD_ROTATION_DAYS is the single source of the 60-day policy", () => {
  assert.equal(PASSWORD_ROTATION_DAYS, 60);
});
