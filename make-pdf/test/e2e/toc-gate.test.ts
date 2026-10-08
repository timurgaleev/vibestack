/**
 * TOC page-number gate — through the compiled binary and the browse daemon.
 *
 * Every `.toc-page` cell must hold the page its heading prints on, and every
 * TOC link must land there. Oracles:
 *   - pdftotext: the number printed beside each TOC label, and the text of
 *     the page that number names (it must contain the heading);
 *   - the PDF's own link annotations and named destinations.
 *
 * The fixture spans several pages and carries an empty heading, a custom id,
 * a duplicate id and a user id squatting the generated `toc-N` scheme, each
 * of which used to shift or misdirect links.
 */

import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import { resolvePopplerTool } from "../../src/pdftotext";
import { pdfDestinationPages } from "../../src/toc-pages";

const ROOT = path.resolve(__dirname, "../../..");
const PDF_BIN = path.join(ROOT, "make-pdf/dist/pdf");
const BROWSE_BIN = path.join(ROOT, "browse/bin/browse");
const CHILD_TIMEOUT_MS = 90_000;

function prerequisitesAvailable(): { ok: true } | { ok: false; reason: string } {
  if (!fs.existsSync(PDF_BIN)) return { ok: false, reason: `make-pdf binary missing (${PDF_BIN}). Run bun run build.` };
  if (!fs.existsSync(BROWSE_BIN)) return { ok: false, reason: `browse binary missing (${BROWSE_BIN}).` };
  if (!resolvePopplerTool("pdfinfo")) return { ok: false, reason: "pdfinfo not found (install poppler-utils)." };
  if (!resolvePopplerTool("pdftotext")) return { ok: false, reason: "pdftotext not found (install poppler-utils)." };
  return { ok: true };
}

const SECTIONS = Array.from({ length: 12 }, (_, i) => `Section ${String(i + 1).padStart(2, "0")}`);
const LABELS = ["Gate Intro", "Squatter Heading", "Custom Heading", "Duplicate Heading", ...SECTIONS];

function fixtureMarkdown(): string {
  const filler = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(30);
  const lines = [
    "# Gate Intro", "", "Intro paragraph.", "",
    "#", "",
    `<h2 id="toc-1">Squatter Heading</h2>`, "", "Body.", "",
    `<h2 id="custom-id">Custom Heading</h2>`, "", "Body.", "",
    `<h2 id="custom-id">Duplicate Heading</h2>`, "", "Body.", "",
  ];
  for (const label of SECTIONS) lines.push(`## ${label}`, "", filler, "");
  return lines.join("\n");
}

const run = (tool: "pdfinfo" | "pdftotext", args: string[]) =>
  execFileSync(resolvePopplerTool(tool)!, args, { encoding: "utf8", timeout: CHILD_TIMEOUT_MS });
const pageText = (pdf: string, page: number, layout = false) =>
  run("pdftotext", [...(layout ? ["-layout"] : []), "-f", String(page), "-l", String(page), pdf, "-"]);
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function checkToc(pdf: string): void {
  const info = run("pdfinfo", [pdf]);
  const pageCount = Number(info.match(/^Pages:\s+(\d+)/m)?.[1] ?? 0);
  expect(pageCount).toBeGreaterThan(4);

  // The number printed beside each label, read from the TOC page's layout text.
  const tocPages = new Set<number>();
  const printed = new Map<string, number>();
  for (let page = 1; page <= pageCount; page++) {
    const text = pageText(pdf, page, true);
    for (const label of LABELS) {
      const m = text.match(new RegExp(`^\\s*${escapeRe(label)}\\s+(\\d+)\\s*$`, "m"));
      if (!m || printed.has(label)) continue;
      printed.set(label, Number(m[1]));
      tocPages.add(page);
    }
  }
  expect([...printed.keys()]).toEqual(LABELS);

  // Each number names the page whose own text holds that heading.
  for (const label of LABELS) {
    const page = printed.get(label)!;
    expect(page).toBeGreaterThan(0);
    expect(tocPages.has(page)).toBe(false);
    const lines = pageText(pdf, page).split("\n").map((l) => l.trim());
    expect({ label, page, found: lines.includes(label) }).toEqual({ label, page, found: true });
  }

  // One link per entry, each to a distinct destination on its entry's page.
  const raw = fs.readFileSync(pdf);
  const links = [...raw.toString("latin1").matchAll(/\/Subtype \/Link\b[^>]*?\/Dest \/([^\s/>\]]+)/g)].map((m) => m[1]);
  expect(links).toHaveLength(LABELS.length);
  const dests = pdfDestinationPages(raw);
  const decoded = links.map((n) =>
    decodeURIComponent(Buffer.from(n.replace(/#([0-9a-fA-F]{2})/g, (_x, h) => String.fromCharCode(parseInt(h, 16))), "latin1").toString("utf8")));
  expect(decoded.map((d) => dests.get(d))).toEqual(LABELS.map((l) => printed.get(l)));
  expect(new Set(decoded).size).toBe(LABELS.length);
}

describe("TOC page-number gate", () => {
  const avail = prerequisitesAvailable();

  for (const variant of [{ name: "cover + toc", args: ["--cover", "--toc"] }, { name: "toc only", args: ["--toc"] }]) {
    test.skipIf(!avail.ok)(`${variant.name}: every TOC cell holds its heading's printed page`, () => {
      if (!avail.ok) return;
      // /tmp, not os.tmpdir(): browse only writes PDFs under its safe dirs.
      const dir = fs.mkdtempSync("/tmp/make-pdf-toc-gate-");
      try {
        fs.writeFileSync(path.join(dir, "toc.md"), fixtureMarkdown());
        const out = path.join(dir, "out.pdf");
        execFileSync(PDF_BIN, ["generate", path.join(dir, "toc.md"), out, "--quiet", "--title", "Gate Doc", ...variant.args], {
          encoding: "utf8",
          env: { ...process.env, BROWSE_BIN },
          stdio: ["ignore", "pipe", "pipe"],
          timeout: CHILD_TIMEOUT_MS,
        });
        checkToc(out);
        // No intermediate print is left next to the output.
        expect(fs.readdirSync(dir).sort()).toEqual(["out.pdf", "toc.md"]);
      } finally {
        fs.rmSync(dir, { recursive: true, force: true });
      }
    }, 180_000);
  }

  if (!avail.ok) {
    test("toc gate prerequisites are present (hard-required in CI)", () => {
      if (process.env.CI) {
        throw new Error(`toc gate prerequisites missing in CI: ${avail.reason}`);
      }
      console.warn(`[skip] ${avail.reason}`);
    });
  }
});
