"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { FloppyDisk } from "@phosphor-icons/react/dist/csr/FloppyDisk";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import {
  OKR_BLOCKED_MESSAGE,
  okrErrorMessage,
  parseMetricValue,
  validateKeyResultDraft,
  type KeyResultDraft,
} from "@/lib/okr";
import type { KeyResult } from "@/lib/types";

type Props = {
  objectiveId: string;
  keyResults: KeyResult[];
};

const EMPTY_DRAFT: KeyResultDraft = {
  title: "",
  metric_unit: "",
  start_value: "0",
  target_value: "",
};

const inputStyle = {
  borderColor: "var(--border)",
  backgroundColor: "var(--background)",
  color: "var(--foreground)",
} as const;

/**
 * Add key results to an objective and edit their STRUCTURAL columns only:
 * title, metric_unit, start_value, target_value.
 *
 * current_value and score are deliberately absent from every payload here.
 * They belong to the check-in propagation path
 * (apply_check_in_to_key_result -> recompute_key_result_score) and a direct
 * client UPDATE touching them is rejected with 42501 by the column-scope
 * guard. score_override is HR-only and likewise never rendered.
 */
export function KeyResultEditor({ objectiveId, keyResults }: Props) {
  const router = useRouter();
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState<KeyResultDraft>(EMPTY_DRAFT);
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  async function handleAdd(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems = validateKeyResultDraft(draft);
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    const start = parseMetricValue(draft.start_value);
    const target = parseMetricValue(draft.target_value);
    if (!start.ok || !target.ok) return;

    setPending(true);
    const supabase = createClient();
    const { error } = await supabase.from("key_result").insert({
      objective_id: objectiveId,
      title: draft.title.trim(),
      metric_unit: draft.metric_unit.trim() || null,
      start_value: start.value,
      target_value: target.value,
      // current_value is left to the database: it has no meaningful value
      // until the first check-in, and score stays null until then too.
    });

    if (error) {
      setErrors([okrErrorMessage(error) ?? OKR_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setDraft(EMPTY_DRAFT);
    setAdding(false);
    setPending(false);
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-4">
      {keyResults.map((kr) =>
        editingId === kr.id ? (
          <KeyResultEditRow
            key={kr.id}
            keyResult={kr}
            onDone={() => {
              setEditingId(null);
              router.refresh();
            }}
            onCancel={() => setEditingId(null)}
          />
        ) : (
          <div
            key={kr.id}
            className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border p-4"
            style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          >
            <div className="min-w-0">
              <p className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                {kr.title}
              </p>
              <p className="font-data mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                {kr.start_value} → {kr.target_value} {kr.metric_unit ?? ""}
              </p>
            </div>
            <button
              type="button"
              onClick={() => setEditingId(kr.id)}
              className="min-h-11 rounded-lg border px-3 text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              Edit
            </button>
          </div>
        ),
      )}

      {adding ? (
        <form
          onSubmit={handleAdd}
          className="rounded-2xl border p-5"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          noValidate
        >
          <h3 className="font-heading text-sm font-semibold" style={{ color: "var(--foreground)" }}>
            New key result
          </h3>

          <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5 sm:col-span-2">
              <label htmlFor="kr-title" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Title
              </label>
              <input
                id="kr-title"
                value={draft.title}
                onChange={(e) => setDraft((d) => ({ ...d, title: e.target.value }))}
                placeholder="Median time-to-first-PR under 3 days"
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={inputStyle}
              />
            </div>

            <div className="flex flex-col gap-1.5">
              <label htmlFor="kr-start" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Start value
              </label>
              <input
                id="kr-start"
                inputMode="decimal"
                value={draft.start_value}
                onChange={(e) => setDraft((d) => ({ ...d, start_value: e.target.value }))}
                className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={inputStyle}
              />
            </div>

            <div className="flex flex-col gap-1.5">
              <label htmlFor="kr-target" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Target value
              </label>
              <input
                id="kr-target"
                inputMode="decimal"
                value={draft.target_value}
                onChange={(e) => setDraft((d) => ({ ...d, target_value: e.target.value }))}
                className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={inputStyle}
              />
            </div>

            <div className="flex flex-col gap-1.5 sm:col-span-2">
              <label htmlFor="kr-unit" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Metric unit <span style={{ color: "var(--muted-foreground)" }}>(optional)</span>
              </label>
              <input
                id="kr-unit"
                value={draft.metric_unit}
                onChange={(e) => setDraft((d) => ({ ...d, metric_unit: e.target.value }))}
                placeholder="days, %, tickets"
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={inputStyle}
              />
            </div>
          </div>

          {errors.length > 0 && (
            <div
              role="alert"
              className="mt-4 flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
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

          <div className="mt-5 flex flex-wrap gap-2">
            <button
              type="submit"
              disabled={pending}
              className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pending ? "Adding..." : "Add key result"}
            </button>
            <button
              type="button"
              onClick={() => {
                setAdding(false);
                setErrors([]);
              }}
              disabled={pending}
              className="min-h-11 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              Cancel
            </button>
          </div>
        </form>
      ) : (
        <button
          type="button"
          onClick={() => setAdding(true)}
          className="inline-flex min-h-11 w-fit items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          <Plus size={14} weight="bold" aria-hidden="true" />
          Add key result
        </button>
      )}
    </div>
  );
}

/** Structural edit of one key result. Never touches current_value or score. */
function KeyResultEditRow({
  keyResult,
  onDone,
  onCancel,
}: {
  keyResult: KeyResult;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState<KeyResultDraft>({
    title: keyResult.title,
    metric_unit: keyResult.metric_unit ?? "",
    start_value: String(keyResult.start_value),
    target_value: String(keyResult.target_value),
  });
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);

  async function handleSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems = validateKeyResultDraft(draft);
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    const start = parseMetricValue(draft.start_value);
    const target = parseMetricValue(draft.target_value);
    if (!start.ok || !target.ok) return;

    setPending(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("key_result")
      .update({
        title: draft.title.trim(),
        metric_unit: draft.metric_unit.trim() || null,
        start_value: start.value,
        target_value: target.value,
      })
      .eq("id", keyResult.id)
      .select("id");

    if (error) {
      setErrors([okrErrorMessage(error) ?? OKR_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    // Silent RLS refusals return neither an error nor a row.
    if (!data || data.length === 0) {
      setErrors([OKR_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setPending(false);
    onDone();
  }

  return (
    <form
      onSubmit={handleSave}
      className="rounded-2xl border p-4"
      style={{ backgroundColor: "var(--card)", borderColor: "var(--accent)" }}
      noValidate
    >
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5 sm:col-span-2">
          <label
            htmlFor={`kr-edit-title-${keyResult.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            Title
          </label>
          <input
            id={`kr-edit-title-${keyResult.id}`}
            value={draft.title}
            onChange={(e) => setDraft((d) => ({ ...d, title: e.target.value }))}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={inputStyle}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`kr-edit-start-${keyResult.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            Start value
          </label>
          <input
            id={`kr-edit-start-${keyResult.id}`}
            inputMode="decimal"
            value={draft.start_value}
            onChange={(e) => setDraft((d) => ({ ...d, start_value: e.target.value }))}
            className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={inputStyle}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`kr-edit-target-${keyResult.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            Target value
          </label>
          <input
            id={`kr-edit-target-${keyResult.id}`}
            inputMode="decimal"
            value={draft.target_value}
            onChange={(e) => setDraft((d) => ({ ...d, target_value: e.target.value }))}
            className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={inputStyle}
          />
        </div>
        <div className="flex flex-col gap-1.5 sm:col-span-2">
          <label
            htmlFor={`kr-edit-unit-${keyResult.id}`}
            className="text-xs"
            style={{ color: "var(--muted-foreground)" }}
          >
            Metric unit
          </label>
          <input
            id={`kr-edit-unit-${keyResult.id}`}
            value={draft.metric_unit}
            onChange={(e) => setDraft((d) => ({ ...d, metric_unit: e.target.value }))}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={inputStyle}
          />
        </div>
      </div>

      <p className="mt-3 text-xs" style={{ color: "var(--muted-foreground)" }}>
        Progress isn&apos;t editable here. Record a check-in to move the current value — the score
        is recomputed by the database from the check-in, never typed in.
      </p>

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

      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={pending}
          className="inline-flex min-h-11 items-center gap-1.5 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          <FloppyDisk size={14} weight="bold" aria-hidden="true" />
          {pending ? "Saving..." : "Save"}
        </button>
        <button
          type="button"
          onClick={onCancel}
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
