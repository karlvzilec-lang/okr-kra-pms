import assert from "node:assert/strict";
import test from "node:test";
import { recoveryLinkError } from "./password-reset.ts";

test("recoveryLinkError rejects an expired or replayed code even when an old session exists", () => {
  assert.equal(
    recoveryLinkError({
      hadRecoveryCode: true,
      initializationError: new Error("PKCE code exchange failed"),
      userId: "existing-user",
    }),
    "This password reset link is invalid, expired, or has already been used. Request a new link and try again.",
  );
});

test("recoveryLinkError rejects a direct visit without a recovery code", () => {
  assert.equal(
    recoveryLinkError({
      hadRecoveryCode: false,
      initializationError: null,
      userId: "existing-user",
    }),
    "This password reset link is missing or incomplete. Request a new link and try again.",
  );
});

test("recoveryLinkError rejects a code that did not establish a user session", () => {
  assert.equal(
    recoveryLinkError({
      hadRecoveryCode: true,
      initializationError: null,
      userId: null,
    }),
    "This password reset link is invalid, expired, or has already been used. Request a new link and try again.",
  );
});

test("recoveryLinkError accepts an exchanged code with a user session", () => {
  assert.equal(
    recoveryLinkError({
      hadRecoveryCode: true,
      initializationError: null,
      userId: "recovered-user",
    }),
    null,
  );
});
