"use server";

import { randomBytes } from "node:crypto";
import { revalidatePath } from "next/cache";
import { passwordMeetsPolicy } from "@/lib/password";
import { getAuthorizedAdminClients } from "@/lib/supabase/admin";

export type AdminActionResult =
  | {
      ok: true;
      message: string;
      temporaryPassword?: string;
    }
  | {
      ok: false;
      message: string;
    };

export type CreateEmployeeInput = {
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

export type UpdateEmployeeInput = {
  profileId: string;
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

export type MatrixScopeGrantInput = {
  employeeGoalPlanId: string;
  participantId: string;
  scopes: Array<{
    scopeType: "kra_category" | "objective";
    scopeId: string;
  }>;
};

type PostgrestLikeError = {
  code?: string | null;
};

type NormalizedEmployeeInput = {
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

type NormalizedMatrixScope = {
  scopeType: "kra_category" | "objective";
  scopeId: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const AUTHORIZATION_MESSAGES = new Set([
  "Your session has expired. Sign in again.",
  "Your employee profile could not be verified.",
  "Change your password before using employee administration.",
  "Employee administration is restricted to HR.",
  "Employee administration is not configured on this server.",
]);

function failure(message: string): AdminActionResult {
  return { ok: false, message };
}

function authorizationFailure(error: unknown): AdminActionResult {
  if (error instanceof Error && AUTHORIZATION_MESSAGES.has(error.message)) {
    return failure(error.message);
  }
  return failure("Employee administration is unavailable. Try again.");
}

function validateEmployeeInput(
  input: CreateEmployeeInput | UpdateEmployeeInput,
): NormalizedEmployeeInput | AdminActionResult {
  if (
    !input ||
    typeof input.fullName !== "string" ||
    typeof input.email !== "string" ||
    (input.managerId !== null && typeof input.managerId !== "string") ||
    typeof input.isHrAdmin !== "boolean"
  ) {
    return failure("The employee details are invalid.");
  }

  const fullName = input.fullName.trim();
  const email = input.email.trim().toLowerCase();
  const managerId = input.managerId?.trim() || null;

  if (fullName.length === 0 || fullName.length > 200) {
    return failure("Enter an employee name between 1 and 200 characters.");
  }
  if (email.length > 320 || !EMAIL_PATTERN.test(email)) {
    return failure("Enter a valid employee email address.");
  }
  if (managerId !== null && !UUID_PATTERN.test(managerId)) {
    return failure("The selected manager is invalid.");
  }

  return {
    fullName,
    email,
    managerId,
    isHrAdmin: input.isHrAdmin,
  };
}

function generateTemporaryPassword(): string {
  // 144 bits of random entropy plus a deterministic policy prefix. The prefix
  // guarantees upper/lower/digit/symbol even if the base64url body happens not
  // to contain one of those classes.
  const password = `Aa1!${randomBytes(18).toString("base64url")}`;
  if (!passwordMeetsPolicy(password)) {
    throw new Error("Temporary password generation failed its policy check.");
  }
  return password;
}

function employeeWriteMessage(error: PostgrestLikeError | null): string {
  switch (error?.code) {
    case "23514":
      return "An employee can't be their own manager.";
    case "23503":
      return "The selected manager no longer exists.";
    case "23505":
      return "An employee with that email already exists.";
    case "42501":
      return "You no longer have permission to manage employees.";
    default:
      return "The employee record could not be saved. Try again.";
  }
}

function matrixScopeMessage(error: PostgrestLikeError | null): string {
  switch (error?.code) {
    case "23514":
      return "That person isn't a matrix manager on this plan.";
    case "23503":
      return "That category or objective no longer exists.";
    case "23505":
      return "That scope is already granted.";
    case "22023":
    default:
      return "We couldn't grant those scopes. Refresh and try again.";
  }
}

async function selectedManagerExists(
  authenticatedClient: Awaited<
    ReturnType<typeof getAuthorizedAdminClients>
  >["authenticatedClient"],
  managerId: string | null,
): Promise<boolean> {
  if (!managerId) return true;

  const { data, error } = await authenticatedClient
    .from("profiles")
    .select("id")
    .eq("id", managerId)
    .maybeSingle();

  return !error && data !== null;
}

export async function createEmployeeAction(
  input: CreateEmployeeInput,
): Promise<AdminActionResult> {
  const normalized = validateEmployeeInput(input);
  if ("ok" in normalized) return normalized;

  let clients: Awaited<ReturnType<typeof getAuthorizedAdminClients>>;
  try {
    clients = await getAuthorizedAdminClients();
  } catch (error) {
    return authorizationFailure(error);
  }

  if (
    !(await selectedManagerExists(
      clients.authenticatedClient,
      normalized.managerId,
    ))
  ) {
    return failure("The selected manager no longer exists.");
  }

  let temporaryPassword: string;
  try {
    temporaryPassword = generateTemporaryPassword();
  } catch {
    return failure("A temporary password could not be generated. Try again.");
  }

  const { data: createdUserData, error: createUserError } =
    await clients.serviceRoleClient.auth.admin.createUser({
      email: normalized.email,
      password: temporaryPassword,
      email_confirm: true,
      user_metadata: { full_name: normalized.fullName },
    });

  if (createUserError || !createdUserData.user) {
    const duplicate =
      createUserError?.code === "email_exists" ||
      createUserError?.code === "user_already_exists";
    return failure(
      duplicate
        ? "An account with that email already exists."
        : "The employee sign-in account could not be created. Try again.",
    );
  }

  const createdUserId = createdUserData.user.id;
  const { error: profileError } = await clients.authenticatedClient
    .from("profiles")
    .insert({
      id: createdUserId,
      full_name: normalized.fullName,
      email: normalized.email,
      manager_id: normalized.managerId,
      is_hr_admin: normalized.isHrAdmin,
      password_changed_at: null,
    });

  if (profileError) {
    const { error: cleanupError } =
      await clients.serviceRoleClient.auth.admin.deleteUser(createdUserId);

    if (cleanupError) {
      return failure(
        "The sign-in account was created, but profile setup and automatic cleanup failed. Remove that Auth user before retrying.",
      );
    }

    return failure(employeeWriteMessage(profileError));
  }

  revalidatePath("/admin");
  revalidatePath("/admin/matrix-scopes");

  return {
    ok: true,
    message: "Employee created. Copy the temporary password now; it won't be shown again.",
    temporaryPassword,
  };
}

export async function updateEmployeeAction(
  input: UpdateEmployeeInput,
): Promise<AdminActionResult> {
  if (!input || typeof input.profileId !== "string") {
    return failure("The employee id is invalid.");
  }

  const profileId = input.profileId.trim();
  if (!UUID_PATTERN.test(profileId)) {
    return failure("The employee id is invalid.");
  }

  const normalized = validateEmployeeInput(input);
  if ("ok" in normalized) return normalized;
  if (normalized.managerId === profileId) {
    return failure("An employee can't be their own manager.");
  }

  let clients: Awaited<ReturnType<typeof getAuthorizedAdminClients>>;
  try {
    clients = await getAuthorizedAdminClients();
  } catch (error) {
    return authorizationFailure(error);
  }

  const { data: currentProfile, error: currentProfileError } =
    await clients.authenticatedClient
      .from("profiles")
      .select("id, email")
      .eq("id", profileId)
      .maybeSingle<{ id: string; email: string }>();

  if (currentProfileError || !currentProfile) {
    return failure("That employee no longer exists.");
  }

  if (
    !(await selectedManagerExists(
      clients.authenticatedClient,
      normalized.managerId,
    ))
  ) {
    return failure("The selected manager no longer exists.");
  }

  const { data: emailOwner, error: emailOwnerError } =
    await clients.authenticatedClient
      .from("profiles")
      .select("id")
      .eq("email", normalized.email)
      .neq("id", profileId)
      .limit(1)
      .maybeSingle();

  if (emailOwnerError) {
    return failure("The employee email could not be checked. Try again.");
  }
  if (emailOwner) {
    return failure("An employee with that email already exists.");
  }

  const previousEmail = currentProfile.email;
  const emailChanged = previousEmail !== normalized.email;

  if (emailChanged) {
    const { error: authUpdateError } =
      await clients.serviceRoleClient.auth.admin.updateUserById(profileId, {
        email: normalized.email,
        email_confirm: true,
      });

    if (authUpdateError) {
      return failure("The employee sign-in email could not be updated. Try again.");
    }
  }

  const { data: updatedProfile, error: profileUpdateError } =
    await clients.authenticatedClient
      .from("profiles")
      .update({
        full_name: normalized.fullName,
        email: normalized.email,
        manager_id: normalized.managerId,
        is_hr_admin: normalized.isHrAdmin,
      })
      .eq("id", profileId)
      .select("id")
      .maybeSingle();

  if (profileUpdateError || !updatedProfile) {
    if (emailChanged) {
      const { error: compensationError } =
        await clients.serviceRoleClient.auth.admin.updateUserById(profileId, {
          email: previousEmail,
          email_confirm: true,
        });

      if (compensationError) {
        return failure(
          "The profile update failed and the Auth email could not be restored. Reconcile that employee's email before retrying.",
        );
      }
    }

    return failure(employeeWriteMessage(profileUpdateError));
  }

  revalidatePath("/admin");
  revalidatePath("/admin/matrix-scopes");

  return {
    ok: true,
    message: "Employee details updated.",
  };
}

function normalizeMatrixScopes(
  input: MatrixScopeGrantInput,
): NormalizedMatrixScope[] | AdminActionResult {
  if (
    !input ||
    typeof input.employeeGoalPlanId !== "string" ||
    typeof input.participantId !== "string" ||
    !UUID_PATTERN.test(input.employeeGoalPlanId) ||
    !UUID_PATTERN.test(input.participantId) ||
    !Array.isArray(input.scopes) ||
    input.scopes.length === 0 ||
    input.scopes.length > 200
  ) {
    return failure("Choose a valid plan, matrix manager, and at least one scope.");
  }

  const scopes: NormalizedMatrixScope[] = [];
  const uniqueScopes = new Set<string>();

  for (const scope of input.scopes) {
    if (
      !scope ||
      (scope.scopeType !== "kra_category" &&
        scope.scopeType !== "objective") ||
      typeof scope.scopeId !== "string" ||
      !UUID_PATTERN.test(scope.scopeId)
    ) {
      return failure("One of the selected scopes is invalid.");
    }

    const key = `${scope.scopeType}:${scope.scopeId}`;
    if (uniqueScopes.has(key)) {
      return failure("Choose each category or objective only once.");
    }
    uniqueScopes.add(key);
    scopes.push({ scopeType: scope.scopeType, scopeId: scope.scopeId });
  }

  return scopes;
}

export async function grantMatrixScopesAction(
  input: MatrixScopeGrantInput,
): Promise<AdminActionResult> {
  const scopes = normalizeMatrixScopes(input);
  if (!Array.isArray(scopes)) return scopes;

  let clients: Awaited<ReturnType<typeof getAuthorizedAdminClients>>;
  try {
    clients = await getAuthorizedAdminClients();
  } catch (error) {
    return authorizationFailure(error);
  }

  const { data: plan, error: planError } = await clients.authenticatedClient
    .from("employee_goal_plan")
    .select("id, review_cycle_id, employee_id")
    .eq("id", input.employeeGoalPlanId)
    .maybeSingle<{
      id: string;
      review_cycle_id: string;
      employee_id: string;
    }>();

  if (planError || !plan) {
    return failure("That employee plan no longer exists.");
  }

  const { data: participant, error: participantError } =
    await clients.authenticatedClient
      .from("profiles")
      .select("id")
      .eq("id", input.participantId)
      .maybeSingle();

  if (participantError || !participant) {
    return failure("That matrix manager no longer exists.");
  }

  const categoryIds = scopes
    .filter((scope) => scope.scopeType === "kra_category")
    .map((scope) => scope.scopeId);
  const objectiveIds = scopes
    .filter((scope) => scope.scopeType === "objective")
    .map((scope) => scope.scopeId);

  if (categoryIds.length > 0) {
    const { data: categories, error: categoryError } =
      await clients.authenticatedClient
        .from("kra_category")
        .select("id")
        .eq("employee_goal_plan_id", plan.id)
        .in("id", categoryIds);

    if (
      categoryError ||
      new Set((categories ?? []).map((category) => category.id)).size !==
        categoryIds.length
    ) {
      return failure("Every category scope must belong to the selected employee's plan.");
    }
  }

  if (objectiveIds.length > 0) {
    const { data: objectives, error: objectiveError } =
      await clients.authenticatedClient
        .from("objective")
        .select("id")
        .eq("review_cycle_id", plan.review_cycle_id)
        .eq("owner_id", plan.employee_id)
        .in("id", objectiveIds);

    if (
      objectiveError ||
      new Set((objectives ?? []).map((objective) => objective.id)).size !==
        objectiveIds.length
    ) {
      return failure(
        "Every objective scope must belong to the selected employee and review cycle.",
      );
    }
  }

  const { data: reviewParticipant, error: participantUpsertError } =
    await clients.authenticatedClient
      .from("review_participant")
      .upsert(
        {
          employee_goal_plan_id: plan.id,
          participant_id: input.participantId,
          role: "matrix_manager",
        },
        {
          onConflict: "employee_goal_plan_id,participant_id,role",
        },
      )
      .select("id")
      .single<{ id: string }>();

  if (participantUpsertError || !reviewParticipant) {
    return failure(matrixScopeMessage(participantUpsertError));
  }

  const { error: scopeInsertError } = await clients.authenticatedClient
    .from("review_participant_scope")
    .insert(
      scopes.map((scope) => ({
        review_participant_id: reviewParticipant.id,
        scope_type: scope.scopeType,
        scope_id: scope.scopeId,
      })),
    );

  if (scopeInsertError) {
    return failure(matrixScopeMessage(scopeInsertError));
  }

  revalidatePath("/admin/matrix-scopes");

  return {
    ok: true,
    message: `${scopes.length} ${scopes.length === 1 ? "scope" : "scopes"} granted.`,
  };
}
