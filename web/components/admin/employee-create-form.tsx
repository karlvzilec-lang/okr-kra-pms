"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Plus } from "@phosphor-icons/react/dist/csr/Plus";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { Key } from "@phosphor-icons/react/dist/csr/Key";
import { createEmployeeAction } from "@/app/admin/actions";
import { validateEmployeeDraft } from "@/lib/admin";
import type { ProfileWithManager } from "@/lib/admin-queries";

type Props = { people: ProfileWithManager[] };

/**
 * Provision an employee account.
 *
 * This is the one form on the site that does NOT write through the browser
 * Supabase client. Creating an auth.users row needs the service-role key,
 * which may never reach a browser, so the whole sequence lives behind a Server
 * Action; this component's only job is to collect the fields and render what
 * comes back.
 *
 * There is deliberately no password field. The temporary password is generated
 * server-side and returned exactly once, and the new profile's
 * password_changed_at is left null so the existing forced-rotation redirect
 * makes the person set their own on first sign-in. Letting HR choose the
 * password would put a credential they know into an account they don't own.
 */
export function EmployeeCreateForm({ people }: Props) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [managerId, setManagerId] = useState("");
  const [isHrAdmin, setIsHrAdmin] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);
  const [tempPassword, setTempPassword] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems = validateEmployeeDraft({ fullName, email, managerId, isHrAdmin });
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const result = await createEmployeeAction({
      fullName: fullName.trim(),
      email: email.trim(),
      managerId: managerId || null,
      isHrAdmin,
    });
    setPending(false);

    if (!result.ok) {
      setErrors([result.message]);
      return;
    }

    // temporaryPassword is optional on the result type, so a missing value is
    // surfaced rather than rendered as an empty credential box.
    if (!result.temporaryPassword) {
      setErrors([
        "The account was created, but no temporary password came back. Reset it from Supabase before handing the account over.",
      ]);
      return;
    }

    setTempPassword(result.temporaryPassword);
    setFullName("");
    setEmail("");
    setManagerId("");
    setIsHrAdmin(false);
    setOpen(false);
    router.refresh();
  }

  // Shown once, never re-fetchable: the password is not stored anywhere it
  // could be read back, so if this panel is dismissed before the password is
  // relayed the account has to be reset rather than looked up.
  if (tempPassword) {
    return (
      <div
        role="status"
        className="rounded-2xl border p-5 sm:p-6"
        style={{
          backgroundColor: "color-mix(in srgb, var(--accent) 8%, transparent)",
          borderColor: "var(--accent)",
        }}
      >
        <div className="flex items-center gap-2">
          <Key size={16} weight="bold" style={{ color: "var(--accent)" }} aria-hidden="true" />
          <h2
            className="font-heading text-base font-semibold"
            style={{ color: "var(--foreground)" }}
          >
            Account created
          </h2>
        </div>
        <p className="mt-2 text-sm" style={{ color: "var(--muted-foreground)" }}>
          Give them this temporary password directly — it isn&apos;t emailed and it isn&apos;t
          stored anywhere you can look it up again. They&apos;ll be required to set their own
          password the first time they sign in.
        </p>
        <p
          className="font-data mt-3 rounded-lg border px-3 py-2 text-base break-all"
          style={{
            borderColor: "var(--border)",
            backgroundColor: "var(--background)",
            color: "var(--foreground)",
          }}
        >
          {tempPassword}
        </p>
        <button
          type="button"
          onClick={() => setTempPassword(null)}
          className="mt-4 min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          I&apos;ve saved it
        </button>
      </div>
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
        Add employee
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
        Add employee
      </h2>
      <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
        Creates the sign-in account and the profile together. No email is sent — you&apos;ll get a
        temporary password to pass on yourself.
      </p>

      <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="employee-name"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Full name
          </label>
          <input
            id="employee-name"
            value={fullName}
            onChange={(e) => setFullName(e.target.value)}
            placeholder="Dara Chan"
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
            htmlFor="employee-email"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Email
          </label>
          <input
            id="employee-email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="dara@example.com"
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
            htmlFor="employee-manager"
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Line manager <span style={{ color: "var(--muted-foreground)" }}>(optional)</span>
          </label>
          <select
            id="employee-manager"
            value={managerId}
            onChange={(e) => setManagerId(e.target.value)}
            className="min-h-11 rounded-lg border px-3 text-base outline-none transition-colors focus:border-[var(--accent)] sm:text-sm"
            style={{
              borderColor: "var(--border)",
              backgroundColor: "var(--background)",
              color: "var(--foreground)",
            }}
          >
            <option value="">No line manager</option>
            {people.map((person) => (
              <option key={person.id} value={person.id}>
                {person.full_name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex items-end">
          <label
            className="flex min-h-11 items-center gap-2 text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            <input
              type="checkbox"
              checked={isHrAdmin}
              onChange={(e) => setIsHrAdmin(e.target.checked)}
              className="h-4 w-4"
            />
            HR admin
          </label>
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
          {pending ? "Creating..." : "Create account"}
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
