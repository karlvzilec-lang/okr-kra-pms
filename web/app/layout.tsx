import type { Metadata } from "next";
import { Lexend, Source_Sans_3, IBM_Plex_Mono } from "next/font/google";
import { connection } from "next/server";
import "./globals.css";

const lexend = Lexend({
  variable: "--font-lexend",
  subsets: ["latin"],
  weight: ["500", "600", "700"],
});

const sourceSans = Source_Sans_3({
  variable: "--font-source-sans",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
});

const plexMono = IBM_Plex_Mono({
  variable: "--font-plex-mono",
  subsets: ["latin"],
  weight: ["500", "600"],
});

export const metadata: Metadata = {
  title: "Performance Review | okr-kra-pms",
  description: "KRA and OKR review summary for one employee cycle.",
};

export default async function RootLayout({ children }: LayoutProps<"/">) {
  // The CSP in `proxy.ts` carries a per-request nonce, and Next only stamps
  // `nonce=` onto its <script> tags when a page is rendered per request.
  // Statically prerendered pages are built without any request, so their HTML
  // has no nonce and `'strict-dynamic'` would block every script on them.
  // Opting the root layout into per-request rendering covers the whole app at
  // once instead of route by route.
  await connection();

  return (
    <html
      lang="en"
      className={`${lexend.variable} ${sourceSans.variable} ${plexMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
