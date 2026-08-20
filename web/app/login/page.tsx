"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { ChartLineUp } from "@phosphor-icons/react/dist/csr/ChartLineUp";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { Eye } from "@phosphor-icons/react/dist/csr/Eye";
import { EyeSlash } from "@phosphor-icons/react/dist/csr/EyeSlash";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setError(null);

    const supabase = createClient();
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (signInError) {
      setError("That email and password combination doesn't match an account. Check the seed data credentials and try again.");
      setPending(false);
      return;
    }

    router.push("/review");
    router.refresh();
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
            <ChartLineUp size={22} weight="bold" aria-hidden="true" />
          </span>
          <div>
            <h1 className="font-heading text-xl font-semibold" style={{ color: "var(--foreground)" }}>
              Performance Review
            </h1>
            <p className="mt-1 text-sm" style={{ color: "var(--muted-foreground)" }}>
              Sign in to see your KRA and OKR summary
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
                onChange={(e) => setEmail(e.target.value)}
                className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                style={{ borderColor: "var(--border)", backgroundColor: "var(--background)", color: "var(--foreground)" }}
              />
            </div>

            <div className="flex flex-col gap-1.5">
              <label htmlFor="password" className="text-sm font-medium" style={{ color: "var(--foreground)" }}>
                Password
              </label>
              <div className="relative">
                <input
                  id="password"
                  name="password"
                  type={showPassword ? "text" : "password"}
                  autoComplete="current-password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="min-h-11 w-full rounded-lg border px-3 pr-11 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
                  style={{ borderColor: "var(--border)", backgroundColor: "var(--background)", color: "var(--foreground)" }}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((v) => !v)}
                  aria-label={showPassword ? "Hide password" : "Show password"}
                  aria-pressed={showPassword}
                  className="absolute inset-y-0 right-0 flex w-11 items-center justify-center cursor-pointer"
                  style={{ color: "var(--muted-foreground)" }}
                >
                  {showPassword ? (
                    <EyeSlash size={18} weight="bold" aria-hidden="true" />
                  ) : (
                    <Eye size={18} weight="bold" aria-hidden="true" />
                  )}
                </button>
              </div>
              <div className="flex min-h-11 items-center justify-end">
                <Link
                  href="/forgot-password"
                  className="text-sm font-medium transition-colors hover:underline"
                  style={{ color: "var(--accent)" }}
                >
                  Forgot password?
                </Link>
              </div>
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
              {pending ? "Signing in..." : "Sign in"}
            </button>
          </div>
        </form>

        <p className="mt-6 text-center text-xs" style={{ color: "var(--muted-foreground)" }}>
          Local seed data: dara.sok@example.com or ana.manager@example.com, password123
        </p>
      </div>
    </main>
  );
}
