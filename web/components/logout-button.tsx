"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { SignOut } from "@phosphor-icons/react/dist/csr/SignOut";
import { createClient } from "@/lib/supabase/client";

export function LogoutButton() {
  const router = useRouter();
  const [pending, setPending] = useState(false);

  async function handleLogout() {
    setPending(true);
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <button
      type="button"
      onClick={handleLogout}
      disabled={pending}
      className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-4 text-sm font-medium transition-colors hover:bg-[var(--muted)] active:scale-[0.98] disabled:opacity-50 cursor-pointer"
      style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
    >
      <SignOut size={16} weight="bold" aria-hidden="true" />
      {pending ? "Signing out..." : "Sign out"}
    </button>
  );
}
