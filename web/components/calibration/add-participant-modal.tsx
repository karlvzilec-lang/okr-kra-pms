"use client";

import { useEffect, useMemo, useState } from "react";
import { MagnifyingGlass } from "@phosphor-icons/react/dist/csr/MagnifyingGlass";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import {
  calibrationErrorMessage,
  formatScore,
  type EligiblePlan,
} from "@/lib/calibration";

/**
 * Picker for adding a manager-rated plan to an open session.
 *
 * calibration_eligible_plans already excludes plans that are in this session
 * and plans that have been published (a published plan cannot be recalibrated —
 * add_plan_to_calibration_session rejects it with 55000). So this list should
 * never offer something that errors on click; the error path below exists for
 * the race where someone else publishes between load and click.
 */
export function AddParticipantModal({
  sessionId,
  scaleMax,
  pending,
  error,
  onAdd,
  onClose,
}: {
  sessionId: string;
  scaleMax: number;
  pending: boolean;
  error: string | null;
  onAdd: (planId: string) => void;
  onClose: () => void;
}) {
  const [plans, setPlans] = useState<EligiblePlan[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [query, setQuery] = useState("");

  useEffect(() => {
    let cancelled = false;
    const supabase = createClient();

    supabase
      .rpc("calibration_eligible_plans", { p_session_id: sessionId })
      .then(({ data, error: rpcError }) => {
        if (cancelled) return;
        if (rpcError) {
          setLoadError(calibrationErrorMessage(rpcError));
          setPlans([]);
          return;
        }
        setPlans((data ?? []) as EligiblePlan[]);
      });

    return () => {
      cancelled = true;
    };
  }, [sessionId]);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && !pending) onClose();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onClose, pending]);

  const filtered = useMemo(() => {
    if (!plans) return [];
    const needle = query.trim().toLowerCase();
    if (needle.length === 0) return plans;
    return plans.filter(
      (plan) =>
        plan.employee_full_name.toLowerCase().includes(needle) ||
        plan.employee_email.toLowerCase().includes(needle),
    );
  }, [plans, query]);

  const shownError = error ?? loadError;

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4"
      style={{ backgroundColor: "color-mix(in srgb, black 45%, transparent)" }}
      onClick={() => {
        if (!pending) onClose();
      }}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-participant-title"
        onClick={(event) => event.stopPropagation()}
        className="flex max-h-[85dvh] w-full max-w-md flex-col rounded-t-2xl border p-5 sm:rounded-2xl sm:p-6"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <h2
          id="add-participant-title"
          className="font-heading text-base font-semibold"
          style={{ color: "var(--foreground)" }}
        >
          Add an employee
        </h2>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          Only plans in this session&apos;s review cycle with a computed manager rating, not yet
          published, and not already on this board.
        </p>

        <div className="relative mt-4">
          <MagnifyingGlass
            size={16}
            weight="bold"
            aria-hidden="true"
            className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2"
            style={{ color: "var(--muted-foreground)" }}
          />
          <input
            aria-label="Search employees"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search by name or email"
            className="min-h-11 w-full rounded-lg border pl-9 pr-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        {shownError && (
          <div
            role="alert"
            className="mt-3 flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
            style={{
              backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)",
              color: "var(--destructive)",
            }}
          >
            <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
            <span>{shownError}</span>
          </div>
        )}

        <div className="mt-3 min-h-0 flex-1 overflow-y-auto">
          {plans === null ? (
            <p className="py-6 text-center text-sm" style={{ color: "var(--muted-foreground)" }}>
              Loading eligible plans...
            </p>
          ) : filtered.length === 0 ? (
            <p
              className="rounded-xl border border-dashed p-4 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              {plans.length === 0
                ? "No eligible plans left for this cycle. Everyone rated is either already on the board or already published."
                : "No one matches that search."}
            </p>
          ) : (
            <ul className="flex flex-col gap-2">
              {filtered.map((plan) => (
                <li key={plan.plan_id}>
                  <button
                    type="button"
                    disabled={pending}
                    onClick={() => onAdd(plan.plan_id)}
                    className="flex min-h-11 w-full items-center justify-between gap-3 rounded-xl border p-3 text-left transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer disabled:cursor-default"
                    style={{ borderColor: "var(--border)" }}
                  >
                    <span className="min-w-0">
                      <span
                        className="block truncate text-sm font-medium"
                        style={{ color: "var(--foreground)" }}
                      >
                        {plan.employee_full_name}
                      </span>
                      <span
                        className="block truncate text-xs"
                        style={{ color: "var(--muted-foreground)" }}
                      >
                        {plan.employee_email}
                      </span>
                    </span>
                    <span
                      className="font-data shrink-0 text-sm"
                      style={{ color: "var(--foreground)" }}
                    >
                      {formatScore(plan.manager_score)} / {scaleMax}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>

        <button
          type="button"
          onClick={onClose}
          disabled={pending}
          className="mt-4 min-h-11 shrink-0 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          Close
        </button>
      </div>
    </div>
  );
}
