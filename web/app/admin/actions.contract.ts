import {
  createEmployeeAction,
  grantMatrixScopesAction,
  updateEmployeeAction,
} from "./actions";

type ExpectedCreateEmployeeInput = {
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

type ExpectedUpdateEmployeeInput = {
  profileId: string;
  fullName: string;
  email: string;
  managerId: string | null;
  isHrAdmin: boolean;
};

type ExpectedMatrixScopeGrantInput = {
  employeeGoalPlanId: string;
  participantId: string;
  scopes: Array<{
    scopeType: "kra_category" | "objective";
    scopeId: string;
  }>;
};

type ExpectedAdminActionResult =
  | {
      ok: true;
      message: string;
      temporaryPassword?: string;
    }
  | {
      ok: false;
      message: string;
    };

type Equal<Left, Right> =
  (<Value>() => Value extends Left ? 1 : 2) extends
  (<Value>() => Value extends Right ? 1 : 2)
    ? (<Value>() => Value extends Right ? 1 : 2) extends
        (<Value>() => Value extends Left ? 1 : 2)
      ? true
      : false
    : false;

type Expect<Value extends true> = Value;

/**
 * Compile-time integration lock for Jcode's client forms. A parameter rename,
 * FormData conversion, or widened return DTO breaks `tsc`/`next build` here.
 */
export type AdminActionContractAssertions = [
  Expect<
    Equal<
      typeof createEmployeeAction,
      (input: ExpectedCreateEmployeeInput) => Promise<ExpectedAdminActionResult>
    >
  >,
  Expect<
    Equal<
      typeof updateEmployeeAction,
      (input: ExpectedUpdateEmployeeInput) => Promise<ExpectedAdminActionResult>
    >
  >,
  Expect<
    Equal<
      typeof grantMatrixScopesAction,
      (input: ExpectedMatrixScopeGrantInput) => Promise<ExpectedAdminActionResult>
    >
  >,
];
