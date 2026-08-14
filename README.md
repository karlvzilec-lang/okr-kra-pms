# okr-kra-pms

A proof-of-concept schema for a web-based performance management system covering both **KRA** (Key Result Area) scorecards and **OKR** (Objectives & Key Results) tracking — the two frameworks most mid-size orgs run in parallel, and the two most performance-management tools (SAP SuccessFactors, Oracle Fusion HCM, Workday, Lattice, Betterworks) keep structurally separate rather than merging into one score.

This repo is schema-first: Postgres migrations + Row-Level Security policies for a Supabase backend, built and cross-verified by two independent AI coding agents (Jcode/Claude and Codex/GPT-5.6) with an adversarial cross-challenge round before anything merges, and a live `supabase db reset` + RLS/rollup verification pass before anything ships. See `VERIFICATION.md` for the actual test queries and expected results.

## Design decisions

- **KRA drives the appraisal number, OKR is a strategic overlay.** KRA goals roll up into one weighted rating (Oracle's "Average Method"); OKR key results carry their own 0.0–1.0 score and feed evidence into the same review without being mathematically merged into the KRA rating.
- **Cascade and align are different relationships**, not one generic parent-goal pointer — a cascade copies a manager's goal down to a report; an alignment links two independently pre-existing goals, one link up per goal, many down.
- **Matrix management is a first-class, explicitly-scoped role** — a matrix manager can rate only the specific KRA categories they've been granted, keyed off an explicit grant row, never off the role name alone.
- **Every RLS policy is keyed off an explicit participant/grant table** (`review_participant`, `review_participant_scope`), never off a bare role name or job title — this was a deliberate response to a documented SAP SuccessFactors permissioning quirk where a broadly-granted role surfaced UI for people it shouldn't have applied to.
- **Calibration is a human-facilitated override, never an algorithm.** Every vendor researched (SAP, Workday, Lattice, Betterworks) explicitly avoids forced-distribution normalization — `calibration_participant` stores the pre-calibration snapshot (`original_score`, immutable) alongside the HR-adjusted value (`calibrated_score`) as the audit trail, and nothing auto-curves anyone's rating.
- **The employee never sees a calibrated/final score until HR explicitly publishes it** (`employee_goal_plan.published_at`) — even mid-calibration, even after the manager's raw rating is already visible. Publishing itself is blocked while the plan's calibration session is still open, so a published score can never be a stale, un-finalized number.
- **Comp export is deliberately more restricted than day-to-day review visibility.** A line manager can already see their own reports' individual reviews, but `comp_export_rows` gates on `is_hr_admin` explicitly — compensation-cycle data gets a narrower circle than performance-review data, as a deliberate governance boundary, not an oversight.
- **A published score is a one-way door.** Building the facilitator UI surfaced a real hole in the original Phase 3 functions: nothing stopped a published plan from being added to a *second*, still-open calibration session, silently changing the employee's already-visible published score without a new publish action. `add_plan_to_calibration_session` now rejects that outright (`published_at is not null` → `55000`), and `calibration_eligible_plans` excludes published plans from the picker so HR never sees the option in the first place.

## Local development

Requires Docker Desktop.

```bash
npm install
npx supabase start
npx supabase db reset   # applies all migrations + seed.sql
```

Local Supabase ports are remapped to `15420`–`15429` in `supabase/config.toml` (the CLI's 54320s defaults fall inside a Windows Hyper-V dynamic port-exclusion range on the machine this was built on — harmless on other platforms, left as-is for portability).

Studio: `http://127.0.0.1:15423` · API: `http://127.0.0.1:15421` · DB: `postgresql://postgres:postgres@127.0.0.1:15422/postgres`

### Automated verification

`scripts/verify.sql` is an assertion suite (RLS coverage across all 18 tables, the rollup regression guard, the matrix-scope join, the check-in scoring trigger, every Ruling fix across all three phases, the calibration finalize/publish gates, the comp-export HR-only boundary, and the facilitator UI's HR-gated read RPCs, atomic session creation, and published-plan recalibration guard — 33 assertions) that runs against a freshly-reset database and fails loudly on any mismatch:

```bash
psql "postgresql://postgres:postgres@127.0.0.1:15422/postgres" -v ON_ERROR_STOP=1 -f scripts/verify.sql
```

The same script gates every push in CI (`.github/workflows/ci.yml`).

## Frontend

`web/` is a Next.js (App Router) + Tailwind v4 app with one real screen: the employee review summary — KRA scorecard and OKR objectives/key results side by side, backed by the `employee_review_summary` RPC and enforced end-to-end by the RLS policies above (log in as a different seeded user and you see a different, correctly-scoped result).

```bash
cd web
npm install
cp .env.example .env.local   # fill in NEXT_PUBLIC_SUPABASE_ANON_KEY from `npx supabase status`
npm run dev
```

Local seed credentials: `dara.sok@example.com` / `password123` (or any other seeded user — see `supabase/seed.sql`). First login forces a password change (see Security, below); after that, the review summary shows the manager rating alongside a "Published calibrated score" card once HR has run the employee through calibration and published the result — the seed data ships with Dara already calibrated (`3.580` → `3.200`, moderated down a band) and published, so this renders on first login rather than needing manual setup.

HR admins (`hr.admin@example.com` / `password123`) also see a "Calibration" link in the header, leading to `/calibration` — the facilitator board. Sessions render as a Kanban of the session's configured bands; every score change goes through an "Adjust" modal (the database only accepts an exact `calibrated_score`, never a band directly, so there's no such thing as a silent commit) with a live preview of which band that score lands in. Dragging a card onto a different band column is a convenience on top of the same modal — it pre-fills a sensible score inside the target band's range and still requires an explicit Save, so a fumbled drag on a touchscreen can't quietly mis-rate someone. Drag runs on one Pointer Events controller (mouse, touch, and pen share the same code path) rather than the HTML5 Drag and Drop API, which never fires on touch at all — each card has a dedicated `touch-action: none` grip handle so a genuine drag never fights the board's own horizontal scroll or the page's vertical scroll, and the board auto-scrolls horizontally when a drag nears either edge, since only about one band column fits on a phone screen at a time. Finalizing a session (behind a confirmation dialog — there's no un-finalize) freezes further adjustment and unblocks publishing, per-plan, from the board.

**Design system:** Data-Dense Dashboard pattern, navy/blue B2B palette (`#0F172A` ink, `#0369A1` accent — WCAG AA/AAA verified in both light and dark), Lexend (headings) + Source Sans 3 (body) + IBM Plex Mono (tabular score data), Phosphor icons. OKR key-result scores use the Viva Goals 0.0–0.4/0.5–0.6/0.7–0.9/1.0 red-amber-green-orange banding convention from the original research.

**Device-agnostic:** verified at 375px (mobile), 768px (tablet), and desktop widths, plus light/dark `prefers-color-scheme`. All interactive controls (inputs, buttons, the password-visibility toggle) hit a 44×44px minimum touch target. Mobile text inputs are 16px to avoid iOS auto-zoom on focus. Every route has a friendly `error.tsx` and `not-found.tsx` — no framework default error pages.

## Security

- **RLS is the primary boundary**, not the frontend — every table is covered (see `scripts/verify.sql`), and policies key off explicit participant/grant rows, never a bare role name. A logged-in user can only ever see what their `review_participant` rows entitle them to, regardless of what the UI shows or hides.
- **Forced password rotation.** HR-provisioned accounts have no password of their own (`profiles.password_changed_at` starts `NULL`), so first login redirects to `/change-password` before anything else is reachable. Passwords expire again after 60 days (`lib/password.ts`'s `PASSWORD_ROTATION_DAYS`), enforced server-side on every load of `/review`, not just client-side.
- **Password policy**: minimum 10 characters, upper + lower + digit + symbol, enforced both client-side (live checklist, immediate feedback) and server-side (`supabase/config.toml`'s `password_requirements` — GoTrue rejects non-compliant passwords on the actual `updateUser` call, so the client check is a UX convenience, not the real gate). Seeded demo passwords (`password123`) are exempt because they're inserted directly as pre-hashed rows, not through this API — that's what makes the forced-first-login-change flow possible to demo at all.
- **Self-service is column-scoped, not just row-scoped.** A user can update their own `profiles` row (needed to record their own password change), but a `BEFORE UPDATE` trigger blocks them from touching anything on that row except `password_changed_at` — name, email, manager, and HR-admin flag stay HR-only, mirroring the same column-level-guard pattern used for line-manager goal ratings in Phase 1.
- **No user enumeration**: the login error message is identical whether the email doesn't exist or the password is wrong.
- **Security headers** (`web/next.config.ts`): `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, a restrictive `Permissions-Policy`, and HSTS. No CSP yet — deliberately deferred rather than shipping a guessed-at policy that might silently break Turbopack's dev-mode HMR; that's the clear next step before a production deploy.
- **Auth rate limiting** is GoTrue's built-in `[auth.rate_limit]` config in `supabase/config.toml` (30 sign-in attempts / 5 min / IP by default) — not reimplemented at the app layer.
- **Known follow-up**: `web/middleware.ts` uses Next.js's now-deprecated `middleware` convention (Next recommends renaming to `proxy.ts`). Left as-is rather than blind-applying an unverified codemod to security-critical session-refresh code — functionally correct, just not on the newest convention name.
- **Known follow-up**: HR's RLS grant on `calibration_session`/`calibration_band` is a blanket `is_hr_admin()` policy, so nothing at the database level stops a direct API call from reopening a finalized session or deleting a band out from under a participant (`band_id` uses `ON DELETE SET NULL`). The facilitator UI doesn't expose an un-finalize or band-delete control, so this isn't reachable through normal use of what's shipped — a deliberate scope boundary for now, not an oversight, and the next thing to harden if this UI's write surface grows.

## Status

- **Phase 1 (done):** KRA goal plans, categories, weighted goals, cascade/align, the Average Method rollup, RLS.
- **Phase 2 (done):** Objective/Key-Result tree, check-ins, OKR alignment, matrix-manager role with scoped ratings, combined KRA+OKR review summary.
- **Phase 3 (done):** Calibration sessions with configurable bands (no hardcoded box count), the publish/close gate, an HR-only comp export surface, and a facilitator UI (Kanban board, Adjust-modal-as-commit-primitive with drag as convenience, session creation, finalize/publish) — including a correctness fix found while building it: a published plan can no longer be silently recalibrated by adding it to a second, still-open session.
- **Frontend (done):** employee review summary page and the HR-only calibration facilitator board (Next.js + Tailwind + Supabase Auth/SSR).

See `BRIEF.md` / `RULING.md` (Phase 1), `BRIEF_PHASE2.md` / `RULING_PHASE2.md` (Phase 2), `BRIEF_PHASE3.md` / `RULING_PHASE3.md` (Phase 3), and `BRIEF_CALIBRATION_UI.md` / `RULING_CALIBRATION_UI.md` (the calibration facilitator UI) for the full design rationale and the specific disagreements that were resolved during build — Phase 3 in particular has two real, independently-reasoned disagreements between the two builders (documented in the ruling) rather than the near-total convergence of the earlier phases, and the calibration UI ruling documents a real correctness bug one builder found in the other's read of the existing schema.

## License

MIT — see `LICENSE`.
