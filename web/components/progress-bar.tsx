export function ProgressBar({ fraction }: { fraction: number | null }) {
  const pct = fraction === null ? 0 : Math.round(Math.max(0, Math.min(1, fraction)) * 100);
  const color =
    fraction === null
      ? "var(--muted-foreground)"
      : fraction <= 0.4
        ? "var(--destructive)"
        : fraction <= 0.6
          ? "var(--warn)"
          : fraction < 1
            ? "var(--good)"
            : "var(--stretch)";

  return (
    <div
      className="h-1.5 w-full overflow-hidden rounded-full"
      style={{ backgroundColor: "var(--border)" }}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      <div
        className="h-full rounded-full transition-[width] duration-300 ease-out"
        style={{ width: `${pct}%`, backgroundColor: color }}
      />
    </div>
  );
}
