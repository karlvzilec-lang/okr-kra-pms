"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Trash } from "@phosphor-icons/react/dist/csr/Trash";
import { revokeMatrixScopeAction } from "@/app/admin/actions";

/**
 * Revoke one matrix-scope grant.
 *
 * Two clicks, not a modal: the action is easily reversible (HR can re-grant
 * the same scope from the form above in a few clicks), so this matches the
 * codebase's lightest-weight confirmation pattern rather than reaching for a
 * typed-confirmation modal, which is reserved for the genuinely hard-to-undo
 * calibration-reversal actions.
 */
export function RevokeScopeButton({ scopeId }: { scopeId: string }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConfirm() {
    setPending(true);
    setError(null);
    const result = await revokeMatrixScopeAction(scopeId);
    setPending(false);
    if (!result.ok) {
      setError(result.message);
      setConfirming(false);
      return;
    }
    router.refresh();
  }

  if (error) {
    return (
      <span className="text-xs" style={{ color: "var(--destructive)" }}>
        {error}
      </span>
    );
  }

  if (confirming) {
    return (
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={handleConfirm}
          disabled={pending}
          className="min-h-11 rounded-lg border px-3 text-xs font-semibold transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--destructive)" }}
        >
          {pending ? "Revoking..." : "Confirm revoke"}
        </button>
        <button
          type="button"
          onClick={() => setConfirming(false)}
          disabled={pending}
          className="min-h-11 rounded-lg border px-3 text-xs font-medium transition-colors hover:bg-[var(--muted)] disabled:opacity-60 cursor-pointer"
          style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
        >
          Cancel
        </button>
      </div>
    );
  }

  return (
    <button
      type="button"
      onClick={() => setConfirming(true)}
      aria-label="Revoke this scope grant"
      className="inline-flex h-11 w-11 items-center justify-center rounded-lg border transition-colors hover:bg-[var(--muted)] cursor-pointer"
      style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
    >
      <Trash size={16} weight="bold" aria-hidden="true" />
    </button>
  );
}
