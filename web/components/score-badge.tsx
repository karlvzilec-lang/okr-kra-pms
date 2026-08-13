type Band = {
  label: string;
  color: string;
  bg: string;
};

function bandFor(score: number | null): Band {
  if (score === null) {
    return { label: "Not scored", color: "var(--muted-foreground)", bg: "var(--muted)" };
  }
  if (score <= 0.4) {
    return { label: "Off track", color: "var(--destructive)", bg: "color-mix(in srgb, var(--destructive) 14%, transparent)" };
  }
  if (score <= 0.6) {
    return { label: "At risk", color: "var(--warn)", bg: "var(--warn-bg)" };
  }
  if (score < 1) {
    return { label: "On track", color: "var(--good)", bg: "var(--good-bg)" };
  }
  return { label: "Target hit", color: "var(--stretch)", bg: "var(--stretch-bg)" };
}

export function ScoreBadge({ score }: { score: number | null }) {
  const band = bandFor(score);
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium"
      style={{ color: band.color, backgroundColor: band.bg }}
    >
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{ backgroundColor: band.color }}
        aria-hidden="true"
      />
      {band.label}
    </span>
  );
}

export function ScoreValue({ score }: { score: number | null }) {
  return (
    <span className="font-data text-sm">
      {score === null ? "—" : score.toFixed(2)}
    </span>
  );
}
