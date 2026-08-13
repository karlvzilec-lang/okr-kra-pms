# okr-kra-pms

A proof-of-concept schema for a web-based performance management system covering both **KRA** (Key Result Area) scorecards and **OKR** (Objectives & Key Results) tracking — the two frameworks most mid-size orgs run in parallel, and the two most performance-management tools (SAP SuccessFactors, Oracle Fusion HCM, Workday, Lattice, Betterworks) keep structurally separate rather than merging into one score.

This repo is schema-first: Postgres migrations + Row-Level Security policies for a Supabase backend, built and cross-verified by two independent AI coding agents (Jcode/Claude and Codex/GPT-5.6) with an adversarial cross-challenge round before anything merges, and a live `supabase db reset` + RLS/rollup verification pass before anything ships. See `VERIFICATION.md` for the actual test queries and expected results.

## Design decisions

- **KRA drives the appraisal number, OKR is a strategic overlay.** KRA goals roll up into one weighted rating (Oracle's "Average Method"); OKR key results carry their own 0.0–1.0 score and feed evidence into the same review without being mathematically merged into the KRA rating.
- **Cascade and align are different relationships**, not one generic parent-goal pointer — a cascade copies a manager's goal down to a report; an alignment links two independently pre-existing goals, one link up per goal, many down.
- **Matrix management is a first-class, explicitly-scoped role** — a matrix manager can rate only the specific KRA categories they've been granted, keyed off an explicit grant row, never off the role name alone.
- **Every RLS policy is keyed off an explicit participant/grant table** (`review_participant`, `review_participant_scope`), never off a bare role name or job title — this was a deliberate response to a documented SAP SuccessFactors permissioning quirk where a broadly-granted role surfaced UI for people it shouldn't have applied to.

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

`scripts/verify.sql` is an assertion suite (RLS coverage, the rollup regression guard, the matrix-scope join, the check-in scoring trigger, both Ruling fixes) that runs against a freshly-reset database and fails loudly on any mismatch:

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

Local seed credentials: `dara.sok@example.com` / `password123` (or any other seeded user — see `supabase/seed.sql`).

**Design system:** Data-Dense Dashboard pattern, navy/blue B2B palette (`#0F172A` ink, `#0369A1` accent — WCAG AA/AAA verified in both light and dark), Lexend (headings) + Source Sans 3 (body) + IBM Plex Mono (tabular score data), Phosphor icons. OKR key-result scores use the Viva Goals 0.0–0.4/0.5–0.6/0.7–0.9/1.0 red-amber-green-orange banding convention from the original research.

## Status

- **Phase 1 (done):** KRA goal plans, categories, weighted goals, cascade/align, the Average Method rollup, RLS.
- **Phase 2 (done):** Objective/Key-Result tree, check-ins, OKR alignment, matrix-manager role with scoped ratings, combined KRA+OKR review summary.
- **Frontend (done):** employee review summary page (Next.js + Tailwind + Supabase Auth/SSR).
- **Phase 3 (not started):** Calibration sessions, publish/close gate, comp-cycle export.

See `BRIEF.md` / `RULING.md` (Phase 1) and `BRIEF_PHASE2.md` / `RULING_PHASE2.md` (Phase 2) for the full design rationale and the specific disagreements that were resolved during build.

## License

MIT — see `LICENSE`.
