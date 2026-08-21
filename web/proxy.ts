import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

const isDev = process.env.NODE_ENV === "development";

// `NEXT_PUBLIC_SUPABASE_URL` cannot change within a running server process, so
// the origin is derived once at module load rather than per request. A
// malformed value omits the origin instead of throwing — a broken env var
// should not turn every request into a 500.
const supabaseOrigin = (() => {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!).origin;
  } catch {
    return "";
  }
})();

function buildCsp(request: NextRequest, nonce: string) {
  // Dev only: Turbopack's HMR client opens a websocket back to the dev server
  // itself, so scope the allowance to this request's own host rather than a
  // blanket `ws: wss:`.
  const devWebSocketOrigin = isDev
    ? `${request.nextUrl.protocol === "https:" ? "wss:" : "ws:"}//${request.nextUrl.host}`
    : "";

  const connectSrc = ["'self'", supabaseOrigin, devWebSocketOrigin]
    .filter(Boolean)
    .join(" ");

  // `'strict-dynamic'` is required alongside the nonce: Next's client bundle
  // injects further scripts (chunk loading, prefetch) that must inherit trust
  // from the initially-nonce'd script.
  // Dev also needs `'unsafe-eval'` for Turbopack's HMR runtime.
  const scriptSrc = [
    "'self'",
    `'nonce-${nonce}'`,
    "'strict-dynamic'",
    isDev ? "'unsafe-eval'" : "",
  ]
    .filter(Boolean)
    .join(" ");

  // `style-src 'unsafe-inline'` is a deliberate, documented tradeoff: a nonce
  // does not cover `style={{}}` attributes at all (that is `style-src-attr`,
  // which falls back to `style-src` when omitted), and this app styles inline
  // in 46 files. Removing it is a separate, larger change.
  return [
    "default-src 'self'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    `script-src ${scriptSrc}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self'",
    "font-src 'self'",
    `connect-src ${connectSrc}`,
  ].join("; ");
}

export async function proxy(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const csp = buildCsp(request, nonce);

  // Clone the incoming headers exactly once and mutate only this object.
  // Supabase's `setAll` callback below rebuilds the response mid-flight; if
  // each rebuild re-read the original request headers, the nonce would
  // silently vanish — a failure invisible to lint and build, and visible only
  // in a browser. Every `NextResponse.next()` call must receive this same
  // `Headers` instance.
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-nonce", nonce);
  // Next reads the nonce back off the *request*'s CSP header to stamp
  // `nonce=` onto the framework's own <script> tags.
  requestHeaders.set("Content-Security-Policy", csp);

  let response = NextResponse.next({ request: { headers: requestHeaders } });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          response = NextResponse.next({ request: { headers: requestHeaders } });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Refreshing the session here keeps server components' auth.getUser()
  // reads in sync with the browser's cookie-stored session.
  await supabase.auth.getUser();

  // Set on the response only after `getUser()` resolves, so it survives any
  // reassignment `setAll` performed above.
  response.headers.set("Content-Security-Policy", csp);

  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
