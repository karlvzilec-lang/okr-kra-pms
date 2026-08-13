export type PasswordCheck = {
  label: string;
  passed: boolean;
};

export function passwordChecks(password: string): PasswordCheck[] {
  return [
    { label: "At least 10 characters", passed: password.length >= 10 },
    { label: "One uppercase letter", passed: /[A-Z]/.test(password) },
    { label: "One lowercase letter", passed: /[a-z]/.test(password) },
    { label: "One number", passed: /[0-9]/.test(password) },
    { label: "One symbol", passed: /[^A-Za-z0-9]/.test(password) },
  ];
}

export function passwordMeetsPolicy(password: string): boolean {
  return passwordChecks(password).every((c) => c.passed);
}

export const PASSWORD_ROTATION_DAYS = 60;

export function isPasswordExpired(passwordChangedAt: string | null): boolean {
  if (!passwordChangedAt) return true;
  const changed = new Date(passwordChangedAt).getTime();
  const ageMs = Date.now() - changed;
  return ageMs > PASSWORD_ROTATION_DAYS * 24 * 60 * 60 * 1000;
}
