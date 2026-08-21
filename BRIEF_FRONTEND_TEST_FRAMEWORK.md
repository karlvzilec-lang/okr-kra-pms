# Brief: Automated frontend test framework

Repo: `okr-kra-pms`. Round 8 of the gap-closure effort. Rounds 1-7 are
merged on `master` at `00c6880`. Read `README.md` in full first.

## Ground truth (pre-verified against this repo — not general Next.js/
testing-tool knowledge)

**Two real test files already exist and are completely unexecuted.**
`web/lib/password-reset.test.ts` (48 lines, 4 tests) and
`web/lib/comp-export.test.ts` (127 lines, 6 tests) both use Node's
*built-in* `node:test` + `node:assert/strict` — no framework installed,
no framework needed to write them. They import their subjects with
explicit `.ts` extensions (`from "./password-reset.ts"`), which resolves
under Node's native TypeScript support but not under plain `tsc`/webpack
module resolution as currently configured. **Nothing runs them**:
`web/package.json`'s `scripts` block is `dev`/`build`/`start`/`lint` only,
no `test` script exists, and zero testing packages are installed
(`devDependencies` is `@tailwindcss/postcss`, `@types/node`,
`@types/react`, `@types/react-dom`, `eslint`, `eslint-config-next`,
`tailwindcss`, `typescript` — nothing else). These tests have been dead
code since whichever round wrote them. **Getting them actually running is
the single highest-value, lowest-risk first deliverable this round can
ship** — it's proof the framework works against real, already-correct
assertions, not a fresh unknown.

**`.github/workflows/ci.yml`'s `web` job** (confirmed unchanged after
Round 7): `runs-on: ubuntu-latest`, `working-directory: web`, steps are
checkout → `setup-node@v4` (node 22, npm cache) → `npm ci` → `npm run
lint` → `npm run build`. No test step exists. No browser binaries are
installed anywhere in CI — a Playwright/Cypress E2E suite would need new
setup added (`npx playwright install --with-deps` or equivalent), not
just a new script.

**Next.js 16.3.0's own bundled docs** (`node_modules/next/dist/docs/
01-app/02-guides/testing/`) document four options with no single
recommended default: Vitest, Jest, Playwright, Cypress. One documented
fact worth weighing directly: *"Since `async` Server Components are new to
the React ecosystem, some tools do not fully support them... we recommend
using End-to-End Testing over Unit Testing for `async` components."*
Vitest's manual setup needs `vitest @vitejs/plugin-react jsdom
@testing-library/react @testing-library/dom` (+ `vite-tsconfig-paths`).

**The testable surface, concretely:**
- `web/lib/` has 16 non-test `.ts` files. **9 are pure or near-pure logic
  with no Supabase import** — `admin.ts`, `calibration.ts`,
  `comp-export.ts` (already tested), `goals.ts`, `okr.ts`, `pagination.ts`,
  `password.ts`, `password-reset.ts` (already tested), `types.ts`
  (type-only). **7 are Supabase-querying** (`admin-queries.ts`,
  `comp-export-queries.ts`, `goal-plan-queries.ts`, `okr-queries.ts`,
  `supabase/admin.ts`, `supabase/client.ts`, `supabase/server.ts`) — these
  need either a running DB, heavy mocking, or are out of scope for unit
  testing and better covered by `scripts/verify.sql` (the RLS/DB layer)
  plus live Gate 2 verification (the UI layer), which is how every prior
  round has actually caught the real bugs in this class of file (the
  self-referencing-RLS bugs, the ambiguous-embed regression from the
  brutal-QA round) — unit tests with a mocked Supabase client would not
  have caught either.
- `web/components/` has 31 files: **24 Client Components** (real
  interactive logic — forms, modals, the custom pointer-drag hook behind
  the calibration board) and **7 Server Components** (small presentational
  cards/badges/pills, no async data-fetching of their own).
- `web/tsconfig.json` already type-checks `**/*.ts`/`**/*.tsx` with no
  exclusion for test files. `web/.gitignore` already has a `# testing`
  section ignoring `/coverage` — already anticipated by whoever wrote the
  two dead test files, just never finished.

**What Gate 2 already covers, every round, manually.** This project's own
process already includes a mandatory live-browser verification pass
before anything merges — every round's Gate 2 has caught real bugs unit
tests wouldn't (wrong RLS embed direction, a silently-broken picker, a
redirect-URL mismatch only visible by clicking the real emailed link).
That's relevant to how much E2E-framework investment this round actually
needs: a Playwright suite would formalize and repeat SOME of what Gate 2
already does by hand, but Gate 2 itself isn't going away, and CI has no
browser setup today. Don't let "add a test framework" become "add a full
E2E suite" by default — the brief wants you to make a reasoned call on
scope, not assume maximal.

## Scope for this round — open questions for you to answer with reasoning

1. **Runner choice: extend the existing zero-dependency `node:test`
   convention, or pull in Vitest?** Both are legitimate. `node:test` needs
   nothing new installed and matches this project's consistently minimal
   `devDependencies` list; its rough edge is the `.ts`-extension import
   pattern already used in both dead test files, which needs Node's
   native TS stripping (Node 22+, matching CI's `node-version: 22`) or a
   loader to actually execute — verify which, empirically, don't assume.
   Vitest is the more standard/full-featured choice with fuller Next.js
   doc support, native ESM+TS, and a real path to component testing via
   jsdom + Testing Library, at the cost of ~5 new devDependencies. State
   your reasoning and pick one — don't hedge with a mixed setup.
2. **Component testing: in scope this round, or a deliberate stretch/
   future-round line?** 24 Client Components have real logic (form
   validation, the drag hook, modal state machines). Testing them
   meaningfully needs jsdom + Testing Library (only available under the
   Vitest path above) — if you pick `node:test`, say explicitly that
   component testing is therefore out of scope this round and why that's
   an acceptable trade, not a silent gap.
3. **E2E (Playwright/Cypress): in scope, out of scope, or deferred with a
   stated reason?** Given CI has no browser setup today and Gate 2 already
   provides hand-driven E2E-equivalent coverage every round, make an
   explicit call rather than defaulting to "add Playwright because Next's
   docs mention it." If you think E2E genuinely belongs this round, justify
   it against what Gate 2 already catches; if not, say so plainly rather
   than skipping the question.
4. **Coverage plan for this round**: get the two existing dead tests
   running first (proof the runner works against known-correct
   assertions), then which of the 7 untested pure-logic `lib/` files
   are you writing new tests for, and what's each file's actual highest-
   value test target (a validation function, a formatting function, an
   edge case a prior round's brief/README already flagged as tricky —
   e.g. `pagination.ts`'s clamping behavior, `calibration.ts`'s band-range
   logic). Don't test everything uniformly; name specific functions and
   why they're worth a test.
5. **CI integration**: exactly what step(s) get added to `.github/
   workflows/ci.yml`'s `web` job (or a new job), matching the existing
   job's shape rather than inventing a different pattern.

## Explicitly out of scope this round

Testing the 7 Supabase-querying `lib/` files against a mocked client (see
reasoning above — this class of bug is caught by `verify.sql` + live Gate
2, not unit tests with a stubbed Supabase response). Retrofitting every
Client Component with tests in one round — pick real, valuable targets,
not maximal coverage for its own sake. Any change to `scripts/verify.sql`
or the DB layer — this round is frontend-only. Hosted deployment,
real email/webhook notifications (permanently out, per every prior brief).

## Constraints carried from every prior round

`npm run lint && npm run build` clean before reporting done — plus,
this round specifically, the new `npm run test` (or equivalent) command
must actually pass when run for real, not just be wired up and assumed
to work. Do not touch `README.md` or copy brief/ruling docs into the
repo — Fable handles that after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your runner choice and reasoning (question 1).
- Your call on component testing scope (question 2).
- Your call on E2E scope (question 3).
- The exact list of new tests you'd write this round and why each one is
  worth writing (question 4) — be concrete, not "add tests for X.ts".
- Your exact CI integration (question 5).
- How you'll verify the runner actually works empirically (not just that
  `npm run test` exits 0 with zero tests collected — a real failure mode
  for a misconfigured runner) before reporting done.
- Division of labor if pairing with another builder.
