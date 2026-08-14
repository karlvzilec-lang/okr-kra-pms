// Shared, framework-free helpers for HR administration, matrix-scope grants
// and the cascade / alignment link forms. Everything here is pure so the admin
// pages, the goal-link form and the objective-alignment form agree on what
// "valid" and "already linked" mean before anything reaches the database.
//
// Three rules in this file are load-bearing and are NOT stylistic choices:
//
//   1. A cascade link and an alignment link are DIFFERENT things and the UI
//      must keep them distinguishable. A cascade is a top-down copy event —
//      it CREATES a new goal in the employee's own plan, pre-filled from the
//      source. An alignment is a bottom-up link between two goals that both
//      already exist. Merging the two controls would lose the origin
//      direction the schema deliberately models in two separate tables.
//
//   2. Both links are one-shot. goal_cascade.cascaded_goal_id and
//      goal_alignment.child_goal_id are UNIQUE, as is
//      objective_alignment.child_objective_id. Once a goal or objective is the
//      target of a link, a second attempt is a 23505, and there is no unlink
//      path for anyone but HR — UPDATE and DELETE on all three link tables are
//      HR-only. The UI therefore renders an existing link as read-only state
//      and says so in words, rather than letting someone discover it through a
//      failed save.
//
//   3. Denials are silent. RLS refusals on these tables surface as either a
//      zero-row result or a PGRST116, never as a permission exception, so the
//      error mapping below has to treat "nothing came back" as a real,
//      explainable outcome rather than an unexpected one.

import type { ScopeType } from "@/lib/types";

// ---------------------------------------------------------------------------
// Employee provisioning
// ---------------------------------------------------------------------------

export type EmployeeDraft = {
  fullName: string;
  email: string;
  /** "" means no line manager, which the column allows (nullable). */
  managerId: string;
  isHrAdmin: boolean;
};

/**
 * Deliberately permissive: this is a "did you obviously mistype it" check, not
 * an attempt to decide which addresses exist. The database's own uniqueness
 * constraint and Supabase Auth are the real authorities, and both report back
 * through the error mapping below.
 */
const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function validateEmployeeDraft(draft: EmployeeDraft): string[] {
  const problems: string[] = [];

  if (draft.fullName.trim().length === 0) {
    problems.push("Enter the person's full name.");
  }
  if (draft.email.trim().length === 0) {
    problems.push("Enter an email address — it's how they sign in.");
  } else if (!EMAIL_SHAPE.test(draft.email.trim())) {
    problems.push("That doesn't look like an email address.");
  }

  return problems;
}

/**
 * Edits to an existing profile. The email is intentionally absent: changing it
 * here would move the profiles row without moving the auth.users identity the
 * person actually signs in with, leaving the two silently disagreeing. Email
 * changes are out of scope this round rather than half-implemented.
 */
export type EmployeeEdit = {
  fullName: string;
  managerId: string;
  isHrAdmin: boolean;
};

export function validateEmployeeEdit(
  edit: EmployeeEdit,
  employeeId: string,
): string[] {
  const problems: string[] = [];

  if (edit.fullName.trim().length === 0) {
    problems.push("Enter the person's full name.");
  }
  // profiles_manager_not_self (23514). Caught here so the person filling the
  // form reads a sentence instead of a constraint name.
  if (edit.managerId && edit.managerId === employeeId) {
    problems.push("Someone can't be their own line manager.");
  }

  return problems;
}

// ---------------------------------------------------------------------------
// Matrix-scope grants
// ---------------------------------------------------------------------------

export const SCOPE_TYPE_LABEL: Record<ScopeType, string> = {
  kra_category: "KRA category",
  objective: "Objective",
};

export type ScopeGrantDraft = {
  planId: string;
  participantId: string;
  categoryIds: string[];
  objectiveIds: string[];
};

export function validateScopeGrant(draft: ScopeGrantDraft): string[] {
  const problems: string[] = [];

  if (!draft.planId) {
    problems.push("Pick the goal plan the matrix manager will work on.");
  }
  if (!draft.participantId) {
    problems.push("Pick the person to grant matrix access to.");
  }
  if (draft.categoryIds.length === 0 && draft.objectiveIds.length === 0) {
    problems.push(
      "Pick at least one KRA category or objective. A matrix manager with no scopes can't see or rate anything.",
    );
  }

  return problems;
}

// ---------------------------------------------------------------------------
// Cascade / alignment links
// ---------------------------------------------------------------------------

export type CascadeDraft = {
  sourceGoalId: string;
  targetCategoryId: string;
  /** Raw text from the weight input; parsed with lib/goals.ts, not here. */
  weight: string;
};

export function validateCascadeDraft(draft: CascadeDraft): string[] {
  const problems: string[] = [];

  if (!draft.sourceGoalId) {
    problems.push("Pick the goal to cascade from.");
  }
  if (!draft.targetCategoryId) {
    problems.push(
      "Pick which of your KRA categories the copied goal should land in. Cascading doesn't create a category.",
    );
  }

  return problems;
}

/**
 * The wording used everywhere a link already exists. Stated plainly because
 * the alternative — letting someone try again and hit a 23505, or try to
 * remove it and hit a silent zero-row UPDATE — teaches them nothing about why.
 */
export const LINK_IS_PERMANENT_MESSAGE =
  "Links are recorded once and can't be changed or removed here. Ask HR if this one is wrong.";

export const CASCADE_EXPLAINER =
  "Cascading copies one of your manager's goals into your own plan as a new goal, and records where it came from. The copy is yours to reweight and rate; the original stays with your manager.";

export const ALIGNMENT_EXPLAINER =
  "Aligning links a goal you already have to a higher-level goal, without copying anything. Use it when the work already existed and you're recording how it ladders up.";

export const OBJECTIVE_ALIGNMENT_EXPLAINER =
  "Aligning links this objective to a higher-level one you can see. Nothing is copied, and an objective can align upward to only one parent.";

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

type PostgrestLikeError = {
  code?: string;
  message?: string;
  details?: string | null;
};

/**
 * Turn a PostgREST / RPC failure into something the person in front of the
 * form can act on.
 *
 * The codes here are the ones this feature's own constraints and triggers
 * actually raise, not a generic catalogue:
 *
 *   23505  a uniqueness constraint — for the link tables this always means
 *          "already linked", because the unique is on the target column.
 *   23514  a CHECK — profiles_manager_not_self, the no-self-link checks, or
 *          enforce_scope_participant_is_matrix rejecting a non-matrix row.
 *   23503  an FK or the polymorphic scope-target trigger: the thing being
 *          pointed at no longer exists.
 *   22023  validate_scope_target_exists hitting an unhandled scope_type.
 *   42501  an explicit permission denial.
 *   PGRST116 zero rows from a write that expected one — which is exactly what
 *          a silent RLS refusal looks like from the client.
 */
export function adminErrorMessage(error: PostgrestLikeError | null): string | null {
  if (!error) return null;

  switch (error.code) {
    case "23505":
      return "That's already recorded. A goal or objective can only be linked once, and an email address can only belong to one account.";
    case "23514":
      return (
        error.message ??
        "The database rejected that combination. Check that the person is a matrix manager on this plan and isn't being set as their own manager."
      );
    case "23503":
      return "That points at a record that no longer exists. Refresh and try again.";
    case "22023":
      return "That request wasn't understood by the database. Refresh and try again.";
    case "42501":
      return (
        error.message ??
        "You aren't allowed to do that. Employee accounts and matrix access are HR-only."
      );
    case "PGRST116":
      return "That was rejected. You may not have permission, or the record moved on before you saved.";
    default:
      return error.message ?? "Something went wrong. Try again.";
  }
}

/**
 * Shared wording for "the statement ran but produced nothing", which is how an
 * RLS-blocked write reads from the client — no exception, no rows.
 */
export const ADMIN_BLOCKED_MESSAGE =
  "That didn't go through. The database refused it — refresh to see the current state.";
