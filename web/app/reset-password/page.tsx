"use client";

import { useEffect, useMemo, useState, type FormEvent } from "react";
import Link from "next/link";
import { Check } from "@phosphor-icons/react/dist/csr/Check";
import { ShieldCheck } from "@phosphor-icons/react/dist/csr/ShieldCheck";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { X } from "@phosphor-icons/react/dist/csr/X";
import { passwordChecks, passwordMeetsPolicy } from "@/lib/password";
import { recoveryLinkError } from "@/lib/password-reset";
import { createClient } from "@/lib/supabase/client";

export default function ResetPasswordPage() {
  const [checkingLink, setCheckingLink] = useState(true);
  const [linkError, setLinkError] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [complete, setComplete] = useState(false);

  useEffect(() => {
    let active = true;
    const hadRecoveryCode = new URLSearchParams(window.location.search).has("code");
    const supabase = createClient();

    async function checkRecoveryLink() {
      const { error: initializationError } = await supabase.auth.initialize();
      const { data } = initializationError
        ? { data: { user: null } }
        : await supabase.auth.getUser();
      const message = recoveryLinkError({
        hadRecoveryCode,
        initializationError,
        userId: data.user?.id ?? null,
      });

      if (active) {
        setLinkError(message);
        setCheckingLink(false);
      }
    }

    void checkRecoveryLink();
    return () => {
      active = false;
    };
  }, []);

  const checks = useMemo(() => passwordChecks(password), [password]);
  const policyMet = passwordMeetsPolicy(password);
  const confirmMismatch = confirm.length > 0 && confirm !== password;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);

    if (!policyMet) {
      setError("Your new password doesn't meet all the requirements below yet.");
      return;
    }
    if (!confirm || confirm !== password) {
      setError("Those two passwords don't match.");
      return;
    }

    setPending(true);
    const supabase = createClient();
    const { data: userData } = await supabase.auth.getUser();

    if (!userData.user) {
      setLinkError("Your password reset session has expired. Request a new link and try again.");
      setPending(false);
      return;
    }

    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) {
      setError(updateError.message || "Couldn't update your password. Try again.");
      setPending(false);
      return;
    }

    const { error: profileError } = await supabase
      .from("profiles")
      .update({ password_changed_at: new Date().toISOString() })
      .eq("id", userData.user.id);

    if (profileError) {
      setError("Your password was updated, but we couldn't record the change. Contact HR if you're asked to change it again immediately.");
      setPending(false);
      return;
    }

    await supabase.auth.signOut();
    setComplete(true);
    setPending(false);
  }

  return (
    <main
      className="flex min-h-dvh flex-1 items-center justify-center px-4 py-12"
      style={{ backgroundColor: "var(--background)" }}
    >
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-3 text-center">
          <span
            className="flex h-11 w-11 items-center justify-center rounded-xl"
            style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
          >
            <ShieldCheck size={22} weight="bold" aria-hidden="true" />
          </span>
          <div>
            <h1 className="font-heading text-xl font-semibold" style={{ color: "var(--foreground)" }}>
              Choose a new password
            </h1>
            <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
              Use a strong password you haven&apos;t used for this account before.
            </p>
          </div>
        </div>

        <section
          className="rounded-2xl border p-6"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
        >
          {checkingLink ? (
            <p role="status" className="text-center text-sm" style={{ color: "var(--muted-foreground)" }}>
              Checking your reset link...
            </p>
          ) : linkError ? (
            <div className="flex flex-col gap-4">
              <div
                role="alert"
                className="flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
                style={{ backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)", color: "var(--destructive)" }}
              >
                <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
                <span>{linkError}</span>
              </div>
              <Link
                href="/forgot-password"
                className="flex min-h-11 items-center justify-center rounded-lg px-4 text-sm font-semibold transition-transform active:scale-[0.98]"
                style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
              >
                Request a new link
              </Link>
            </div>
          ) : complete ? (
            <div className="flex flex-col gap-4 text-center">
              <div
                role="status"
                className="rounded-lg px-3 py-3 text-sm"
                style={{ backgroundColor: "color-mix(in srgb, var(--good) 12%, transparent)", color: "var(--good)" }}
              >
                Your password has been updated. Sign in with your new password.
              </div>
              <Link
                href="/login"
                className="flex min-h-11 items-center justify-center rounded-lg px-4 text-sm font-semibold transition-transform active:scale-[0.98]"
                style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
              >
                Continue to sign in
              </Link>
            </div>
          ) : (
            <form onSubmit={handleSubmit} noValidate>
              <div className="flex flex-col gap-4">
                <div className="flex flex-col gap-1.5">
                  <label htmlFor="new-password" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                    New password
                  </label>
                  <input
                    id="new-password"
                    name="new-password"
                    type="password"
                    autoComplete="new-password"
                    autoFocus
                    required
                    value={password}
                    onChange={(event) => setPassword(event.target.value)}
                    className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                    style={{ borderColor: "var(--border)", backgroundColor: "var(--background)", color: "var(--foreground)" }}
                  />
                </div>

                <ul className="flex flex-col gap-1" aria-label="Password requirements">
                  {checks.map((check) => (
                    <li key={check.label} className="flex items-center gap-2 text-xs" style={{ color: check.passed ? "var(--good)" : "var(--muted-foreground)" }}>
                      {check.passed ? (
                        <Check size={13} weight="bold" aria-hidden="true" />
                      ) : (
                        <X size={13} weight="bold" aria-hidden="true" />
                      )}
                      {check.label}
                    </li>
                  ))}
                </ul>

                <div className="flex flex-col gap-1.5">
                  <label htmlFor="confirm-password" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                    Confirm new password
                  </label>
                  <input
                    id="confirm-password"
                    name="confirm-password"
                    type="password"
                    autoComplete="new-password"
                    required
                    value={confirm}
                    onChange={(event) => setConfirm(event.target.value)}
                    className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                    style={{
                      borderColor: confirmMismatch ? "var(--destructive)" : "var(--border)",
                      backgroundColor: "var(--background)",
                      color: "var(--foreground)",
                    }}
                    aria-invalid={confirmMismatch}
                    aria-describedby={confirmMismatch ? "confirm-error" : undefined}
                  />
                  {confirmMismatch && (
                    <p id="confirm-error" className="text-xs" style={{ color: "var(--destructive)" }}>
                      Passwords don&apos;t match.
                    </p>
                  )}
                </div>

                {error && (
                  <div
                    role="alert"
                    className="flex items-start gap-2 rounded-lg px-3 py-2 text-sm"
                    style={{ backgroundColor: "color-mix(in srgb, var(--destructive) 12%, transparent)", color: "var(--destructive)" }}
                  >
                    <WarningCircle size={16} weight="bold" className="mt-0.5 shrink-0" aria-hidden="true" />
                    <span>{error}</span>
                  </div>
                )}

                <button
                  type="submit"
                  disabled={pending}
                  className="min-h-11 cursor-pointer rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60"
                  style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
                >
                  {pending ? "Updating..." : "Update password"}
                </button>
              </div>
            </form>
          )}
        </section>
      </div>
    </main>
  );
}
