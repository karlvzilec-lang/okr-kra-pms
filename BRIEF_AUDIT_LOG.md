# Brief: generic audit-log table

Repo: `okr-kra-pms`. Round 9 — the **last round** of the gap-closure
effort. Rounds 1-8 are merged on `master` at `7a6d518`. Read `README.md`
in full first, especially the calibration-reversal design decisions and
the brutal-QA-round bullet about the matrix-scope revoke control.

## Ground truth (pre-verified against this repo — not general audit-log
design knowledge)

**This repo already has three different, deliberately-scoped answers to
"who did this and why," and the brief needs you to complement them, not
replace or duplicate any of them:**

1. **Calibration reversal snapshots** (`0022_calibration_reversal_
   controls.sql`): `calibration_session.last_unfinalized_at/by/reason` and
   `employee_goal_plan.last_unpublished_at/by/reason`, each an all-or-
   nothing triple (a CHECK constraint requires all three null or all
   three set). The migration's own header is explicit: *"these triples
   are snapshots, not audit logs."* README.md says the same thing in its
   own words and names this exact gap: *"a repeated reversal overwrites
   it rather than pretending to be history it isn't... since the generic
   audit-log table is a later round's scope."* **This round is that
   round.** Do not touch these columns or their functions — add a
   genuine history alongside them, so a *second* reversal doesn't erase
   the record of the first one the way the snapshot columns do today.
2. **`check_in`'s append-only design**: enforced by the *absence* of any
   UPDATE/DELETE RLS policy on the table (not a trigger) — `checked_in_by`/
   `created_at` rely on NOT NULL/default plus the INSERT policy's `with
   check`. This is already a real, working history for OKR progress and
   needs nothing added.
3. **The matrix-scope revoke control** (brutal-QA round): `DELETE FROM
   review_participant_scope WHERE id = ...` — zero trace. The row just
   vanishes; nothing records who revoked it, when, or what it was. This
   is real, current, and exactly the kind of gap a generic audit log
   should close.

**Other real gaps with zero tracking today, confirmed by direct
migration read**: `profiles.is_hr_admin` can be toggled and
`profiles.manager_id` reassigned via `updateEmployeeAction` with no
record of who changed it or from what. `goal_cascade`/`goal_alignment`
links are, per README, *"permanent once created... only HR can unlink
them, and there's currently no unlink screen"* — right now only
`created_by` exists, nothing else.

**Migrations**: 22 files exist, next number is **0023**. Every
`SECURITY DEFINER` write-path function in this codebase (`is_hr_admin()`,
`create_cascaded_goal`, `adjust_calibration_participant`,
`publish_employee_goal_plan`, `unpublish_employee_goal_plan`,
`unfinalize_calibration_session`, etc.) calls `auth.uid()` itself, inline
— there is no passed-in caller-identity parameter convention to hook into,
so a capture layer has to either call `auth.uid()` itself (inside a
trigger or an explicit insert) or be handed it explicitly by the caller.

**RLS convention, and a real trap to avoid**: every HR-only table
follows a scoped-`select` + blanket-`for all using (is_hr_admin())`
two-policy shape — *except* `calibration_session`/`calibration_band`,
where 0022 **removed** the blanket `for all` specifically because it was
an unguarded write hole (any HR-authenticated caller could issue a raw
`UPDATE`/`DELETE` with nothing at the database level stopping it). A new
audit-log table holds exactly the kind of data where that same mistake
would matter most — a table anyone can freely `DELETE` from isn't an
audit log. Match 0022's tightened pattern (scoped HR-only `SELECT`, no
client write grant of any kind — writes happen only from inside
`SECURITY DEFINER` functions/triggers), not the older permissive one.

**No frontend history/activity/log UI exists anywhere in this repo
today** — grepped across `web/app/**` and `web/components/**`; the only
hits are the unrelated existing "Check-in history" list and one
unrelated code comment. A Round 9 UI surface is entirely new, not an
extension of something partial.

**`scripts/verify.sql` baseline: 121 real assertions.**

## Scope for this round — open questions for you to answer with reasoning

1. **Capture mechanism: triggers on every write, or explicit inserts from
   specific instrumented write paths?** Both are legitimate and this
   project's own history favors deliberate, scoped mechanisms over blanket
   ones (see the 0022 RLS trap above, and the calibration-reversal
   functions' own targeted design). A blanket trigger on every table would
   also audit routine, already-legitimate activity this app doesn't need
   tracked (an employee's own self-rating edit, a check-in). State which
   specific write paths you're instrumenting and why those are the
   valuable ones, not "everything."
2. **What actually gets an audit row this round.** Concretely propose the
   list. Strong candidates given the gaps above: `profiles.is_hr_admin`
   toggles and manager reassignment (`updateEmployeeAction`), matrix-scope
   grant *and* revoke (`grantMatrixScopesAction`/`revokeMatrixScopeAction`
   — revoke especially, since it currently leaves nothing), and the
   calibration reversal actions (as a genuine append-only history
   alongside the existing snapshot columns, which stay as-is). Don't feel
   bound to exactly this list — argue for additions or narrower scope with
   reasoning, but don't propose auditing genuinely routine writes just to
   look thorough.
3. **Row shape: structured columns, a human-readable summary, or both?**
   This codebase's existing reversal-reason convention is a free-text
   `reason`/`comment` a human wrote, not a structured before/after diff —
   `calibration_participant`'s adjust flow, the reversal functions. Decide
   whether the audit row follows that same human-readable convention (an
   actor, an action label, a target reference, a short generated
   description) or captures structured old/new values, and justify against
   what this table is actually for: could an HR admin reading this table
   understand what happened without cross-referencing five other tables?
4. **Actor capture**: how does the row reliably get `auth.uid()` when the
   write happens inside a `SECURITY DEFINER` function that's already
   running as the table owner? Verify this empirically against how the
   existing reversal functions already do it (they call `auth.uid()`
   directly inside the function body) rather than assuming a trigger
   context has the same access — a `SECURITY DEFINER` trigger function's
   `auth.uid()` behavior needs to actually be confirmed, not assumed
   identical to a regular RPC function's.
5. **Frontend scope**: a real, minimal HR-only "Activity" page (paginated
   the same way every other admin list in this codebase already is —
   `web/lib/pagination.ts`, 25 rows, `?page=N`) reading the new table, or
   is the schema + write-instrumentation the actual round-9 deliverable
   with the UI as a smaller stretch? State your call — this is the last
   round of the whole effort, so "ship the backend and skip the UI
   silently" is not an acceptable default; if you scope the UI down, say
   exactly what it does and doesn't show and why.

## Explicitly out of scope this round

Touching the calibration-reversal snapshot columns or their functions
(0022) — this round adds alongside them, doesn't replace them. Retrofitting
audit rows onto every table in the schema. Any UI beyond a scoped read
surface for HR (no editing, no deleting audit rows — an audit log a
privileged user can edit isn't one). Hosted deployment, real email/webhook
notifications (permanently out, per every prior brief).

## Constraints carried from every prior round

`npm run lint && npm run build` clean, `scripts/verify.sql` must still
pass and should grow with real new coverage for whatever RLS/trigger
logic this round adds (state your target assertion count and what they
cover). A full `supabase db reset` must apply the new migration(s)
cleanly. Do not touch `README.md` or copy brief/ruling docs into the
repo — Fable handles that after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your answer to each of the 5 questions above, with reasoning.
- The exact table/column shape and migration number(s) you'd use.
- Your exact RLS policy set for the new table.
- What you'd add to `scripts/verify.sql` and roughly how many new
  assertions.
- Division of labor if pairing with another builder.
