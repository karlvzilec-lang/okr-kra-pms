// ============================================================================
// PLACEHOLDER — DELETE AND REPLACE WITH SOL'S REAL FILE AT MERGE.
// ============================================================================
//
// web/app/admin/actions.ts belongs to Sol this round: it owns the service-role
// boundary, the auth + HR re-verification, the Auth Admin API call and the
// compensating delete. None of that is implemented here and none of it should
// be added here.
//
// This file exists only because a TypeScript ambient declaration does not
// satisfy the bundler — Turbopack resolves the import for real, so the UI half
// cannot build against a module that has no file at all. The alternative,
// pointing the form at some other placeholder path, would be worse: it would
// leave a working-looking import that has to be rewritten at merge, and a
// silent no-op is a far more dangerous thing to ship than a loud failure.
//
// So this throws. If it ever runs, the merge was incomplete, and the person
// clicking the button finds out immediately rather than being told an account
// was created that wasn't.
//
// Contract this placeholder pins down (agreed with Sol before either half was
// written — the signature the form calls by):
//
//   createEmployee(input: {
//     fullName: string;
//     email: string;
//     managerId: string | null;
//     isHrAdmin: boolean;
//   }): Promise<{ tempPassword: string } | { error: string }>
//
// Note the return shape carries failure as data rather than as a thrown error:
// a Server Action that throws surfaces as an opaque digest in production, so
// the mapped, readable message has to travel back as a value.

"use server";

export type CreateEmployeeInput = {
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

export type CreateEmployeeResult = { tempPassword: string } | { error: string };

export async function createEmployee(
  input: CreateEmployeeInput,
): Promise<CreateEmployeeResult> {
  throw new Error(
    `app/admin/actions.ts is still the placeholder from the UI half of this round, so ` +
      `no account was created for ${input.email}. Employee provisioning is not wired up ` +
      `until the service-role implementation is merged.`,
  );
}
