# Gate 1 Ruling: generic audit-log table

Both plans converge almost completely: the same 5 targeted write paths
across the same 4 tables, the same reasoning against a blanket trigger,
the same hybrid structured+human-readable row-shape instinct, the same
RLS shape (HR-only `SELECT`, no client write grant of any kind, writes
only through `SECURITY DEFINER` trigger functions), the same real
frontend commitment, and near-identical `verify.sql` coverage down to
the specific negative tests (a non-audited field edit emits zero rows;
two successive reversals leave two history rows even though the 0022
snapshot column only ever holds the latest — the exact gap this round
exists to close). Ruling directly on the handful of real disagreements
rather than dispatching a separate cross-challenge round.

## Resolved disagreements

1. **How the two calibration-reversal events get their audit row: an
   `AFTER UPDATE` trigger reading the 0022 snapshot columns, not a
   `create or replace` of the reversal functions.** This was Jcode's own
   explicit ask for a ruling, and it named the trigger approach as its
   own fallback. The brief said "do not touch these columns or their
   functions" — a trigger on `employee_goal_plan`/`calibration_session`
   that fires on the exact transition (`published_at not null → null`;
   `status: finalized → open`) and reads `NEW.last_unpublished_by/at/
   reason` / `NEW.last_unfinalized_by/at/reason` satisfies that literally:
   zero lines of 0022 change. Since 0022 already revoked every other
   write path to these two state transitions, a trigger here isn't
   weaker than an in-function insert on the bypass-resistance axis either
   — there is no other way to reach this transition. Use the trigger.

2. **`old_values`/`new_values`: `jsonb`, not paired `old_value`/
   `new_value` text columns.** Jcode's concern (don't make "read the
   table directly in psql" worse) is real, but both plans already solve
   it with a required, frozen `summary` column — that's what a human
   reads in psql or in the UI, not the structured columns. The
   structured columns' job is precise filtering/evidence, and two of the
   six event types (`matrix_scope.granted`/`revoked`) are genuinely
   multi-field (participant, plan, employee, cycle, scope type, scope id,
   scope label) — cramming that into a single text pair would mean
   picking one field to show and losing the rest, or hand-rolling a
   second serialization format inside a text column, which is worse than
   `jsonb` for exactly the case that needs it most. Use `jsonb`, matching
   Sol's shape, with the `not null default '{}'::jsonb` +
   `jsonb_typeof(...) = 'object'` constraints Sol already specified.

3. **`actor_id`: nullable, not `NOT NULL`.** Sol's instinct — an
   unidentifiable sensitive mutation should fail rather than silently
   create incomplete history — is a reasonable general audit-logging
   principle, but `NOT NULL` here means a bug or an untested edge case in
   the *audit* trigger can block the underlying HR action itself (an
   admin literally cannot toggle someone's HR flag if the audit
   infrastructure has a gap it didn't anticipate). Coupling core
   application functionality to observability-layer reliability is the
   wrong trade for this table. Use Jcode's answer: `actor_id` nullable,
   `actor_name` `not null` with an explicit literal fallback (`'system
   (service role)'` or equivalent) so a null actor is *visible in the UI*
   rather than either blocking the write or rendering a blank cell, and a
   `verify.sql` assertion pins that a write with no JWT claim produces
   exactly that fallback row rather than erroring or going blank. This
   doesn't lower the bar on investigating *why* an actor went uncaptured
   if it ever happens — it just means the HR action itself isn't held
   hostage to the audit layer.

4. **Add Jcode's immutability trigger as an explicit, required layer,
   not just RLS.** `BEFORE UPDATE OR DELETE` raising on `public.audit_log`
   itself, on top of (not instead of) the revoked grants and the missing
   RLS write policies both plans already specify. This is genuine defense
   in depth matching this project's own established pattern (0022's
   private-schema one-time-token layered on top of RLS, not relying on
   RLS alone) — a table whose entire purpose is being un-rewritable
   shouldn't depend on privilege grants never having a bug.

5. **Table/column naming: `audit_log` (Sol's name, matches the brief's
   own language), with Sol's simpler `target_type`/`target_id`/
   `target_label` shape** (no separate `subject_id`/`subject_name` pair
   on top of it). Jcode's actor/subject split is more general, but for
   all 5 instrumented events the "row that changed" and "the human this
   event is about" either collapse to the same profile row or are already
   fully captured in the `jsonb` payload (ruled in point 2) — a fourth
   identity column pair would be redundant with the payload rather than
   adding real precision. Keep `on delete restrict` on `actor_id`'s FK
   (Sol's addition — profiles are never deleted in this app today, but
   there's no reason to leave that unconstrained).

6. **Ordering: `occurred_at desc, id desc` everywhere, consistently** —
   Sol's own plan used `desc, id` on the index and `desc, id asc` in the
   frontend section, an internal inconsistency. Pick one direction and
   match it in the index, the `ORDER BY`, and `pagination.ts`'s tiebreaker
   convention (which both plans already correctly cite as required).

## Where both plans already agreed (confirming, not re-litigating)

- **The 5 instrumented paths and 6 event labels**: `profiles` (manager
  reassignment and HR-admin toggle, as two independently-readable events
  when both change in one edit — not collapsed into one row),
  `review_participant_scope` INSERT and DELETE (grant/revoke symmetry —
  the brutal-QA-round gap this round specifically closes), the two
  calibration-reversal transitions. Both plans independently excluded
  the same things for the same reasons: check-ins (already append-only),
  rating edits (routine, already has evidence via `calibration_participant`),
  goal cascade/alignment creation (already has `created_by`, and there's
  no unlink UI yet to audit the absence of).
- **RLS**: exactly one `SELECT` policy gated on `is_hr_admin()`, no
  `INSERT`/`UPDATE`/`DELETE` policy for any role, no blanket `for all` —
  matching 0022's tightened pattern, not the older permissive one both
  plans correctly identified as a mistake to avoid repeating.
  `service_role` gets `SELECT` only, same as `authenticated` — neither
  plan wants a leaked service key able to erase history.
- **Actor capture must be proven empirically, not assumed** — both plans
  independently flagged that `SECURITY DEFINER` changes the executing
  *role*, not the `request.jwt.claim.sub` GUC `auth.uid()` reads, and
  both want a real probe (`set local role authenticated` +
  `set_config('request.jwt.claim.sub', ...)`, matching `verify.sql`'s own
  existing harness pattern) run and confirmed before anything else is
  built, not assumed correct because it "should" work.
- **Frontend**: `/admin/activity`, a real page this round, HR-gated
  (`requireHrAdmin()`, matching every other admin page), 25-row
  pagination via the existing `web/lib/pagination.ts` conventions, no
  edit/delete/export/filter/search — a readable ledger, not an
  investigation tool, and explicitly not a stretch goal to skip silently.
- **`verify.sql`**: ~18 new assertions, ~121 → ~139, covering RLS
  (positive and negative), the empirical actor-capture proof, exact
  old/new value correctness per event type, the zero-row negative test
  for non-audited field edits, and the two-reversals-two-rows regression
  test that is this round's actual reason to exist.
- **Migration**: single file, `0023_audit_log.sql` — table, RLS, indexes,
  trigger functions, and the triggers themselves, all in one migration
  (splitting it would leave an intermediate state where instrumentation
  targets a table that doesn't exist yet).

## Division of labor

Matches both plans' own converged proposal — database/verification vs.
frontend, contract agreed first.

- **Both, first, ~30 minutes, before either writes anything else**: the
  `auth.uid()`-inside-a-`SECURITY DEFINER`-trigger empirical probe. Don't
  proceed on an assumption either plan admits it hasn't actually run yet.
- **Jcode**: `0023_audit_log.sql` in full — table (jsonb columns, ruled
  shape, `on delete restrict`), RLS, the five trigger functions (four
  reading `auth.uid()` directly, two reading the 0022 snapshot columns
  per ruling point 1), the immutability trigger (ruling point 4), and
  every new `scripts/verify.sql` assertion. Report the actual final
  assertion count rather than bending tests to hit exactly 139.
- **Sol**: `web/lib/audit-log-queries.ts` + `web/app/admin/activity/
  page.tsx` + the admin nav link, against the agreed column list — start
  from the `create table` block the moment it's committed, not after the
  whole migration lands, since the two halves don't otherwise block each
  other.
- **Both, at the end**: `npm run lint && npm run build`, `npm test`, a
  full `supabase db reset` + `scripts/verify.sql` pass, and — per this
  project's own repeated lesson that its worst bugs were invisible to
  lint/build/verify.sql — a live click-through as HR (see the real page
  populate) and as a non-HR employee (confirm `/admin/activity` is
  actually gated, not just hidden from nav).

## Explicitly not re-litigated

Everything the brief already marked out of scope stays out of scope: any
edit to 0022's columns or function *semantics* (only the new trigger
reads them), a blanket schema-wide trigger, retrofitting every table,
any edit/delete surface on the audit log itself, hosted deployment, real
email/webhook notifications.
