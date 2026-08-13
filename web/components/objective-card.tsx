import type { Objective } from "@/lib/types";
import { ProgressBar } from "@/components/progress-bar";
import { ScoreBadge, ScoreValue } from "@/components/score-badge";

export function ObjectiveCard({ objective }: { objective: Objective }) {
  return (
    <div
      className="rounded-2xl border p-5"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
            {objective.title}
          </h3>
          {objective.description && (
            <p className="mt-1 max-w-[60ch] text-sm" style={{ color: "var(--muted-foreground)" }}>
              {objective.description}
            </p>
          )}
        </div>
        <span
          className="shrink-0 rounded-full px-2.5 py-1 text-xs font-medium capitalize"
          style={{ backgroundColor: "var(--muted)", color: "var(--muted-foreground)" }}
        >
          {objective.status}
        </span>
      </div>

      <div className="mt-4 flex flex-col gap-3 border-t pt-4" style={{ borderColor: "var(--border)" }}>
        {objective.key_results.length === 0 && (
          <p className="text-sm" style={{ color: "var(--muted-foreground)" }}>
            No key results yet.
          </p>
        )}
        {objective.key_results.map((kr) => (
          <div key={kr.id} className="grid grid-cols-1 gap-2 sm:grid-cols-[1fr_auto] sm:items-center sm:gap-4">
            <div>
              <div className="flex items-center justify-between gap-3 sm:justify-start">
                <p className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                  {kr.title}
                </p>
                <span className="font-data text-xs sm:hidden" style={{ color: "var(--muted-foreground)" }}>
                  {kr.current_value} / {kr.target_value} {kr.metric_unit ?? ""}
                </span>
              </div>
              <div className="mt-1.5">
                <ProgressBar fraction={kr.effective_score} />
              </div>
            </div>
            <div className="hidden flex-col items-end gap-1 sm:flex">
              <span className="font-data text-xs" style={{ color: "var(--muted-foreground)" }}>
                {kr.current_value} / {kr.target_value} {kr.metric_unit ?? ""}
              </span>
              <div className="flex items-center gap-2">
                <ScoreValue score={kr.effective_score} />
                <ScoreBadge score={kr.effective_score} />
              </div>
            </div>
            <div className="flex items-center gap-2 sm:hidden">
              <ScoreValue score={kr.effective_score} />
              <ScoreBadge score={kr.effective_score} />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
