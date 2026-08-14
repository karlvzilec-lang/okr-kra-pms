"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { PencilSimple } from "@phosphor-icons/react/dist/csr/PencilSimple";
import { WarningCircle } from "@phosphor-icons/react/dist/csr/WarningCircle";
import { updateEmployeeAction } from "@/app/admin/actions";
import { validateEmployeeEdit } from "@/lib/admin";
import type { ProfileWithManager } from "@/lib/admin-queries";

type Props = {
  person: ProfileWithManager;
  people: ProfileWithManager[];
};

/**
 * Edit an existing profile's name, line manager and HR flag.
 *
 * Goes through the same Server Action as creation rather than writing from the
 * browser. RLS would permit the direct write (profiles_hr_all covers it), but
 * routing it through the action keeps ONE authorization path — the action
 * re-verifies auth, password expiry and HR status on every call — and lets the
 * server revalidate the cached admin pages, which a browser-side write cannot
 * do.
 *
 * Email is passed through unchanged. The action requires the field, but this
 * form does not offer it for editing: the profiles row and the auth.users
 * identity carry the address independently, so changing one without the other
 * would leave the person unable to sign in with what the directory shows.
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
    const result = await updateEmployeeAction({
      profileId: person.id,
      fullName: fullName.trim(),
      // Unchanged: this form does not edit the address, but the action's
      // contract requires it.
      email: person.email,
      managerId: managerId || null,
      isHrAdmin,
    });

    if (!result.ok) {
      setErrors([result.message]);
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
