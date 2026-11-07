/**
 * Stand-in for src/orchestrator.ts in the exit-code test. MAKE_PDF_STUB picks
 * the outcome; the error classes are the real ones, so cli.ts maps exactly
 * what the production pipeline would throw. preload.ts serves this source as
 * src/orchestrator.ts, so imports resolve relative to src/.
 */
import { BrowseClientError, ExitCode } from "./types";
import { TocPaginationError } from "./toc-pages";

function outcome(): string {
  switch (process.env.MAKE_PDF_STUB) {
    case "ok":
      return "/stub/out.pdf";
    case "enoent":
      throw Object.assign(new Error("ENOENT: no such file"), { code: "ENOENT", path: "/stub/missing.md" });
    case "render":
      throw new Error("stub render failure");
    case "toc":
      throw new TocPaginationError("stub toc failure");
    case "browse":
      throw new BrowseClientError(127, "newtab", "stub browse missing");
    default:
      throw new Error(`unknown MAKE_PDF_STUB '${process.env.MAKE_PDF_STUB}'`);
  }
}

export async function generate(): Promise<string> {
  return outcome();
}

export async function preview(): Promise<string> {
  return outcome();
}

export { ExitCode };
