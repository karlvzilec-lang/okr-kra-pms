import Link from "next/link";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { EmployeeCreateForm } from "@/components/admin/employee-create-form";
import { EmployeeEditForm } from "@/components/admin/employee-edit-form";
import { loadAllProfiles, requireHrAdmin } from "@/lib/admin-queries";

/**
 * The employee directory: who exists, who reports to whom, who holds HR admin.
 *
 * The gate is re-run here rather than inherited from layout.tsx. A layout and
 * its page render concurrently in the App Router, so a redirect thrown in the
 * layout does NOT stop this page's loaders from running or keep its markup out
 * of the response body — verified against the running server, where GET /admin
 * with no session returned 307 /login carrying the rendered directory. RLS
 * still scopes every row, so nothing private crossed the wire, but privileged
 * queries must not run for someone already being redirected away.
 *
 * This page reads through the ordinary cookie-backed client, so what it lists
 * is what RLS lets the caller see — the HR gate is what makes that set mean
 * "everyone" rather than "me and my reports".
 *
 * There is no deactivate or delete control. Removing an account would cascade
 * through profiles into goal plans and ratings, and a review history that
 * quietly loses its subject is worse than one that keeps a departed person in
 * it. Deactivation is out of scope this round rather than half-built.
 */
export default async function AdminEmployeesPage() {
  const supabase = await createClient();
  await requireHrAdmin(supabase);

  const people = await loadAllProfiles(supabase);

  return (
    <div className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-8">
      <Link
        href="/review"
        className="mb-6 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
        style={{ color: "var(--muted-foreground)" }}
      >
        <ArrowLeft size={16} weight="bold" aria-hidden="true" />
        Back to my review
      </Link>

      <div className="mb-8">
        <p className="text-sm font-medium" style={{ color: "var(--accent)" }}>
          HR administration
        </p>
        <h1
          className="font-heading mt-1 text-2xl font-semibold sm:text-3xl"
          style={{ color: "var(--foreground)" }}
        >
          Employees
        </h1>
        <p className="mt-2 max-w-2xl text-sm" style={{ color: "var(--muted-foreground)" }}>
          Creating someone here makes both their sign-in account and their profile. They&apos;ll be
          required to set their own password the first time they sign in — no email is sent, so
          you&apos;ll need to pass the temporary one on yourself.
        </p>
      </div>

      <EmployeeCreateForm people={people} />

      <section className="mt-8">
        <h2
          className="font-heading mb-3 text-sm font-semibold uppercase tracking-wide"
          style={{ color: "var(--muted-foreground)" }}
        >
          Everyone ({people.length})
        </h2>

        {people.length === 0 ? (
          <p
            className="rounded-2xl border border-dashed p-6 text-sm"
            style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
          >
            No profiles yet. Add the first employee above.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {people.map((person) => (
              <li
                key={person.id}
                className="flex flex-wrap items-start justify-between gap-4 rounded-2xl border p-5"
                style={{ backgroundColor: "var(--card)", borderColor: "var(--border)" }}
              >
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span
                      className="font-heading truncate text-sm font-semibold"
                      style={{ color: "var(--foreground)" }}
                    >
                      {person.full_name}
                    </span>
                    {person.is_hr_admin && (
                      <span
                        className="rounded-full px-2 py-0.5 text-xs font-medium"
                        style={{
                          backgroundColor: "color-mix(in srgb, var(--accent) 16%, transparent)",
                          color: "var(--accent)",
                        }}
                      >
                        HR admin
                      </span>
                    )}
                    {person.password_changed_at === null && (
                      <span
                        className="rounded-full px-2 py-0.5 text-xs font-medium"
                        style={{
                          backgroundColor: "var(--muted)",
                          color: "var(--muted-foreground)",
                        }}
                      >
                        Hasn&apos;t signed in yet
                      </span>
                    )}
                  </div>
                  <p className="font-data mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                    {person.email}
                  </p>
                  <p className="mt-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
                    {person.manager_name
                      ? `Reports to ${person.manager_name}`
                      : "No line manager"}
                  </p>
                </div>
                <EmployeeEditForm person={person} people={people} />
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
