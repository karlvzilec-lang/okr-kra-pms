import Link from "next/link";
import { redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { Users } from "@phosphor-icons/react/dist/ssr/Users";
import { ShieldCheck } from "@phosphor-icons/react/dist/ssr/ShieldCheck";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { isPasswordExpired } from "@/lib/password";

/**
 * Shared shell and gate for every /admin route.
 *
 * Password expiry is checked BEFORE the HR check, matching /calibration and
 * /review-cycles: an expired credential must not be able to probe who holds
 * HR admin by comparing a 403 against a redirect.
 *
 * This gate is a convenience, not the security boundary. Every write beneath
 * it re-verifies independently — the Server Action because it can be invoked
 * directly without ever rendering this layout, and the client-side writes
 * because RLS, not this component, is what actually decides. A layout gate
 * alone would be a single point of failure for a whole section.
 */
export default async function AdminLayout({ children }: LayoutProps<"/admin">) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("is_hr_admin, password_changed_at")
    .eq("id", user.id)
    .single();

  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  if (!profile?.is_hr_admin) {
    return (
      <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
        <AdminHeader showNav={false} />
        <div className="mx-auto w-full max-w-2xl flex-1 px-4 py-16 sm:px-8">
          <h1 className="font-heading text-2xl font-semibold" style={{ color: "var(--foreground)" }}>
            Administration is HR-only
          </h1>
          <p className="mt-2 text-sm" style={{ color: "var(--muted-foreground)" }}>
            Employee accounts and matrix access are managed by HR. Your own goals and objectives are
            on your review page.
          </p>
          <Link
            href="/review"
            className="mt-6 inline-flex min-h-11 items-center rounded-lg px-4 text-sm font-semibold"
            style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
          >
            Back to my review
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
      <AdminHeader showNav />
      {children}
    </main>
  );
}

function AdminHeader({ showNav }: { showNav: boolean }) {
  return (
    <header
      className="sticky top-0 z-10 flex h-16 items-center justify-between border-b px-4 sm:px-8"
      style={{ backgroundColor: "var(--background)", borderColor: "var(--border)" }}
    >
      <div className="flex items-center gap-2.5">
        <span
          className="flex h-8 w-8 items-center justify-center rounded-lg"
          style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
        >
          <ChartLineUp size={16} weight="bold" aria-hidden="true" />
        </span>
        <span className="font-heading text-sm font-semibold" style={{ color: "var(--foreground)" }}>
          Administration
        </span>
      </div>
      <div className="flex items-center gap-2">
        {showNav && (
          <>
            <Link
              href="/admin"
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <Users size={16} weight="bold" aria-hidden="true" />
              Employees
            </Link>
            <Link
              href="/admin/matrix-scopes"
              className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)]"
              style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
            >
              <ShieldCheck size={16} weight="bold" aria-hidden="true" />
              Matrix access
            </Link>
          </>
        )}
        <LogoutButton />
      </div>
    </header>
  );
}
