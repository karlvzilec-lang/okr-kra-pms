"use client";

import {
  effectiveScore,
  formatDelta,
  formatScore,
  scoreDelta,
  type CalibrationParticipant,
} from "@/lib/calibration";
import { NotePencil } from "@phosphor-icons/react/dist/csr/NotePencil";

export function ParticipantCard({
  participant,
  scaleMax,
  disabled,
  dragging,
  onAdjust,
  onDragStart,
  onDragEnd,
}: {
  participant: CalibrationParticipant;
  scaleMax: number;
  disabled: boolean;
  dragging: boolean;
  onAdjust: () => void;
  onDragStart: () => void;
  onDragEnd: () => void;
}) {
  const delta = scoreDelta(participant);
  const current = effectiveScore(participant);

  return (
    <div
      // Drag is a convenience shortcut into the Adjust modal, never a commit —
      // dropping a card only prefills a proposed score for confirmation. The
      // button below is the real, keyboard-reachable primitive.
      draggable={!disabled}
      onDragStart={(event) => {
        if (disabled) return;
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", participant.id);
        onDragStart();
      }}
      onDragEnd={onDragEnd}
      className="rounded-xl border p-3 transition-opacity"
      style={{
        backgroundColor: "var(--card)",
        borderColor: "var(--border)",
        opacity: dragging ? 0.45 : 1,
        cursor: disabled ? "default" : "grab",
      }}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p
            className="truncate text-sm font-semibold"
            style={{ color: "var(--foreground)" }}
            title={participant.employee_full_name}
          >
            {participant.employee_full_name}
          </p>
          <p
            className="truncate text-xs"
            style={{ color: "var(--muted-foreground)" }}
            title={participant.manager_full_name ?? undefined}
          >
            {participant.manager_full_name
              ? `Manager: ${participant.manager_full_name}`
              : "No line manager on this cycle"}
          </p>
        </div>
        <span className="font-data shrink-0 text-sm font-semibold" style={{ color: "var(--foreground)" }}>
          {formatScore(current)}
        </span>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        <span className="font-data text-xs" style={{ color: "var(--muted-foreground)" }}>
          was {formatScore(participant.original_score)} / {scaleMax}
        </span>
        {delta !== null && (
          <span
            className="font-data inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium"
            style={{
              color: delta > 0 ? "var(--good)" : "var(--warn)",
              backgroundColor: delta > 0 ? "var(--good-bg)" : "var(--warn-bg)",
            }}
          >
            {formatDelta(delta)}
          </span>
        )}
        {participant.published_at && (
          <span
            className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium"
            style={{ color: "var(--accent)", backgroundColor: "var(--muted)" }}
          >
            Published
          </span>
        )}
      </div>

      {participant.facilitator_note && (
        <p
          className="mt-2 flex items-start gap-1.5 text-xs"
          style={{ color: "var(--muted-foreground)" }}
        >
          <NotePencil size={12} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
          <span className="line-clamp-3">{participant.facilitator_note}</span>
        </p>
      )}

      <button
        type="button"
        onClick={onAdjust}
        disabled={disabled}
        className="mt-3 min-h-11 w-full rounded-lg border text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-50 disabled:hover:bg-transparent cursor-pointer disabled:cursor-default"
        style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
      >
        {disabled ? "Locked" : "Adjust"}
      </button>
    </div>
  );
}
