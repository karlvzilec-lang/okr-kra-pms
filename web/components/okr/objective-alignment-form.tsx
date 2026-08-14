"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ArrowBendUpRight } from "@phosphor-icons/react/dist/csr/ArrowBendUpRight";
import { LockSimple } from "@phosphor-icons/react/dist/csr/LockSimple";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import {
  ADMIN_BLOCKED_MESSAGE,
  adminErrorMessage,
  LINK_IS_PERMANENT_MESSAGE,
  OBJECTIVE_ALIGNMENT_EXPLAINER,
} from "@/lib/admin";
import type { ExistingObjectiveAlignment } from "@/lib/admin-queries";
import type { ObjectiveWithCycle } from "@/lib/types";

type Props = {
  objectiveId: string;
  parents: ObjectiveWithCycle[];
  existing: ExistingObjectiveAlignment | null;
};

/**
 * Align this objective upward to a readable one in the same cycle.
 *
 * Deliberately simpler than the goal cascade form, and for a concrete reason:
 * nothing is created here. objective_alignment links two objectives that both
 * already exist, so a plain insert under the existing policy is sufficient and
 * there is no partial state an RPC would need to protect against. The
 * insert-side rule mirrors goal_alignment exactly — write authority on the
 * CHILD, read authority on the PARENT, not participation in both.
 *
 * child_objective_id is UNIQUE, so an objective aligns upward to exactly one
 * parent, once. When that row exists this renders it as state rather than
 * offering a re-link: a second attempt would be a 23505, and removing it is
 * HR-only, so there is nothing here for the owner to change.
 */
export function ObjectiveAlignmentForm({ objectiveId, parents, existing }: Props) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [parentId, setParentId] = useState("");
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    if (!parentId) {
      setErrors(["Pick the objective this one ladders up to."]);
      return;
    }

    setPending(true);
    const supabase = createClient();

    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      setErrors(["Your session has expired. Sign in again to record links."]);
      setPending(false);
      return;
    }

    const { data, error } = await supabase
      .from("objective_alignment")
      .insert({
        parent_objective_id: parentId,
        child_objective_id: objectiveId,
        // From the session, never a form field. A payload naming someone else
        // is refused, and rendering the field would imply it was a choice.
        created_by: user.id,
      })
      .select("id")
      .maybeSingle();

    if (error) {
      setErrors([adminErrorMessage(error) ?? "Couldn't record that alignment."]);
      setPending(false);
      return;
    }
    if (!data) {
      setErrors([ADMIN_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setPending(false);
    setOpen(false);
    router.refresh();
  }

  if (existing) {
    return (
      <div
        className="rounded-2xl border p-4"
        style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
      >
        <span
          className="inline-flex items-center gap-1 text-xs"
          style={{ color: "var(--muted-foreground)" }}
        >
          <LockSimple size={12} weight="bold" aria-hidden="true" />
          Aligned to
        </span>
        <p className="mt-1 text-sm" style={{ color: "var(--foreground)" }}>
          {existing.parent_title ?? "An objective you can no longer see"}
        </p>
        <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          {LINK_IS_PERMANENT_MESSAGE}
        </p>
      </div>
    );
  }

  if (parents.length === 0) {
    return (
      <p
        className="rounded-2xl border border-dashed p-6 text-sm"
        style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
      >
        There are no other objectives in this cycle visible to you, so there&apos;s nothing to align
        this one to yet.
      </p>
    );
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
        style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
      >
        <ArrowBendUpRight size={16} weight="bold" aria-hidden="true" />
        Align to a higher-level objective
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
      <h3 className="font-heading text-base font-semibold" style={{ color: "var(--foreground)" }}>
        Align this objective
      </h3>
      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
        {OBJECTIVE_ALIGNMENT_EXPLAINER}
      </p>

      <div className="mt-4 flex flex-col gap-1.5">
        <label
          htmlFor="objective-align-parent"
          className="text-sm font-medium"
          style={{ color: "var(--foreground)" }}
        >
          Ladders up to
        </label>
        <select
          id="objective-align-parent"
          value={parentId}
          onChange={(e) => setParentId(e.target.value)}
          className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
          style={{
            borderColor: "var(--border)",
            backgroundColor: "var(--background)",
            color: "var(--foreground)",
          }}
        >
          <option value="">Pick an objective</option>
          {parents.map((parent) => (
            <option key={parent.id} value={parent.id}>
              {parent.title}
            </option>
          ))}
        </select>
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

      <p className="mt-4 text-xs" style={{ color: "var(--muted-foreground)" }}>
        {LINK_IS_PERMANENT_MESSAGE}
      </p>

      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={pending}
          className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          {pending ? "Recording..." : "Record alignment"}
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
