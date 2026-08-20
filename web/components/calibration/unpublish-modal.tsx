"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import {
  formatScore,
  reversalReasonError,
  type CalibrationParticipant,
} from "@/lib/calibration";

/**
 * Confirmation for unpublish_employee_goal_plan.
 *
 * Narrow blast radius by design: one employee, and the calibrated score and
 * band are left exactly as they are — only visibility to the employee is
 * withdrawn. So this asks for a reason but not a typed confirmation, unlike
 * the session-wide un-finalize dialog.
 *
 * The reason is mandatory (the DB raises 23514 on a blank one) and is stored
 * as the plan's latest-reversal metadata, overwriting any previous reversal.
 */
export function UnpublishModal({
  participant,
  pending,
  error,
  onSubmit,
  onClose,
}: {
  participant: CalibrationParticipant;
  pending: boolean;
  error: string | null;
  onSubmit: (reason: string) => void;
  onClose: () => void;
}) {
  const [reason, setReason] = useState("");
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

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const reasonProblem = reversalReasonError(reason);
    if (reasonProblem) {
      setLocalError(reasonProblem);
      return;
    }

    setLocalError(null);
    onSubmit(reason.trim());
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
        aria-labelledby="unpublish-title"
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
        className="w-full max-w-md rounded-t-2xl border p-5 sm:rounded-2xl sm:p-6"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <h2
          id="unpublish-title"
          className="font-heading text-base font-semibold"
          style={{ color: "var(--foreground)" }}
        >
          Unpublish {participant.employee_full_name}
        </h2>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          The calibrated score of{" "}
          <span className="font-data">
            {formatScore(participant.calibrated_score ?? participant.original_score)}
          </span>{" "}
          and its band stay exactly as they are. Only the employee&apos;s visibility of it is
          withdrawn, and the plan drops out of the compensation export until it&apos;s published
          again.
        </p>

        <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4" noValidate>
          <div className="flex flex-col gap-1.5">
            <label
              htmlFor="unpublish-reason"
              className="text-sm font-medium"
              style={{ color: "var(--foreground)" }}
            >
              Reason
            </label>
            <textarea
              id="unpublish-reason"
              rows={3}
              autoFocus
              required
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Why this is being withdrawn — e.g. published before the calibration room signed off."
              className="rounded-lg border px-3 py-2 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "var(--background)",
                color: "var(--foreground)",
              }}
            />
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              Required. Stored against the plan as the reason for the most recent unpublish — a
              later one replaces it.
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
              {pending ? "Unpublishing..." : "Unpublish"}
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
