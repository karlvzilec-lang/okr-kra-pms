"use client";

import { useRouter } from "next/navigation";
import { CaretDown } from "@phosphor-icons/react/dist/csr/CaretDown";
import type { ReviewCycle } from "@/lib/types";

/**
 * Switch which review cycle /review is showing.
 *
 * The selected cycle lives in the URL (?cycle=<uuid>), not in component state,
 * for the same reason pagination does: it survives a refresh, it can be linked
 * and bookmarked, and the server decides what is actually visible. This island
 * holds no state of its own — it reads the current value from its prop and
 * navigates, so the page it lands on is always the server's answer rather than
 * an optimistic local guess that RLS might disagree with.
 *
 * The list it renders comes straight from loadReviewCycles, which is already
 * RLS-scoped. There is deliberately no client-side filtering on top: if a cycle
 * is in this list the caller may read it, and if it isn't, no amount of typing
 * a uuid into the address bar will add it.
 */
export function CyclePicker({
  cycles,
  selectedId,
}: {
  cycles: ReviewCycle[];
  selectedId: string;
}) {
  const router = useRouter();

  // One cycle is not a choice, it's a label. The page already prints the name
  // above the heading, so a select with a single option would be furniture.
  if (cycles.length <= 1) return null;

  return (
    <div className="relative inline-flex">
      <label htmlFor="review-cycle" className="sr-only">
        Review cycle
      </label>
      <select
        id="review-cycle"
        value={selectedId}
        onChange={(event) => router.push(`/review?cycle=${event.target.value}`)}
        className="min-h-11 cursor-pointer appearance-none rounded-lg border py-2 pl-3 pr-9 text-sm font-medium transition-[transform,background-color] hover:bg-[var(--muted)] active:scale-[0.98]"
        style={{
          borderColor: "var(--border)",
          color: "var(--foreground)",
          backgroundColor: "var(--background)",
        }}
      >
        {cycles.map((cycle) => (
          <option key={cycle.id} value={cycle.id}>
            {cycle.name}
          </option>
        ))}
      </select>
      <CaretDown
        size={14}
        weight="bold"
        aria-hidden="true"
        className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2"
        style={{ color: "var(--muted-foreground)" }}
      />
    </div>
  );
}
