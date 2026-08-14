import "server-only";

import { createClient as createServiceRoleClient } from "@supabase/supabase-js";
import { isPasswordExpired } from "@/lib/password";
import { createClient as createAuthenticatedClient } from "@/lib/supabase/server";

/**
 * Authorize the current request before the service-role secret is even read.
 * There is intentionally no module-level privileged client and no exported
 * raw constructor.
 */
export async function getAuthorizedAdminClients() {
  const authenticatedClient = await createAuthenticatedClient();
  const {
    data: { user },
    error: userError,
  } = await authenticatedClient.auth.getUser();

  if (userError || !user) {
    throw new Error("Your session has expired. Sign in again.");
  }

  const { data: profile, error: profileError } = await authenticatedClient
    .from("profiles")
    .select("password_changed_at")
    .eq("id", user.id)
    .single<{ password_changed_at: string | null }>();

  if (profileError || !profile) {
    throw new Error("Your employee profile could not be verified.");
  }

  // Expiry is checked before the HR gate so an expired credential cannot be
  // used to probe whether the account has elevated access.
  if (isPasswordExpired(profile.password_changed_at)) {
    throw new Error("Change your password before using employee administration.");
  }

  const { data: isHrAdmin, error: hrCheckError } =
    await authenticatedClient.rpc("is_hr_admin");

  if (hrCheckError || isHrAdmin !== true) {
    throw new Error("Employee administration is restricted to HR.");
  }

  // Do not move either read above the authenticated HR checks.
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("Employee administration is not configured on this server.");
  }

  const serviceRoleClient = createServiceRoleClient(
    supabaseUrl,
    serviceRoleKey,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    },
  );

  return {
    authenticatedClient,
    serviceRoleClient,
    user,
  };
}
