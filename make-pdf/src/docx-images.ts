/**
 * Image guard for the DOCX export. html-to-docx sizes every embedded image by
 * sniffing its bytes, and its ICNS reader never advances past an icon entry
 * that declares length zero — the conversion spins forever. ICNS has no place
 * in a Word document anyway, so any data-URI image whose payload starts with
 * the `icns` magic is replaced by a visible note before conversion.
 *
 * The converter entity-decodes and percent-decodes the src before reading the
 * base64, so the check does the same. After the drop every start tag is
 * scanned again, the src attribute of any element included; one that slipped
 * through fails the export instead of hanging it. Only real src attributes
 * count: text or another attribute's value that merely reads `src=` is not an
 * image source.
 */

import http from "node:http";
import https from "node:https";

const IMG_TAG_RE = /<img\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi;
// An unquoted `<` ends the candidate, so a run of unterminated tags stays linear.
const START_TAG_RE = /<[a-zA-Z][^\s\/>]*(?:"[^"]*"|'[^']*'|[^'"<>])*>/g;
const ATTR_RE = /([^\s"'>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]*)))?/g;

/** The src values of one start tag, read attribute by attribute. */
function srcValues(tag: string): string[] {
  const attrs = tag.slice(1, -1).replace(/^[^\s\/>]+/, "");
  const out: string[] = [];
  for (const m of attrs.matchAll(ATTR_RE)) {
    if (m[1].toLowerCase() === "src") out.push(m[2] ?? m[3] ?? m[4] ?? "");
  }
  return out;
}

export function dropIcnsImages(html: string, warn: (msg: string) => void): string {
  let dropped = 0;
  const out = html.replace(IMG_TAG_RE, (tag) => {
    if (!srcValues(tag).some(isIcnsDataUri)) return tag;
    dropped++;
    return `<span class="image-missing">[image omitted: ICNS icons are not supported in DOCX]</span>`;
  });
  if (dropped > 0) warn(`docx: dropped ${dropped} ICNS image${dropped > 1 ? "s" : ""} (unsupported in Word)`);

  for (const m of out.matchAll(START_TAG_RE)) {
    if (srcValues(m[0]).some(isIcnsDataUri)) {
      throw new Error("docx: an ICNS image survived the image guard; refusing to convert");
    }
  }
  return out;
}

export function isIcnsDataUri(src: string): boolean {
  let s = decodeEntities(src).trim();
  try {
    s = decodeURIComponent(s);
  } catch { /* the converter would choke on it too; inspect as-is */ }
  const m = s.match(/^data:[^,]*;base64,([\s\S]*)$/i);
  if (!m) return false;
  const head = Buffer.from(m[1].replace(/\s+/g, "").slice(0, 16), "base64");
  return head.toString("latin1", 0, 4) === "icns";
}

function decodeEntities(s: string): string {
  return s
    .replace(/&#[xX]([0-9a-fA-F]+);?/g, (_m, h) => String.fromCodePoint(Math.min(parseInt(h, 16), 0x10ffff)))
    .replace(/&#([0-9]+);?/g, (_m, d) => String.fromCodePoint(Math.min(parseInt(d, 10), 0x10ffff)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

/**
 * html-to-docx conversion. The converter downloads every http(s) <img> it is
 * handed, so without --allow-network the process's request entry points
 * refuse to open a connection while it runs, whatever markup reached it.
 */
export async function convertHtmlToDocx(
  html: string,
  meta: { title?: string; creator?: string },
  opts: { allowNetwork: boolean },
): Promise<Uint8Array> {
  const { default: HTMLtoDOCX } = await import("html-to-docx");
  const restore = opts.allowNetwork ? () => {} : blockNetwork();
  try {
    const buf = await HTMLtoDOCX(html, null, meta);
    return buf instanceof Uint8Array ? buf : new Uint8Array(await (buf as Blob).arrayBuffer());
  } finally {
    restore();
  }
}

function blockNetwork(): () => void {
  const refuse = () => {
    throw new Error("network access is off (pass --allow-network to allow it)");
  };
  const saved: Array<[any, string, unknown]> = [];
  for (const mod of [http, https]) {
    for (const key of ["request", "get"]) {
      saved.push([mod, key, (mod as any)[key]]);
      (mod as any)[key] = refuse;
    }
  }
  saved.push([globalThis, "fetch", globalThis.fetch]);
  (globalThis as any).fetch = async () => refuse();
  // The converter reports a failed download through console.warning, which
  // does not exist; without it the refusal would fail the whole export
  // instead of skipping the image.
  saved.push([console, "warning", (console as any).warning]);
  (console as any).warning = () => {};
  return () => {
    for (const [obj, key, value] of saved) obj[key] = value;
  };
}
