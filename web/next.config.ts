import type { NextConfig } from "next";

// Security headers. No CSP here on purpose: a strict CSP under Turbopack dev
// (HMR websocket, inline dev overlays) is easy to get subtly wrong and easy
// to silently break without noticing; the headers below are the
// high-confidence wins that don't risk breaking the dev server, and are a
// clear next step to layer on before a production deploy.
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
