"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { PencilSimple } from "@phosphor-icons/react/dist/csr/PencilSimple";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { createClient } from "@/lib/supabase/client";
import { ADMIN_BLOCKED_MESSAGE, adminErrorMessage, validateEmployeeEdit } from "@/lib/admin";
import type { ProfileWithManager } from "@/lib/admin-queries";

type Props = {
  person: ProfileWithManager;
  people: ProfileWithManager[];
};

/**
 * Edit an existing profile's name, line manager and HR flag.
 *
 * Unlike creation, this writes through the ordinary browser client, the same
 * way every other form in this app does. Nothing here touches auth.users, so
 * nothing here needs the service-role key: profiles_hr_all already gives an HR
 * admin UPDATE authority on any profile row, and RLS remains the authority on
 * whether the write lands.
 *
 * Email is deliberately not editable. The profiles row and the auth.users
 * identity carry the address independently, so changing it here would move one
 * without the other and leave the person unable to sign in with what the
 * directory says their address is.
 */
export function EmployeeEditForm({ person, people }: Props) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState(person.full_name);
  const [managerId, setManagerId] = useState(person.manager_id ?? "");
  const [isHrAdmin, setIsHrAdmin] = useState(person.is_hr_admin);
  const [errors, setErrors] = useState<string[]>([]);
  const [pending, setPending] = useState(false);

  // A person can't manage themselves (profiles_manager_not_self, 23514), so
  // they're kept out of their own manager picker rather than offered and then
  // rejected at save time.
  const managerOptions = people.filter((candidate) => candidate.id !== person.id);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setErrors([]);

    const problems = validateEmployeeEdit({ fullName, managerId, isHrAdmin }, person.id);
    if (problems.length > 0) {
      setErrors(problems);
      return;
    }

    setPending(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("profiles")
      .update({
        full_name: fullName.trim(),
        manager_id: managerId || null,
        is_hr_admin: isHrAdmin,
      })
      .eq("id", person.id)
      .select("id")
      .maybeSingle();

    if (error) {
      setErrors([adminErrorMessage(error) ?? "Couldn't save those changes."]);
      setPending(false);
      return;
    }
    // An RLS-refused UPDATE is silent: no error, no rows. Without this branch
    // the form would clear and claim success on a write that never happened.
    if (!data) {
      setErrors([ADMIN_BLOCKED_MESSAGE]);
      setPending(false);
      return;
    }

    setPending(false);
    setOpen(false);
    router.refresh();
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] cursor-pointer"
        style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
      >
        <PencilSimple size={16} weight="bold" aria-hidden="true" />
        Edit
      </button>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="w-full" noValidate>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`edit-name-${person.id}`}
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Full name
          </label>
          <input
            id={`edit-name-${person.id}`}
            value={fullName}
            onChange={(e) => setFullName(e.target.value)}
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
            htmlFor={`edit-manager-${person.id}`}
            className="text-sm font-medium"
            style={{ color: "var(--foreground)" }}
          >
            Line manager
          </label>
          <select
            id={`edit-manager-${person.id}`}
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
            {managerOptions.map((candidate) => (
              <option key={candidate.id} value={candidate.id}>
                {candidate.full_name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex items-end sm:col-span-2">
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

      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="submit"
          disabled={pending}
          className="min-h-11 rounded-lg px-4 text-sm font-semibold transition-[transform,opacity] active:scale-[0.98] disabled:opacity-60 cursor-pointer"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          {pending ? "Saving..." : "Save changes"}
        </button>
        <button
          type="button"
          onClick={() => {
            setFullName(person.full_name);
            setManagerId(person.manager_id ?? "");
            setIsHrAdmin(person.is_hr_admin);
            setErrors([]);
            setOpen(false);
          }}
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
