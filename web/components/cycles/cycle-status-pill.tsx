import { CYCLE_STATUS_LABEL } from "@/lib/okr";
import type { ReviewCycleStatus } from "@/lib/types";

const TONE: Record<ReviewCycleStatus, { color: string; bg: string }> = {
  draft: { color: "var(--muted-foreground)", bg: "var(--muted)" },
  active: { color: "var(--good)", bg: "var(--good-bg)" },
  self_eval: { color: "var(--warn)", bg: "var(--warn-bg)" },
  manager_eval: { color: "var(--warn)", bg: "var(--warn-bg)" },
  closed: { color: "var(--muted-foreground)", bg: "var(--muted)" },
};

export function CycleStatusPill({ status }: { status: ReviewCycleStatus }) {
  const tone = TONE[status];
  return (
    <span
      className="inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-xs font-medium"
      style={{ color: tone.color, backgroundColor: tone.bg }}
    >
      {CYCLE_STATUS_LABEL[status]}
    </span>
  );
}
