"use client";

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import {
  effectiveScore,
  formatScore,
  previewBandForScore,
  type CalibrationBand,
  type CalibrationParticipant,
} from "@/lib/calibration";

/**
 * The Adjust modal is the calibration primitive: every score change, whether it
 * started as a button click or a drag, is committed from here after explicit
 * confirmation.
 *
 * Note-erasure trap: adjust_calibration_participant writes
 * `facilitator_note = p_note` unconditionally, so omitting the note on a
 * score-only change would blank an existing note. The note field is therefore
 * always pre-filled with the current note and always sent back.
 */
export function AdjustModal({
  participant,
  bands,
  scaleMax,
  proposedScore,
  pending,
  error,
  onSubmit,
  onClose,
}: {
  participant: CalibrationParticipant;
  bands: CalibrationBand[];
  scaleMax: number;
  /** Prefilled score when the modal was opened by a drop; null for a plain Adjust click. */
  proposedScore: number | null;
  pending: boolean;
  error: string | null;
  onSubmit: (score: number, note: string | null) => void;
  onClose: () => void;
}) {
  const initialScore = proposedScore ?? effectiveScore(participant);
  const [score, setScore] = useState(initialScore.toFixed(3));
  const [note, setNote] = useState(participant.facilitator_note ?? "");
  const [localError, setLocalError] = useState<string | null>(null);
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && !pending) onClose();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onClose, pending]);

  useEffect(() => {
    dialogRef.current?.focus();
  }, []);

  const parsed = Number(score);
  const parsedValid = score.trim() !== "" && !Number.isNaN(parsed);

  const previewBand = useMemo(
    () => (parsedValid ? previewBandForScore(bands, parsed) : null),
    [bands, parsed, parsedValid],
  );

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);

    if (!parsedValid) {
      setLocalError("Enter a numeric score.");
      return;
    }
    if (parsed < 0) {
      setLocalError("A calibrated score can't be negative.");
      return;
    }

    const trimmed = note.trim();
    onSubmit(parsed, trimmed.length > 0 ? trimmed : null);
  }

  const shownError = error ?? localError;

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4"
      style={{ backgroundColor: "color-mix(in srgb, black 45%, transparent)" }}
      onClick={() => {
        if (!pending) onClose();
      }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="adjust-title"
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
        className="w-full max-w-md rounded-t-2xl border p-5 sm:rounded-2xl sm:p-6"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <h2 id="adjust-title" className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
          Adjust {participant.employee_full_name}
        </h2>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          Manager rating was{" "}
          <span className="font-data">{formatScore(participant.original_score)}</span> / {scaleMax}. That
          snapshot is permanent — this changes the calibrated value only.
        </p>

        <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4" noValidate>
          <div className="flex flex-col gap-1.5">
            <label htmlFor="adjust-score" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
              Calibrated score
            </label>
            <input
              id="adjust-score"
              inputMode="decimal"
              autoFocus
              value={score}
              onChange={(e) => setScore(e.target.value)}
              className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "var(--background)",
                color: "var(--foreground)",
              }}
            />
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              {parsedValid ? (
                previewBand ? (
                  <>Lands in <strong style={{ color: "var(--foreground)" }}>{previewBand.label}</strong>.</>
                ) : (
                  <span style={{ color: "var(--destructive)" }}>
                    No band in this session covers that score — the change will be rejected.
                  </span>
                )
              ) : (
                "Enter a score to preview its band."
              )}
            </p>
          </div>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="adjust-note" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
              Facilitator note
            </label>
            <textarea
              id="adjust-note"
              rows={3}
              value={note}
              onChange={(e) => setNote(e.target.value)}
              placeholder="Why this rating moved — the reasoning the calibration room agreed on."
              className="rounded-lg border px-3 py-2 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "var(--background)",
                color: "var(--foreground)",
              }}
            />
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              Saved with the score. Clearing this box clears the stored note.
            </p>
          </div>

          {shownError && (
            <div
              role="alert"
              className="flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
              style={{
                backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)",
                color: "var(--destructive)",
              }}
            >
              <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
              <span>{shownError}</span>
            </div>
          )}

          <div className="flex flex-wrap gap-2">
            <button
              type="submit"
              disabled={pending}
              className="min-h-11 flex-1 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pending ? "Saving..." : "Save adjustment"}
            </button>
            <button
              type="button"
              onClick={onClose}
              disabled={pending}
              className="min-h-11 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
