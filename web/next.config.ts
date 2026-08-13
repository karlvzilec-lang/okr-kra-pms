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
