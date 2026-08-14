# Gate 1 Ruling: Admin UI

Jcode and Sol both planned independently. Both independently found the same
correction to my original brief — the cascade actor must be the employee,
not the manager — from direct RLS reading, not from cross-challenging each
other. Given that strong convergence, this ruling skips a separate
cross-challenge round and resolves the one real disagreement directly.
Implement exactly this.

## The cascade/alignment correction (both agreed on the root cause)

My brief's framing was wrong: it assumed a manager could cascade one of
their own goals down into a report's plan. **That's blocked by existing
RLS** — `can_write_goal` only grants a manager write access to a report's
goal during `manager_eval` (the rating window), and `goal_employee_insert`
(creating a brand-new goal) is employee-only. A manager cannot create a goal
in a report's plan at goal-setting time at all. Building the feature as
originally framed would only work for HR, which isn't the feature anyone
asked for.

**Ruling: the actor is the employee.** In their own `/goals/[planId]`
editor, an employee links one of their own goals to a *readable* source —
their manager's goal (readable via `can_read_goal`'s manager branch) for
**cascade**, or any readable goal for **alignment**. This stays entirely
inside RLS authority the employee already has (write their own goal, read
their manager's).

**Ruling on the sub-disagreement (link-existing vs. create-and-link): use
Sol's create-and-link design.** A cascade is conceptually a copy event —
requiring the employee to first manually retype the goal's title/
description/target/scale before linking it reduces "cascade" to "alignment
with extra steps," which isn't what either builder's own research into real
KRA tools described. Build it as **one `SECURITY INVOKER` Postgres RPC**
that inserts the new `goal` row (in the employee's own plan, in an existing
KRA category they pick) and the `goal_cascade` link row in the same
statement/transaction — `SECURITY INVOKER` means it runs under the caller's
own RLS, so it grants nothing beyond what the two separate inserts a client
could already issue would grant; the only thing the RPC adds is atomicity
(a failed link can't strand a half-created goal) and convenience
(pre-filling from the source). Copy `title`, `description`, `target_metric`,
`rating_scale_max` from the source goal; leave `self_rating`/
`self_comment`/`manager_rating`/`manager_comment` null; weight is prefilled
from the source but editable, since plan-level weight balancing is the
employee's own call. Do not auto-create a KRA category — the target category
must already exist, chosen from the employee's own plan.

**Alignment stays simpler — no RPC needed.** Both `goal_alignment` (in
`/goals/[planId]`) and `objective_alignment` (in `/objectives/[objectiveId]`)
are pure links between two already-independently-existing goals/objectives
— a plain client-side insert against the existing RLS policy is sufficient,
no atomicity concern since nothing new is being created.

**Both link types render "already linked" state, not a re-link control.**
`cascaded_goal_id` and `child_goal_id` are both `unique` — a goal/objective
can be the target of only one cascade or one alignment. Once linked, show
that state read-only; don't offer a second link attempt, and don't offer an
unlink control at all (`UPDATE`/`DELETE` on all three link tables is
HR-only — say so in the UI copy if a user might expect to undo it, don't let
them discover that by a failed save).

## Employee provisioning — both plans converged, use this

Both plans independently arrived at the same service-role isolation
approach; this is now settled, not a choice:

- `web/lib/supabase/admin.ts` starts with `import "server-only"` (Next's
  build-time guarantee that a Client Component importing this file is a
  build error, not a runtime hazard — add the `server-only` package if it
  isn't already a transitive dependency).
- No module-level service-role client instance, no raw exported
  constructor. One function, called only from a `"use server"` Server
  Action, that: creates the normal cookie-backed anon client, calls
  `auth.getUser()`, reads the caller's own profile and verifies
  `is_hr_admin()` — **only then** reads `SUPABASE_SERVICE_ROLE_KEY` and
  constructs the service-role client (`@supabase/supabase-js`'s
  `createClient`, not `@supabase/ssr`, `auth: { persistSession: false,
  autoRefreshToken: false }`). The re-check inside the function matters —
  don't rely solely on a route-level gate (e.g. `admin/layout.tsx`) to
  authorize this, since a Server Action can be invoked directly.
- Add an eslint `no-restricted-imports` rule banning
  `@/lib/supabase/admin` from `web/components/**`, so the boundary is
  checked by `npm run lint`, not only by review.
- Provisioning sequence: validate input → generate a cryptographically
  random, password-policy-compliant temporary password → `auth.admin.
  createUser` (`email_confirm: true`, no notification email — matches the
  "skip notifications" decision from earlier in this effort) → insert
  `profiles` via the normal authenticated HR client (not the service-role
  client — `profiles_hr_all` already permits this) with `password_changed_at`
  left `null` (this is what triggers the existing forced-first-login-change
  flow — no new provisioning story) → if the `profiles` insert fails,
  delete the just-created `auth.users` row as a compensating action (there's
  no real cross-system transaction between the Auth Admin API and
  PostgREST, so this is the honest atomicity boundary, not a fake one).
  Return the temporary password once, for HR to relay out-of-band — never
  log it, never persist it anywhere.
- Create `web/.env.example` (it doesn't exist today despite being
  referenced in README) with the local anon key and the local
  `SUPABASE_SERVICE_ROLE_KEY` documented above. README's own update
  (the `cp .env.example .env.local` line, plus documenting the new var) is
  Fable's job after merge, per the standing rule — don't touch README.

## Route/component shape

```
web/app/admin/layout.tsx           password-expiry + HR gate, shared nav
web/app/admin/page.tsx             employee list + create + edit
web/app/admin/actions.ts           "use server" — employee create/edit,
                                    the only caller of lib/supabase/admin.ts
web/app/admin/matrix-scopes/page.tsx   matrix-manager grant flow
web/lib/admin-queries.ts           server-side loaders (anon client, RLS)
web/lib/admin.ts                   validation + error mapping
web/lib/supabase/admin.ts          service-role client (see above)
web/components/admin/*             employee create/edit forms, matrix grant form
web/components/goals/goal-link-form.tsx     cascade + alignment picker for /goals/[planId]
web/components/okr/objective-alignment-form.tsx   for /objectives/[objectiveId]
```

Every Server Action independently re-verifies auth + password-expiry + HR
status — don't let authorization depend solely on the layout gate, matching
the pattern the goal-rating/manager-rating forms already use of never
trusting a single upstream check.

Matrix-scope grant flow, one screen, sequenced: pick employee/plan → pick
the matrix manager → pick one or more scopes (`kra_category` and/or
`objective`, both belonging to that employee's plan/cycle — revalidate this
server-side, don't trust client-supplied IDs even though the trigger would
also catch a mismatch). Submitting reuses an existing `matrix_manager`
`review_participant` row if one already exists for that (plan, participant)
pair, or creates one, then inserts the scope row(s); say plainly in the UI
that step 1 (participant) happens automatically as part of granting a
scope, since it's not a separate visible action. Map `23514` → "that person
isn't a matrix manager on this plan," `23503` → "that category/objective no
longer exists," `23505` → "already granted," `22023` → generic fallback.

`/review` nav gets one new HR-gated "Admin" link, same conditional-`Link`
shape as the two existing HR links, placed alongside them before
`<LogoutButton />`.

Additive-only types in `types.ts`: `Profile`, `GoalCascade`, `GoalAlignment`,
`ObjectiveAlignment`, `ParticipantRole`, `ReviewParticipant`,
`ScopeType`, `ReviewParticipantScope`.

## Division of labor

**Sol — DB + service boundary + verify.sql**: the new `SECURITY INVOKER`
cascade RPC, any RLS/constraint work the RPC design needs, `verify.sql`
extensions (full list below), and `.env.example`. Also owns
`web/app/admin/actions.ts` and `web/lib/supabase/admin.ts` since these are
the security-sensitive server-side pieces that belong with whoever is
already deep in the RLS/security model for this round.

**Jcode — UI layer**: `web/app/admin/page.tsx`, `web/app/admin/layout.tsx`,
`web/app/admin/matrix-scopes/page.tsx`, all `web/components/admin/*`, the
cascade/alignment forms wired into `/goals/[planId]` and
`/objectives/[objectiveId]`, `web/lib/admin-queries.ts`, `web/lib/admin.ts`,
additive `types.ts`, and the `/review` nav link.

**Shared contract, agree before either writes code**: the exact RPC name,
parameter names, and return shape for the cascade RPC (Sol defines it,
states it precisely, Jcode's `goal-link-form.tsx` calls it by that exact
signature — don't let this drift into a guessed integration). Same for the
matrix-scope-grant server action's exact parameter shape.

## `scripts/verify.sql` — required assertions (building on both plans' lists)

1. `profiles` INSERT as HR succeeds, `password_changed_at` left null.
2. `profiles` INSERT as non-HR — no INSERT policy exists for them, confirm
   the actual failure mode (0-row/RLS-denied) and assert that exact shape.
3. `profiles` INSERT with `manager_id = id` (self-reference) — `23514`.
4. `profiles` INSERT with a duplicate `email` — `23505`.
5. Cascade RPC positive path: employee creates a goal linked to their
   manager's readable goal, in one call — both rows exist, fields copied
   correctly, `self_rating`/`manager_rating` null.
6. Cascade RPC denied: source goal not readable by the caller.
7. Cascade RPC denied: `cascaded_by`/actor spoofed to another profile.
8. Cascade RPC denied: caller doesn't own the target plan (this should be
   structurally impossible given the RPC only ever inserts into the
   caller's own plan — assert that, don't just assert a payload override is
   rejected).
9. Second cascade attempt onto an already-cascaded goal — `23505` (the
   `cascaded_goal_id` unique constraint).
10. Failure partway through the RPC (e.g. an invalid category) leaves
    neither a stray `goal` nor a stray `goal_cascade` row — the atomicity
    guarantee.
11. `goal_alignment` negative: parent unreadable to the caller — denied.
12. `goal_alignment` negative: spoofed `created_by` — denied.
13. `objective_alignment` — same two negative cases as (11)/(12).
14. `review_participant` HR insert succeeds through real RLS (not
    fixture/superuser setup as today).
15. `review_participant` non-HR insert denied.
16. `review_participant_scope` HR grants a `kra_category` scope — succeeds.
17. `review_participant_scope` HR grants an `objective` scope — succeeds
    (the polymorphic branch is currently untested in either direction).
18. `review_participant_scope` non-HR insert denied.
19. Scope insert against a `line_manager` (non-matrix) participant —
    `23514` (`enforce_scope_participant_is_matrix`).
20. Scope insert with `scope_id` pointing at a nonexistent category —
    `23503` (`validate_scope_target_exists`).
21. Duplicate scope grant (same participant/type/id) — `23505`.
22. Non-HR UPDATE attempt on `goal_cascade` — confirm it's the silent
    zero-row no-op the UI's "can't unlink" copy depends on being true.

That's a long list, matching the bar every prior round has set. Don't cut
it short.

## Explicitly out of scope this round

Deactivating/deleting employee accounts, bulk import, any notification/email
on account creation, hosted deployment — all permanently or provisionally
out per prior rounds' decisions.

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons only.
Server Components by default, isolated `"use client"` leaves. `npm run lint
&& npm run build` clean before reporting done. Do not touch `README.md` or
copy brief/ruling docs into the repo — Fable handles that after merge.

## Execute now

This ruling is approved. Proceed to implementation in your isolated
worktree, following exactly your assigned half above.
