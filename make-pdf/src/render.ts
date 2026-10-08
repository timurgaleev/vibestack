/**
 * Markdown → HTML renderer. Pure function, no I/O, no Playwright.
 *
 * Pipeline:
 *   1. marked parses markdown → HTML
 *   2. Sanitize: strip <script>, <iframe>, <object>, <embed>, <link>,
 *      <meta>, <base>, <form>, and all on* event handlers + javascript:
 *      URLs. (Codex round 2 #9: untrusted markdown can embed raw HTML.)
 *   3. Smartypants transform (code/URL-safe).
 *   4. Assemble full HTML document with print CSS inlined and
 *      semantic structure (cover, TOC placeholder, body).
 */

import { marked } from "marked";
import { smartypants } from "./smartypants";
import { printCss, type PrintCssOptions } from "./print-css";
import { applyImageDirectives } from "./image-policy";

export interface RenderOptions {
  markdown: string;

  // Document-level metadata (used for cover, PDF metadata, running header).
  title?: string;
  author?: string;
  date?: string;                  // ISO or human string
  subtitle?: string;

  // Features
  cover?: boolean;
  toc?: boolean;
  watermark?: string;
  noChapterBreaks?: boolean;
  confidential?: boolean;         // default: true

  // Page layout
  pageSize?: "letter" | "a4" | "legal" | "tabloid";
  margins?: string;
  // Per-side margins (override `margins`). Must reach the CSS @page rule:
  // when a landscape promotion flips preferCSSPageSize on, the CSS margins
  // are the ones Chromium honors — dropping per-side flags there would
  // silently change the whole document's layout (Codex P2).
  marginTop?: string;
  marginRight?: string;
  marginBottom?: string;
  marginLeft?: string;

  // Footer behavior. pageNumbers defaults to true. When footerTemplate is set,
  // CSS page numbers are suppressed so the custom Chromium footer wins cleanly.
  pageNumbers?: boolean;
  footerTemplate?: string;
}

export interface RenderResult {
  html: string;                   // full HTML document, ready for $B load-html
  printCss: string;               // for debugging / preview
  bodyHtml: string;               // just the rendered body (tests, snapshots)
  meta: {
    title: string;
    author: string;
    date: string;
    wordCount: number;
  };
}

/**
 * Pure renderer. No side effects.
 */
export function render(opts: RenderOptions): RenderResult {
  // 1. Markdown → HTML
  const rawHtml = marked.parse(opts.markdown, { async: false }) as string;

  // 1.5. Image directive suffixes: `![a](x.png){width=50%}` → data-vibestack-*
  // attributes. Before the sanitizer (which keeps data- attrs) so the brace
  // text never reaches smartypants or the final page.
  const directedHtml = applyImageDirectives(rawHtml);

  // 2. Sanitize
  const cleanHtml = sanitizeUntrustedHtml(directedHtml);

  // 3. Decode common entities so smartypants can match raw " and '.
  //    marked HTML-encodes quotes in text ("hello" → &quot;hello&quot;);
  //    without decoding, smartypants' regex never fires. These get re-encoded
  //    implicitly by the browser's HTML parser downstream, and for the ones
  //    that should stay as curly-quote Unicode, that IS the final form.
  const decoded = decodeTypographicEntities(cleanHtml);

  // 4. Smartypants (code-safe)
  const typographicHtml = smartypants(decoded);

  // 4. Derive metadata (title from first H1 if not provided)
  const derivedTitle = opts.title ?? extractFirstHeading(typographicHtml) ?? "Document";
  const derivedAuthor = opts.author ?? "";
  const derivedDate = opts.date ?? formatToday();

  // 5. Build CSS
  // CSS is the single source of truth for page numbers (Chromium native
  // numbering is always off in orchestrator). If the caller supplied a custom
  // footerTemplate, suppress CSS page numbers too so their footer wins.
  const showPageNumbers = opts.pageNumbers !== false && !opts.footerTemplate;
  const cssOptions: PrintCssOptions = {
    cover: opts.cover,
    toc: opts.toc,
    noChapterBreaks: opts.noChapterBreaks,
    watermark: opts.watermark,
    confidential: opts.confidential !== false,
    runningHeader: derivedTitle,
    pageSize: opts.pageSize,
    // Compose per-side margins into the CSS shorthand so @page stays the
    // single source of truth even under preferCSSPageSize.
    margins: composeMargins(opts),
    pageNumbers: showPageNumbers,
  };
  const css = printCss(cssOptions);

  // 6. Assemble document
  const coverBlock = opts.cover
    ? buildCoverBlock({
        title: derivedTitle,
        subtitle: opts.subtitle,
        author: derivedAuthor,
        date: derivedDate,
      })
    : "";

  // TOC labels and link targets come from one heading inventory, so an empty
  // heading or a duplicate id cannot shift the links after it.
  const anchored = opts.toc ? anchorHeadings(typographicHtml) : { html: typographicHtml, entries: [] };
  const anchoredHtml = anchored.html;

  const tocBlock = opts.toc ? buildTocBlock(anchored.entries) : "";

  // Wrap body in .chapter sections at H1 boundaries if chapter breaks are on.
  const chapterHtml = opts.noChapterBreaks
    ? `<section class="chapter">${anchoredHtml}</section>`
    : wrapChaptersByH1(anchoredHtml);

  const watermarkBlock = opts.watermark
    ? `<div class="watermark">${escapeHtml(opts.watermark)}</div>`
    : "";

  const fullHtml = [
    `<!doctype html>`,
    `<html lang="en">`,
    `<head>`,
    `<meta charset="utf-8">`,
    `<title>${escapeHtml(derivedTitle)}</title>`,
    derivedAuthor ? `<meta name="author" content="${escapeHtml(derivedAuthor)}">` : ``,
    `<style>`,
    css,
    `</style>`,
    `</head>`,
    `<body>`,
    watermarkBlock,
    coverBlock,
    tocBlock,
    chapterHtml,
    `</body>`,
    `</html>`,
  ].filter(Boolean).join("\n");

  return {
    html: fullHtml,
    printCss: css,
    bodyHtml: typographicHtml,
    meta: {
      title: derivedTitle,
      author: derivedAuthor,
      date: derivedDate,
      wordCount: countWords(stripTags(typographicHtml)),
    },
  };
}

/**
 * Decode the HTML entities that marked emits for text-node quotes/apostrophes.
 * Only the four that matter for smartypants — leaves &amp; alone because it
 * can be legitimately doubled (&amp;amp;) and we don't want to double-decode.
 */
function decodeTypographicEntities(html: string): string {
  return html
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#x27;/g, "'");
}

// ─── Sanitizer ────────────────────────────────────────────────────────

/**
 * Strip dangerous HTML from markdown-produced output.
 *
 * We can't use DOMPurify (server-side; adds a jsdom dep). A conservative
 * regex sanitizer is fine for this use case because:
 *   1. marked produces structured HTML (never malformed)
 *   2. we only need to strip a fixed blacklist of elements + attrs
 *   3. the output goes through Chromium's parser again, which normalizes
 *
 * What's stripped:
 *   - <script>, <iframe>, <object>, <embed>, <link>, <meta>, <base>, <form>
 *     (and their content).
 *   - on* event handler attributes (onclick, ONCLICK, etc.).
 *   - href/src with javascript: scheme.
 *   - <svg> tags with <script> inside them.
 */
export function sanitizeUntrustedHtml(html: string): string {
  let s = html;

  // Elements to remove entirely (including content).
  const DANGER_TAGS = [
    "script", "iframe", "object", "embed", "link", "meta", "base", "form",
    "applet", "frame", "frameset",
  ];
  for (const tag of DANGER_TAGS) {
    const re = new RegExp(`<${tag}\\b[\\s\\S]*?</${tag}>`, "gi");
    s = s.replace(re, "");
    // Self-closing / unclosed variants
    const selfRe = new RegExp(`<${tag}\\b[^>]*/?>`, "gi");
    s = s.replace(selfRe, "");
  }

  // SVG <script>
  s = s.replace(/<svg([^>]*)>([\s\S]*?)<\/svg>/gi, (_, attrs, body) => {
    return `<svg${attrs}>${body.replace(/<script\b[\s\S]*?<\/script>/gi, "")}</svg>`;
  });

  // Event handler attributes (on* in any case).
  s = s.replace(/\s+on[a-zA-Z]+\s*=\s*"[^"]*"/gi, "");
  s = s.replace(/\s+on[a-zA-Z]+\s*=\s*'[^']*'/gi, "");
  s = s.replace(/\s+on[a-zA-Z]+\s*=\s*[^\s>]+/gi, "");

  // javascript: URLs in href/src/action/formaction
  s = s.replace(
    /(\s(?:href|src|action|formaction|xlink:href)\s*=\s*)(?:"javascript:[^"]*"|'javascript:[^']*'|javascript:[^\s>]+)/gi,
    '$1"#"',
  );

  // srcdoc attribute (iframe escape hatch — already stripped via iframe above,
  // but defense-in-depth).
  s = s.replace(/\s+srcdoc\s*=\s*"[^"]*"/gi, "");
  s = s.replace(/\s+srcdoc\s*=\s*'[^']*'/gi, "");

  // style="url(javascript:..)" — strip javascript: inside style attrs.
  s = s.replace(/url\(\s*javascript:[^)]*\)/gi, "url(#)");

  return s;
}

// ─── Cover / TOC / Chapter helpers ────────────────────────────────────

function buildCoverBlock(opts: {
  title: string;
  subtitle?: string;
  author?: string;
  date: string;
}): string {
  const title = escapeHtml(opts.title);
  const subtitle = opts.subtitle ? escapeHtml(opts.subtitle) : "";
  const author = opts.author ? escapeHtml(opts.author) : "";
  const date = escapeHtml(opts.date);
  return [
    `<section class="cover">`,
    `  <h1 class="cover-title">${title}</h1>`,
    subtitle ? `  <p class="cover-subtitle">${subtitle}</p>` : ``,
    `  <hr class="rule">`,
    `  <div class="cover-meta">`,
    author ? `    <div><strong>${author}</strong></div>` : ``,
    `    <div>${date}</div>`,
    `  </div>`,
    `</section>`,
  ].filter(Boolean).join("\n");
}

export interface TocEntry {
  level: number;
  text: string;
  /** The id the heading carries in the output (decoded text, not attribute-escaped). */
  id: string;
}

/**
 * Emit the TOC. Each entry links to its heading's id; the empty `.toc-page`
 * span is filled with the printed page number by toc-pages.ts once the PDF
 * has been laid out (PDF output only).
 */
function buildTocBlock(entries: TocEntry[]): string {
  if (entries.length === 0) return "";

  const items = entries.map((h) => {
    const level = h.level >= 2 ? "level-2" : "level-1";
    const id = escapeHtml(h.id);
    return [
      `  <li class="${level}">`,
      `    <span class="toc-title"><a href="#${id}">${escapeHtml(h.text)}</a></span>`,
      `    <span class="toc-dots"></span>`,
      `    <span class="toc-page" data-toc-target="${id}"></span>`,
      `  </li>`,
    ].join("\n");
  }).join("\n");

  return [
    `<section class="toc">`,
    `  <h2>Contents</h2>`,
    `  <ol>`,
    items,
    `  </ol>`,
    `</section>`,
  ].join("\n");
}

const ID_ATTR = /(\sid\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i;

/**
 * The single heading inventory behind the TOC. Every H1-H3 with visible text
 * becomes one entry, in document order, and the entry's id is the id that
 * heading owns in the output:
 *   - a heading whose own id is the FIRST element with that id keeps it;
 *   - a heading with no id, or with an id an earlier element already owns
 *     (fragment links resolve to the first owner), gets a fresh `toc-N` that
 *     no element in the document uses.
 * Headings without text get no entry and no id, so they cannot shift the
 * entries after them.
 */
export function anchorHeadings(html: string): { html: string; entries: TocEntry[] } {
  const firstOwner = new Map<string, number>();
  for (const m of html.matchAll(/<[a-zA-Z][^>]*>/g)) {
    const id = attrId(m[0]);
    if (id !== null && !firstOwner.has(id)) firstOwner.set(id, m.index!);
  }
  let next = 0;
  const freshId = (): string => {
    while (firstOwner.has(`toc-${next}`)) next++;
    const id = `toc-${next++}`;
    firstOwner.set(id, -1);
    return id;
  };

  const entries: TocEntry[] = [];
  const out = html.replace(
    /<(h[1-3])\b([^>]*)>([\s\S]*?)<\/\1>/gi,
    (full, tag: string, attrs: string, inner: string, offset: number) => {
      const text = decodeTextEntities(stripTags(inner).trim());
      if (!text) return full;
      const level = parseInt(tag.slice(1), 10);
      const existing = attrId(`<${tag}${attrs}>`);
      if (existing !== null && firstOwner.get(existing) === offset) {
        entries.push({ level, text, id: existing });
        return full;
      }
      const id = freshId();
      entries.push({ level, text, id });
      const newAttrs = ID_ATTR.test(attrs)
        ? attrs.replace(ID_ATTR, (_m, pre: string) => `${pre}"${id}"`)
        : `${attrs} id="${id}"`;
      return `<${tag}${newAttrs}>${inner}</${tag}>`;
    },
  );
  return { html: out, entries };
}

/** The decoded value of a tag's `id` attribute (not `data-id`), or null when absent or empty. */
function attrId(tag: string): string | null {
  const m = tag.match(ID_ATTR);
  const id = m ? decodeTextEntities(m[2] ?? m[3] ?? m[4] ?? "") : "";
  return id || null;
}

/**
 * Wrap H1-rooted sections in <section class="chapter">. When chapter breaks
 * are on (default), CSS `.chapter { break-before: page }` fires between them.
 */
function wrapChaptersByH1(html: string): string {
  // Split on H1 openings. Everything before the first H1 is a preamble.
  const h1Re = /<h1\b[^>]*>/gi;
  const matches: number[] = [];
  let m;
  while ((m = h1Re.exec(html)) !== null) {
    matches.push(m.index);
  }
  if (matches.length === 0) {
    return `<section class="chapter">${html}</section>`;
  }
  const chunks: string[] = [];
  const preamble = html.slice(0, matches[0]);
  if (preamble.trim().length > 0) {
    chunks.push(`<section class="chapter">${preamble}</section>`);
  }
  for (let i = 0; i < matches.length; i++) {
    const start = matches[i];
    const end = i + 1 < matches.length ? matches[i + 1] : html.length;
    chunks.push(`<section class="chapter">${html.slice(start, end)}</section>`);
  }
  return chunks.join("\n");
}

function extractFirstHeading(html: string): string | null {
  const m = html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  return m ? decodeTextEntities(stripTags(m[1]).trim()) : null;
}

/**
 * Decode HTML entities in plain text extracted from rendered HTML. Distinct
 * from decodeTypographicEntities (which runs on in-pipeline HTML and preserves
 * &amp; because &amp;amp; can be legitimate there). This runs on text destined
 * for <title>, cover, and TOC entries where &amp; MUST become & or escapeHtml
 * produces &amp;amp;.
 *
 * Amp-last ordering: input "&amp;#169;" decodes to "&#169;" in the named pass,
 * then the numeric pass decodes "&#169;" to "©". Decoding &amp; first would
 * produce "&#169;" and the numeric pass would consume it — different end state
 * but risks double-decode on inputs like "&amp;lt;".
 */
function decodeTextEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(parseInt(n, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&amp;/g, "&");
}

/** Compose `margin: top right bottom left` from per-side overrides + base. */
function composeMargins(opts: {
  margins?: string; marginTop?: string; marginRight?: string;
  marginBottom?: string; marginLeft?: string;
}): string | undefined {
  const base = opts.margins ?? "1in";
  if (!opts.marginTop && !opts.marginRight && !opts.marginBottom && !opts.marginLeft) {
    return opts.margins;
  }
  return [
    opts.marginTop ?? base,
    opts.marginRight ?? base,
    opts.marginBottom ?? base,
    opts.marginLeft ?? base,
  ].join(" ");
}

function stripTags(html: string): string {
  return html.replace(/<[^>]+>/g, "");
}

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function countWords(text: string): number {
  return text.split(/\s+/).filter(w => w.length > 0).length;
}

function formatToday(): string {
  const now = new Date();
  return now.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
}
