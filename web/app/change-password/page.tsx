"use client";

import { useEffect, useMemo, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ShieldCheck } from "@phosphor-icons/react/dist/csr/ShieldCheck";
import { Check } from "@phosphor-icons/react/dist/csr/Check";
import { X } from "@phosphor-icons/react/dist/csr/X";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { passwordChecks, passwordMeetsPolicy } from "@/lib/password";

export default function ChangePasswordPage() {
  const router = useRouter();
  const [checkingSession, setCheckingSession] = useState(true);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getUser().then(({ data }) => {
      if (!data.user) {
        router.replace("/login");
        return;
      }
      setCheckingSession(false);
    });
  }, [router]);

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
    if (confirmMismatch) {
      setError("Those two passwords don't match.");
      return;
    }

    setPending(true);
    const supabase = createClient();

    const { data: userData } = await supabase.auth.getUser();
    if (!userData.user) {
      router.replace("/login");
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

    router.push("/review");
    router.refresh();
  }

  async function handleSignOut() {
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  if (checkingSession) {
    return (
      <main className="flex min-h-dvh flex-1 items-center justify-center" style={{ backgroundColor: "var(--background)" }} />
    );
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
              Set a new password
            </h1>
            <p className="mt-1 max-w-xs text-sm" style={{ color: "var(--muted-foreground)" }}>
              For your account&apos;s security, you need to set your own password before continuing. You&apos;ll be asked again every 60 days.
            </p>
          </div>
        </div>

        <form
          onSubmit={handleSubmit}
          className="rounded-2xl border p-6"
          style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
          noValidate
        >
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
                onChange={(e) => setPassword(e.target.value)}
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
                onChange={(e) => setConfirm(e.target.value)}
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
              className="mt-1 min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pending ? "Updating..." : "Update password"}
            </button>

            <button
              type="button"
              onClick={handleSignOut}
              className="min-h-11 rounded-lg text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
              style={{ color: "var(--muted-foreground)" }}
            >
              Not now, sign out instead
            </button>
          </div>
        </form>
      </div>
    </main>
  );
}
