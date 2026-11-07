/**
 * Offline posture for untrusted HTML. Without --allow-network the rendered
 * document must not make Chromium (or the DOCX converter) reach a remote
 * host, so every remote reference that would be fetched while laying out the
 * page is neutralised here:
 *
 *   - <style> blocks and style="" attributes: remote @import rules are
 *     removed; remote url() and image-set() strings become `#`. A <style>
 *     inside <svg> is also read as foreign content (see neutralizeStyleText).
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
 *
 * This string pass is the second layer. The first is the content policy every
 * page make-pdf loads carries (offlinePolicyMeta): Chromium itself refuses any
 * fetch that is not data:, blob: or file:, including requests a data:
 * stylesheet makes. The policy cannot stop a navigation (a meta refresh),
 * which is why the sanitizer still runs, and why every page also goes into its
 * browse tab with `load-html --offline`: the tab itself refuses any request,
 * navigation included, that is not file:, data:, blob: or about:.
 */

const LOCAL_SOURCES = "data: blob: file:";

/** No-network policy for the print page, which runs no script of its own. */
export const OFFLINE_PAGE_POLICY =
  `default-src 'none'; img-src ${LOCAL_SOURCES}; style-src 'unsafe-inline' ${LOCAL_SOURCES}; ` +
  `font-src ${LOCAL_SOURCES}; media-src ${LOCAL_SOURCES}`;

/** The same for a page whose own inline scripts must run (the render tab). */
export const OFFLINE_SCRIPT_PAGE_POLICY =
  `${OFFLINE_PAGE_POLICY}; script-src 'unsafe-inline' 'unsafe-eval' ${LOCAL_SOURCES}; ` +
  `worker-src ${LOCAL_SOURCES}; connect-src ${LOCAL_SOURCES}`;

export function offlinePolicyMeta(policy: string): string {
  return `<meta http-equiv="Content-Security-Policy" content="${policy}">`;
}

/** Put the policy first in <head>, ahead of anything that could fetch. */
export function withOfflinePolicy(html: string, policy: string): string {
  const head = html.match(/<head\b[^>]*>/i);
  if (!head || head.index === undefined) return offlinePolicyMeta(policy) + html;
  const at = head.index + head[0].length;
  return html.slice(0, at) + offlinePolicyMeta(policy) + html.slice(at);
}

export function neutralizeRemoteRefs(html: string): string {
  // The end tag is matched the way the tokenizer matches it (`</style x>` and
  // `</style/>` both close the element), and a style left open runs to the end:
  // the page template appended after it is still style text to the browser.
  // Inside <svg> a CDATA section or a comment is not raw text, so a
  // `</style>` inside one does not end the element; the match runs past it.
  // Raw text would end there instead, and which reading applies depends on
  // context, so when such a block holds anything remote, everything between
  // the tags is dropped.
  const styled = html.replace(
    /(<style\b[^>]*>)((?:<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|<!--[\s\S]*?(?:--!?>|$)|[\s\S])*?)(<\/style(?=[\s\/>])[^>]*>|$)/gi,
    (whole: string, open: string, css: string, close: string) => {
      const text = neutralizeStyleText(css);
      if (text === css) return whole;
      return /<\/style(?=[\s\/>])/i.test(css) ? open + close : open + text + close;
    },
  );
  return rewriteTags(styled);
}

/**
 * A <style> is raw text in HTML but foreign content inside <svg>: there a
 * comment drops out, a CDATA section unwraps, and only the element's own text
 * children are its stylesheet, so a URL can be assembled from pieces the
 * raw-text reading never sees whole. The text is neutralised as raw text
 * first; while it still holds markup, each foreign reading of the result is
 * checked as well, and a block that reaches a remote host under any of them
 * is emptied (fail closed).
 */
function neutralizeStyleText(css: string): string {
  const out = neutralizeCss(css, decodeSafeEntities);
  if (!/<[!\/?a-zA-Z]/.test(out)) return out;
  return foreignReadings(out).some((text) => neutralizeCss(text, decodeSafeEntities) !== text) ? "" : out;
}

/**
 * The style text as an SVG <style> could see it: comments dropped, CDATA
 * sections unwrapped, tags removed (attribute quotes respected). A child
 * element either keeps its text (a tag that breaks out of SVG) or loses it
 * (only direct text children count), so both readings are returned. One
 * linear scan; anything left unterminated ends the text.
 */
function foreignReadings(css: string): string[] {
  let all = "";
  let direct = "";
  let depth = 0;
  const text = (t: string) => {
    all += t;
    if (depth === 0) direct += t;
  };
  let i = 0;
  while (i < css.length) {
    const lt = css.indexOf("<", i);
    if (lt === -1) {
      text(css.slice(i));
      break;
    }
    text(css.slice(i, lt));
    const next = css[lt + 1] ?? "";
    if (css.startsWith("<!--", lt)) {
      const e = css.indexOf("-->", lt + 4);
      if (e === -1) break;
      i = e + 3;
    } else if (css.startsWith("<![CDATA[", lt)) {
      const e = css.indexOf("]]>", lt + 9);
      text(css.slice(lt + 9, e === -1 ? css.length : e));
      if (e === -1) break;
      i = e + 3;
    } else if (/[a-zA-Z]/.test(next)) {
      const tag = parseTag(css, lt);
      if (!tag) break;
      if (!tag.selfClosing) depth++;
      i = tag.end;
    } else if (next === "/" && /[a-zA-Z]/.test(css[lt + 2] ?? "")) {
      const tag = parseTag(css, lt + 1);
      if (!tag) break;
      depth = Math.max(0, depth - 1);
      i = tag.end;
    } else if (next === "!" || next === "?" || next === "/") {
      const e = css.indexOf(">", lt + 1);
      if (e === -1) break;
      i = e + 1;
    } else {
      text("<");
      i = lt + 1;
    }
  }
  return [all, direct];
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

  // Bounded so an unterminated @import costs constant work per occurrence; a
  // rule cut short loses its target and is dropped.
  let out = decoded.replace(/@import\b[^;]{0,4096};?/gi, (rule) => {
    const target = rule.match(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^()]*?))\s*\)|"([^"]*)"|'([^']*)'/i);
    const url = target ? (target[1] ?? target[2] ?? target[3] ?? target[4] ?? target[5] ?? "") : "";
    // A data: stylesheet can @import a remote one of its own.
    if (!target || isSuspectUrl(url) || /^\s*data:/i.test(url)) {
      changed = true;
      return "";
    }
    return rule;
  });

  // An unquoted url() cannot hold `(`, and stopping there keeps a run of
  // unclosed `url(` linear.
  out = out.replace(/\burl\(\s*(?:"([^"]*)"|'([^']*)'|([^()]*?))\s*\)/gi, (full, dq, sq, bare) => {
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
    // SMIL to/values can animate a presentation attribute to a remote url().
    const remote = value.split(";").some((part) => isSuspectUrl(part)) ||
      (/url\(/i.test(value) && neutralizeCss(value, (s) => s) !== value);
    return remote ? { name: attr.name, value: "#" } : attr;
  }

  if (/url\(/i.test(value) || /\\/.test(value)) {
    const css = neutralizeCss(value, (s) => s);
    return css === value ? attr : { name: attr.name, value: css };
  }
  return attr;
}

// `"` is written as a numeric reference, which no later pass in the renderer
// decodes back into a quote.
function escapeAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&#34;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
