# Brief: Comp-export frontend surface + pagination pass

Repo: `okr-kra-pms`. Round 4 of the gap-closure effort. Rounds 1-3 are
merged on `master` at `85529e6`. Read `README.md` in full first.

## Ground truth (pre-verified — do not re-derive)

**`comp_export_rows` is a SQL function, not a table/view** —
`public.comp_export_rows(p_review_cycle_id uuid)` in
`0015_review_summary_and_comp_export.sql:138-194`, `security invoker`,
`stable`. Returns `employee_id, full_name, email, manager_full_name,
overall_rating_scale_max, final_score, band_label, published_at` for every
`employee_goal_plan` in the given cycle where `published_at is not null`.
HR-only gate is inline in the function body (a `join profiles as caller ...
and caller.is_hr_admin`), not RLS (functions don't have RLS) — a non-HR
caller gets 0 rows back, not an error. Read-only, no write path exists.
Already granted `execute` to `authenticated` — no new grant needed.

**No UI exists for this at all** — confirmed zero references anywhere in
`web/`. Build `web/app/admin/comp-export/page.tsx` (or similar), HR-only
(same layout/gate pattern as `/admin`), a review-cycle picker (reuse
`loadReviewCycles` from `okr-queries.ts`), and a table rendering the
function's output for the selected cycle. Add a "Download CSV" action —
format the already-fetched rows client-side and trigger a browser download,
no new backend needed; this is genuinely what "export" implies and isn't
much additional work over just rendering a table.

**No page in this repo uses `.range()` anywhere — this round is the first
to introduce real pagination.** Every existing list query is unbounded,
subject only to PostgREST's `max_rows = 1000` (`supabase/config.toml:23`)
repo-wide cap, which also applies to `comp_export_rows` since it's a
stored-procedure-style call through PostgREST (RPCs returning a single JSON
row/scalar, like `employee_review_summary`, are not subject to this the
same way — only row-set-returning calls are).

**Exact list views and their current loaders** (all confirmed unbounded,
no `.range()`/`.limit()` beyond single-row lookups):
- `web/app/admin/page.tsx` → `loadAllProfiles` (`admin-queries.ts:114-133`)
- `web/app/admin/matrix-scopes/page.tsx` → `loadAllProfiles` +
  `loadAdminPlans` (`admin-queries.ts:162-185`) +
  `loadExistingScopeGrants` (`admin-queries.ts:267-276`)
- `web/app/review-cycles/page.tsx` → `loadReviewCycles`
  (`okr-queries.ts:41-48`)
- `web/app/objectives/page.tsx` → `loadReviewCycles` + `loadOwnObjectives`
  (`okr-queries.ts:72-101`)
- `web/app/reports/page.tsx` → `loadManagerReports`
  (`goal-plan-queries.ts:139-150`)
- `web/app/calibration/page.tsx` → two inline queries (session list +
  cycle list, lines 81-91)

**Current seed data is far too small to observe pagination in practice**
(9 profiles, 5 plans, 9 goals, 2 objectives, 1 published/comp-export row —
nowhere near a useful page size, let alone the 1000-row cap). This means
you cannot rely on "it looks right with seed data" as proof pagination
actually works — you must prove it by temporarily bulk-inserting enough
synthetic rows (a local-only `insert ... select generate_series(...)`
snippet run directly against the dev DB, NOT committed to `seed.sql` or any
migration) to genuinely see page 2/3 and confirm prev/next controls behave
correctly, then clean that data up before finishing. State in your summary
exactly how many synthetic rows you inserted and into which table(s) to
prove this.

**`web/lib/types.ts`** (current, 236 lines) has no `CompExportRow` type —
additive only, mirror the function's exact return columns.

**`web/app/review/page.tsx`** nav pattern (current, post-Round-3): three
consecutive HR-only conditional `<Link>` blocks (Calibration, Manage review
cycles, Admin), all gated on `profile?.is_hr_admin`, identical
className/style, before `<LogoutButton />`. A "Compensation export" link
fits the same shape — but consider whether it belongs at `/review`'s
top level or as a sub-link from `/admin` instead (this is a judgment call,
state your reasoning either way).

## Scope for this round

1. **Comp-export UI**: HR-only page, cycle picker, table, CSV download, as
   described above.
2. **Pagination pass**: add page-based (or cursor-based, your call — state
   reasoning) pagination to the list views identified above. Use Supabase's
   `.range(from, to)` with a page-size constant (pick a reasonable default,
   e.g. 25 or 50 — state your reasoning) and prev/next (or page-number)
   controls. Don't over-engineer every single list — prioritize the ones
   most likely to actually grow in real usage (the admin employee list is
   the clearest candidate; judge the others on their merits and say which
   you skipped and why, if any).
3. **`verify.sql`**: `comp_export_rows` coverage is currently thin (no
   multi-row test, no `manager_full_name`/`overall_rating_scale_max`
   correctness test, no zero-published-plans test) — extend it. Pagination
   itself is a frontend concern with no new RLS surface, so it doesn't need
   new SQL assertions unless you introduce a new RPC/function for it (you
   probably don't need to — plain `.range()` on existing PostgREST-exposed
   tables should suffice).

## Explicitly out of scope this round

Any new backend aggregation/export format beyond CSV (no XLSX, no PDF).
Changing `max_rows` in `supabase/config.toml` (1000 is a reasonable local
default; don't touch it without a stated reason). Notifications, hosted
deployment — permanently out per prior rounds.

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons only,
no new dependencies without a strong stated reason (CSV generation should
be plain string-building, not a new library — this is a simple format).
Server Components by default, isolated `"use client"` leaves. `npm run
lint && npm run build` clean before reporting done. Do not touch
`README.md` or copy brief/ruling docs into the repo — Fable handles that
after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Comp-export page route/shape, and where its nav link lives.
- Page-based vs cursor-based pagination choice, and page size, with
  reasoning.
- Which list views get pagination this round and which (if any) you'd
  skip, with reasoning.
- How you'd prove pagination actually works given seed data is too small
  (your synthetic-data-testing plan).
- Division of labor if pairing with another builder.
- `verify.sql` extensions for `comp_export_rows`.
