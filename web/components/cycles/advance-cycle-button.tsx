"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRight } from "@phosphor-icons/react/dist/csr/ArrowRight";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { CYCLE_STATUS_LABEL, nextCycleStatus, OKR_BLOCKED_MESSAGE, okrErrorMessage } from "@/lib/okr";
import type { ReviewCycleStatus } from "@/lib/types";

type Props = {
  cycleId: string;
  status: ReviewCycleStatus;
};

/**
 * Advance a cycle exactly one step. The button only ever offers the single
 * legal next status — skipping, stepping backward and reopening a closed cycle
 * are all rejected by the database with 55000, so there is nothing to render
 * once a cycle is closed.
 *
 * The update re-selects the row so a silent RLS refusal (zero rows, no error)
 * is distinguishable from a real success.
 */
export function AdvanceCycleButton({ cycleId, status }: Props) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  const next = nextCycleStatus(status);

  if (!next) {
    return (
      <span className="text-xs" style={{ color: "var(--muted-foreground)" }}>
        Closed — final
      </span>
    );
  }

  async function handleAdvance() {
    if (!next) return;
    setError(null);
    setPending(true);

    const supabase = createClient();
    const { data, error: updateError } = await supabase
      .from("review_cycle")
      .update({ status: next })
      .eq("id", cycleId)
      .select("id, status");

    if (updateError) {
      setError(okrErrorMessage(updateError) ?? OKR_BLOCKED_MESSAGE);
      setPending(false);
      return;
    }

    // An RLS-blocked UPDATE returns no error and no rows. Without this check
    // the UI would report success on a write that never happened.
    if (!data || data.length === 0) {
      setError(OKR_BLOCKED_MESSAGE);
      setPending(false);
      return;
    }

    setPending(false);
    router.refresh();
  }

  return (
    <div className="flex flex-col items-end gap-1.5">
      <button
        type="button"
        onClick={handleAdvance}
        disabled={pending}
        className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-3 text-sm font-medium transition-[transform,colors] hover:bg-[var(--muted)] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
        style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
      >
        {pending ? "Advancing..." : `Advance to ${CYCLE_STATUS_LABEL[next]}`}
        <ArrowRight size={14} weight="bold" aria-hidden="true" />
      </button>
      {next === "closed" && !error && (
        <span className="text-xs" style={{ color: "var(--muted-foreground)" }}>
          Closing freezes every objective and check-in. It can&apos;t be undone.
        </span>
      )}
      {error && (
        <span
          role="alert"
          className="inline-flex max-w-sm items-start gap-1.5 text-xs"
          style={{ color: "var(--destructive)" }}
        >
          <WarningCircle size={13} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
          {error}
        </span>
      )}
    </div>
  );
}
