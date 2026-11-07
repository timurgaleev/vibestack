/**
 * Offline posture for untrusted HTML. Without --allow-network the rendered
 * document must not make Chromium (or the DOCX converter) reach a remote
 * host, so every remote reference that would be fetched while laying out the
 * page is neutralised here:
 *
 *   - <style> blocks and style="" attributes: remote @import rules are
 *     removed; remote url() and image-set() strings become `#`.
 *   - srcset / imagesrcset with a remote candidate are dropped.
 *   - src, poster, background, data, SVG href/xlink:href, SMIL to/from/values
 *     and friends become `#` when remote; url() inside any other attribute
 *     (SVG fill, filter, mask, ...) is neutralised like CSS.
 *
 * Hyperlinks (<a>/<area> href) are not fetches and stay. Remote <img src>
 * stays too, normalised to a double-quoted literal, so the image pass can
 * swap it for the visible "remote image blocked" placeholder.
 *
 * Values are inspected the way the browser will read them: HTML entities and
 * CSS escapes decoded, tabs/newlines stripped, comments removed. A named
 * entity this decoder does not know is treated as remote (fail closed).
 */

export function neutralizeRemoteRefs(html: string): string {
  // The end tag is matched the way the tokenizer matches it (`</style x>` and
  // `</style/>` both close the element), and a style left open runs to the end:
  // the page template appended after it is still style text to the browser.
  const styled = html.replace(
    /(<style\b[^>]*>)([\s\S]*?)(<\/style(?=[\s\/>])[^>]*>|$)/gi,
    (_m, open: string, css: string, close: string) => open + neutralizeCss(css, decodeSafeEntities) + close,
  );
  return rewriteTags(styled);
}

// ─── URL classification ───────────────────────────────────────────────

/** True when the URL, as the browser parses it, points at another host. */
export function isRemoteUrl(value: string): boolean {
  // The URL parser drops tab/LF/CR anywhere and C0/space at the edges.
  const s = value.replace(/[\t\n\r]/g, "").replace(/^[\u0000-\u0020]+/, "");
  if (/^file:/i.test(s)) {
    const host = s.match(/^file:[\\/]{2}([^\\/]*)/i)?.[1];
    return host !== undefined && host !== "" && host.toLowerCase() !== "localhost";
  }
  // Special schemes need no slashes (`https:evil.test` is a remote URL), and
  // a backslash counts as a slash.
  return /^(?:[a-z][a-z0-9+.-]*:)?[\\/]{2}/i.test(s) || /^(?:https?|ftp|wss?):/i.test(s);
}

/** A named entity left after decoding is one this module cannot vouch for. */
function hasUnknownEntity(s: string): boolean {
  return /&[a-zA-Z][a-zA-Z0-9]*;/.test(s);
}

function isSuspectUrl(value: string): boolean {
  return isRemoteUrl(value) || hasUnknownEntity(value);
}

// ─── CSS ──────────────────────────────────────────────────────────────

/**
 * Neutralise remote references in CSS text. Returns the input unchanged when
 * nothing remote was found, so ordinary stylesheets keep their exact bytes.
 */
function neutralizeCss(css: string, decodeEntities: (s: string) => string): string {
  const decoded = decodeCssEscapes(decodeEntities(css)).replace(/\/\*[\s\S]*?\*\//g, "");
  let changed = false;

  let out = decoded.replace(/@import\b[^;]*;?/gi, (rule) => {
    const target = rule.match(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)|"([^"]*)"|'([^']*)'/i);
    const url = target ? (target[1] ?? target[2] ?? target[3] ?? target[4] ?? target[5] ?? "") : "";
    if (!target || isSuspectUrl(url)) {
      changed = true;
      return "";
    }
    return rule;
  });

  out = out.replace(/\burl\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/gi, (full, dq, sq, bare) => {
    if (!isSuspectUrl(dq ?? sq ?? bare ?? "")) return full;
    changed = true;
    return "url(#)";
  });

  // Bare strings are fetched by image-set(); a remote one anywhere is cut.
  out = out.replace(/"([^"\\\n]*(?:\\.[^"\\\n]*)*)"|'([^'\\\n]*(?:\\.[^'\\\n]*)*)'/g, (full, dq, sq) => {
    if (!isSuspectUrl(dq ?? sq ?? "")) return full;
    changed = true;
    return `"#"`;
  });

  return changed ? out : css;
}

/**
 * Decode CSS escapes that can spell a URL or a function name (`\68 ttps`,
 * `\75 rl(`). Escapes producing a quote, backslash, bracket, angle bracket or
 * control character stay escaped so the decoded text keeps its structure.
 */
function decodeCssEscapes(css: string): string {
  // A backslash before a newline continues a CSS string onto the next line.
  return css.replace(/\\(?:\r\n|[\n\r\f])/g, "").replace(/\\(?:([0-9a-fA-F]{1,6})[ \t\n\r\f]?|([^\n0-9a-fA-F]))/g, (full, hex, ch) => {
    const c = hex ? safeCodePoint(parseInt(hex, 16)) : ch;
    return /^[\u0000-\u001f"'\\()<>&;{}\u007f]$/.test(c) ? full : c;
  });
}

// ─── Entities ─────────────────────────────────────────────────────────

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0",
  Tab: "\t", NewLine: "\n", colon: ":", sol: "/", bsol: "\\", period: ".",
  lpar: "(", rpar: ")", comma: ",", semi: ";", equals: "=", num: "#",
  excl: "!", quest: "?", lsqb: "[", rsqb: "]", lbrack: "[", rbrack: "]",
  lcub: "{", rcub: "}", lbrace: "{", rbrace: "}", ast: "*", midast: "*",
  plus: "+", hyphen: "-", dash: "-", lowbar: "_", UnderBar: "_", Hat: "^",
  grave: "`", percnt: "%", dollar: "$", commat: "@", verbar: "|", vert: "|",
};

/** Decode entities the way an attribute value is decoded. */
function decodeAttrEntities(s: string): string {
  return s.replace(/&(?:#[xX]([0-9a-fA-F]+);?|#([0-9]+);?|([a-zA-Z][a-zA-Z0-9]*);)/g, (full, hex, dec, name) => {
    if (hex) return safeCodePoint(parseInt(hex, 16));
    if (dec) return safeCodePoint(parseInt(dec, 10));
    return NAMED_ENTITIES[name] ?? full;
  });
}

/**
 * Entity decoding for <style> text (SVG style elements decode entities). The
 * result is written back into a raw-text element, so markup characters stay
 * encoded and cannot close the element.
 */
function decodeSafeEntities(s: string): string {
  return s.replace(/&(?:#[xX]([0-9a-fA-F]+);?|#([0-9]+);?|([a-zA-Z][a-zA-Z0-9]*);)/g, (full, hex, dec, name) => {
    const c = hex ? safeCodePoint(parseInt(hex, 16)) : dec ? safeCodePoint(parseInt(dec, 10)) : NAMED_ENTITIES[name];
    return c === undefined || /^[<>&]$/.test(c) ? full : c;
  });
}

function safeCodePoint(n: number): string {
  return n > 0 && n <= 0x10ffff && !(n >= 0xd800 && n <= 0xdfff) ? String.fromCodePoint(n) : "\ufffd";
}

// ─── Tags ─────────────────────────────────────────────────────────────

interface Attr { name: string; value: string | null }

interface ParsedTag { name: string; rawName: string; attrs: Attr[]; end: number; selfClosing: boolean }

// Attributes whose value the browser fetches (HTML media/legacy, SVG links
// and SMIL animation values, XML base).
const FETCH_ATTRS = new Set([
  "src", "href", "xlink:href", "poster", "background", "data", "lowsrc",
  "dynsrc", "codebase", "xml:base", "to", "from", "by", "values", "manifest",
  "action", "formaction", "ping",
]);

function rewriteTags(html: string): string {
  let out = "";
  let i = 0;
  while (i < html.length) {
    const lt = html.indexOf("<", i);
    if (lt === -1) break;
    if (!/[a-zA-Z]/.test(html[lt + 1] ?? "")) {
      out += html.slice(i, lt + 1);
      i = lt + 1;
      continue;
    }
    const tag = parseTag(html, lt);
    // A start tag still open at the end is dropped: the page template appended
    // after this fragment would otherwise finish it, attributes unchecked.
    if (!tag) return out + html.slice(i, lt);
    out += html.slice(i, lt) + rewriteTag(html.slice(lt, tag.end), tag);
    i = tag.end;
  }
  return out + html.slice(i);
}

/**
 * Tokenise one start tag the way the HTML tokenizer does: `/` separates
 * attributes, quotes only matter right after `=`, an unquoted value runs to
 * whitespace or `>`. Returns null for a tag cut off by end of input.
 */
function parseTag(html: string, start: number): ParsedTag | null {
  let i = start + 1;
  const nameStart = i;
  while (i < html.length && !/[\s\/>]/.test(html[i])) i++;
  const rawName = html.slice(nameStart, i);
  const attrs: Attr[] = [];
  let selfClosing = false;
  for (;;) {
    while (i < html.length && /[\s\/]/.test(html[i])) {
      selfClosing = html[i] === "/";
      i++;
    }
    if (i >= html.length) return null;
    if (html[i] === ">") return { name: rawName.toLowerCase(), rawName, attrs, end: i + 1, selfClosing };
    selfClosing = false;
    const an = i;
    i++; // a leading `=` belongs to the name
    while (i < html.length && !/[\s\/>=]/.test(html[i])) i++;
    const attrName = html.slice(an, i);
    let j = i;
    while (j < html.length && /\s/.test(html[j])) j++;
    if (html[j] !== "=") {
      attrs.push({ name: attrName, value: null });
      continue;
    }
    j++;
    while (j < html.length && /\s/.test(html[j])) j++;
    const q = html[j];
    if (q === '"' || q === "'") {
      const close = html.indexOf(q, j + 1);
      if (close === -1) return null;
      attrs.push({ name: attrName, value: html.slice(j + 1, close) });
      i = close + 1;
    } else {
      let k = j;
      while (k < html.length && !/[\s>]/.test(html[k])) k++;
      attrs.push({ name: attrName, value: html.slice(j, k) });
      i = k;
    }
  }
}

function rewriteTag(raw: string, tag: ParsedTag): string {
  let changed = false;
  const kept: Attr[] = [];
  for (const attr of tag.attrs) {
    const next = rewriteAttr(tag.name, attr);
    if (next !== attr) changed = true;
    // Rebuilt attributes are re-escaped below, so untouched ones go back to
    // their decoded value first.
    if (next === attr && attr.value !== null) kept.push({ name: attr.name, value: decodeAttrEntities(attr.value) });
    else if (next) kept.push(next);
  }
  if (!changed) return raw;
  const attrs = kept
    .map((a) => (a.value === null ? ` ${a.name}` : ` ${a.name}="${escapeAttr(a.value)}"`))
    .join("");
  return `<${tag.rawName}${attrs}${tag.selfClosing ? " /" : ""}>`;
}

/** Returns the attribute itself when untouched, a replacement, or null to drop it. */
function rewriteAttr(tagName: string, attr: Attr): Attr | null {
  if (attr.value === null) return attr;
  const name = attr.name.toLowerCase();
  const value = decodeAttrEntities(attr.value);

  if (name === "xmlns" || name.startsWith("xmlns:")) return attr;

  if (name === "style") {
    const css = neutralizeCss(value, (s) => s);
    return css === value ? attr : { name: attr.name, value: css };
  }

  if (name === "srcset" || name === "imagesrcset") {
    return value.split(/[\s,]+/).some((tok) => tok && isSuspectUrl(tok)) ? null : attr;
  }

  if ((name === "href" || name === "xlink:href") && (tagName === "a" || tagName === "area")) return attr;

  if (name === "src" && tagName === "img") {
    if (!isRemoteUrl(value)) return attr;
    // Hand the image pass a plain double-quoted URL it recognises as remote.
    const clean = value.replace(/[\t\n\r]/g, "").replace(/^[\u0000-\u0020]+|[\u0000-\u0020]+$/g, "");
    return { name: attr.name, value: clean };
  }

  if (FETCH_ATTRS.has(name)) {
    return value.split(";").some((part) => isSuspectUrl(part)) ? { name: attr.name, value: "#" } : attr;
  }

  if (/url\(/i.test(value) || /\\/.test(value)) {
    const css = neutralizeCss(value, (s) => s);
    return css === value ? attr : { name: attr.name, value: css };
  }
  return attr;
}

// `"` is written as a numeric reference: the renderer later decodes &quot;
// back into a bare quote for smartypants, which would end the attribute.
function escapeAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&#34;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
