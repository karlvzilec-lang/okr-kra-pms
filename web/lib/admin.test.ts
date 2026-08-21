import assert from "node:assert/strict";
import test from "node:test";
import {
  adminErrorMessage,
  validateEmployeeEdit,
  validateScopeGrant,
} from "./admin.ts";

test("validateEmployeeEdit rejects assigning an employee as their own manager", () => {
  assert.deepEqual(
    validateEmployeeEdit(
      { fullName: "Dara Sok", managerId: "employee-1", isHrAdmin: false },
      "employee-1",
    ),
    ["Someone can't be their own line manager."],
  );
  assert.deepEqual(
    validateEmployeeEdit(
      { fullName: "Dara Sok", managerId: "manager-1", isHrAdmin: false },
      "employee-1",
    ),
    [],
  );
});

test("validateScopeGrant requires a plan, participant, and at least one real scope", () => {
  assert.deepEqual(
    validateScopeGrant({
      planId: "",
      participantId: "",
      categoryIds: [],
      objectiveIds: [],
    }),
    [
      "Pick the goal plan the matrix manager will work on.",
      "Pick the person to grant matrix access to.",
      "Pick at least one KRA category or objective. A matrix manager with no scopes can't see or rate anything.",
    ],
  );
  assert.deepEqual(
    validateScopeGrant({
      planId: "plan-1",
      participantId: "participant-1",
      categoryIds: ["category-1"],
      objectiveIds: [],
    }),
    [],
  );
  assert.deepEqual(
    validateScopeGrant({
      planId: "plan-1",
      participantId: "participant-1",
      categoryIds: [],
      objectiveIds: ["objective-1"],
    }),
    [],
  );
});

test("adminErrorMessage distinguishes duplicate links from silent RLS rejection", () => {
  assert.equal(
    adminErrorMessage({ code: "23505" }),
    "That's already recorded. A goal or objective can only be linked once, and an email address can only belong to one account.",
  );
  assert.equal(
    adminErrorMessage({ code: "PGRST116" }),
    "That was rejected. You may not have permission, or the record moved on before you saved.",
  );
});
