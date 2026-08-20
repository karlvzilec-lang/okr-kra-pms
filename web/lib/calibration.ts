// Types and pure helpers for the HR calibration facilitator board.
//
// The three RPCs this file describes (calibration_session_detail,
// calibration_eligible_plans, create_calibration_session_with_bands) are locked
// by the Gate 1 ruling and land in migration 0016. Everything here is written
// against that contract.

export type CalibrationSessionStatus = "open" | "finalized";

/** One row of the session index (read directly off calibration_session). */
export type CalibrationSessionListItem = {
  id: string;
  name: string;
  status: CalibrationSessionStatus;
  review_cycle_id: string;
  review_cycle_name: string | null;
  participant_count: number;
  created_at: string;
};

export type CalibrationBand = {
  id: string;
  label: string;
  min_score: number;
  max_score: number;
  sort_order: number;
};

/**
 * A plan's place in one session.
 *
 * `band_id` is emitted by the RPC verbatim, including `null` (ruling #5): a
 * band can be deleted out from under a participant via the still-open RLS gap
 * documented in the ruling, and the board must render such a row in the
 * "Unassigned" column rather than silently dropping it.
 */
export type CalibrationParticipant = {
  id: string;
  employee_goal_plan_id: string;
  employee_id: string;
  employee_full_name: string;
  employee_email: string;
  /** Resolved via review_participant (role = 'line_manager'), not profiles.manager_id. */
  manager_full_name: string | null;
  original_score: number;
  calibrated_score: number | null;
  band_id: string | null;
  facilitator_note: string | null;
  overall_rating_scale_max: number;
  published_at: string | null;
  /**
   * Latest-reversal metadata for this participant's plan (migration 0022).
   *
   * Written atomically as a triple by unpublish_employee_goal_plan, and
   * collectively null until the plan has been unpublished at least once.
   * Deliberately *latest*, not history — a second unpublish overwrites the
   * first. A generic audit trail is out of scope for this round.
   */
  last_unpublished_at: string | null;
  /** profiles.id of the HR admin who unpublished. */
  last_unpublished_by: string | null;
  last_unpublish_reason: string | null;
};

export type CalibrationSessionDetail = {
  session: {
    id: string;
    name: string;
    status: CalibrationSessionStatus;
    review_cycle_id: string;
    review_cycle_name: string | null;
    created_at: string;
    updated_at: string;
    /**
     * Latest-reversal metadata for the session (migration 0022). Written
     * atomically as a triple by unfinalize_calibration_session; collectively
     * null until the session has been un-finalized at least once. A session
     * that was un-finalized and then re-finalized keeps this triple — it
     * describes the most recent reversal, not the current status.
     */
    last_unfinalized_at: string | null;
    /** profiles.id of the HR admin who un-finalized. */
    last_unfinalized_by: string | null;
    last_unfinalize_reason: string | null;
  };
  bands: CalibrationBand[];
  participants: CalibrationParticipant[];
};

export type EligiblePlan = {
  plan_id: string;
  employee_id: string;
  employee_full_name: string;
  employee_email: string;
  manager_score: number;
};

export type ReviewCycleOption = {
  id: string;
  name: string;
};

/** A band-draft row in the new-session form, before it becomes a real band. */
export type BandDraft = {
  /** Client-only key; the DB assigns real ids. */
  key: string;
  label: string;
  min_score: string;
  max_score: string;
};

/** The payload shape create_calibration_session_with_bands expects in p_bands. */
export type BandInput = {
  label: string;
  min_score: number;
  max_score: number;
  sort_order: number;
};

// ---------------------------------------------------------------------------
// Board grouping
// ---------------------------------------------------------------------------

/** Sentinel column id for participants whose band_id doesn't resolve. */
export const UNASSIGNED_COLUMN_ID = "__unassigned__";

export type BoardColumn = {
  id: string;
  label: string;
  /** null for the Unassigned pseudo-column — it isn't a real band. */
  band: CalibrationBand | null;
  participants: CalibrationParticipant[];
};

/**
 * Group participants into one column per band, in sort_order, plus a trailing
 * "Unassigned" column for any participant whose band_id is null or points at a
 * band that isn't in this session's band list (ruling #5). The Unassigned
 * column is only rendered when it has rows.
 */
export function buildBoardColumns(
  bands: CalibrationBand[],
  participants: CalibrationParticipant[],
): BoardColumn[] {
  const ordered = [...bands].sort(
    (a, b) => a.sort_order - b.sort_order || a.label.localeCompare(b.label),
  );

  const columns = new Map<string, BoardColumn>(
    ordered.map((band) => [
      band.id,
      { id: band.id, label: band.label, band, participants: [] },
    ]),
  );

  const unassigned: CalibrationParticipant[] = [];

  for (const participant of participants) {
    const column =
      participant.band_id === null ? undefined : columns.get(participant.band_id);
    if (column) {
      column.participants.push(participant);
    } else {
      unassigned.push(participant);
    }
  }

  const result = ordered.map((band) => columns.get(band.id)!);

  if (unassigned.length > 0) {
    result.push({
      id: UNASSIGNED_COLUMN_ID,
      label: "Unassigned",
      band: null,
      participants: unassigned,
    });
  }

  return result;
}

/**
 * The score a participant currently sits at. calibrated_score is nullable in
 * the schema; add_plan_to_calibration_session always seeds it from
 * original_score, so a null here means someone reached the row outside the
 * functions — fall back to the snapshot rather than rendering a blank card.
 */
export function effectiveScore(participant: CalibrationParticipant): number {
  return participant.calibrated_score ?? participant.original_score;
}

/** Signed delta from the pre-calibration snapshot, or null when unchanged. */
export function scoreDelta(participant: CalibrationParticipant): number | null {
  const delta = effectiveScore(participant) - participant.original_score;
  // numeric(6,3) round-trips through JSON as a float; treat sub-milli noise as
  // "no change" so an untouched participant never shows a +0.000 chip.
  if (Math.abs(delta) < 0.0005) return null;
  return delta;
}

export function formatScore(score: number | null): string {
  return score === null ? "—" : score.toFixed(3);
}

export function formatDelta(delta: number): string {
  return `${delta > 0 ? "+" : "−"}${Math.abs(delta).toFixed(3)}`;
}

// ---------------------------------------------------------------------------
// Band-draft validation (client-side UX only)
// ---------------------------------------------------------------------------

/**
 * Pre-submit validation for the new-session form. The real guarantees live in
 * the DB (calibration_band_range_ordered check + calibration_band_no_overlap
 * exclusion constraint); this exists so HR sees a readable message instead of a
 * raw constraint violation on a typo.
 */
export function validateBandDrafts(drafts: BandDraft[]): string[] {
  const errors: string[] = [];

  if (drafts.length === 0) {
    errors.push("Add at least one band — a session with no bands can't accept any plans.");
    return errors;
  }

  const parsed: { label: string; min: number; max: number; index: number }[] = [];

  drafts.forEach((draft, index) => {
    const position = index + 1;
    const label = draft.label.trim();
    const min = Number(draft.min_score);
    const max = Number(draft.max_score);

    if (label.length === 0) {
      errors.push(`Band ${position} needs a label.`);
    }
    if (draft.min_score.trim() === "" || Number.isNaN(min)) {
      errors.push(`Band ${position} ("${label || "untitled"}") needs a numeric minimum score.`);
      return;
    }
    if (draft.max_score.trim() === "" || Number.isNaN(max)) {
      errors.push(`Band ${position} ("${label || "untitled"}") needs a numeric maximum score.`);
      return;
    }
    if (min < 0) {
      errors.push(`Band ${position} ("${label || "untitled"}") can't have a negative minimum.`);
    }
    if (max <= min) {
      errors.push(
        `Band ${position} ("${label || "untitled"}") must have a maximum above its minimum.`,
      );
    }

    parsed.push({ label, min, max, index });
  });

  // Overlap check mirrors the DB's half-open [min, max) exclusion constraint.
  const sorted = [...parsed].sort((a, b) => a.min - b.min);
  for (let i = 1; i < sorted.length; i += 1) {
    const previous = sorted[i - 1];
    const current = sorted[i];
    if (current.min < previous.max) {
      errors.push(
        `Bands "${previous.label || "untitled"}" and "${current.label || "untitled"}" overlap — ranges are half-open [min, max), so one band's maximum may equal the next one's minimum but not exceed it.`,
      );
    }
  }

  const labels = new Set<string>();
  for (const band of parsed) {
    const key = band.label.toLowerCase();
    if (key.length === 0) continue;
    if (labels.has(key)) {
      errors.push(`Two bands are both labelled "${band.label}" — give each one a distinct name.`);
    }
    labels.add(key);
  }

  return errors;
}

/** Turn validated drafts into the p_bands payload, sort_order by ascending min. */
export function bandDraftsToInput(drafts: BandDraft[]): BandInput[] {
  return [...drafts]
    .map((draft) => ({
      label: draft.label.trim(),
      min_score: Number(draft.min_score),
      max_score: Number(draft.max_score),
    }))
    .sort((a, b) => a.min_score - b.min_score)
    .map((band, index) => ({ ...band, sort_order: index }));
}

/**
 * Which band a score lands in under the DB's half-open [min, max) rule.
 * Used only to preview an adjustment before it's committed — the authoritative
 * match is calibration_band_for_score, re-run server-side on every adjust.
 */
export function previewBandForScore(
  bands: CalibrationBand[],
  score: number,
): CalibrationBand | null {
  const ordered = [...bands].sort((a, b) => a.sort_order - b.sort_order);
  return (
    ordered.find((band) => score >= band.min_score && score < band.max_score) ?? null
  );
}

// ---------------------------------------------------------------------------
// Reversal reasons (client-side UX only)
// ---------------------------------------------------------------------------

/**
 * Minimum characters a reversal reason must carry. The authoritative rule is
 * the DB check constraint on unpublish_employee_goal_plan /
 * unfinalize_calibration_session, which raises 23514 on a blank or too-short
 * reason; this mirror exists so HR sees the requirement before submitting
 * rather than after a round trip.
 */
export const MIN_REVERSAL_REASON_LENGTH = 10;

/**
 * Validate a reversal reason the way the DB will. Returns null when the reason
 * is acceptable, otherwise a readable message. Whitespace-only never passes —
 * both reversal functions treat a blank reason as 23514.
 */
export function reversalReasonError(reason: string): string | null {
  const trimmed = reason.trim();
  if (trimmed.length === 0) {
    return "A reason is required — this is the only record of why the reversal happened.";
  }
  if (trimmed.length < MIN_REVERSAL_REASON_LENGTH) {
    return `Give a bit more detail — at least ${MIN_REVERSAL_REASON_LENGTH} characters.`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Error surfacing
// ---------------------------------------------------------------------------

type PostgrestLikeError = {
  code?: string | null;
  message?: string | null;
};

/**
 * Map the SQLSTATEs the calibration RPCs raise onto plain language. Anything
 * unrecognised falls through to the raw message rather than being swallowed —
 * a constraint violation HR can read beats a generic "something went wrong".
 */
export function calibrationErrorMessage(error: PostgrestLikeError | null): string | null {
  if (!error) return null;

  switch (error.code) {
    case "42501":
      return "Only HR admins can make calibration changes.";
    case "P0002":
      return "That record no longer exists. Refresh the page and try again.";
    case "55000":
      return (
        error.message ??
        "That action isn't allowed in the session's current state."
      );
    case "23514":
      return (
        error.message ??
        "That score doesn't fall inside any band configured for this session."
      );
    case "23505":
      return "That plan is already in this session.";
    default:
      return error.message ?? "Something went wrong. Try again.";
  }
}
