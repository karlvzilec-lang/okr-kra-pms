import type { KraRating } from "@/lib/types";

const LABELS: Record<KraRating["rating_type"], string> = {
  self: "Self rating",
  manager: "Manager rating",
};

export function KraStatCard({ rating, scaleMax }: { rating: KraRating; scaleMax: number }) {
  return (
    <div
      className="rounded-2xl border p-5"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
    >
      <p className="text-sm font-medium" style={{ color: "var(--muted-foreground)" }}>
        {LABELS[rating.rating_type]}
      </p>
      <p className="mt-2 flex items-baseline gap-1.5">
        <span className="font-data text-3xl font-semibold" style={{ color: "var(--foreground)" }}>
          {rating.overall_score.toFixed(3)}
        </span>
        <span className="font-data text-sm" style={{ color: "var(--muted-foreground)" }}>
          / {scaleMax}
        </span>
      </p>
      <p className="mt-1.5 text-xs" style={{ color: "var(--muted-foreground)" }}>
        Weighted KRA average, computed{" "}
        {new Date(rating.computed_at).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        })}
      </p>
      {rating.final_score !== null && (
        <div
          className="mt-3 flex items-center justify-between gap-2 rounded-lg px-3 py-2"
          style={{ backgroundColor: "var(--accent-soft, var(--muted))" }}
        >
          <span className="text-xs font-medium" style={{ color: "var(--accent)" }}>
            Published calibrated score
          </span>
          <span className="font-data text-sm font-semibold" style={{ color: "var(--accent)" }}>
            {rating.final_score.toFixed(3)}
          </span>
        </div>
      )}
    </div>
  );
}

export function KraStatCardEmpty({ label }: { label: string }) {
  return (
    <div
      className="rounded-2xl border border-dashed p-5"
      style={{ borderColor: "var(--border)" }}
    >
      <p className="text-sm font-medium" style={{ color: "var(--muted-foreground)" }}>
        {label}
      </p>
      <p className="mt-2 text-sm" style={{ color: "var(--muted-foreground)" }}>
        Not yet computed for this cycle.
      </p>
    </div>
  );
}
