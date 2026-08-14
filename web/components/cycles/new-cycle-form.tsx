"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { okrErrorMessage, validateCycleDraft } from "@/lib/okr";

/**
 * Create a review cycle. There is deliberately no status field: the lifecycle
 * guard requires every cycle to be born in 'draft' and rejects anything else
 * with 55000, so offering the choice would only produce a save-time error.
 * Cycles advance afterwards, one step at a time, via the advance button.
 */
export function NewCycleForm() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems = validateCycleDraft({
      name,
      start_date: startDate,
      end_date: endDate,
    });
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();
    const { error } = await supabase.from("review_cycle").insert({
      name: name.trim(),
      start_date: startDate,
      end_date: endDate,
      // status omitted on purpose — the column defaults to 'draft', which is
      // the only value the insert guard accepts.
    });

    if (error) {
      setErrors([okrErrorMessage(error) ?? "Couldn't create the cycle."]);
      setPending(false);
      return;
    }

    setName("");
    setStartDate("");
    setEndDate("");
    setOpen(false);
    setPending(false);
    router.refresh();
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
        New review cycle
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
        New review cycle
      </h2>
      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
        Every cycle starts as a draft and moves forward one step at a time. Closing a cycle is
        final — there is no way to reopen it.
      </p>

      <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="flex flex-col gap-1.5 sm:col-span-3">
          <label htmlFor="cycle-name" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Cycle name
          </label>
          <input
            id="cycle-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="FY2027 Annual Review"
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="cycle-start" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Start date
          </label>
          <input
            id="cycle-start"
            type="date"
            value={startDate}
            onChange={(e) => setStartDate(e.target.value)}
            className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="cycle-end" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            End date
          </label>
          <input
            id="cycle-end"
            type="date"
            value={endDate}
            onChange={(e) => setEndDate(e.target.value)}
            className="font-data min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
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
          {pending ? "Creating..." : "Create cycle"}
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
