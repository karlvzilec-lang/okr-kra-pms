# Gate 1 Ruling: Comp-export frontend surface + pagination pass

Jcode and Sol both planned independently and converged strongly — same
route, same page size, same CSV-scope decision, same synthetic-data testing
method. This ruling resolves the few real differences and is final.

## Resolved (both agreed, or one's answer settles the other's open question)

**Route: `/admin/comp-export`**, nested under the existing `/admin`
HR-gated layout, linked from `/admin`'s own header alongside "Employees"
and "Matrix access" — not a fourth top-level link on `/review`. Both
builders independently reasoned the same way: it's HR administration by
definition (the function's own gate is `is_hr_admin`), and `/review`
already carries three HR-only links.

**Page-based pagination, page size 25**, using `.range(from, to)` with
`{ count: "exact" }`. Both independently rejected cursor pagination for the
same reason: these are small, stable, admin-facing datasets where a total
count and jump-to-page matter more than cursor-pagination's concurrent-
insert stability, which doesn't apply here.

**CSV exports the full cycle, not just the current page.** Sol assumed
this without even flagging it as a question; Jcode flagged it as the one
open question and reasoned the same way — a truncated compensation export
is a genuinely dangerous artifact (HR could act on incomplete comp data).
Settled: fetch the complete export in bounded `.range()` batches
server/client-side (however you structure it) so the CSV is always
complete regardless of the 1000-row `max_rows` cap or the table's own
pagination state.

**Deterministic ordering with a tiebreaker before every `.range()` call.**
Sol's point, uncontested and correct: `full_name`/`start_date` aren't
unique, so paging without a tiebreaker (e.g. `.order("full_name").order("id")`)
risks a row appearing twice or being skipped across a page boundary if two
rows share the same primary sort value. Apply this to every paginated
query, not just the ones where a collision seems likely.

**`/admin`'s manager-picker dropdown must NOT be paginated.** Sol's point,
which Jcode's plan didn't explicitly address but must incorporate: the
employee *directory* (rendered rows) gets paginated, but the "assign a
manager" `<select>` inside the create/edit forms needs the complete,
unbounded list of candidate managers — silently hiding valid manager
choices because they're on a different directory page would be a real
bug, not a UX nicety. Fetch these as two separate queries: one paginated
(directory rows), one complete (picker options). Apply the same principle
anywhere else a paginated list's rows also double as a form's option set
(check `/admin/matrix-scopes` for the same pattern — its employee/plan
picker and matrix-manager picker must stay unbounded even if the "current
grants" list below them is paginated).

## Resolved (my ruling on the one real disagreement)

**Skip `/review-cycles` pagination — Sol's position, not Jcode's.** A
review cycle is created a handful of times per year at most; this list
will realistically never reach even a second page of 25 in the lifetime of
a real org, and HR genuinely benefits from seeing the full chronology in
one view (comparing cycle-over-cycle timing, statuses). Jcode's plan
included it "since it's cheap to add," which is true but isn't a reason on
its own — don't paginate a list whose real-world cardinality will never
justify it. Same reasoning extends to any other genuinely low-cardinality,
rarely-created list you encounter — state your judgment if you find one
Jcode/Sol didn't already call out, don't default to "paginate everything."

**`/calibration`'s session list gets paginated (both agreed); its cycle
picker does not (both agreed).** No disagreement here, just confirming
both plans already landed on the same answer.

**`/objectives` and `/reports`: paginate, per both plans.** For `/reports`,
Jcode flagged a real risk — `loadManagerReports` currently filters/reshapes
client-side after the query, so a raw `.range()` would paginate pre-filter
rows and could yield short or misleading pages. Investigate this
concretely before implementing: if the reshaping can move into the query
itself (filter/sort in SQL, not after fetch) so `.range()` genuinely
operates on the final row set, do that. If it genuinely can't be made
correct within this round's scope, skip pagination on `/reports` and say
so explicitly in your summary — don't ship a page control that lies about
what page you're on, matching Jcode's own stated principle.

**`/admin/matrix-scopes`'s "Current grants" list gets paginated.** Both
agreed on this specific list (not the pickers feeding the grant form,
which stay unbounded per the ruling above).

## `scripts/verify.sql` — use Jcode's fuller list, folding in Sol's fixture

Jcode's six-item list is more complete (it covers the `final_score`
coalesce precedence and the `band_label`-null case as their own explicit
assertions, which are the function's actual business logic and were
previously unpinned) — implement that list. Use Sol's specific fixture
suggestion (temporarily publish Vuthy's already-manager-rated plan for the
second row, rather than inventing new IDs) since it's simpler and reuses
existing seed data:

1. Multi-row: publish a second plan (Sol's Vuthy fixture) in the same
   cycle, assert exactly 2 rows, ordered by `full_name`.
2. `manager_full_name` correctness: matches the real manager's name; is
   `null` for an employee with no manager (add a fixture for this specific
   null case if Vuthy doesn't already cover it — check first, don't guess).
3. `overall_rating_scale_max` matches the plan's own column, not a
   hardcoded value.
4. Zero published plans in a cycle → 0 rows, not an error.
5. `final_score` coalesce precedence: a plan with both a manager rating
   and a calibrated score returns the calibrated one; a plan with only a
   manager rating (Vuthy's fixture) returns that.
6. `band_label`: non-null when a calibration participant has a band, null
   when it doesn't (Vuthy's fixture, per Sol, naturally covers the null
   case since he has no calibration band).

Keep the existing HR-only assertion and confirm/add the "non-HR gets 0
rows, not an error" case explicitly if it isn't already unambiguous.

No new SQL surface is needed for pagination itself — plain `.range()` on
already-exposed tables/the existing RPC needs no new RLS.

## Division of labor

**Sol — comp-export surface**: `/admin/comp-export/page.tsx`, the
`CompExportRow` type, `web/lib/comp-export-queries.ts` (or equivalent),
the ranged-batch full-cycle fetch, the table, the CSV client leaf,
`verify.sql` extensions, and the synthetic-data proof (both plans
converged on a similar-sized synthetic dataset — pick a concrete number
that gets you past page 1 for both the employee directory and the
comp-export table, matching your own stated approach; state the exact
count you used and confirm cleanup afterward).

**Jcode — pagination pass**: a shared pagination primitive/component,
`PAGE_SIZE` constant, and the loader/page changes across `/admin`,
`/admin/matrix-scopes` (grants list only, pickers stay unbounded),
`/objectives`, `/reports` (investigate the reshaping issue per the ruling
above before committing to paginate it), `/calibration` (session list
only). Skip `/review-cycles` per the ruling.

**Shared contract, agree before either writes code**: the paginated result
shape returned by every updated loader — `{ rows: T[], total: number,
page: number, pageCount: number }` (or your own equivalent, but pick ONE
shape and use it everywhere so the pagination component is genuinely
shared, not reimplemented per page) — and the query-param convention
(`?page=N`, 1-indexed, out-of-range clamps rather than 404s or empty
tables).

## Explicitly out of scope this round

XLSX/PDF export. Changing `max_rows`. Notifications, hosted deployment —
permanently out per prior rounds.

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies (CSV generation is plain string-building, no
library). Server Components by default, isolated `"use client"` leaves.
`npm run lint && npm run build` clean before reporting done. Do not touch
`README.md` or copy brief/ruling docs into the repo — Fable handles that
after merge.

## Execute now

This ruling is approved. Proceed to implementation in your isolated
worktree, following exactly your assigned half above.
