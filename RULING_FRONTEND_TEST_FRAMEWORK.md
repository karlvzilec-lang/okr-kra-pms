# Gate 1 Ruling: automated frontend test framework

Both plans converge almost completely — same runner choice with identical
reasoning, the same false-green gotcha found independently by both via
empirical testing before either saw the other's plan, matching scope calls
on component testing and E2E with overlapping cited evidence, and nearly
identical test-file lists. Ruling directly rather than dispatching a
separate cross-challenge round.

## Resolved disagreements

1. **Test invocation: adopt Sol's `web/scripts/run-tests.mjs` wrapper, not
   Jcode's bare `node --test "lib/**/*.test.ts"` one-liner.** Both builders
   independently found the same real failure mode (an unquoted/misscoped
   invocation silently collects zero tests and exits 0) — the brief named
   this exact risk explicitly, and Sol's answer defends against it more
   directly: the wrapper discovers files itself, hard-fails if it finds
   zero, and prints what it found before running them. Jcode's one-liner
   is simpler but only survives today's exact glob syntax remaining
   correct forever; the wrapper survives someone editing the script later
   and getting the pattern wrong too. Keep it as lean as Sol specified —
   discover, count-check, run, propagate the exit code, nothing more.

2. **Do not add `"type": "module"` to `web/package.json`.** Sol proposed
   it to silence the `MODULE_TYPELESS_PACKAGE_JSON` warning; the warning
   is real but cosmetic (tests still run and pass either way), and
   `"type": "module"` is a repo-wide module-resolution change to a Next.js
   app that neither plan verified against `next dev`/`next build` — Next's
   own config loading has its own rules for `.ts`/`.js` files that a blind
   package.json edit could interact with in ways not worth the risk for a
   cosmetic warning. Leave the warning as accepted noise. (The wrapper
   script itself should be `.mjs`, which is unambiguous regardless of
   `package.json`'s `type` field, so this doesn't block anything.)

3. **Node version for local empirical verification: Sol already confirmed
   native TS stripping works on Node 22.18.0 directly** (not just Jcode's
   locally-installed Node 24) — this directly closes the exact uncertainty
   Jcode's own plan flagged ("verify 22 specifically, not just my local
   24"). Treat that as settled; the remaining check is only that CI's
   `setup-node@v4` with `node-version: 22` resolves to something ≥ 22.18
   (native-by-default), not the older 22.6–22.17 flag-gated range —
   confirm this empirically against whatever CI actually resolves to
   rather than assuming, but don't re-derive the underlying stripping
   behavior, Sol already did.

4. **Commit to all 6 new test files as real deliverables, not a
   conditional list.** Jcode's plan treated `admin.ts` as "lower priority,
   if time allows"; Sol committed to it as a full planned file with three
   concrete tests. Do the fuller version — `validateEmployeeEdit`'s
   self-manager rejection and `validateScopeGrant`'s category/objective
   requirement are both real business rules worth pinning, matching this
   round's own stated goal of covering the actual highest-value logic
   rather than doing five files well and treating the sixth as optional.

5. **Add Sol's `buildBoardColumns sorts bands and retains null or dangling
   participants as Unassigned` to `calibration.test.ts`.** Not in Jcode's
   list. This is a concrete, valuable addition given the brutal-QA round's
   own finding that a dangling/unresolved reference (there, a matrix-scope
   grant pointing at a deleted category) can silently degrade instead of
   crashing — the calibration board has the same shape of risk if a
   participant reference goes stale, and nothing currently pins that it
   degrades gracefully rather than dropping the row.

## Where both plans already agreed (confirming, not re-litigating)

- **Runner: `node:test`, no Vitest.** Zero new dependencies, already
  proven against the two existing dead test files, matches this repo's
  consistently minimal `devDependencies` list across every prior round.
- **Component testing: explicitly out of scope**, with the reasoning
  both plans gave — the load-bearing logic lives in `lib/`, not JSX, and
  Gate 2's live-browser pass already exercises the actual rendered
  components every round. Name the pointer-drag hook and modal state
  machines as a stated gap for a future round, not a silent omission.
- **E2E (Playwright/Cypress): explicitly out of scope**, on the same
  evidence both plans independently cited — Round 5's `PGRST201` ambiguity
  and Round 7's nonce-forwarding hazard were both caught by adversarial
  human clicking through the app, not by scripted happy-path tests, and
  CI has no browser setup today to build one on top of. If this changes
  later, it's a deliberate future round, not a default reach.
- **CI integration**: one `Test` step in the existing `web` job, between
  `Lint` and `Build` (fails fast on a broken assertion before spending
  build time), running the new `npm test` (nothing new: no job, no browser
  install, no service container).
- **The anti-false-green empirical verification protocol**: prove the
  runner collects the real test count (not just exit-0), deliberately
  break a passing assertion and confirm a red run, deliberately break a
  subject function (not the test) and confirm the matching test catches
  it, then revert both and confirm green again. This is the actual gate
  for "done," not a clean exit code on its own.
- **The specific business rules each new test file targets** — both
  plans independently reached for the same real edge cases per file
  (pagination's inclusive-range and clamp-recursion guard, calibration's
  band-boundary and null-vs-zero-calibrated-score handling, goals' weight-
  hundredths precision and the null-vs-zero-rating distinction, OKR's
  one-way lifecycle chain, password's exact rotation-day boundary) —
  independent convergence on the same specific functions is strong
  evidence these are the right things to test, not filler.

## Division of labor

This round splits cleanly into disjoint files, unlike Round 7's
single-file constraint — both builders get real, non-overlapping work.

- **Jcode**: `web/scripts/run-tests.mjs`, `web/package.json`'s `test`
  script, the `.github/workflows/ci.yml` step, any `tsconfig`/lint fallout
  from the new test files, confirming the two existing suites pass
  through the new runner first (this is the sequencing-critical path
  everything else depends on) — plus `lib/pagination.test.ts`,
  `lib/okr.test.ts`, `lib/password.test.ts`.
- **Sol**: `lib/admin.test.ts`, `lib/calibration.test.ts` (including the
  added `buildBoardColumns` case from point 5 above), `lib/goals.test.ts`.
  Do not touch the runner/CI/`package.json` — Jcode's wrapper script is
  the dependency both need, so build against its documented contract
  (discovers `lib/**/*.test.ts`, fails loudly on zero) rather than
  inventing a second invocation path.
- **Both**: run the full anti-false-green protocol (point above) against
  your own files before reporting done — don't defer that to Fable's Gate
  2 alone. Fable still does an independent Gate 2 pass on the merged
  result, including re-running the deliberate-break-and-revert check
  personally rather than trusting either builder's self-report of it,
  matching every prior round's process.

## Explicitly not re-litigated

Everything the brief already marked out of scope stays out of scope:
testing the 7 Supabase-querying `lib/` files, retrofitting every Client
Component, any `scripts/verify.sql`/DB-layer change, hosted deployment,
real email/webhook notifications.
