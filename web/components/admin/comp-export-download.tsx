"use client";

import { DownloadSimple } from "@phosphor-icons/react/DownloadSimple";

type CompExportDownloadProps = {
  csv: string;
  filename: string;
  rowCount: number;
};

export function CompExportDownload({ csv, filename, rowCount }: CompExportDownloadProps) {
  function download() {
    const blob = new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.click();
    URL.revokeObjectURL(url);
  }

  return (
    <button
      type="button"
      onClick={download}
      disabled={rowCount === 0}
      className="inline-flex min-h-11 items-center gap-2 rounded-lg px-4 text-sm font-semibold transition-transform active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-50"
      style={{ backgroundColor: "var(--accent)", color: "var(--accent-foreground)" }}
    >
      <DownloadSimple size={18} weight="bold" aria-hidden="true" />
      Download full-cycle CSV
    </button>
  );
}
