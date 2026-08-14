"use client";

import { useCallback, useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { LockSimple } from "@phosphor-icons/react/dist/csr/LockSimple";
import { PaperPlaneTilt } from "@phosphor-icons/react/dist/csr/PaperPlaneTilt";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { AdjustModal } from "@/components/calibration/adjust-modal";
import { AddParticipantModal } from "@/components/calibration/add-participant-modal";
import { ParticipantCard } from "@/components/calibration/participant-card";
import { SessionStatusPill } from "@/components/calibration/session-status-pill";
import {
  usePointerDrag,
  DROP_TARGET_ATTR,
  SCROLLER_ATTR,
} from "@/components/calibration/use-pointer-drag";
import {
  buildBoardColumns,
  calibrationErrorMessage,
  scoreDelta,
  UNASSIGNED_COLUMN_ID,
  type CalibrationParticipant,
  type CalibrationSessionDetail,
} from "@/lib/calibration";

type AdjustTarget = {
  participant: CalibrationParticipant;
  /** Non-null when the modal was opened by dropping onto a band. */
  proposedScore: number | null;
};

/**
 * A dropped card proposes the midpoint of the target band. Ranges are half-open
 * [min, max), so the midpoint is always inside; the facilitator still confirms
 * (or overrides) the exact number in the modal — dropping never commits.
 */
function proposedScoreForBand(min: number, max: number): number {
  return Number(((min + max) / 2).toFixed(3));
}

export function CalibrationBoard({ detail }: { detail: CalibrationSessionDetail }) {
  const router = useRouter();
  const [isRefreshing, startRefresh] = useTransition();

  const [adjustTarget, setAdjustTarget] = useState<AdjustTarget | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [pendingAction, setPendingAction] = useState<
    "adjust" | "add" | "finalize" | "publish" | null
  >(null);
  const [modalError, setModalError] = useState<string | null>(null);
  const [boardError, setBoardError] = useState<string | null>(null);
  const [confirmFinalize, setConfirmFinalize] = useState(false);

  const finalized = detail.session.status === "finalized";
  const locked = finalized;

  const columns = useMemo(
    () => buildBoardColumns(detail.bands, detail.participants),
    [detail.bands, detail.participants],
  );

  const scaleMax = detail.participants[0]?.overall_rating_scale_max ?? 5;

  const adjustedCount = detail.participants.filter((p) => scoreDelta(p) !== null).length;
  const unpublished = detail.participants.filter((p) => p.published_at === null);

  function refresh() {
    startRefresh(() => router.refresh());
  }

  async function handleAdjust(score: number, note: string | null) {
    if (!adjustTarget) return;
    setPendingAction("adjust");
    setModalError(null);

    const supabase = createClient();
    // p_note is always sent: the RPC assigns facilitator_note unconditionally,
    // so omitting it on a score-only edit would silently erase the note.
    const { error } = await supabase.rpc("adjust_calibration_participant", {
      p_participant_id: adjustTarget.participant.id,
      p_new_score: score,
      p_note: note,
    });

    setPendingAction(null);

    if (error) {
      setModalError(calibrationErrorMessage(error));
      return;
    }

    setAdjustTarget(null);
    refresh();
  }

  async function handleAdd(planId: string) {
    setPendingAction("add");
    setModalError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc("add_plan_to_calibration_session", {
      p_session_id: detail.session.id,
      p_plan_id: planId,
    });

    setPendingAction(null);

    if (error) {
      setModalError(calibrationErrorMessage(error));
      return;
    }

    setAddOpen(false);
    refresh();
  }

  async function handleFinalize() {
    setPendingAction("finalize");
    setBoardError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc("finalize_calibration_session", {
      p_session_id: detail.session.id,
    });

    setPendingAction(null);
    setConfirmFinalize(false);

    if (error) {
      setBoardError(calibrationErrorMessage(error));
      return;
    }

    refresh();
  }

  async function handlePublish(planId: string) {
    setPendingAction("publish");
    setBoardError(null);

    const supabase = createClient();
    const { error } = await supabase.rpc("publish_employee_goal_plan", {
      p_plan_id: planId,
    });

    setPendingAction(null);

    if (error) {
      setBoardError(calibrationErrorMessage(error));
      return;
    }

    refresh();
  }

  // participantId arrives explicitly from the pointer controller rather than
  // being read out of state at drop time, which would be a stale closure.
  const handleDrop = useCallback(
    (participantId: string, columnId: string | null) => {
      if (locked || !columnId) return;

      const participant = detail.participants.find((p) => p.id === participantId);
      if (!participant) return;

      // The Unassigned column isn't a band, so there is nothing to propose.
      if (columnId === UNASSIGNED_COLUMN_ID) return;

      const band = detail.bands.find((b) => b.id === columnId);
      if (!band) return;
      if (participant.band_id === band.id) return;

      setModalError(null);
      setAdjustTarget({
        participant,
        proposedScore: proposedScoreForBand(band.min_score, band.max_score),
      });
    },
    [detail.bands, detail.participants, locked],
  );

  const { draggingId, dragOverColumn, preview, startDrag } = usePointerDrag({
    onDrop: handleDrop,
    disabled: locked,
  });

  const hoverColumnLabel =
    dragOverColumn === null
      ? null
      : (columns.find((c) => c.id === dragOverColumn)?.label ?? null);

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1
              className="font-heading text-2xl font-semibold sm:text-3xl"
              style={{ color: "var(--foreground)" }}
            >
              {detail.session.name}
            </h1>
            <SessionStatusPill status={detail.session.status} />
          </div>
          <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
            {detail.session.review_cycle_name ?? "Unknown cycle"} ·{" "}
            {detail.participants.length}{" "}
            {detail.participants.length === 1 ? "participant" : "participants"}
            {adjustedCount > 0 && ` · ${adjustedCount} adjusted`}
          </p>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            disabled={locked || pendingAction !== null}
            onClick={() => {
              setModalError(null);
              setAddOpen(true);
            }}
            className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-50 disabled:hover:bg-transparent cursor-pointer disabled:cursor-default"
            style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
          >
            <Plus size={16} weight="bold" aria-hidden="true" />
            Add employee
          </button>

          {!finalized && (
            <button
              type="button"
              disabled={pendingAction !== null || detail.participants.length === 0}
              onClick={() => setConfirmFinalize(true)}
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-50 cursor-pointer disabled:cursor-default"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              <LockSimple size={16} weight="bold" aria-hidden="true" />
              Finalize session
            </button>
          )}
        </div>
      </div>

      {finalized && (
        <p
          className="rounded-2xl border p-4 text-sm"
          style={{
            borderColor: "var(--border)",
            backgroundColor: "var(--muted)",
            color: "var(--muted-foreground)",
          }}
        >
          This session is finalized. Scores are frozen and can no longer be adjusted. Publish each
          plan below to make its calibrated score visible to the employee.
        </p>
      )}

      {boardError && (
        <p
          role="alert"
          className="rounded-2xl border p-4 text-sm"
          style={{
            borderColor: "var(--border)",
            backgroundColor: "color-mix(in srgb, var(--destructive) 8%, transparent)",
            color: "var(--destructive)",
          }}
        >
          {boardError}
        </p>
      )}

      {confirmFinalize && (
        <div
          className="rounded-2xl border p-4"
          style={{
            borderColor: "var(--border)",
            backgroundColor: "color-mix(in srgb, var(--warn) 10%, transparent)",
          }}
        >
          <p className="flex items-start gap-2 text-sm" style={{ color: "var(--foreground)" }}>
            <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
            <span>
              Finalizing freezes every score in this session permanently — there is no way to reopen
              it from this screen. Publishing is only possible after finalizing.
            </span>
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={handleFinalize}
              disabled={pendingAction !== null}
              className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pendingAction === "finalize" ? "Finalizing..." : "Yes, finalize"}
            </button>
            <button
              type="button"
              onClick={() => setConfirmFinalize(false)}
              disabled={pendingAction !== null}
              className="min-h-11 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {detail.bands.length === 0 && (
        <p
          className="rounded-2xl border border-dashed p-6 text-sm"
          style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
        >
          This session has no bands, so no plan can be added to it — every score has to land in a
          band. Create a new session with bands instead.
        </p>
      )}

      {/* Board: horizontal scroll on narrow screens, one column per band. */}
      <div
        {...{ [SCROLLER_ATTR]: "" }}
        className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0"
        aria-label="Calibration board"
      >
        <div className="flex min-w-max gap-4 pb-2">
          {columns.map((column) => {
            const isDropTarget = dragOverColumn === column.id;
            const droppable = !locked && column.band !== null;

            return (
              <section
                key={column.id}
                {...(droppable ? { [DROP_TARGET_ATTR]: column.id } : {})}
                className="flex w-72 shrink-0 flex-col rounded-2xl border p-3 transition-colors"
                style={{
                  borderColor: isDropTarget ? "var(--accent)" : "var(--border)",
                  backgroundColor: isDropTarget
                    ? "color-mix(in srgb, var(--accent) 8%, var(--muted))"
                    : "var(--muted)",
                }}
              >
                <header className="mb-3 px-1">
                  <h2
                    className="font-heading text-sm font-semibold"
                    style={{ color: "var(--foreground)" }}
                  >
                    {column.label}
                  </h2>
                  <p className="font-data mt-0.5 text-xs" style={{ color: "var(--muted-foreground)" }}>
                    {column.band
                      ? `${column.band.min_score} – ${column.band.max_score} · ${column.participants.length}`
                      : `Band missing · ${column.participants.length}`}
                  </p>
                </header>

                <div className="flex flex-col gap-2">
                  {column.participants.length === 0 ? (
                    <p
                      className="rounded-xl border border-dashed p-4 text-center text-xs"
                      style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
                    >
                      No one here
                    </p>
                  ) : (
                    column.participants.map((participant) => (
                      <div key={participant.id} className="flex flex-col gap-1.5">
                        <ParticipantCard
                          participant={participant}
                          scaleMax={scaleMax}
                          disabled={locked}
                          dragging={draggingId === participant.id}
                          onAdjust={() => {
                            setModalError(null);
                            setAdjustTarget({ participant, proposedScore: null });
                          }}
                          onDragHandlePointerDown={(event) =>
                            startDrag(event, participant.id, participant.employee_full_name)
                          }
                        />
                        {finalized && participant.published_at === null && (
                          <button
                            type="button"
                            disabled={pendingAction !== null}
                            onClick={() => handlePublish(participant.employee_goal_plan_id)}
                            className="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-lg px-3 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
                            style={{
                              backgroundColor: "var(--accent)",
                              color: "var(--accent-foreground)",
                            }}
                          >
                            <PaperPlaneTilt size={14} weight="bold" aria-hidden="true" />
                            Publish
                          </button>
                        )}
                      </div>
                    ))
                  )}
                </div>
              </section>
            );
          })}
        </div>
      </div>

      {finalized && unpublished.length > 0 && (
        <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
          {unpublished.length} {unpublished.length === 1 ? "plan is" : "plans are"} finalized but not
          yet published. Employees can&apos;t see their calibrated score until you publish.
        </p>
      )}

      {isRefreshing && (
        <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
          Refreshing board...
        </p>
      )}

      {preview && (
        <div
          aria-hidden="true"
          className="pointer-events-none fixed z-50 rounded-xl border px-3 py-2 text-sm font-semibold shadow-lg"
          style={{
            left: preview.x,
            top: preview.y,
            transform: "translate(-50%, -50%)",
            backgroundColor: "var(--card)",
            borderColor: "var(--accent)",
            color: "var(--foreground)",
          }}
        >
          {preview.label}
        </div>
      )}

      <p aria-live="polite" className="sr-only">
        {preview
          ? hoverColumnLabel
            ? `Dragging ${preview.label}. Over ${hoverColumnLabel}. Release to propose a score.`
            : `Dragging ${preview.label}. No band under pointer.`
          : ""}
      </p>

      {adjustTarget && (
        <AdjustModal
          participant={adjustTarget.participant}
          bands={detail.bands}
          scaleMax={scaleMax}
          proposedScore={adjustTarget.proposedScore}
          pending={pendingAction === "adjust"}
          error={modalError}
          onSubmit={handleAdjust}
          onClose={() => {
            setAdjustTarget(null);
            setModalError(null);
          }}
        />
      )}

      {addOpen && (
        <AddParticipantModal
          sessionId={detail.session.id}
          scaleMax={scaleMax}
          pending={pendingAction === "add"}
          error={modalError}
          onAdd={handleAdd}
          onClose={() => {
            setAddOpen(false);
            setModalError(null);
          }}
        />
      )}
    </div>
  );
}
