"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { CYCLE_STATUS_LABEL, defaultCycleId, okrErrorMessage, selectableCycles } from "@/lib/okr";
import type { ReviewCycle } from "@/lib/types";

type Props = { cycles: ReviewCycle[] };

/**
 * Create an objective owned by the signed-in user.
 *
 * There is no owner_id field, by design: the owner is read from the session at
 * submit time, never from a hidden input, exactly as the goal-plan editor
 * refuses to render a manager_rating field it isn't allowed to write. A payload
 * naming someone else would be rejected with 42501 anyway.
 *
 * Closed cycles are filtered out of the picker: a closed cycle freezes every
 * OKR write for everyone including HR, so selecting one could only ever
 * produce a 55000 at save time.
 */
export function NewObjectiveForm({ cycles }: Props) {
  const router = useRouter();
  const openCycles = selectableCycles(cycles);

  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [cycleId, setCycleId] = useState(() => defaultCycleId(cycles));
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems: string[] = [];
    if (title.trim().length === 0) {
      problems.push("Give the objective a title.");
    }
    if (!cycleId) {
      problems.push("Pick the review cycle this objective belongs to.");
    }
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setErrors(["Your session has expired. Sign in again to create objectives."]);
      setPending(false);
      return;
    }

    const { data, error } = await supabase
      .from("objective")
      .insert({
        review_cycle_id: cycleId,
        owner_id: user.id,
        title: title.trim(),
        description: description.trim() || null,
      })
      .select("id")
      .single();

    if (error || !data) {
      setErrors([okrErrorMessage(error) ?? "Couldn't create the objective."]);
      setPending(false);
      return;
    }

    setPending(false);
    router.push(`/objectives/${data.id}`);
  }

  if (openCycles.length === 0) {
    return (
      <p
        className="rounded-2xl border border-dashed p-6 text-sm"
        style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
      >
        There&apos;s no open review cycle to set objectives against. Closed cycles are frozen, so
        new objectives can&apos;t be added to them.
      </p>
    );
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
        New objective
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
        New objective
      </h2>

      <div className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="objective-title" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Title
          </label>
          <input
            id="objective-title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Cut onboarding time for new engineers"
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="objective-description"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Description <span style={{ color: "var(--muted-foreground)" }}>(optional)</span>
          </label>
          <textarea
            id="objective-description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={3}
            className="rounded-lg border px-3 py-2 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="objective-cycle" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
            Review cycle
          </label>
          <select
            id="objective-cycle"
            value={cycleId}
            onChange={(e) => setCycleId(e.target.value)}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          >
            {openCycles.map((cycle) => (
              <option key={cycle.id} value={cycle.id}>
                {cycle.name} — {CYCLE_STATUS_LABEL[cycle.status]}
              </option>
            ))}
          </select>
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
          {pending ? "Creating..." : "Create objective"}
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
