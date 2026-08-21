# Gate 1 Ruling: CSP implementation + middleware.ts → proxy.ts migration

Both plans converge strongly on the shape of the solution (CSP lives solely
in `proxy.ts`, nonce + nonce-forwarding hazard identified independently by
both builders with the same root cause and the same fix shape, same live
page-matrix approach, same header-layering decision). Ruling directly
rather than dispatching a separate cross-challenge round — this comparison
itself serves that function.

## Final CSP (production)

```
default-src 'self';
base-uri 'none';
object-src 'none';
frame-src 'none';
frame-ancestors 'none';
form-action 'self';
script-src 'self' 'nonce-${nonce}' 'strict-dynamic';
style-src 'self' 'unsafe-inline';
img-src 'self';
font-src 'self';
connect-src 'self' ${supabaseOrigin};
```

Dev adds `'unsafe-eval'` to `script-src` (NODE_ENV==='development' only)
and `${devWebSocketOrigin}` to `connect-src` (derived `ws:`/`wss:` from the
request's own origin — Sol's proposal — not a blanket `ws: wss:` allowance,
so HMR is scoped to the actual dev host/port).

### Resolved disagreements

1. **`'strict-dynamic'` — include from the start (Sol), not Jcode's
   start-without-it hedge.** Next's own bundled CSP guide (already
   independently confirmed by this round's fact-gathering agent reading
   `node_modules/next/dist/docs`, and cited again by Sol) documents nonce +
   `'strict-dynamic'` together specifically because Next's client bundle
   injects further scripts (chunk loading, prefetch) that need to inherit
   trust from the initially-nonce'd script. This isn't a guess to hedge
   against — it's already-verified documented behavior for this exact
   installed version. Include it from the start; still empirically confirm
   via live testing that chunk loading actually works, rather than trusting
   the doc blindly.

2. **`base-uri 'none'` (Sol), not `'self'` (Jcode).** The app has zero
   `<base>` tag usage anywhere — confirmed by both builders' greps.
   `'none'` is strictly tighter with no functional cost. Use it.

3. **`img-src 'self'` (Sol), not `'self' data: blob:'` (Jcode's
   speculative allowance).** Jcode itself said it would drop the extra
   sources if verification showed them unused, and Sol's grep found no
   current consumer. Ship the narrower policy. If live verification (Gate
   2) surfaces an actual broken image/blob load, add exactly the source
   needed and document why — don't add it preemptively.

4. **`connect-src`'s Supabase origin: derive once at module scope in
   `proxy.ts` (Jcode), not re-parsed per request (Sol).**
   `NEXT_PUBLIC_SUPABASE_URL` cannot change within a running server
   process, so per-request `new URL()` parsing is pure overhead with zero
   behavioral difference. Keep Sol's defensive framing (`new URL().origin`,
   try/catch fallback that omits the origin rather than 500ing on a
   malformed env var) — just evaluate it once at module load, not inside
   the request handler.

5. **Nonce generation: `crypto.randomUUID()`, base64-encoded (Sol's
   concrete mechanism, matching Next's own documented example).** Adopt
   directly — this is exactly the pattern the fact-gathering agent
   confirmed from the bundled docs.

6. **Dynamic-rendering contingency: adopt Sol's fallback, gated on
   empirical need.** Don't assume every route is already dynamic (Sol is
   right to refuse that claim without measurement). Compare the `next
   build` route table before and after. If — and only if — some route
   unexpectedly stays static under the nonce policy, make `layout.tsx`
   async and call `await connection()` once in the root layout to force
   per-request rendering app-wide, rather than fixing routes one at a time.
   Report the actual before/after diff either way, per both plans.

### Where both plans already agreed (no ruling needed, just confirming)

- CSP header set exactly once, in `proxy.ts` only — `next.config.ts` keeps
  its existing 5 headers unchanged, and its stale "no CSP on purpose"
  comment gets updated to point at `proxy.ts` (Jcode's addition — do this,
  it's a real accuracy fix, not scope creep).
- `style-src 'self' 'unsafe-inline'` as the stated, deliberate,
  documented-in-a-comment tradeoff — both builders independently note a
  nonce does *not* cover `style={{}}` attributes at all (that's
  `style-src-attr`, which falls back to `style-src` if omitted, so no
  separate directive is needed). Do not attempt to eliminate this — out of
  scope per the brief.
- `font-src 'self'`, `object-src 'none'`, `form-action 'self'`,
  `frame-src 'none'`, `frame-ancestors 'none'` + keep `X-Frame-Options:
  DENY` for defense in depth, omit `upgrade-insecure-requests` (would break
  the local HTTP Supabase origin), omit reporting directives (no external
  service, out of scope).

## The load-bearing hazard both builders independently found — fix it exactly this way

Supabase's SSR `setAll` cookie callback reassigns `response =
NextResponse.next({ request })` mid-flight in the current middleware. If
the nonce is set on request headers once up front and Supabase's callback
rebuilds the response from the *original* `request` object afterward, the
`x-nonce` header silently disappears — the app still builds and lints
clean, and only fails visibly in a browser (exactly the kind of gap this
round's brief flagged CI as blind to). Both builders converged on the same
fix independently, which is strong evidence it's correct: clone
`request.headers` once, set `x-nonce` on that single `Headers` object, pass
that *same* object into every `NextResponse.next({ request: { headers } })`
call including the one inside `setAll`, and attach the
`Content-Security-Policy` response header only after `getUser()` resolves
so it survives the reassignment too. Verify empirically (not just by
reading the diff): in a real browser, confirm framework `<script>` tags
carry a `nonce=` attribute matching the response's CSP header for the same
request, and that the nonce differs across two reloads.

## Codemod verification protocol

Follow Jcode's concrete steps (more mechanically precise than Sol's):
commit a checkpoint, run `npx @next/codemod@canary middleware-to-proxy .`
from `web/`, then `git diff` every line rather than trusting a visual scan
— specifically confirm the file lands at `web/proxy.ts` (not nested under
`app/`), the exported function is renamed `middleware` → `proxy`, the
`config.matcher` regex is preserved character-for-character (the escaped
`\.` and alternation are exactly where a codemod is likely to mangle
something), and the Supabase cookie closure survives intact. Confirm
`middleware.ts` is actually deleted, not left alongside (two active entry
points would be a silent double-execution bug). If the codemod's output is
wrong or unavailable, hand-write the 39-line rename and review it exactly
as if it were codemod output.

## Division of labor

This round doesn't split into disjoint file areas the way prior rounds did
— it's fundamentally one file (`proxy.ts`) doing one job. Don't force an
artificial split that would produce two competing `proxy.ts`
implementations to reconcile at merge time.

- **Jcode implements**, in its own worktree, against this ruling in full:
  the codemod migration, the CSP directive set and hazard fix above, the
  `next.config.ts` comment update, and its own `npm run lint && npm run
  build` gate.
- **Sol does adversarial CLI-only verification** against Jcode's actual
  diff once it exists (not the plan — the real code): apply the diff in
  its own worktree, review it line by line against this ruling, run its
  own `npm run lint && npm run build`, and run the curl-based
  header/nonce-rotation checks from its own plan (exactly-one CSP header,
  nonce present and differs across two curl calls, `unsafe-eval` absent
  from a production build's header, the 5 existing headers still present).
  Report any deviation from this ruling as a concrete finding, not a style
  opinion.
- **Fable (me) owns Gate 2's live-browser pass personally, as in every
  prior round — this is not delegable to either builder.** Round 6 already
  established that neither builder's sandbox can drive a real browser
  (Jcode and Sol are both CLI-only agents with no GUI/DevTools access);
  Sol's detailed browser-verification protocol — DevTools Console with
  "Preserve log," a fresh browser profile, walking the full authenticated
  route matrix under all three seeded roles, the HMR whitespace-edit
  round-trip, the incognito production pass — is exactly right as a
  protocol, but I will be the one executing it via the Browser pane tools,
  using Sol's writeup as my test script rather than trusting either
  builder's self-report of it.

## Explicitly not re-litigated

Everything the brief already marked out of scope stays out of scope:
rewriting the 46-file inline-style pattern, CSP violation reporting
infrastructure, changes to the other 5 existing headers beyond
`X-Frame-Options`/`frame-ancestors` coexistence, hosted deployment.
