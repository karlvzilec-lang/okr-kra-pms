// Shared, framework-free helpers for review-cycle management and OKR
// authoring. Everything here is pure so the cycle board, the objective list
// and the check-in form agree on what "valid" and "allowed" mean before
// anything reaches the database.
//
// Three rules in this file are load-bearing and are NOT stylistic choices:
//
//   1. Numeric metric values are compared as integers in hundredths, the same
//      discipline lib/goals.ts applies to numeric(6,2) weights. Float equality
//      (0.1 + 0.2 !== 0.3) would let this UI call a degenerate start/target
//      range "fine" on a pair the database then scores as null, or vice versa.
//
//   2. Lifecycle-order violations and permission denials are DIFFERENT errors
//      and must stay distinguishable. 55000 means "the object's state doesn't
//      allow this, regardless of who you are" — retrying as HR will not help.
//      42501 means "you lack permission" — a different account might succeed.
//      Collapsing them into one generic failure would tell an HR admin to go
//      find someone with more rights to reopen a closed cycle, which no one
//      has, because there is no reopen path at all.
//
//   3. A closed cycle freezes every OKR write in the database, HR included.
//      The gates below exist so the UI doesn't render a form whose save is
//      already guaranteed to fail, not as the security boundary itself.

import type { ReviewCycleStatus } from "@/lib/types";

// ---------------------------------------------------------------------------
// Cycle lifecycle
// ---------------------------------------------------------------------------

/** The only path a cycle may walk, one step at a time, forward only. */
export const CYCLE_STATUS_ORDER: ReviewCycleStatus[] = [
  "draft",
  "active",
  "self_eval",
  "manager_eval",
  "closed",
];

export const CYCLE_STATUS_LABEL: Record<ReviewCycleStatus, string> = {
  draft: "Draft",
  active: "Active",
  self_eval: "Self evaluation",
  manager_eval: "Manager evaluation",
  closed: "Closed",
};

/**
 * The single status a cycle may move to next, or null when it's at the end.
 * There is no skip, no backward step, and no reopening a closed cycle — the
 * database rejects all three with 55000, so the UI only ever offers the one
 * transition that can actually succeed.
 */
export function nextCycleStatus(status: ReviewCycleStatus): ReviewCycleStatus | null {
  const index = CYCLE_STATUS_ORDER.indexOf(status);
  if (index < 0 || index === CYCLE_STATUS_ORDER.length - 1) return null;
  return CYCLE_STATUS_ORDER[index + 1];
}

/** A closed cycle is frozen: no objective, key result or check-in may change. */
export function cycleIsClosed(status: ReviewCycleStatus | null | undefined): boolean {
  return status === "closed";
}

/**
 * Cycles an objective may be created against. Closed cycles are excluded
 * entirely — the database would reject the insert with 55000, and offering a
 * dead option is worse than not offering it.
 */
export function selectableCycles<T extends { status: ReviewCycleStatus }>(cycles: T[]): T[] {
  return cycles.filter((cycle) => !cycleIsClosed(cycle.status));
}

/**
 * Which cycle the objective form should default to. The currently active
 * cycle wins over "most recent by date" on purpose: a future draft cycle
 * inserted for planning must not silently become the default target for
 * everyone's new objectives.
 */
export function defaultCycleId<T extends { id: string; status: ReviewCycleStatus }>(
  cycles: T[],
): string {
  const selectable = selectableCycles(cycles);
  if (selectable.length === 0) return "";

  const preference: ReviewCycleStatus[] = ["active", "self_eval", "manager_eval", "draft"];
  for (const status of preference) {
    const match = selectable.find((cycle) => cycle.status === status);
    if (match) return match.id;
  }
  return selectable[0].id;
}

export type CycleDraft = {
  name: string;
  start_date: string;
  end_date: string;
};

/**
 * Validate a new cycle before it's sent. Inverted dates are a CHECK constraint
 * (review_cycle_dates_ordered, 23514), so catching them here turns a raw
 * constraint name into a sentence the person filling the form can act on.
 */
export function validateCycleDraft(draft: CycleDraft): string[] {
  const problems: string[] = [];

  if (draft.name.trim().length === 0) {
    problems.push("Give the cycle a name so it's identifiable later.");
  }
  if (!draft.start_date) {
    problems.push("Pick a start date.");
  }
  if (!draft.end_date) {
    problems.push("Pick an end date.");
  }
  if (draft.start_date && draft.end_date && draft.end_date < draft.start_date) {
    problems.push("The end date can't fall before the start date.");
  }

  return problems;
}

// ---------------------------------------------------------------------------
// Exact decimal metric values
// ---------------------------------------------------------------------------

/** Two decimal places, matching lib/goals.ts's treatment of numeric columns. */
const VALUE_SCALE = 100;

export type ValueParse =
  | { ok: true; value: number; hundredths: number }
  | { ok: false; reason: string };

/**
 * Parse a user-typed metric value (start, target, current) into both the
 * number PostgREST should receive and its exact integer-hundredths form.
 * Negatives are allowed — a key result can legitimately track a reduction
 * from a positive baseline down through zero.
 */
export function parseMetricValue(raw: string): ValueParse {
  const text = raw.trim();
  if (text.length === 0) {
    return { ok: false, reason: "Enter a number." };
  }
  if (!/^-?\d{1,12}(\.\d{1,2})?$/.test(text)) {
    return { ok: false, reason: "Values are numbers with at most two decimal places." };
  }

  const negative = text.startsWith("-");
  const [whole, fraction = ""] = text.replace("-", "").split(".");
  const padded = (fraction + "00").slice(0, 2);
  const magnitude = Number(whole) * VALUE_SCALE + Number(padded);

  if (!Number.isSafeInteger(magnitude)) {
    return { ok: false, reason: "That number is too large." };
  }

  const hundredths = negative ? -magnitude : magnitude;
  return { ok: true, value: hundredths / VALUE_SCALE, hundredths };
}

/** Render a nullable numeric value for display without turning null into 0. */
export function formatMetricValue(value: number | null | undefined): string {
  return value === null || value === undefined ? "—" : String(value);
}

/**
 * A key result whose start equals its target has no meaningful progress
 * ratio, so recompute_key_result_score stores score = null forever. That's a
 * silent dead end for the owner, so the form blocks it with an explanation
 * rather than accepting a key result that can never score.
 */
export const DEGENERATE_RANGE_MESSAGE =
  "Start and target are the same value, so progress can't be scored. Set a target that differs from the start value.";

export type KeyResultDraft = {
  title: string;
  metric_unit: string;
  start_value: string;
  target_value: string;
};

export function validateKeyResultDraft(draft: KeyResultDraft): string[] {
  const problems: string[] = [];

  if (draft.title.trim().length === 0) {
    problems.push("Give the key result a title.");
  }

  const start = parseMetricValue(draft.start_value);
  const target = parseMetricValue(draft.target_value);

  if (!start.ok) problems.push(`Start value: ${start.reason}`);
  if (!target.ok) problems.push(`Target value: ${target.reason}`);

  // Integer-hundredths comparison, never float equality.
  if (start.ok && target.ok && start.hundredths === target.hundredths) {
    problems.push(DEGENERATE_RANGE_MESSAGE);
  }

  return problems;
}

// ---------------------------------------------------------------------------
// Write gates
// ---------------------------------------------------------------------------

/**
 * Can this objective's owner still write to it? A closed cycle freezes the
 * whole OKR tree beneath it — objectives, key results and check-ins alike —
 * for every role including HR. Checked up-front so the page renders read-only
 * instead of offering a form whose save is already doomed.
 */
export function okrIsWritable(cycleStatus: ReviewCycleStatus | null | undefined): boolean {
  return !cycleIsClosed(cycleStatus);
}

/** Why the OKR surface is read-only right now, or null when it isn't. */
export function okrBlockedReason(
  cycleStatus: ReviewCycleStatus | null | undefined,
): string | null {
  if (okrIsWritable(cycleStatus)) return null;
  return "This review cycle is closed. Objectives, key results and check-ins are frozen — closing a cycle is final, and there's no path to reopen it.";
}

// ---------------------------------------------------------------------------
// Error surfacing
// ---------------------------------------------------------------------------

type PostgrestLikeError = {
  code?: string | null;
  message?: string | null;
};

/**
 * Map the SQLSTATEs the review-cycle and OKR guards raise onto plain language.
 *
 * The 55000 / 42501 split is the important part and is deliberate:
 *
 *   55000  object_not_in_prerequisite_state — a lifecycle-order violation
 *          (skipping a status, stepping backward, reopening a closed cycle) or
 *          a write against a closed cycle. No role can do this, so the message
 *          must not suggest asking someone with more permissions.
 *
 *   42501  insufficient_privilege — a genuine RLS, ownership or column-scope
 *          denial (writing someone else's objective, setting current_value or
 *          score_override by hand). A different account legitimately could.
 *
 * Unrecognised codes fall through to the raw message rather than being
 * swallowed behind a generic failure.
 */
export function okrErrorMessage(error: PostgrestLikeError | null): string | null {
  if (!error) return null;

  switch (error.code) {
    case "55000":
      return (
        error.message ??
        "That isn't allowed at this point in the cycle's lifecycle. Cycles move forward one step at a time and a closed cycle is frozen for everyone."
      );
    case "42501":
      return (
        error.message ??
        "You aren't allowed to change that. Progress values are set by checking in, not by editing them directly, and only HR can override a score."
      );
    case "23514":
      return error.message ?? "That value falls outside what the database allows.";
    case "22023":
      return "That record no longer exists. Refresh and try again.";
    case "23503":
      return "That references a record that no longer exists. Refresh and try again.";
    case "PGRST116":
      // Zero rows came back from a write that expected one. RLS blocks are
      // silent — no exception, no rows — so this is the only signal that the
      // row was invisible or the write was refused outright.
      return "That change was rejected. You may no longer have permission to make it, or someone else moved this record on first.";
    default:
      return error.message ?? "Something went wrong. Try again.";
  }
}

/**
 * Shared wording for the "the write succeeded but no row came back" case,
 * which is exactly what an RLS-blocked UPDATE looks like from the client.
 */
export const OKR_BLOCKED_MESSAGE =
  "That change didn't go through. The database refused it — refresh the page to see the current state.";
