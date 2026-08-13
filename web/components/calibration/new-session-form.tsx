"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { Trash } from "@phosphor-icons/react/dist/csr/Trash";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import {
  bandDraftsToInput,
  calibrationErrorMessage,
  validateBandDrafts,
  type BandDraft,
  type ReviewCycleOption,
} from "@/lib/calibration";

/**
 * Default band set matching the seeded FY2026 session. The top band deliberately
 * extends above the 5-point scale max: band matching is half-open [min, max), so
 * a perfect 5.000 would otherwise match nothing and the DB would raise 23514.
 */
function defaultBands(): BandDraft[] {
  return [
    { key: "b1", label: "Needs Improvement", min_score: "0", max_score: "2.5" },
    { key: "b2", label: "Meets Expectations", min_score: "2.5", max_score: "3.5" },
    { key: "b3", label: "Exceeds Expectations", min_score: "3.5", max_score: "4.5" },
    { key: "b4", label: "Outstanding", min_score: "4.5", max_score: "5.001" },
  ];
}

export function NewSessionForm({ cycles }: { cycles: ReviewCycleOption[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [cycleId, setCycleId] = useState(cycles[0]?.id ?? "");
  const [bands, setBands] = useState<BandDraft[]>(defaultBands);
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);
  const [nextKey, setNextKey] = useState(5);

  function updateBand(key: string, patch: Partial<BandDraft>) {
    setBands((current) =>
      current.map((band) => (band.key === key ? { ...band, ...patch } : band)),
    );
  }

  function addBand() {
    setBands((current) => [
      ...current,
      { key: `b${nextKey}`, label: "", min_score: "", max_score: "" },
    ]);
    setNextKey((k) => k + 1);
  }

  function removeBand(key: string) {
    setBands((current) => current.filter((band) => band.key !== key));
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems: string[] = [];
    if (name.trim().length === 0) {
      problems.push("Give the session a name so it's identifiable later.");
    }
    if (!cycleId) {
      problems.push("Pick the review cycle this session calibrates.");
    }
    problems.push(...validateBandDrafts(bands));

    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();

    // One RPC, one transaction: the session and its bands are created together
    // or not at all. A rejected band set (overlap, inverted range) rolls the
    // whole thing back rather than leaving an orphaned bandless session.
    const { data, error } = await supabase.rpc("create_calibration_session_with_bands", {
      p_name: name.trim(),
      p_review_cycle_id: cycleId,
      p_bands: bandDraftsToInput(bands),
    });

    if (error) {
      setErrors([calibrationErrorMessage(error) ?? "Couldn't create the session."]);
      setPending(false);
      return;
    }

    const sessionId = typeof data === "string" ? data : null;
    if (sessionId) {
      router.push(`/calibration/${sessionId}`);
    } else {
      router.refresh();
    }
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] cursor-pointer"
        style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
      >
        <Plus size={16} weight="bold" aria-hidden="true" />
        New calibration session
      </button>
    );
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="rounded-2xl border p-5 sm:p-6"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      noValidate
    >
      <h2 className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
        New calibration session
      </h2>

      <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="session-name" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Session name
          </label>
          <input
            id="session-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="FY2026 Engineering calibration"
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="session-cycle" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Review cycle
          </label>
          <select
            id="session-cycle"
            value={cycleId}
            onChange={(e) => setCycleId(e.target.value)}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          >
            {cycles.length === 0 && <option value="">No review cycles available</option>}
            {cycles.map((cycle) => (
              <option key={cycle.id} value={cycle.id}>
                {cycle.name}
              </option>
            ))}
          </select>
        </div>
      </div>

      <fieldset className="mt-6">
        <legend className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
          Bands
        </legend>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          Ranges are half-open — a score matches when it&apos;s at or above the minimum and below the
          maximum. Give the top band a maximum above your rating scale&apos;s max so a perfect score
          still lands somewhere.
        </p>

        <div className="mt-3 flex flex-col gap-2">
          {bands.map((band, index) => (
            <div key={band.key} className="flex flex-wrap items-end gap-2">
              <div className="flex min-w-[10rem] flex-1 flex-col gap-1">
                <label
                  htmlFor={`band-label-${band.key}`}
                  className="text-xs"
                  style={{ color: "var(--muted-foreground)" }}
                >
                  Label {index + 1}
                </label>
                <input
                  id={`band-label-${band.key}`}
                  value={band.label}
                  onChange={(e) => updateBand(band.key, { label: e.target.value })}
                  className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                  style={{
                    borderColor: "var(--border)",
                    backgroundColor: "var(--background)",
                    color: "var(--foreground)",
                  }}
                />
              </div>
              <div className="flex w-24 flex-col gap-1">
                <label
                  htmlFor={`band-min-${band.key}`}
                  className="text-xs"
                  style={{ color: "var(--muted-foreground)" }}
                >
                  Min
                </label>
                <input
                  id={`band-min-${band.key}`}
                  inputMode="decimal"
                  value={band.min_score}
                  onChange={(e) => updateBand(band.key, { min_score: e.target.value })}
                  className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                  style={{
                    borderColor: "var(--border)",
                    backgroundColor: "var(--background)",
                    color: "var(--foreground)",
                  }}
                />
              </div>
              <div className="flex w-24 flex-col gap-1">
                <label
                  htmlFor={`band-max-${band.key}`}
                  className="text-xs"
                  style={{ color: "var(--muted-foreground)" }}
                >
                  Max
                </label>
                <input
                  id={`band-max-${band.key}`}
                  inputMode="decimal"
                  value={band.max_score}
                  onChange={(e) => updateBand(band.key, { max_score: e.target.value })}
                  className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                  style={{
                    borderColor: "var(--border)",
                    backgroundColor: "var(--background)",
                    color: "var(--foreground)",
                  }}
                />
              </div>
              <button
                type="button"
                onClick={() => removeBand(band.key)}
                aria-label={`Remove band ${band.label || index + 1}`}
                className="inline-flex h-11 w-11 items-center justify-center rounded-lg border transition-colors hover:bg-[var(--muted)] cursor-pointer"
                style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
              >
                <Trash size={16} weight="bold" aria-hidden="true" />
              </button>
            </div>
          ))}
        </div>

        <button
          type="button"
          onClick={addBand}
          className="mt-3 inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-3 text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          <Plus size={14} weight="bold" aria-hidden="true" />
          Add band
        </button>
      </fieldset>

      {errors.length > 0 && (
        <div
          role="alert"
          className="mt-5 flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
          style={{
            backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)",
            color: "var(--destructive)",
          }}
        >
          <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
          <ul className="flex flex-col gap-1">
            {errors.map((message) => (
              <li key={message}>{message}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="mt-6 flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={pending}
          className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          {pending ? "Creating..." : "Create session"}
        </button>
        <button
          type="button"
          onClick={() => setOpen(false)}
          disabled={pending}
          className="min-h-11 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
