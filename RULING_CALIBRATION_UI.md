# Gate 1 Ruling: Calibration Facilitator UI

Both plans read. Jcode's frontend plan is adopted essentially as proposed — it is concrete, correct, and already accounts for the `adjust_calibration_participant` note-erasure trap and drag-as-convenience-not-commit. Sol's backend risk analysis surfaced a real correctness hole in the *already-shipped* Phase 3 schema that this UI would make trivially reachable by a real user, and that gets fixed as part of this pass. Division of labor below; execute against this contract exactly — it supersedes anything in the original brief where they conflict.

## Rulings on disagreements / risks raised

1. **Cross-session republish hole (Sol's finding) — MUST FIX, in scope.** `published_goal_plan_final_score` (0015) picks the calibration participant with the latest `updated_at` **across all sessions for a plan**, with no regard to that session's status. Today this requires hand-written SQL to trigger; this UI's "Add employee" picker makes it a two-click action: add an already-published plan to a second open session, adjust its score there, and the employee's *published* number changes immediately — with no new `publish_employee_goal_plan` call, silently violating this repo's own stated guarantee ("a published score can never be a stale, un-finalized number"). Fix, via `create or replace function` in the new migration (this is the established pattern — `0015` replaced `0010`'s `employee_review_summary` the same way):
   - `add_plan_to_calibration_session` (0014): reject with `raise exception ... using errcode = '55000'` when the target plan's `employee_goal_plan.published_at is not null`. Message should say plainly that a published plan cannot be recalibrated without an unpublish step (which does not exist yet and is not in scope — this is a hard stop, not a workflow).
   - `calibration_eligible_plans` (new, 0016): exclude `egp.published_at is not null` at the query level too, so the picker never offers a published plan in the first place — the function-level reject above is the real guarantee, this is UX defense in depth so HR doesn't hit a raw error on a normal click.

2. **"No un-finalize" (Sol's finding) — real, out of scope for this pass.** HR's existing blanket RLS grant on `calibration_session`/`calibration_band` (`calibration_session_hr_all`, `calibration_band_hr_all`) means nothing stops a direct API/SQL call from reopening a finalized session or deleting a band out from under a participant (`ON DELETE SET NULL`). The UI we're building will not expose an un-finalize control or a band-delete control, so it's not reachable through normal use of what ships here. Do not add DB-level guards for this in this pass — document it as a known, deliberate follow-up in `README.md`'s Security section, same style as the existing CSP-deferred note.

3. **Session+band creation atomicity — resolved by adding a third RPC.** Neither "compensating delete" nor leaving it as two client calls is as good as just making it atomic, and we're already touching this migration. Add:
   `create_calibration_session_with_bands(p_name text, p_review_cycle_id uuid, p_bands jsonb) returns uuid` — SECURITY DEFINER, HR-gated (`42501`), single PL/pgSQL body (implicitly transactional): inserts the session, then loops `p_bands` (array of `{label, min_score, max_score, sort_order}`) inserting each band row. Real validation (ascending, non-overlap, `max_score` bounds) stays where it already lives — the `calibration_band_range_ordered` check and the `calibration_band_no_overlap` exclusion constraint — this function does not need to duplicate that logic, just needs to let those constraint violations propagate as normal errors (they already carry meaningful SQLSTATEs). Client still does its own pre-submit validation for UX (per both plans), this RPC is the correctness backstop. Returns the new session's id.

4. **`manager_full_name` source — use `review_participant` (Jcode's position), not `profiles.manager_id` (Sol's position).** Reason: the RLS gate on this exact endpoint (`can_read_calibration_session`/`can_read_calibration_participant`) is itself keyed off `review_participant.role = 'line_manager'`, not `profiles.manager_id` — so using the same relation for the *displayed* manager name keeps the endpoint internally consistent with what actually governs who can see it. It's also more correct for a calibration board, which is inherently about a specific past review cycle: `profiles.manager_id` reflects the employee's *current* manager, which can have changed since the cycle closed, and showing today's manager next to a historical calibration decision would be misleading. `comp_export_rows`'s use of `profiles.manager_id` stands as-is (different function, different purpose, not being touched) — this is a deliberate, documented divergence, not an inconsistency to "fix" later.

5. **`band_id`/`calibrated_score` nullable in the schema (Sol's finding) — handle, don't assume away.** `calibration_session_detail`'s participant objects always include `band_id` verbatim (including `null`, on the off chance a band was deleted out from under a participant via item 2's still-open gap). Frontend groups by `band_id`; any participant whose `band_id` doesn't match a band in the `bands` array (including `null`) renders in a visible "Unassigned" column at the end of the board rather than being silently dropped. This is cheap defensive handling, not a new feature.

6. **Adjust/Add/drag disabled after finalize; password-expiry gate before the HR check — both plans already agreed; confirmed as written.** No change needed.

## Locked RPC contract (frontend builds against this; backend implements exactly this)

```sql
-- All three: SECURITY DEFINER, stable where read-only, set search_path = '',
-- HR gate via `if not public.is_hr_admin() then raise ... using errcode = '42501'`
-- checked BEFORE any existence lookup. revoke all from public; grant execute
-- to authenticated, service_role. New migration: 0016_calibration_facilitator_views.sql.

calibration_session_detail(p_session_id uuid) returns table (detail jsonb)
-- raises P0002 if session doesn't exist (after the 42501 check).
-- detail shape: { session: {...}, bands: [...], participants: [...] }
-- exactly as specified in the original brief, EXCEPT:
--   - participants[].manager_full_name resolved via review_participant
--     (role = 'line_manager'), not profiles.manager_id — see ruling #4.
--   - participants[].band_id is emitted as-is, including null — see ruling #5.
--   - bands and participants both coalesce to '[]'::jsonb, never JSON null.
--   - participants ordered by band sort_order (nulls last), employee full
--     name, then participant id.

calibration_eligible_plans(p_session_id uuid)
  returns table (plan_id uuid, employee_id uuid, employee_full_name text,
                 employee_email text, manager_score numeric)
-- raises P0002 if session doesn't exist, 42501 gate as above.
-- excludes plans already a participant IN THIS SESSION, and excludes any
-- plan with employee_goal_plan.published_at is not null (ruling #1).
-- ordered by employee_full_name, plan_id.

create_calibration_session_with_bands(
  p_name text, p_review_cycle_id uuid, p_bands jsonb
) returns uuid
-- HR gate as above (no P0002 possible — nothing pre-exists to look up).
-- p_bands: jsonb array of {label, min_score, max_score, sort_order}.
-- Inserts session then bands in one transaction; lets check/exclusion
-- constraint violations propagate. Returns the new calibration_session.id.

-- Also, `create or replace` in the same migration (ruling #1):
add_plan_to_calibration_session(p_session_id uuid, p_plan_id uuid) returns uuid
-- unchanged signature/behavior, PLUS: raise 55000 if the target plan's
-- employee_goal_plan.published_at is not null, checked alongside the
-- existing session-status/cycle checks.
```

## Division of labor

**Sol** (`okr-kra-pms-sol-calibration-ui` worktree) — backend, matching your own risk analysis:
- `supabase/migrations/0016_calibration_facilitator_views.sql`: all three new RPCs above, plus the `create or replace` patch to `add_plan_to_calibration_session`.
- `supabase/seed.sql`: add a manager-rated `employee_goal_plan` for **Vuthy Long** (`11111111-1111-4111-8111-000000000008`, already a seeded profile, currently has no goal plan) — one `kra_category`, one `goal`, self+manager `goal_plan_rating` inputs, a `compute_goal_plan_rating(..., 'manager')` call — following the exact pattern already used for Dara's plan A (`33333333-...000a`). No calibration participant for this plan — it's the "still eligible" fixture `calibration_eligible_plans` needs, which does not currently exist in seed data. Pick fresh UUIDs continuing the existing lettered suffix convention (plan `e` after `a`–`d`); do not renumber or touch anything existing.
- `scripts/verify.sql` + `VERIFICATION.md`: new assertions — non-HR gets `42501` from all three RPCs; HR gets correct shape/rows from `calibration_session_detail` against the existing seeded (finalized, published) session; `calibration_eligible_plans` excludes Dara's plan (already a participant) AND excludes nothing-published-yet-but-wrong-cycle plans correctly, and includes Vuthy's new plan; a direct call to `add_plan_to_calibration_session` against Dara's plan (published) raises `55000`; `create_calibration_session_with_bands` creates a session+bands atomically and a bad band set (e.g. overlapping) rolls back the whole thing (no orphaned session row). Update the running assertion count consistently in `scripts/verify.sql`'s closing `\echo`, `VERIFICATION.md`, and flag the new total for me — do not edit `README.md` yourself, I'll reconcile the final count and the README/Status write-up centrally after merge so it only gets written once.

**Jcode** (`okr-kra-pms-jcode-calibration-ui` worktree) — frontend, per your own plan, updated for this ruling:
- `web/app/calibration/page.tsx`, `web/app/calibration/[sessionId]/page.tsx`, and the `web/components/calibration/*` + `web/lib/calibration.ts` files from your plan.
- New-session creation calls `create_calibration_session_with_bands` (ruling #3) instead of two separate inserts + compensating delete — simpler than what you proposed, use it.
- `manager_full_name` is just a field on the participant object per the locked contract above — no client-side resolution logic needed, the RPC does it (ruling #4).
- Add the "Unassigned" pseudo-column for `band_id === null` participants (ruling #5) — low-probability in practice, but the board must not silently drop a row.
- Everything else — the Adjust-modal-is-the-primitive design, drag-as-convenience-only, the note-field-erasure compensation, the delta indicator, the finalize/publish flow, responsive behavior — build exactly as you already planned it.
- The RPC layer doesn't exist in your worktree yet (Sol is building it in a separate worktree) — build and lint/typecheck against the contract above; we integrate at merge. If you want to sanity-check against a live DB before merge, the existing `master` migrations (through `0015`) are enough to run the rest of the app — the three new RPC calls just won't resolve until merge, which is expected and fine.

Both of you: do not touch `README.md` — I'll write the final Status/Security/Frontend updates once after merging both branches, so it only changes once and stays consistent with whatever actually landed.

Proceed with implementation now.
