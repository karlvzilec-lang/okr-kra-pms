import type { CalibrationSessionStatus } from "@/lib/calibration";

const STYLES: Record<
  CalibrationSessionStatus,
  { label: string; color: string; bg: string }
> = {
  open: {
    label: "Open",
    color: "var(--good)",
    bg: "var(--good-bg)",
  },
  finalized: {
    label: "Finalized",
    color: "var(--muted-foreground)",
    bg: "var(--muted)",
  },
};

export function SessionStatusPill({ status }: { status: CalibrationSessionStatus }) {
  const style = STYLES[status];
  return (
    <span
      className="inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium"
      style={{ color: style.color, backgroundColor: style.bg }}
    >
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{ backgroundColor: style.color }}
        aria-hidden="true"
      />
      {style.label}
    </span>
  );
}
