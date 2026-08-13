import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ChartLineUp } from "@phosphor-icons/react/dist/ssr/ChartLineUp";
import { ArrowLeft } from "@phosphor-icons/react/dist/ssr/ArrowLeft";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";
import { CalibrationBoard } from "@/components/calibration/calibration-board";
import { isPasswordExpired } from "@/lib/password";
import type { CalibrationSessionDetail } from "@/lib/calibration";

export default async function CalibrationSessionPage({
  params,
}: PageProps<"/calibration/[sessionId]">) {
  const { sessionId } = await params;
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

  // Expiry gate runs before the HR check, so an expired credential can't be
  // used to probe which accounts have HR admin.
  if (isPasswordExpired(profile?.password_changed_at ?? null)) {
    redirect("/change-password");
  }

  if (!profile?.is_hr_admin) {
    redirect("/calibration");
  }

  const { data, error } = await supabase
    .rpc("calibration_session_detail", { p_session_id: sessionId })
    .single<{ detail: CalibrationSessionDetail }>();

  // P0002 is the RPC's "no such session" signal — a 404, not an error page.
  if (error?.code === "P0002") {
    notFound();
  }

  return (
    <main className="flex flex-1 flex-col" style={{ backgroundColor: "var(--background)" }}>
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
            Calibration
          </span>
        </div>
        <LogoutButton />
      </header>

      <div className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-8">
        <Link
          href="/calibration"
          className="inline-flex min-h-11 items-center gap-1.5 text-sm font-medium"
          style={{ color: "var(--muted-foreground)" }}
        >
          <ArrowLeft size={14} weight="bold" aria-hidden="true" />
          All sessions
        </Link>

        <div className="mt-4">
          {error ? (
            <p
              role="alert"
              className="rounded-2xl border p-4 text-sm"
              style={{
                borderColor: "var(--border)",
                backgroundColor: "color-mix(in srgb, var(--destructive) 8%, transparent)",
                color: "var(--destructive)",
              }}
            >
              Couldn&apos;t load this calibration session: {error.message}
            </p>
          ) : data?.detail ? (
            <CalibrationBoard detail={data.detail} />
          ) : (
            <p
              className="rounded-2xl border border-dashed p-6 text-sm"
              style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
            >
              This calibration session returned no data.
            </p>
          )}
        </div>
      </div>
    </main>
  );
}
