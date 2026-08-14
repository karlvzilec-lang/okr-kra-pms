# Brief: Admin UI — employee management, goal cascade/alignment creation, matrix-manager scope grants

Repo: `okr-kra-pms`. Round 3 of the gap-closure effort. Rounds 1 (Goal/Rating
UI) and 2 (Review cycle + OKR UI) are merged on `master` at `a7b927b`. Read
`README.md` in full first, especially the "Design decisions" and "Security"
sections — this round touches the account-provisioning boundary described
there ("HR-provisioned accounts have no password of their own").

## User decision already made — read this first

The user was asked whether this round should build real new-employee account
creation (needs the Supabase Auth Admin API + a service-role key, server-side
only) or scope down to editing existing accounts only. **They chose full
account creation.** This is not open for re-litigation — implement it. It
does mean this round touches server-side secret handling for the first time
in this repo; treat that with the care the existing Security section already
shows for password policy and rate limiting.

## Ground truth (pre-verified — do not re-derive)

**`profiles` table** (`0001_core_tables.sql:57-69`): `id` (FK `auth.users`,
cascade), `full_name`, `email` (unique), `manager_id` (FK `profiles`, `on
delete set null`, self-reference check), `is_hr_admin` (default `false`),
`created_at`, `updated_at`. `0011_password_policy.sql` adds
`password_changed_at` (nullable, no default — `null` is what triggers the
forced first-login password change per `lib/password.ts`).

**`profiles` RLS**: `profiles_select_scoped` (self, HR, or your own manager
can see you — `0003_rls_policies.sql:276-286`). `profiles_hr_all` (`for
all`, `0003:288-293`) — **HR is the only INSERT path today**, no other
INSERT policy exists. `profiles_self_update` (`0011:57-63`) — row-scoped to
self, but a `BEFORE UPDATE` trigger (`restrict_profile_self_updates`,
`0011:23-55`) column-scopes it down to `password_changed_at` only; every
other column requires `is_hr_admin()`.

**No app-facing signup/invite path exists anywhere today.** Every account
(`auth.users` + `profiles` row) was created by a direct `insert into
auth.users` in `seed.sql`, run with database-owner privileges, entirely
outside any Supabase Auth API call. `web/lib/supabase/` has exactly two
files (`client.ts`, `server.ts`), both using only
`NEXT_PUBLIC_SUPABASE_URL`/`NEXT_PUBLIC_SUPABASE_ANON_KEY` — **no
service-role client exists anywhere in `web/`, and there is no
`.env.example` file anywhere in the repo** (README.md references `cp
.env.example .env.local` for a file that doesn't actually exist — fix that
as part of this round's polish, it's a genuine pre-existing gap, not
in-scope-creep to notice it and fix it in passing).

**Local service-role key for `.env.local` / `.env.example` documentation**
(from `npx supabase status` on this machine — a fixed local Supabase CLI
demo value, not a real secret, safe to put directly in `.env.example` as the
literal default the way the anon key already is; every developer running
`npx supabase start` locally gets this exact same value, it's baked into the
CLI's default `config.toml`/JWT secret):
```
SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU
```
This must **never** be `NEXT_PUBLIC_*` — it is a server-only secret,
readable only in Server Components / server-side code, never sent to the
client. A leaked service-role key bypasses RLS entirely, so any new
service-role client must be constructed only inside server-side code paths
that are themselves already gated on `is_hr_admin()`, and must never be
importable from a Client Component.

**Goal cascade / alignment tables — all three follow the same "child-write +
parent-read + self-attributed" RLS shape, and non-HR users can already
insert them today** (this is unlike `profiles`/`review_participant`, which
are HR-only — don't assume this needs an HR gate, it doesn't, per existing
RLS):

`goal_cascade` (`0002_relationship_tables.sql:15-25`): `source_goal_id` (FK
`goal`), `cascaded_goal_id` (FK `goal`, **unique** — a goal can be the
result of only one cascade), `cascaded_by`, `cascaded_at`. RLS insert
(`0003:464-476`): `is_hr_admin() or (can_write_goal(cascaded_goal_id) and
can_read_goal(source_goal_id) and cascaded_by = auth.uid())`.

`goal_alignment` (`0002:32-40`): `parent_goal_id`, `child_goal_id` (FK
`goal`, **unique** — one parent per child, many children per parent),
`created_by`, `created_at`. RLS insert (`0003:508-520`): same shape,
`can_write_goal(child_goal_id) and can_read_goal(parent_goal_id) and
created_by = auth.uid()`.

`objective_alignment` (`0006_okr_tables.sql:124-133`): identical shape at
the OKR level — no OKR cascade table exists by design (the 0006 header
comment explains: OKR tools link objectives, they don't copy them). RLS
insert (`0008_okr_matrix_rls.sql:355-367`): same shape.

All three also have HR-only UPDATE/DELETE policies — a non-HR creator can
insert the link but never edit or unlink it themselves.

**The cascade workflow needs a real design decision, not just a form.** The
RLS requires `cascaded_goal_id` to already reference an existing `goal` row
that the caller can write. So either: (a) the target goal must already exist
(created normally through the Round-1 goal-plan editor) before it can be
linked via cascade — meaning the UI is "pick an existing goal in a report's
plan, pick one of the manager's own goals, link them" — or (b) the UI
creates the target goal AND the cascade link in one action, pre-filling the
new goal's text/target from the source goal (closer to what "cascade" means
in real KRA tools — a manager's goal gets copied down as a starting point,
not manually retyped). Decide which during planning and state your
reasoning; (b) is more useful but touches `goal`/`kra_category` INSERT as
well as `goal_cascade` INSERT in one transaction-shaped action, so weigh the
complexity against the value honestly rather than defaulting to whichever is
easier to build.

**`review_participant`** (`0002:48-56`): `employee_goal_plan_id`,
`participant_id`, `role` (`participant_role` enum — includes at least
`line_manager`, `matrix_manager`), unique per `(plan, participant, role)`.
RLS (`0003:541-557`): `review_participant_hr_all` is a blanket `for all` —
**INSERT is HR-only**, no narrower path exists.

**`review_participant_scope`** (`0007_matrix_tables.sql:25-33`):
`review_participant_id` (FK `review_participant`), `scope_type`
(`'kra_category' | 'objective'`), `scope_id` (polymorphic, no FK — validated
by trigger), unique per `(participant, scope_type, scope_id)`. RLS
(`0008:388-401`): same blanket-HR-only shape. Two enforcement triggers
backstop integrity (not access control): `enforce_scope_participant_is_matrix`
(the participant row's `role` must actually be `matrix_manager`, else
`23514`) and `validate_scope_target_exists` (the `kra_category`/`objective`
referenced by `scope_id` must actually exist, else `23503`; an unhandled
`scope_type` raises `22023`).

**Practical implication**: granting matrix-manager rights is a two-step HR
action — first ensure a `review_participant` row exists with `role =
'matrix_manager'` for that person on that specific employee's plan (create
one if it doesn't), then grant one or more `review_participant_scope` rows
(a `kra_category` or an `objective`) to that participant row. Both steps are
HR-only; design the UI as one coherent flow rather than two disconnected
screens, but the two inserts are real, separate table writes.

**`web/lib/types.ts`** (current, 147 lines) has no `Profile`,
`GoalCascade`/`GoalAlignment`/`ObjectiveAlignment`, or
`ReviewParticipant`/`ReviewParticipantScope` types — all new, additive only,
same rule as every prior round (don't touch existing exports).

**`web/app/review/page.tsx`** nav pattern (current, post-Round-2): identical
conditional-`Link` blocks, both existing HR-only links (Calibration, Manage
review cycles) sit last before `<LogoutButton />`. A new "Admin" link
(`profile?.is_hr_admin`) fits the same shape.

**`verify.sql` coverage gaps** (confirmed by direct grep): `profiles`
INSERT has zero coverage (only three UPDATE tests exist, none of which
insert). `goal_cascade` has zero coverage of any kind beyond the
RLS-enabled-on-every-table sweep. `review_participant_scope` has zero
coverage of any kind. `goal_alignment` and `objective_alignment` already
have one positive INSERT test each (no negative/denied test for either,
also worth adding). `review_participant` is only ever inserted as
fixture setup (table-owner role, not through RLS as a real test) —
worth adding a real positive/negative RLS test for it too.

## Scope for this round

1. **Employee management UI (HR only)**: list all employees (name, email,
   manager, HR-admin flag). Create a new employee — creates both the
   `auth.users` row (via the Supabase Auth Admin API, server-side, using the
   new service-role client) with a temporary/random password (matching the
   existing "no password of their own, forced change on first login" model
   — don't invent a different provisioning story) and the `profiles` row
   (`full_name`, `email`, `manager_id`, `is_hr_admin`) in the same action.
   Edit an existing employee's `manager_id`/`is_hr_admin` (both already
   HR-writable per existing RLS, no new policy needed for edits — only
   INSERT needs the new service-role path).
2. **Goal cascade/alignment creation UI**: reachable from wherever makes
   sense given the design decision above (likely inside the manager's
   `/reports/[planId]` view for cascading a goal down, and/or inside the
   employee's `/goals/[planId]` editor for aligning one of their own goals
   to an existing parent) — not HR-gated, since RLS already permits any
   authorized employee to create these links themselves.
3. **Matrix-manager scope grant UI (HR only)**: the two-step flow described
   above, as one coherent screen/flow.
4. **Infrastructure**: server-side service-role Supabase client
   (`web/lib/supabase/admin.ts` or similar — server-only, never imported by
   a Client Component), `.env.example` (create it — it doesn't exist today
   despite being referenced in README), document the new
   `SUPABASE_SERVICE_ROLE_KEY` var there and in README's local-dev section.
5. **`verify.sql`**: close the coverage gaps listed above (`profiles`
   INSERT positive/negative, `goal_cascade` positive/negative,
   `review_participant_scope` positive/negative, `goal_alignment`/
   `objective_alignment` negative tests, `review_participant` real
   RLS-path test).
6. **Nav wiring**: an HR-only "Admin" link on `/review`.

## Explicitly out of scope this round

Deactivating/deleting employee accounts (not requested, adds account-lifecycle
complexity beyond this round's scope — flag it as a follow-up if you think
it's needed, don't build it). Bulk import. Any notification/email on account
creation (permanently out of scope, no provider). Hosted deployment
(permanently out of scope).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons only,
no new dependencies without a strong stated reason (the Supabase Admin API
is already part of `@supabase/supabase-js`, already a dependency — no new
package needed for that). Server Components by default, isolated `"use
client"` leaves for forms. `npm run lint && npm run build` clean before
reporting done. Do not touch `README.md` or copy brief/ruling docs into the
repo — Fable handles that after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your view on the cascade-workflow design question above ((a) link
  pre-existing goals vs (b) create-and-link in one action), with reasoning.
- Route/component shape for all three surfaces.
- How you'd structure the server-side service-role client so it can never
  leak into client-side code (concrete file boundary, not just "be
  careful").
- Division of labor if pairing with another builder.
- How you'd extend `verify.sql` for the gaps listed, and any other edge
  cases you'd add.
