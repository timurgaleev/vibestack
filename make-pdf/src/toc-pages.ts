/**
 * TOC page numbers, offline: print, read where each heading landed from the
 * printed PDF itself, write those numbers into the TOC, and print again until
 * the numbers the PDF shows are the numbers its own layout produced.
 *
 * Why this strategy: Chromium's print engine has no CSS
 * `target-counter()`, and a pagination polyfill (Paged.js) would mean running
 * a third-party script inside the user's browser profile on untrusted
 * markdown and re-implementing the layout Chromium already does. Instead the
 * oracle is the PDF: the TOC links make Chromium (Skia) write one named
 * destination per target heading — `/Dests << /toc-0 [<page ref> /XYZ …] >>`
 * in the catalog — and the page tree gives each page ref its 1-based number,
 * the same physical number the `counter(page)` footer prints.
 *
 * No script is injected and nothing is fetched, so the offline/sanitization
 * boundary is unchanged. Every failure is explicit (TocPaginationError →
 * exit 3): a PDF this parser cannot read, a TOC target with no destination,
 * or numbers that have not settled after MAX_PRINTS. A TOC with empty
 * page-number cells is never written.
 */

import * as fs from "node:fs";
import * as path from "node:path";

/** Prints needed is normally 2 (measure, then confirm); the third absorbs one reflow. */
export const MAX_PRINTS = 3;

export class TocPaginationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TocPaginationError";
  }
}

const TOC_SECTION = /<section class="toc">[\s\S]*?<\/section>/;
const TOC_PAGE_SPAN = /(<span class="toc-page" data-toc-target=")([^"]*)(">)[^<]*(<\/span>)/g;

function decodeAttr(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");
}

/**
 * The key a TOC target and its PDF destination share. Chromium names a
 * destination after the link's URL fragment, percent-encoded (`#café` →
 * `/caf#25C3#25A9`), so both sides compare percent-decoded.
 */
function destKey(id: string): string {
  try {
    return decodeURIComponent(id);
  } catch {
    return id;
  }
}

/** TOC target keys, in TOC order. Empty when the document has no TOC. */
export function tocTargets(html: string): string[] {
  const toc = html.match(TOC_SECTION)?.[0] ?? "";
  return [...toc.matchAll(TOC_PAGE_SPAN)].map((m) => destKey(decodeAttr(m[2])));
}

/** Write each target's page from `pages` (keyed by tocTargets keys; 0 when unknown) into its TOC cell. */
export function fillTocPages(html: string, pages: ReadonlyMap<string, number>): string {
  return html.replace(TOC_SECTION, (toc) =>
    toc.replace(TOC_PAGE_SPAN, (_m, open: string, target: string, close: string, end: string) =>
      `${open}${target}${close}${pages.get(destKey(decodeAttr(target))) ?? 0}${end}`));
}

// ─── PDF reading (classic xref, as Chromium/Skia writes it) ───────────────

/** PDF name token (after the slash) → string: `#xx` escapes are UTF-8 bytes. */
function decodePdfName(raw: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] === "#" && /^[0-9a-fA-F]{2}$/.test(raw.slice(i + 1, i + 3))) {
      bytes.push(parseInt(raw.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      bytes.push(raw.charCodeAt(i) & 0xff);
    }
  }
  return Buffer.from(bytes).toString("utf8");
}

/**
 * Named destination (as a tocTargets key) → 1-based page number, read from a PDF's catalog /Dests
 * dictionary and page tree. Throws TocPaginationError when the file is not a
 * PDF this reader understands (cross-reference streams, a /Dests name tree).
 */
export function pdfDestinationPages(pdf: Uint8Array): Map<string, number> {
  const fail = (why: string): never => {
    throw new TocPaginationError(`could not read TOC page numbers from the printed PDF: ${why}`);
  };
  const s = Buffer.from(pdf).toString("latin1");
  const startxref = s.match(/startxref\s+(\d+)\s+%%EOF\s*$/);
  if (!startxref) return fail("no startxref trailer");
  const xrefAt = Number(startxref[1]);
  if (!s.startsWith("xref", xrefAt)) return fail("cross-reference streams are not supported");

  const offsets = new Map<number, number>();
  const trailerAt = s.indexOf("trailer", xrefAt);
  if (trailerAt < 0) return fail("no trailer dictionary");
  const table = s.slice(xrefAt + 4, trailerAt).trim().split(/\r?\n|\r/);
  for (let i = 0; i < table.length;) {
    const [first, count] = table[i].trim().split(/\s+/).map(Number);
    for (let k = 0; k < count; k++) {
      const [off, , kind] = (table[i + 1 + k] ?? "").trim().split(/\s+/);
      if (kind === "n") offsets.set(first + k, Number(off));
    }
    i += 1 + count;
  }

  const object = (num: number): string => {
    const at = offsets.get(num);
    if (at === undefined) return fail(`object ${num} is not in the cross-reference table`);
    const end = s.indexOf("endobj", at);
    return s.slice(at, end < 0 ? undefined : end);
  };
  const ref = (body: string, key: string): number | null => {
    const m = body.match(new RegExp(`/${key}\\s+(\\d+)\\s+\\d+\\s+R`));
    return m ? Number(m[1]) : null;
  };

  const root = ref(s.slice(trailerAt), "Root") ?? fail("trailer has no /Root");
  const catalog = object(root);
  const pagesRoot = ref(catalog, "Pages") ?? fail("catalog has no /Pages");

  const pageNumber = new Map<number, number>();
  const walk = (num: number, depth: number): void => {
    if (depth > 32) fail("page tree is too deep");
    const node = object(num);
    const kids = node.match(/\/Kids\s*\[([^\]]*)\]/);
    if (/\/Type\s*\/Pages\b/.test(node) && kids) {
      for (const k of kids[1].matchAll(/(\d+)\s+\d+\s+R/g)) walk(Number(k[1]), depth + 1);
    } else {
      pageNumber.set(num, pageNumber.size + 1);
    }
  };
  walk(pagesRoot, 0);

  const pages = new Map<string, number>();
  const destsRef = ref(catalog, "Dests");
  if (destsRef === null) {
    if (/\/Names\s*<<[^>]*\/Dests/.test(catalog)) fail("named destinations in a /Names tree are not supported");
    return pages;
  }
  for (const m of object(destsRef).matchAll(/\/([^\s()<>[\]{}/%]+)\s*\[\s*(\d+)\s+\d+\s+R/g)) {
    const page = pageNumber.get(Number(m[2]));
    if (page !== undefined) pages.set(destKey(decodePdfName(m[1])), page);
  }
  return pages;
}

// ─── Print loop ───────────────────────────────────────────────────────────

/**
 * Print `html` to `output` with every TOC page cell holding the page its
 * heading prints on. `print(html, out)` prints one PDF (one browser render).
 * Returns print's result from the accepted pass.
 */
export async function printWithTocPages<R>(
  html: string,
  output: string,
  print: (html: string, out: string) => R | Promise<R>,
): Promise<R> {
  const targets = tocTargets(html);
  if (targets.length === 0) return print(html, output);

  const tmp = path.join(path.dirname(output), `.${path.basename(output)}.toc-pass.pdf`);
  let pages: ReadonlyMap<string, number> = new Map();
  try {
    for (let pass = 1; pass <= MAX_PRINTS; pass++) {
      const result = await print(fillTocPages(html, pages), tmp);
      const printed = pdfDestinationPages(fs.readFileSync(tmp));
      const missing = targets.filter((t) => !printed.has(t));
      if (missing.length > 0) {
        throw new TocPaginationError(
          `the printed PDF has no destination for TOC target(s) ${missing.map((t) => `#${t}`).join(", ")}; ` +
          `their links and page numbers would be wrong`);
      }
      if (targets.every((t) => pages.get(t) === printed.get(t))) {
        fs.renameSync(tmp, output);
        return result;
      }
      pages = printed;
    }
    throw new TocPaginationError(
      `TOC page numbers did not settle after ${MAX_PRINTS} prints (adding them reflowed the document); ` +
      `drop --toc or shorten the longest TOC entries`);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}
