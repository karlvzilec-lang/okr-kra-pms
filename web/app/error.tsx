"use client";

import { useEffect } from "react";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { ArrowClockwise } from "@phosphor-icons/react/dist/csr/ArrowClockwise";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <main
      className="flex min-h-dvh flex-1 flex-col items-center justify-center gap-4 px-4 text-center"
      style={{ backgroundColor: "var(--background)" }}
    >
      <span
        className="flex h-12 w-12 items-center justify-center rounded-xl"
        style={{ backgroundColor: "color-mix(in srgb, var(--destructive) 14%, transparent)", color: "var(--destructive)" }}
      >
        <WarningCircle size={24} weight="bold" aria-hidden="true" />
      </span>
      <div>
        <h1 className="font-heading text-lg font-semibold" style={{ color: "var(--foreground)" }}>
          Something went wrong
        </h1>
        <p className="mt-1 max-w-sm text-sm" style={{ color: "var(--muted-foreground)" }}>
          Your review summary couldn&apos;t load. This is usually temporary, try again.
        </p>
      </div>
      <button
        type="button"
        onClick={reset}
        className="inline-flex min-h-11 items-center gap-2 rounded-lg px-4 text-sm font-semibold transition-transform active:scale-[0.98] cursor-pointer"
        style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
      >
        <ArrowClockwise size={16} weight="bold" aria-hidden="true" />
        Try again
      </button>
    </main>
  );
}
