"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { reversalReasonError } from "@/lib/calibration";

/** What HR must type to confirm. Deliberately not the session name: it's short, unambiguous, and can't be pasted from the heading above by accident. */
export const UNFINALIZE_CONFIRM_WORD = "UNFINALIZE";

/**
 * Confirmation for unfinalize_calibration_session.
 *
 * The more consequential of the two reversals — it reopens every score in the
 * session for editing — so it carries more friction than unpublish: a required
 * reason *and* a typed confirmation word.
 *
 * This dialog is only reachable when no participant is still published. That
 * precondition is enforced by the DB (55000, naming the blocking count) and
 * mirrored by the board, which disables rather than hides the control and
 * explains why.
 */
export function UnfinalizeModal({
  sessionName,
  participantCount,
  pending,
  error,
  onSubmit,
  onClose,
}: {
  sessionName: string;
  participantCount: number;
  pending: boolean;
  error: string | null;
  onSubmit: (reason: string) => void;
  onClose: () => void;
}) {
  const [reason, setReason] = useState("");
  const [confirmText, setConfirmText] = useState("");
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

  const confirmed = confirmText.trim().toUpperCase() === UNFINALIZE_CONFIRM_WORD;

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const reasonProblem = reversalReasonError(reason);
    if (reasonProblem) {
      setLocalError(reasonProblem);
      return;
    }
    if (!confirmed) {
      setLocalError(`Type ${UNFINALIZE_CONFIRM_WORD} to confirm.`);
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
        aria-labelledby="unfinalize-title"
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
        className="w-full max-w-md rounded-t-2xl border p-5 sm:rounded-2xl sm:p-6"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <h2
          id="unfinalize-title"
          className="font-heading text-base font-semibold"
          style={{ color: "var(--foreground)" }}
        >
          Un-finalize {sessionName}
        </h2>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          This returns the session to open. All {participantCount}{" "}
          {participantCount === 1 ? "score becomes" : "scores become"} editable again, and nothing
          can be published until the session is finalized once more.
        </p>

        <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4" noValidate>
          <div className="flex flex-col gap-1.5">
            <label
              htmlFor="unfinalize-reason"
              className="text-sm font-medium"
              style={{ color: "var(--foreground)" }}
            >
              Reason
            </label>
            <textarea
              id="unfinalize-reason"
              rows={3}
              autoFocus
              required
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Why this session is being reopened — e.g. a manager rating was corrected after finalization."
              className="rounded-lg border px-3 py-2 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "var(--background)",
                color: "var(--foreground)",
              }}
            />
            <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
              Required. Stored against the session as the reason for the most recent un-finalize —
              a later one replaces it.
            </p>
          </div>

          <div className="flex flex-col gap-1.5">
            <label
              htmlFor="unfinalize-confirm"
              className="text-sm font-medium"
              style={{ color: "var(--foreground)" }}
            >
              Type {UNFINALIZE_CONFIRM_WORD} to confirm
            </label>
            <input
              id="unfinalize-confirm"
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
              autoComplete="off"
              spellCheck={false}
              aria-describedby="unfinalize-confirm-hint"
              className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "var(--background)",
                color: "var(--foreground)",
              }}
            />
            <p
              id="unfinalize-confirm-hint"
              className="text-xs"
              style={{ color: "var(--muted-foreground)" }}
            >
              Reopening a finalized session is the most consequential action on this board, so it
              asks for this extra step.
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
              disabled={pending || !confirmed}
              className="min-h-11 flex-1 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer disabled:cursor-default"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pending ? "Reopening..." : "Un-finalize session"}
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
