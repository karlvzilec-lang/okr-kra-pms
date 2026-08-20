# Gate 1 Ruling: Password reset + past review-cycle visibility

Jcode and Sol converged almost completely — same routes, same
no-enumeration messaging, same redirect-URL fix, same live-Mailpit test
plan, same cycle-switcher shape, and both independently chose Dara Sok as
the historical-cycle fixture employee. This ruling adopts the union,
resolves the few cosmetic differences, and is final.

## Part A — password reset (both agreed, adopt as-is)

Routes: `/forgot-password` (email → `resetPasswordForEmail(email,
{ redirectTo })`, one fixed confirmation message regardless of whether the
address exists — same no-enumeration principle the login page already
follows) and `/reset-password` (the recovery landing/new-password screen,
reusing `passwordChecks`/`passwordMeetsPolicy` from `web/lib/password.ts`
verbatim, calling `updateUser({ password })`, then stamping
`profiles.password_changed_at` so a reset also satisfies forced rotation
and doesn't immediately bounce the user back through it again). "Forgot
password?" linked from `/login` under the password field.

**Verify the token-exchange mechanism empirically, don't assume it from
either plan's write-up.** Both plans independently landed on "PKCE,
`?code=` param, auto-exchanged by `createBrowserClient`'s URL-session
detection" based on the pinned `@supabase/ssr`/`@supabase/supabase-js`
versions — but both also explicitly committed to confirming this against
the actual installed package source and the actual link Mailpit receives
before finalizing, rather than shipping on the write-up alone. Hold to
that: read the installed `node_modules/@supabase/ssr` source yourself,
inspect the real captured email's link shape, and if auto-exchange doesn't
behave as expected, fall back to the SDK's documented explicit
`exchangeCodeForSession(code)` call rather than mixing in an unrelated
older hash-token pattern. Handle missing/expired/replayed links with a
visible error state, not a blank screen or a silent hang.

**Redirect-URL config**: `supabase/config.toml`'s `site_url` is
`http://127.0.0.1:3000` but `additional_redirect_urls` only contains an
`https` entry with no path — add the exact `http://127.0.0.1:3000/reset-password`
entry (both builders independently found this exact gap; it's real, not a
hypothetical).

**Live Mailpit proof required before reporting done** — both plans'
test sequences are effectively identical, follow them: request a reset for
Dara and for an unknown address (confirm identical response copy, and that
only Dara's produces a captured email), open the real link in Mailpit,
walk it through to a successful password change, sign out, confirm the old
password now fails and the new one works, then test a reused/expired link
shows the error state. Watch for the auth rate limiter (`email_sent`
config) — don't misread a legitimate rate-limit rejection during repeated
testing as a bug in your own code. Reset the database back to committed
seed state when you're done so the seeded demo credentials stay
reproducible for whoever picks this up next.

Production SMTP stays untouched and out of scope — note it for Fable's
post-merge README pass (a deployment prerequisite, same documentation
pattern as CSP and the `middleware.ts`→`proxy.ts` rename), don't attempt
to configure it and don't touch `README.md` yourselves.

## Part B — past review-cycle visibility

**Cycle picker shape (both agreed, adopt as-is)**: `/review?cycle=<uuid>`.
Server Component calls `loadReviewCycles(supabase)` (already correctly
RLS-scoped, no new query needed), selects the requested cycle only if it's
actually present in that RLS-scoped result, else falls back to today's
newest-first default. A small isolated `"use client"` `<select>` leaf
updates the query param, `min-h-11`. The selected cycle drives both
`employee_review_summary` and whatever loads "Edit my goals"/the plan
link, so a stale or cross-cycle edit link can never appear. A visible past
cycle with no plan for this employee renders a plain "no plan in this
cycle" state, not an error. A closed/past cycle gets a quiet read-only
indicator.

**Seed fixture — adopt Sol's concrete numbers, and Sol's "not published"
choice over Jcode's "published" choice.** Both chose Dara Sok as the
employee (README already treats her as the primary demo account) and a
`FY2025 Annual Review` cycle walked `draft → active → self_eval →
manager_eval → closed` through real transitions (never inserted directly
as `closed` — the lifecycle trigger requires this, and the existing seed
already sets this precedent). Use Sol's specific, already-worked-out
numbers so this doesn't need re-deriving:
- One category "Operational Excellence" (100% weight).
- Two goals: "Stabilize payment reconciliation" (weight 60, self 4.0,
  manager 4.0), "Automate month-end exception reporting" (weight 40, self
  5.0, manager 4.0).
- Plan status `manager_reviewed`. Computed via the real
  `compute_goal_plan_rating` calls for both self and manager — never
  hardcode the `goal_plan_rating` rows directly — expected results self
  `4.400`, manager `4.000`.
- Full `review_participant` set: Dara (employee), Ana Kim (line manager),
  Maly Hor (HR admin) — RLS keys off these rows.
- **Leave it unpublished** (Sol's choice, not Jcode's) — Dara's existing
  FY2026 fixture already covers the published+calibrated case from Round
  1; a second historical fixture that's merely `manager_reviewed` and
  unpublished is a materially different, additionally valuable test case
  (proving an employee can see their own past manager rating even without
  ever having gone through calibration/publish), not a duplicate of the
  same shape.
- Vuthy Long deliberately gets no FY2025 row — the negative fixture, per
  both plans.
- Fixed UUIDs, `on conflict do nothing`, re-runnable, matching every
  existing seed block's convention.

## `scripts/verify.sql` — merge both lists, five assertions total

1. As Dara: `review_cycle_select_scoped` returns the FY2025 row (an
   employee sees their own past cycle).
2. As Dara: `employee_review_summary(FY2025, dara)` returns exactly one
   row, with the historical plan's real computed self (`4.400`) and
   manager (`4.000`) ratings — cross-validate against the actual
   `goal_plan_rating` rows the seed produced, not hardcoded constants,
   matching Round 4's established precedent.
3. As Sophea Im (a different employee under a different manager):
   `review_cycle_select_scoped` does **not** return the FY2025 row.
4. As Sophea: `employee_review_summary(FY2025, dara)` returns zero rows —
   both the RLS layer and the `security invoker` RPC's own reliance on
   that RLS are independently pinned, not just one assumed to imply the
   other.
5. As HR: the FY2025 cycle is visible — confirms the HR branch of
   `review_cycle_select_scoped` still short-circuits correctly and wasn't
   accidentally narrowed by anything in this round (Jcode's addition,
   adopt it — cheap, closes an obvious blind spot the other four don't
   cover).

## Division of labor

Both plans said "wouldn't pair this round" for their own solo work, but
since this is running as two parallel builders regardless, split it
exactly along the brief's own natural seam — zero file overlap either way:

**Sol — Part A (password reset)**: `/forgot-password`,
`/reset-password`, `supabase/config.toml`'s `[auth]` redirect-URL entry,
the live Mailpit verification.

**Jcode — Part B (past-cycle visibility)**: `/review` cycle-picker wiring,
any small `okr-queries.ts` addition if genuinely needed (note: per the
brief's own fact-gathering, `loadReviewCycles` should already be
sufficient as-is — don't add a new query variant unless you find a real
reason to during implementation), `supabase/seed.sql`'s FY2025 fixture,
`scripts/verify.sql`'s five assertions.

**Shared contract**: neither touches the other's files. If Part B's seed
fixture additions interact with anything Part A's config changes might
affect (they shouldn't — auth config and seed data are orthogonal), flag
it, don't silently work around a conflict.

## Explicitly out of scope this round

Production SMTP configuration. Any other recovery method (SMS, security
questions). Hosted deployment (permanently out).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies (Supabase's own auth methods cover this
entirely). Server Components by default, isolated `"use client"` leaves.
`npm run lint && npm run build` clean before reporting done. Do not touch
`README.md` or copy brief/ruling docs into the repo — Fable handles that
after merge.

## Execute now

This ruling is approved. Proceed to implementation in your isolated
worktree, following exactly your assigned half above.
