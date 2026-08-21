import type { NextConfig } from "next";

// Security headers. The Content-Security-Policy is deliberately NOT here: it
// needs a fresh per-request nonce, which a static header table cannot
// express, so it is set in `proxy.ts` instead. The headers below are static
// and apply to every response, including the asset paths `proxy.ts`'s matcher
// skips. `X-Frame-Options: DENY` intentionally overlaps `frame-ancestors
// 'none'` in that CSP, as defense in depth for older clients.
const securityHeaders = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
];

const nextConfig: NextConfig = {
  // The repo root has its own package.json (a devDependency-only shim so
  // `npx supabase` works without a global install — see README's Local
  // development section). Turbopack sees two lockfiles and, without this,
  // guesses the repo root as the workspace root instead of `web/`, which
  // breaks `next dev`'s module resolution entirely ("Could not find the
  // Next.js package"). `next build` only warns about this; `next dev`
  // hard-fails, so pin it explicitly.
  turbopack: {
    root: __dirname,
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
