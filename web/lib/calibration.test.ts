import assert from "node:assert/strict";
import test from "node:test";
import {
  buildBoardColumns,
  previewBandForScore,
  reversalReasonError,
  scoreDelta,
  UNASSIGNED_COLUMN_ID,
  validateBandDrafts,
} from "./calibration.ts";
import type {
  CalibrationBand,
  CalibrationParticipant,
} from "./calibration.ts";

const lowerBand: CalibrationBand = {
  id: "lower",
  label: "Developing",
  min_score: 0,
  max_score: 2,
  sort_order: 0,
};

const upperBand: CalibrationBand = {
  id: "upper",
  label: "Strong",
  min_score: 2,
  max_score: 5,
  sort_order: 1,
};

function participant(
  id: string,
  bandId: string | null,
  calibratedScore: number | null = 3,
): CalibrationParticipant {
  return {
    id,
    employee_goal_plan_id: `plan-${id}`,
    employee_id: `employee-${id}`,
    employee_full_name: `Employee ${id}`,
    employee_email: `${id}@example.com`,
    manager_full_name: "Manager One",
    original_score: 3,
    calibrated_score: calibratedScore,
    band_id: bandId,
    facilitator_note: null,
    overall_rating_scale_max: 5,
    published_at: "2026-08-14T12:30:00+00:00",
    last_unpublished_at: null,
    last_unpublished_by: null,
    last_unpublish_reason: null,
  };
}

test("validateBandDrafts accepts adjacent half-open ranges and rejects overlap", () => {
  assert.deepEqual(
    validateBandDrafts([
      { key: "lower", label: "Developing", min_score: "0", max_score: "2" },
      { key: "upper", label: "Strong", min_score: "2", max_score: "5" },
    ]),
    [],
  );
  assert.deepEqual(
    validateBandDrafts([
      { key: "lower", label: "Developing", min_score: "0", max_score: "2" },
      { key: "upper", label: "Strong", min_score: "1.999", max_score: "5" },
    ]),
    [
      "Bands \"Developing\" and \"Strong\" overlap — ranges are half-open [min, max), so one band's maximum may equal the next one's minimum but not exceed it.",
    ],
  );
});

test("previewBandForScore assigns a shared boundary to the upper band", () => {
  assert.equal(previewBandForScore([upperBand, lowerBand], 2), upperBand);
  assert.equal(previewBandForScore([upperBand, lowerBand], 5), null);
});

test("buildBoardColumns sorts bands and retains null or dangling participants as Unassigned", () => {
  const columns = buildBoardColumns(
    [upperBand, lowerBand],
    [
      participant("assigned", "upper"),
      participant("null-band", null),
      participant("dangling-band", "deleted-band"),
    ],
  );

  assert.deepEqual(
    columns.map((column) => column.id),
    ["lower", "upper", UNASSIGNED_COLUMN_ID],
  );
  assert.deepEqual(
    columns.map((column) => column.participants.map(({ id }) => id)),
    [[], ["assigned"], ["null-band", "dangling-band"]],
  );
  assert.equal(columns[2].label, "Unassigned");
  assert.equal(columns[2].band, null);
});

test("scoreDelta treats sub-milli float noise as unchanged and falls back to original_score", () => {
  assert.equal(scoreDelta(participant("missing-score", "upper", null)), null);
  assert.equal(scoreDelta(participant("float-noise", "upper", 3.0004)), null);
  assert.equal(scoreDelta(participant("zero-score", "lower", 0)), -3);
});

test("reversalReasonError trims input and enforces the 10-character boundary", () => {
  assert.equal(
    reversalReasonError("   "),
    "A reason is required — this is the only record of why the reversal happened.",
  );
  assert.equal(
    reversalReasonError("123456789"),
    "Give a bit more detail — at least 10 characters.",
  );
  assert.equal(reversalReasonError("  1234567890  "), null);
});
