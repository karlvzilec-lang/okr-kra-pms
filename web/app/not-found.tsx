import Link from "next/link";
import { Compass } from "@phosphor-icons/react/dist/ssr/Compass";

export default function NotFound() {
  return (
    <main
      className="flex min-h-dvh flex-1 flex-col items-center justify-center gap-4 px-4 text-center"
      style={{ backgroundColor: "var(--background)" }}
    >
      <span
        className="flex h-12 w-12 items-center justify-center rounded-xl"
        style={{ backgroundColor: "var(--muted)", color: "var(--muted-foreground)" }}
      >
        <Compass size={24} weight="bold" aria-hidden="true" />
      </span>
      <div>
        <h1 className="font-heading text-lg font-semibold" style={{ color: "var(--foreground)" }}>
          Page not found
        </h1>
        <p className="mt-1 max-w-sm text-sm" style={{ color: "var(--muted-foreground)" }}>
          That page doesn&apos;t exist. Head back to your review summary.
        </p>
      </div>
      <Link
        href="/review"
        className="inline-flex min-h-11 items-center rounded-lg px-4 text-sm font-semibold transition-transform active:scale-[0.98]"
        style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
      >
        Back to review summary
      </Link>
    </main>
  );
}
