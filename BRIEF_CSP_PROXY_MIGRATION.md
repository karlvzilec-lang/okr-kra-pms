# Brief: CSP implementation + middleware.ts → proxy.ts migration

Repo: `okr-kra-pms`. Round 7 of the gap-closure effort. Rounds 1-6 are
merged on `master` at `37cc930`. Read `README.md` in full first, especially
the CSP "deliberately deferred" note and the `middleware.ts` "Known
follow-up" bullet in Security.

## Ground truth (pre-verified against this repo's actual installed
Next.js 16.3.0 and its own bundled docs — not recalled from general
Next.js knowledge, which is stale across versions for this exact topic)

**`middleware.ts` → `proxy.ts` is a pure rename in this Next.js version**,
confirmed from Next 16.3.0's own bundled docs
(`node_modules/next/dist/docs/.../proxy.md`): the rename shipped in
`v16.0.0`, Proxy now defaults to the Node.js runtime (not Edge), the
function signature/`NextRequest`/`NextResponse`/`config.matcher` API is
otherwise unchanged, and Next ships an official codemod:
`npx @next/codemod@canary middleware-to-proxy .`. Current
`web/middleware.ts` (39 lines) does exactly one thing — Supabase SSR
session refresh via `supabase.auth.getUser()` — with a single matcher
excluding `_next/static`, `_next/image`, `favicon.ico`, and common image
extensions. Verify the codemod's actual output against this specific file
rather than assuming it's a no-op; the docs describe the rename, not a
guarantee about every file's contents.

**CSP is the harder half, and the honest scope constraint is this: the app
uses React's inline `style={{...}}` prop pervasively — 46 files**, every
one of them part of the established CSS-custom-property design system
(`style={{ backgroundColor: "var(--background)" }}` and equivalents,
used consistently since Round 1). React renders this as a literal DOM
`style="..."` attribute, which a strict `style-src` (no `unsafe-inline`,
no nonce, no hash) blocks exactly like inline `<style>`. **Do not attempt
to eliminate or rewrite this pattern this round** — that would be a
codebase-wide rewrite of the established design system, not a CSP
implementation, and is explicitly out of scope. The realistic, honest CSP
this round can ship is: a strict `script-src` (real security value — this
blocks the actual XSS-via-script-injection threat CSP exists for) paired
with a `style-src` that still allows `'unsafe-inline'` (a stated,
deliberate tradeoff, not an oversight — document it as such, matching this
repo's established pattern of naming tradeoffs explicitly rather than
hiding them).

**`script-src` can be genuinely strict, because there's nothing to
accommodate**: confirmed by full-repo grep — zero `dangerouslySetInnerHTML`,
zero raw `<script>` JSX, zero `eval(`/`new Function(` in application code,
zero analytics/third-party script tags of any kind (this project has none,
consistent with the standing "no external providers" scope). The only
real constraint is Next.js/React's own framework behavior:

- **`'unsafe-eval'` is required in `script-src` during development only**
  (confirmed in Next's own bundled CSP guide — React's dev-mode error-stack
  reconstruction uses `eval`; not used in production builds). Must be
  conditioned on `process.env.NODE_ENV === 'development'`, not shipped
  unconditionally.
- Next's documented, first-class way to get a strict production
  `script-src` is a **Proxy-generated nonce** (`node_modules/next/dist/docs/
  .../content-security-policy.md`) — Proxy sets both a `Content-Security-Policy`
  response header and an `x-nonce` request header per request; Next
  automatically applies that nonce to its own framework-injected scripts.
  This is the mechanism to use for `script-src`, not a static hash list.
- **Nonce-based CSP forces dynamic rendering** on any page that uses it —
  confirmed in the docs (static optimization/ISR/PPR all become
  incompatible). Check whether this is actually a behavior change for this
  app: every route already reads cookies via Supabase SSR / calls
  `auth.getUser()` server-side, which likely already forces dynamic
  rendering on every page in practice — verify this directly (e.g. via
  `next build`'s own route-type output, which prior rounds' build logs
  already show as `ƒ` dynamic for nearly every route) rather than assuming
  the nonce requirement changes anything real.

**Header layering / ordering matters and is a real conflict risk**:
confirmed from Next's own docs — `next.config.ts`'s static `headers()`
block runs *before* Proxy in the request chain, and when two header blocks
set the *same header key* for the same path, **the later-evaluated one
wins**. Since CSP needs to be per-request (nonce), it must be set in
`proxy.ts`, **not** duplicated in `next.config.ts`'s existing
`headers()` array — the other 5 existing headers (`X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`,
`Strict-Transport-Security`) can stay exactly where they are; only CSP is
new and it has to live in `proxy.ts`. Decide and implement this cleanly —
don't let both files declare `Content-Security-Policy` and rely on
override behavior to sort it out silently.

**`X-Frame-Options` is superseded by CSP's `frame-ancestors`** per Next's
own docs — add `frame-ancestors 'none'` to the CSP directive set; keep the
existing `X-Frame-Options: DENY` too for older-browser defense in depth
(redundant is fine here, not harmful).

**`connect-src` needs the actual Supabase origin, and only the local dev
origin exists anywhere in this repo** (`NEXT_PUBLIC_SUPABASE_URL=http://
127.0.0.1:15421` in `.env.local`/`.env.example`). Don't hardcode this —
derive `connect-src` from `process.env.NEXT_PUBLIC_SUPABASE_URL` at
request time in `proxy.ts` (or build time, your call, state which and
why) so it's correct for local dev now and for whatever real origin gets
configured later, without another manual edit.

**Fonts need no special CSP allowance** — `web/app/layout.tsx` uses
`next/font/google`, which self-hosts font files at build time; there is no
runtime request to any `fonts.googleapis.com`/`fonts.gstatic.com` origin.
`font-src 'self'` is sufficient; don't add a Google Fonts origin that
isn't actually needed.

**No images from external hosts** — `web/public/` is five local SVGs, no
`next/image` usage anywhere, no external image origins referenced.

**CI cannot and will not catch a CSP regression** — confirmed by reading
`.github/workflows/ci.yml` in full: the `web` job is exactly `npm run
lint` + `npm run build`, no browser-based test of any kind exists in this
repo. A CSP that silently breaks the rendered app (a blocked script, a
console full of violation reports) would pass CI cleanly and only be
caught by someone actually opening the app in a browser. This makes live
browser verification — checking the browser console for CSP violation
reports on every major page, not just confirming the page "loads" —
non-negotiable for this round's Gate 2, more so than any prior round.

## Scope for this round

1. **`proxy.ts` migration**: rename/migrate `middleware.ts`'s existing
   session-refresh logic (verify the codemod's actual output on this file
   rather than assuming a clean rename; fix by hand if it doesn't produce
   correct code).
2. **CSP via `proxy.ts`**: nonce-based `script-src`, `style-src` with a
   documented `'unsafe-inline'` allowance, `frame-ancestors 'none'`,
   `connect-src` derived from the actual Supabase origin env var,
   `font-src 'self'`, sensible defaults for the remaining directives
   (`default-src 'self'`, `img-src 'self'`, `object-src 'none'`, etc. —
   your call on the full directive list, state your reasoning for each
   non-obvious one). Dev-mode `'unsafe-eval'` conditioned correctly.
3. **Thread the nonce into anywhere the app needs it** — Next auto-applies
   it to its own framework scripts, but confirm whether this app has any
   place that needs to read/pass the nonce explicitly (e.g. a `<Script>`
   tag — grep first, don't assume there is or isn't one).
4. **Live verification, both dev and production build** — this round's
   CI-can't-catch-it gap means you must actually exercise the app in a
   browser: log in, navigate through the major authenticated surfaces
   (`/review`, `/goals/[planId]`, `/calibration`, `/admin`, etc.), and
   check the browser console for zero CSP violation reports, in both
   `npm run dev` (confirming the README's original HMR worry is actually
   resolved, not just avoided by never testing dev mode) and a production
   `npm run build && npm start` (or equivalent) pass.

## Explicitly out of scope this round

Rewriting the app's inline-`style={{}}` design-system pattern to eliminate
the `style-src 'unsafe-inline'` allowance — a real, large, separate effort,
not part of "add a CSP." CSP violation reporting infrastructure (no
external service to report to, matching the standing no-provider scope).
Any change to the other 5 existing security headers beyond what's needed
for `X-Frame-Options`/`frame-ancestors` coexistence. Hosted deployment
(permanently out).

## Constraints carried from every prior round

Existing CSS tokens, `min-h-11`, `active:scale-[0.98]`, Phosphor icons
only, no new dependencies. `npm run lint && npm run build` clean before
reporting done. Do not touch `README.md` or copy brief/ruling docs into
the repo — Fable handles that after merge.

## What I need from you right now

Do NOT implement anything yet. Propose your plan/approach only:
- Your exact CSP directive list, with reasoning for each non-obvious
  choice (especially `style-src`, `script-src`, `connect-src`).
- How you'll verify the `middleware.ts` → `proxy.ts` codemod's actual
  output is correct for this specific file, not just assume it.
- How you'll thread the nonce (Proxy → wherever it needs to reach) and
  confirm Next's automatic application actually covers what this app
  needs, empirically.
- Your plan for live-verifying zero CSP violations across the major
  authenticated pages, in both dev and a production build — this is the
  one thing CI cannot do for you this round, so be concrete about it.
- Division of labor if pairing with another builder.
