import Link from "next/link";
import { CaretLeft } from "@phosphor-icons/react/dist/ssr/CaretLeft";
import { CaretRight } from "@phosphor-icons/react/dist/ssr/CaretRight";
import { PAGE_SIZE } from "@/lib/pagination";

/**
 * The page control shared by every paginated list.
 *
 * Deliberately a Server Component built out of <Link>s rather than a client
 * island with onClick handlers. Page state lives in the URL, which means it
 * survives a refresh, can be linked and bookmarked, and — the reason that
 * actually matters here — paging works before and without JavaScript, since
 * each control is a real navigation rather than an event handler. There is no
 * client state to hold, so there is no reason to ship a client bundle for it.
 *
 * It renders nothing at all when there's only one page. A pager on a list that
 * fits on one screen is furniture that tells the reader nothing.
 */
export function Pagination({
  page,
  pageCount,
  total,
  basePath,
  itemLabel,
}: {
  page: number;
  pageCount: number;
  total: number;
  /** Path this list lives at, e.g. "/admin". The page number is appended as ?page=N. */
  basePath: string;
  /** Singular noun for the rows, e.g. "employee". Pluralised with a trailing "s". */
  itemLabel: string;
}) {
  if (pageCount <= 1) return null;

  const first = (page - 1) * PAGE_SIZE + 1;
  const last = Math.min(page * PAGE_SIZE, total);

  // Page 1 drops the query string entirely so the canonical URL of a list is
  // its bare path, not an equivalent-but-different ?page=1.
  const hrefFor = (target: number) => (target <= 1 ? basePath : `${basePath}?page=${target}`);

  return (
    <nav
      aria-label={`${itemLabel} pagination`}
      className="mt-6 flex flex-wrap items-center justify-between gap-3"
    >
      <p className="text-xs" style={{ color: "var(--muted-foreground)" }}>
        Showing{" "}
        <span className="font-data">
          {first}–{last}
        </span>{" "}
        of <span className="font-data">{total}</span> {total === 1 ? itemLabel : `${itemLabel}s`}
      </p>

      <div className="flex items-center gap-2">
        <PageLink
          href={hrefFor(page - 1)}
          disabled={page <= 1}
          label={`Previous page of ${itemLabel}s`}
        >
          <CaretLeft size={14} weight="bold" aria-hidden="true" />
          Previous
        </PageLink>

        <span className="font-data px-1 text-xs" style={{ color: "var(--muted-foreground)" }}>
          {page} / {pageCount}
        </span>

        <PageLink
          href={hrefFor(page + 1)}
          disabled={page >= pageCount}
          label={`Next page of ${itemLabel}s`}
        >
          Next
          <CaretRight size={14} weight="bold" aria-hidden="true" />
        </PageLink>
      </div>
    </nav>
  );
}

/**
 * One step control.
 *
 * At the ends of the range this renders a <span>, not a disabled <a>. An
 * anchor with no destination is not focusable or actionable anyway, so giving
 * it a disabled *appearance* while leaving it in the tab order would be a lie
 * to a keyboard or screen-reader user; removing it from the accessibility tree
 * as a plain span matches what it actually is.
 */
function PageLink({
  href,
  disabled,
  label,
  children,
}: {
  href: string;
  disabled: boolean;
  label: string;
  children: React.ReactNode;
}) {
  const shared =
    "inline-flex min-h-11 items-center gap-1.5 rounded-lg border px-3 text-sm font-medium";

  if (disabled) {
    return (
      <span
        aria-hidden="true"
        className={`${shared} opacity-40`}
        style={{ borderColor: "var(--border)", color: "var(--muted-foreground)" }}
      >
        {children}
      </span>
    );
  }

  return (
    <Link
      href={href}
      aria-label={label}
      className={`${shared} transition-[transform,background-color] active:scale-[0.98] hover:bg-[var(--muted)]`}
      style={{ borderColor: "var(--border)", color: "var(--foreground)" }}
    >
      {children}
    </Link>
  );
}
