// ============================================================================
// PLACEHOLDER — DELETE AT MERGE. Sol's real implementation supersedes this.
// ============================================================================
//
// web/app/admin/actions.ts belongs to Sol this round: the service-role
// boundary, the auth + password-expiry + HR re-verification, the Auth Admin
// API call, the compensating delete, and revalidatePath() all live there. None
// of that is implemented here and none of it should be added here.
//
// This file exists only because Turbopack resolves the import for real, so a
// TypeScript ambient declaration is not enough to build against. Every function
// throws: if one ever runs, the merge was incomplete, and a loud failure is far
// safer than telling an HR admin an account was created that wasn't.
//
// The signatures below are NOT guesses. They were read off Sol's landed
// sol-admin-ui branch (commit 432d3dd) and verified by merging both halves in a
// scratch worktree and building — which is also how the original placeholder
// names were caught as wrong:
//
//   createEmployee(...)      ->  createEmployeeAction(...)
//   {tempPassword}|{error}   ->  {ok, message, temporaryPassword?}
//
// Sol additionally ships app/admin/actions.contract.ts, a compile-time lock
// that fails `next build` if these shapes drift again. That file is the
// authority; this placeholder simply agrees with it.

"use server";

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

function notMerged(what: string): never {
  throw new Error(
    `app/admin/actions.ts is still the UI-half placeholder, so ${what} did not happen. ` +
      "Replace this file with the implementation from sol-admin-ui before using employee administration.",
  );
}

export async function createEmployeeAction(
  input: CreateEmployeeInput,
): Promise<AdminActionResult> {
  notMerged(`account creation for ${input.email}`);
}

export async function updateEmployeeAction(
  input: UpdateEmployeeInput,
): Promise<AdminActionResult> {
  notMerged(`the profile update for ${input.profileId}`);
}

export async function grantMatrixScopesAction(
  input: MatrixScopeGrantInput,
): Promise<AdminActionResult> {
  notMerged(`the matrix-scope grant on plan ${input.employeeGoalPlanId}`);
}
