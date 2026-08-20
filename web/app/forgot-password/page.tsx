"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { ArrowLeft } from "@phosphor-icons/react/dist/csr/ArrowLeft";
import { EnvelopeSimple } from "@phosphor-icons/react/dist/csr/EnvelopeSimple";
import { createClient } from "@/lib/supabase/client";
import { PASSWORD_RESET_CONFIRMATION } from "@/lib/password-reset";

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [pending, setPending] = useState(false);
  const [confirmation, setConfirmation] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setConfirmation(null);

    try {
      const supabase = createClient();
      await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${window.location.origin}/reset-password`,
      });
    } finally {
      setConfirmation(PASSWORD_RESET_CONFIRMATION);
      setPending(false);
    }
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
            <EnvelopeSimple size={22} weight="bold" aria-hidden="true" />
          </span>
          <div>
            <h1 className="font-heading text-xl font-semibold" style={{ color: "var(--foreground)" }}>
              Reset your password
            </h1>
            <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
              Enter your work email and we&apos;ll send you a secure reset link.
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
              <label htmlFor="email" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Email
              </label>
              <input
                id="email"
                name="email"
                type="email"
                inputMode="email"
                autoComplete="email"
                autoFocus
                required
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{ borderColor: "var(--border)", backgroundColor: "var(--background)", color: "var(--foreground)" }}
              />
            </div>

            {confirmation && (
              <div
                role="status"
                className="rounded-lg px-3 py-2 text-sm"
                style={{ backgroundColor: "color-mix(in srgb, var(--good) 12%, transparent)", color: "var(--good)" }}
              >
                {confirmation}
              </div>
            )}

            <button
              type="submit"
              disabled={pending}
              className="min-h-11 cursor-pointer rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60"
              style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
            >
              {pending ? "Sending..." : "Send reset link"}
            </button>
          </div>
        </form>

        <Link
          href="/login"
          className="mt-4 flex min-h-11 items-center justify-center gap-2 text-sm font-medium"
          style={{ color: "var(--muted-foreground)" }}
        >
          <ArrowLeft size={16} weight="bold" aria-hidden="true" />
          Back to sign in
        </Link>
      </div>
    </main>
  );
}
