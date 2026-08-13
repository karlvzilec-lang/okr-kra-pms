# Brief: Calibration Facilitator UI (okr-kra-pms)

## Context

Repo: `C:\Users\Mark Celiz\Documents\okr-kra-pms` (Next.js App Router + Tailwind v4 frontend in `web/`, Supabase/Postgres backend in `supabase/`). Phase 3 (calibration sessions, bands, participants, the publish/close gate, comp export) is schema-and-function complete but has **no facilitator-facing screen** — HR currently drives calibration via direct SQL/RPC calls, same as `supabase/seed.sql` does. This brief is to build that screen.

Read these files before planning — they are the ground truth, not this summary:
- `supabase/migrations/0012_calibration_tables.sql` — `calibration_session`, `calibration_band`, `calibration_participant`, `employee_goal_plan.published_at`
- `supabase/migrations/0013_calibration_rls.sql` — RLS + the `can_read_calibration_session` / `can_read_calibration_participant` helpers
- `supabase/migrations/0014_calibration_functions.sql` — `add_plan_to_calibration_session`, `adjust_calibration_participant`, `finalize_calibration_session`, `publish_employee_goal_plan`, the shared half-open `[min_score, max_score)` band matcher
- `supabase/migrations/0015_review_summary_and_comp_export.sql` — `employee_review_summary`, `comp_export_rows`, the HR-only explicit-gate pattern (`join public.profiles as caller on caller.id = auth.uid() and caller.is_hr_admin`)
- `web/app/review/page.tsx`, `web/components/*`, `web/lib/*`, `web/app/globals.css` — existing frontend conventions (design tokens, `createClient()` server/browser wrappers, Phosphor icons, `font-heading`/`font-data` classes)
- `scripts/verify.sql` and `VERIFICATION.md` — the existing assertion-suite pattern this feature must extend

## Scope

This is an **HR-only facilitator tool**. It replaces HR's direct function calls with a UI; it does not add any calibration visibility for line managers or employees (that boundary — "the employee never sees a calibrated/final score until HR explicitly publishes it" — already exists and is out of scope to touch).

Two pieces of work, locked as a stable contract so both of you can build in parallel:

### A. Backend: two new read-only RPCs (new migration `0016_calibration_facilitator_views.sql`)

Both are **SECURITY DEFINER, HR-only** (raise `42501` via the same `if not public.is_hr_admin() then raise exception ... using errcode = '42501'` style already used in `0014`) — this is a facilitator tool, not a general RLS-scoped view, so gate explicitly rather than relying on table RLS to shape the result. `revoke all ... from public; grant execute ... to authenticated, service_role;` matching `0014`/`0015`'s style. Do not touch `0012`–`0015` — this is additive only.

**`calibration_session_detail(p_session_id uuid) returns table (detail jsonb)`** — `stable`. Raises `P0002` if the session doesn't exist. Shape of `detail`:

```jsonc
{
  "session": {
    "id": "uuid", "name": "text", "status": "open" | "finalized",
    "review_cycle_id": "uuid", "review_cycle_name": "text",
    "created_at": "timestamptz", "updated_at": "timestamptz"
  },
  "bands": [
    // ordered by sort_order
    { "id": "uuid", "label": "text", "min_score": 0.0, "max_score": 0.0, "sort_order": 0 }
  ],
  "participants": [
    // ordered by band sort_order, then employee_full_name
    {
      "id": "uuid",                      // calibration_participant.id
      "employee_goal_plan_id": "uuid",
      "employee_id": "uuid",
      "employee_full_name": "text",
      "employee_email": "text",
      "manager_full_name": "text | null",
      "original_score": 0.0,
      "calibrated_score": 0.0,
      "band_id": "uuid",
      "facilitator_note": "text | null",
      "published_at": "timestamptz | null",
      "overall_rating_scale_max": 0,
      "updated_at": "timestamptz"
    }
  ]
}
```

**`calibration_eligible_plans(p_session_id uuid) returns table (plan_id uuid, employee_id uuid, employee_full_name text, employee_email text, manager_score numeric)`** — `stable`. Employee goal plans in the session's `review_cycle_id` that (a) have a computed `goal_plan_rating` with `rating_type = 'manager'`, and (b) are **not already** a `calibration_participant` in this session. Ordered by `employee_full_name`. This backs the "add employee to session" picker — it must not require the caller to already know which plans exist.

Session and band **creation** does NOT need a new RPC — `calibration_session_hr_all` / `calibration_band_hr_all` already grant HR full CRUD via RLS (`using (is_hr_admin()) with check (is_hr_admin())`), so the frontend inserts directly via `supabase.from("calibration_session").insert(...)` / `.from("calibration_band").insert([...])`, same pattern the rest of the frontend already uses for direct table reads.

Extend `scripts/verify.sql` and `VERIFICATION.md` with assertions for both new RPCs: a non-HR caller gets `42501` from each; an HR caller gets the right shape and right rows; `calibration_eligible_plans` correctly excludes a plan already added as a participant (use the existing seeded calibration session/participant from Phase 3's `seed.sql` as one fixture, and add a second, never-calibrated seeded plan as the "still eligible" fixture if one doesn't already exist). Keep the running assertion count accurate wherever it's stated (`README.md`'s "25 assertions" line and `scripts/verify.sql`'s own closing `\echo`).

### B. Frontend: `/calibration` (list) and `/calibration/[sessionId]` (facilitator board)

**Routing & access.** Both are Server Components at the top level (matching `web/app/review/page.tsx`'s pattern: `createClient()` from `@/lib/supabase/server`, `supabase.auth.getUser()`, redirect to `/login` if absent). Additionally redirect to `/review` if `profiles.is_hr_admin` is not true — this UI does not exist for non-HR users, full stop. Do **not** add a `loading.tsx` for either route — `web/app/review/loading.tsx` was deliberately removed after a real, reproduced streaming-SSR bug in this environment's browser tooling (see `README.md`'s Frontend section and the git history on that file); follow the same reliability-over-nicety call here.

Add a small "Calibration" nav link to `web/app/review/page.tsx`'s header, visible only when `profile.is_hr_admin` is true, pointing at `/calibration` — this is currently a single-screen app with no nav, and HR needs a way in.

**`/calibration` — session list.** Plain server-side `supabase.from("calibration_session").select(...)` joined/enriched with cycle name and a participant count (either a second query or a Postgres view/count — your call). Rows show name, cycle, status badge (open = accent, finalized = muted/good — pick from the existing token palette, do not invent new CSS variables), participant count, and link to the detail page. A "New session" control opens a form (name, review cycle picker, and at least one band row — label + min + max, addable/removable, client-validated so the ranges are non-overlapping and ascending before submit re-validates it server-side via the DB's own exclusion constraint) that inserts the session then its bands.

**`/calibration/[sessionId]` — the facilitator board.** This is the actual "calibration UI" the task is asking for:

- Header: session name, cycle name, status badge, a **Finalize session** button (only when `status = 'open'`; behind a confirmation dialog since it's a meaningful governance action — no un-finalize exists) and an **Add employee** button (opens the picker backed by `calibration_eligible_plans`).
- **Kanban board**, one column per band ordered by `sort_order`, column header shows the band's label and its `[min_score, max_score)` range. Each participant is a card in the column matching its current `band_id`.
- **Card contents:** employee name + email, manager (line manager) name if present, `original_score` always shown, `calibrated_score` shown alongside it with a delta indicator when they differ (direction matters — this is literally "moderated up/down a band", make it visible at a glance, not just a raw number diff), a truncated `facilitator_note` if set, and a published/unpublished state indicator.
- **Adjusting a score is a modal, not a silent drag-commit.** `calibrated_score` is the real input the database accepts — `band_id` is *derived* from it via the `[min_score, max_score)` matcher, never settable directly. So:
  - Every card has a visible, keyboard-reachable **"Adjust"** button that opens a modal: numeric score input (prefilled with current `calibrated_score`), an optional note textarea (prefilled with current `facilitator_note`), a live client-side preview of which band that score would land in (compute this from the already-fetched `bands` array — same half-open `[min, max)` rule as the DB matcher), Save/Cancel. Save calls `adjust_calibration_participant(p_participant_id, p_new_score, p_note)`.
  - **Drag-and-drop is a convenience on top of the same modal, never a replacement for it.** Use native HTML5 DnD (`draggable`, `onDragStart`/`onDragOver`/`onDrop`) — **do not add a new npm dependency** (no `@dnd-kit`, no `react-beautiful-dnd`); this project's dependency list is deliberately minimal and CI (`npm ci`) doesn't need a new lockfile entry for this. Dropping a card on a different band column **opens the same Adjust modal**, prefilled with a sensible score inside the target band's range (e.g. its midpoint, clamped to stay inside `[min, max)`) instead of the card's current score — HR still confirms or edits the exact number and hits Save. A drop must never call `adjust_calibration_participant` directly without that confirmation step. This is a hard requirement, not a style preference: it's the difference between an HR tool and a way to silently mis-rate someone by a fumbled drag on a touchscreen.
  - This also satisfies accessibility for keyboard-only and touch users for free — the Adjust button is the primitive, drag is sugar.
- **Publish button** per card: enabled once `published_at is null`; calls `publish_employee_goal_plan(p_plan_id)`. Per the existing gate (`publish_employee_goal_plan` in `0014`), this will fail with `55000` while the session is still `open` — surface that as a plain inline error, don't try to prevent the click preemptively via extra client logic beyond "already published → show published state instead of a button." An optional (nice-to-have, not required) bulk **"Publish all"** action once the session is `finalized` is fine to add if time allows but is not load-bearing for this brief.
- **Responsive:** at 375px the kanban columns must not force horizontal page scroll in a broken way — either a deliberate horizontal-scroll region for the board (`overflow-x: auto` on the board container, not the page body) or a stacked single-column layout on narrow viewports; either is acceptable, pick one and apply it consistently. Native drag-and-drop is unreliable on touch — this is exactly why the Adjust-button path must work standalone without ever touching drag.
- **Empty band column:** show a plain "No participants" placeholder, not a broken empty grid.

**Design tokens.** Reuse existing CSS custom properties only (`--background`, `--card`, `--card-foreground`, `--muted`, `--muted-foreground`, `--border`, `--accent`, `--accent-foreground`, `--destructive`, `--good`/`--good-bg`, `--warn`/`--warn-bg`, `--stretch`/`--stretch-bg`, `--ring`) plus `font-heading`/`font-data` utility classes and Phosphor icons (`@phosphor-icons/react`, already a dependency) — do not introduce a second icon set or new color tokens. Match `kra-stat-card.tsx`/`score-badge.tsx`'s existing visual language (rounded-2xl cards, `border`, `min-h-11` touch targets, `cursor-pointer`, `active:scale-[0.98]` press feedback) rather than inventing a new one.

## Deliverable

At the end of this brief, both new routes should be reachable, lint- and build-clean (`npm run lint && npm run build` in `web/`), the new migration should apply cleanly via `supabase db reset`, and `scripts/verify.sql` should pass end to end with the new assertions included.

## What we need from you right now

**Do not implement yet.** Propose your plan/approach only:
- How you'd structure the new migration (0016) and its two RPCs.
- How you'd structure the frontend routes/components (file layout, what's a Server Component vs. a `"use client"` island, how the drag-and-drop + modal interaction is wired).
- Anything in this brief you think is wrong, underspecified, or risky, and what you'd do instead.
- How you'd verify this end-to-end before calling it done.
