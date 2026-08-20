export const PASSWORD_RESET_CONFIRMATION =
  "If an account exists for that email, a password reset link is on its way. Check your inbox.";

const INVALID_LINK_MESSAGE =
  "This password reset link is invalid, expired, or has already been used. Request a new link and try again.";

type RecoveryLinkState = {
  hadRecoveryCode: boolean;
  initializationError: unknown;
  userId: string | null;
};

export function recoveryLinkError({
  hadRecoveryCode,
  initializationError,
  userId,
}: RecoveryLinkState): string | null {
  if (initializationError) return INVALID_LINK_MESSAGE;
  if (!hadRecoveryCode) {
    return "This password reset link is missing or incomplete. Request a new link and try again.";
  }
  if (!userId) return INVALID_LINK_MESSAGE;
  return null;
}
