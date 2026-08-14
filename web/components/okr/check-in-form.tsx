"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { CheckCircle } from "@phosphor-icons/react/dist/csr/CheckCircle";
import { createClient } from "@/lib/supabase/client";
import { OKR_BLOCKED_MESSAGE, okrErrorMessage, parseMetricValue } from "@/lib/okr";
import { ProgressBar } from "@/components/progress-bar";
import { ScoreBadge, ScoreValue } from "@/components/score-badge";
import type { KeyResult } from "@/lib/types";

type Props = { keyResult: KeyResult };

/**
 * Record a check-in against one key result.
 *
 * checked_in_by is read from the session at submit time, never from a form
 * field: RLS requires it to equal auth.uid(), and a before-insert trigger
 * force-sets both it and created_at regardless of what the client sends, so a
 * spoofed author or a backdated timestamp cannot survive. Sending them here
 * would be theatre.
 *
 * After the insert the key result is re-read from the database rather than
 * being updated in place. current_value and score are maintained by triggers
 * (apply_check_in_to_key_result -> recompute_key_result_score) and computing
 * either client-side would let the two drift apart on screen — including the
 * clamping at 0 and 1, and the null score on a degenerate range.
 */
export function CheckInForm({ keyResult }: Props) {
  const router = useRouter();
  const [value, setValue] = useState("");
  const [note, setNote] = useState("");
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);
  const [latest, setLatest] = useState<KeyResult>(keyResult);
  const [saved, setSaved] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);
    setSaved(false);

    const parsed = parseMetricValue(value);
    if (!parsed.ok) {
      setErrors([`New value: ${parsed.reason}`]);
      return;
    }

    setPending(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setErrors(["Your session has expired. Sign in again to check in."]);
      setPending(false);
      return;
    }

    const { error } = await supabase.from("check_in").insert({
      key_result_id: latest.id,
      checked_in_by: user.id,
      new_value: parsed.value,
      note: note.trim() || null,
    });

    if (error) {
      setErrors([okrErrorMessage(error) ?? OKR_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    // Re-read the propagated values instead of guessing them.
    const { data: refreshed } = await supabase
      .from("key_result")
      .select(
        "id, title, metric_unit, start_value, target_value, current_value, score, " +
          "score_override, created_at, updated_at",
      )
      .eq("id", latest.id)
      .maybeSingle();

    if (refreshed) {
      const row = refreshed as unknown as Omit<KeyResult, "effective_score">;
      setLatest({ ...row, effective_score: row.score_override ?? row.score });
    }

    setValue("");
    setNote("");
    setSaved(true);
    setPending(false);
    // Refresh the server-rendered check-in history below the form.
    router.refresh();
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="rounded-2xl border p-5"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      noValidate
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="font-heading text-sm font-semibold" style={{ color: "var(--foreground)" }}>
            {latest.title}
          </h3>
          <p className="font-data mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
            {latest.current_value ?? latest.start_value} / {latest.target_value}{" "}
            {latest.metric_unit ?? ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <ScoreValue score={latest.effective_score} />
          <ScoreBadge score={latest.effective_score} />
        </div>
      </div>

      <div className="mt-3">
        <ProgressBar fraction={latest.effective_score} />
      </div>

      <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-[10rem_1fr]">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`check-in-value-${latest.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            New value
          </label>
          <input
            id={`check-in-value-${latest.id}`}
            inputMode="decimal"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`check-in-note-${latest.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            Note <span style={{ color: "var(--muted-foreground)" }}>(optional)</span>
          </label>
          <input
            id={`check-in-note-${latest.id}`}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="What moved this week?"
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>
      </div>

      {errors.length > 0 && (
        <div
          role="alert"
          className="mt-3 flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
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

      {saved && errors.length === 0 && (
        <p
          className="mt-3 inline-flex items-center gap-1.5 text-sm"
          style={{ color: "var(--good)" }}
        >
          <CheckCircle size={16} weight="bold" aria-hidden="true" />
          Check-in recorded. Progress above is read back from the database.
        </p>
      )}

      <div className="mt-4">
        <button
          type="submit"
          disabled={pending}
          className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          {pending ? "Recording..." : "Record check-in"}
        </button>
      </div>
    </form>
  );
}
