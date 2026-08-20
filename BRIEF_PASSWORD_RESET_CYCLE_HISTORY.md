# Brief: Self-service password reset + past review-cycle visibility

Repo: `okr-kra-pms`. Round 6 of the gap-closure effort. Rounds 1-5 are
merged on `master` at `124ca3e`. Read `README.md` in full first.

## Two unrelated features, cleanly separable — treat them as such

## Part A: self-service password reset

**The gap, exact**: the only password-related flow today is
`/change-password`, which is a client-side-gated "you're already logged in
and must set a new password" screen (`useEffect` calls `supabase.auth.
getUser()`; no user → `router.replace("/login")`). It has **no token/OTP
exchange path** — `updateUser({ password })` is called with only the new
password, relying entirely on an already-active session. There is no
"Forgot password?" link anywhere, no `resetPasswordForEmail()` call
anywhere in the repo, confirmed by grep. Someone genuinely locked out has
no way back in through this app at all today.

**This is a real security/UX gap, not a "notification"** — don't conflate
it with the standing "skip real notifications, no provider account exists"
decision from earlier in this effort. That decision was about proactive
business alerts (Telegram-style pings, webhook-driven emails). Password
recovery is a core authentication capability that just happens to need an
email transport, using Supabase Auth's own standard mechanism
(`resetPasswordForEmail()` + a confirm page that exchanges the recovery
token via `updateUser()`), not a third-party integration. Build the real
thing.

**What already exists to build on**: `[local_smtp]` in
`supabase/config.toml:108-118` is `enabled = true` on port `15424` — this
is the Supabase CLI's local email-capture server (what `npx supabase
status` reports as `MAILPIT_URL`). It intercepts any email a local auth
call would send and shows it in a web UI, so a real `resetPasswordForEmail()`
call is fully demonstrable and testable end-to-end locally, with no
external email provider needed. **Production is a separate story**:
`[auth.email.smtp]` (`config.toml:246-253`) is entirely commented out —
no real SMTP host is configured, so this flow would not actually deliver
email outside local dev without that being set up first. That's expected
and fine — document it plainly as a deployment prerequisite (matching how
CSP and the `middleware.ts`→`proxy.ts` rename are already documented as
known, deliberate follow-ups elsewhere in README), don't treat it as a
reason to skip building the real flow.

**Scope**:
1. "Forgot password?" link on `/login`, leading to a request-reset screen
   (email input → `resetPasswordForEmail(email, { redirectTo: ... })`).
   Same "no user enumeration" principle the login page already follows
   (README: "the login error message is identical whether the email
   doesn't exist or the password is wrong") — the request-reset
   confirmation message must not reveal whether the email exists in the
   system.
2. A reset-confirm route that receives Supabase's recovery redirect,
   establishes the recovery session (Supabase's client SDK handles the
   token exchange from the URL automatically when configured correctly —
   verify the exact current-SDK-version mechanism rather than assuming a
   pattern from memory, this has changed across Supabase JS SDK versions),
   and calls `updateUser({ password })` — reuse the exact same password-
   policy validation `/change-password` already has (`web/lib/password.ts`),
   don't reimplement it.
3. Confirm `supabase/config.toml`'s `[auth]` `site_url`/redirect-URL
   allow-list actually permits whatever route you land the user on after
   clicking the email link — read the current config rather than guessing
   it'll just work.

## Part B: past review-cycle visibility on `/review`

**The gap, exact**: `/review`'s only cycle query is
(`web/app/review/page.tsx:32-37`) `.from("review_cycle").select("id, name,
status").order("start_date", { ascending: false }).limit(1).maybeSingle()`
— the single newest-started cycle, full stop. No switcher, no history
link, no way for an employee to see last cycle's results once a new one
starts.

**The good news: everything this needs already exists correctly-scoped,
except the seed data and the UI wiring.**

- `loadReviewCycles` (`web/lib/okr-queries.ts:42-49`) already returns
  every cycle the caller may see, **already correctly RLS-scoped** — HR
  sees all cycles, a regular employee sees only cycles where they have a
  `review_participant` row (i.e., cycles they actually had a plan in),
  via `review_cycle_select_scoped`/`is_review_cycle_participant`
  (`0003_rls_policies.sql:299-307`, `:42-59`). No new RLS, no new query
  variant needed — reuse this function directly for the switcher's option
  list.
- `employee_review_summary(p_review_cycle_id, p_employee_id)`
  (`0015_review_summary_and_comp_export.sql:55-132`) has no hardcoded
  "current cycle" assumption anywhere in its body — it's a plain filter on
  whatever `p_review_cycle_id` you pass, `security invoker`, so it relies
  on the caller's own RLS the same way for any past or present cycle. The
  only reason today's UI never shows a past cycle is that
  `web/app/review/page.tsx` never asks it to.

**What's actually missing**: a cycle-picker UI on `/review` (reusing
`loadReviewCycles`, scoped correctly by construction), and — since
`supabase/seed.sql` commits **exactly one** `review_cycle` row today
(confirmed by full-file read) — a second, closed/past seed cycle with at
least one real plan in it for an existing seeded employee, so past-cycle
visibility is actually demonstrable against committed data rather than
only provable by manually inserting throwaway rows during your own
testing. Decide whose plan to attach it to and what shape (closed cycle,
manager-reviewed or published plan — your call, state your reasoning) —
this is a `seed.sql` addition, treat it with the same care as any other
seed fixture in this repo (real, plausible names/dates/scores, not
placeholder junk).

**No `verify.sql` coverage currently proves an employee can read their own
past cycle** (confirmed: zero matches for any past/prior/second-cycle RLS
test) — add at least one assertion proving `review_cycle_select_scoped`
correctly includes an employee's own past-cycle row and
`employee_review_summary` returns real data for it, plus a negative case
(an unrelated employee can't see it).

## Division of labor

**Password reset (Part A)** and **past-cycle visibility (Part B)** touch
almost entirely disjoint files (auth/login/change-password area vs.
`/review` + `okr-queries.ts` + `seed.sql`) — this is the natural split if
pairing. State your own division in your plan regardless.

## Explicitly out of scope this round

Actual production SMTP configuration (document as a deployment
prerequisite, don't attempt to wire a real provider — no account exists,
matching every prior round's notification-scope decision). Any other
account-recovery method (SMS, security questions). Hosted deployment
(permanently out).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies (Supabase's own auth methods cover this
entirely). Server Components by default, isolated `"use client"` leaves.
`npm run lint && npm run build` clean before reporting done. Do not touch
`README.md` or copy brief/ruling docs into the repo — Fable handles that
after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Exact route shape for the reset-request and reset-confirm screens, and
  how you'll verify the current Supabase JS SDK's actual recovery-token
  exchange mechanism rather than assuming one.
- How you'll test the reset flow works end-to-end locally via Mailpit
  before reporting done — this needs a real, live demonstration, not just
  code that compiles.
- The cycle-switcher's UI shape on `/review`.
- The new seed fixture's exact shape (which employee, what cycle
  name/dates/status, what plan/rating data) and your reasoning for the
  choice.
- Division of labor if pairing with another builder.
- `verify.sql` extensions for the past-cycle RLS coverage.
