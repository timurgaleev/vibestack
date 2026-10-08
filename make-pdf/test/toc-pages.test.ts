/**
 * TOC page numbers. The PDF reader and the print loop, driven by
 * synthetic PDFs laid out the way Chromium/Skia writes them (classic xref,
 * catalog /Dests dictionary, `#xx`-escaped percent-encoded names). The real
 * browser path is make-pdf/test/e2e/toc-gate.test.ts.
 */
import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { render } from "../src/render";
import {
  MAX_PRINTS,
  TocPaginationError,
  fillTocPages,
  pdfDestinationPages,
  printWithTocPages,
  tocTargets,
} from "../src/toc-pages";

/** A minimal classic-xref PDF: `pages` leaf pages under `fanout`-wide intermediate nodes. */
function syntheticPdf(opts: { pages: number; dests: Record<string, number>; fanout?: number }): Uint8Array {
  const objs: string[] = [];
  const add = (body: string) => objs.push(body) - 1 + 1; // object numbers start at 1
  const leaf: number[] = [];
  for (let i = 0; i < opts.pages; i++) leaf.push(add("<</Type /Page /Parent 0 0 R>>"));
  let level = leaf;
  const fanout = opts.fanout ?? opts.pages;
  do {
    const next: number[] = [];
    for (let i = 0; i < level.length; i += fanout) {
      const kids = level.slice(i, i + fanout);
      next.push(add(`<</Type /Pages /Count ${kids.length} /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}]>>`));
    }
    level = next;
  } while (level.length > 1);
  const destEntries = Object.entries(opts.dests).map(([name, page]) => `/${name} [${leaf[page - 1]} 0 R /XYZ 0 792 0]`);
  const dests = add(`<<${destEntries.join("\n")}>>`);
  const catalog = add(`<</Type /Catalog\n/Pages ${level[0]} 0 R\n/Dests ${dests} 0 R>>`);

  let out = "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n";
  const offsets: number[] = [];
  objs.forEach((body, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) out += `${String(o).padStart(10, "0")} 00000 n \n`;
  out += `trailer\n<</Size ${objs.length + 1}\n/Root ${catalog} 0 R>>\nstartxref\n${xref}\n%%EOF`;
  return Buffer.from(out, "latin1");
}

describe("pdfDestinationPages", () => {
  test("maps each named destination to its 1-based page through a nested page tree", () => {
    const pdf = syntheticPdf({ pages: 40, fanout: 3, dests: { "toc-0": 3, "toc-1": 17, custom: 40 } });
    expect(Object.fromEntries(pdfDestinationPages(pdf))).toEqual({ "toc-0": 3, "toc-1": 17, custom: 40 });
  });

  test("decodes #xx name escapes and the percent-encoding Chromium applies to fragments", () => {
    // Skia writes id="café-ü" as /caf#25C3#25A9-#25C3#25BC and id="a b" as /a#2520b.
    const pdf = syntheticPdf({ pages: 2, dests: { "caf#25C3#25A9-#25C3#25BC": 1, "a#2520b": 2, "p#28q#29": 2 } });
    expect(Object.fromEntries(pdfDestinationPages(pdf))).toEqual({ "café-ü": 1, "a b": 2, "p(q)": 2 });
  });

  test("a cross-reference-stream PDF fails explicitly instead of yielding no pages", () => {
    const pdf = Buffer.from("%PDF-1.5\n1 0 obj\n<</Type /XRef>>\nendobj\nstartxref\n9\n%%EOF", "latin1");
    expect(() => pdfDestinationPages(pdf)).toThrow(TocPaginationError);
    expect(() => pdfDestinationPages(Buffer.from("not a pdf"))).toThrow(/could not read TOC page numbers/);
  });
});

describe("fillTocPages / tocTargets", () => {
  const { html } = render({ markdown: `# One\n\n## Two\n\n<h2 id="café">Three</h2>\n`, toc: true });

  test("targets come from the TOC section in order; cells fill from the map, 0 when unknown", () => {
    const targets = tocTargets(html);
    expect(targets).toHaveLength(3);
    expect(targets[2]).toBe("café");
    const filled = fillTocPages(html, new Map([[targets[0], 4], [targets[2], 12]]));
    const cells = [...filled.matchAll(/<span class="toc-page" data-toc-target="[^"]*">([^<]*)<\/span>/g)].map((m) => m[1]);
    expect(cells).toEqual(["4", "0", "12"]);
    // Refilling replaces, never appends.
    const refilled = fillTocPages(filled, new Map([[targets[0], 5]]));
    expect([...refilled.matchAll(/data-toc-target="[^"]*">([^<]*)</g)].map((m) => m[1])).toEqual(["5", "0", "0"]);
  });

  test("a look-alike span in the document body is never filled", () => {
    const fake = `<span class="toc-page" data-toc-target="toc-0"></span>`;
    const { html: withFake } = render({ markdown: `# One\n\n${fake}\n`, toc: true });
    const filled = fillTocPages(withFake, new Map([["toc-0", 9]]));
    expect(filled).toContain(fake);
    expect(tocTargets(withFake)).toEqual(["toc-0"]);
  });
});

describe("printWithTocPages", () => {
  const { html } = render({ markdown: `# One\n\n## Two\n\n# Three\n`, toc: true });
  const targets = tocTargets(html);
  const work = () => fs.mkdtempSync(path.join(os.tmpdir(), "toc-pages-"));
  const cellsOf = (h: string) => [...h.matchAll(/data-toc-target="[^"]*">([^<]*)</g)].map((m) => m[1]);

  test("prints until the cells match the printed pages, then writes exactly that PDF", async () => {
    const dir = work();
    const out = path.join(dir, "out.pdf");
    const seen: string[][] = [];
    const layout = { [targets[0]]: 3, [targets[1]]: 3, [targets[2]]: 5 };
    const r = await printWithTocPages(html, out, async (h, o) => {
      seen.push(cellsOf(h));
      fs.writeFileSync(o, syntheticPdf({ pages: 6, dests: layout }));
      return "browse" as const;
    });
    expect(r).toBe("browse");
    expect(seen).toEqual([["0", "0", "0"], ["3", "3", "5"]]);
    expect(Object.fromEntries(pdfDestinationPages(fs.readFileSync(out)))).toEqual(layout);
    expect(fs.readdirSync(dir)).toEqual(["out.pdf"]);
  });

  test("numbers that keep moving fail after MAX_PRINTS and leave no output", async () => {
    const dir = work();
    const out = path.join(dir, "out.pdf");
    let n = 0;
    const p = printWithTocPages(html, out, async (_h, o) => {
      n++;
      fs.writeFileSync(o, syntheticPdf({ pages: 10, dests: Object.fromEntries(targets.map((t) => [t, n])) }));
    });
    await expect(p).rejects.toThrow(/did not settle after 3 prints/);
    expect(n).toBe(MAX_PRINTS);
    expect(fs.readdirSync(dir)).toEqual([]);
  });

  test("a TOC target with no PDF destination fails and names the target", async () => {
    const dir = work();
    const p = printWithTocPages(html, path.join(dir, "out.pdf"), async (_h, o) => {
      fs.writeFileSync(o, syntheticPdf({ pages: 3, dests: { [targets[0]]: 2 } }));
    });
    await expect(p).rejects.toThrow(new RegExp(`no destination for TOC target\\(s\\) #${targets[1]}, #${targets[2]}`));
    expect(fs.readdirSync(dir)).toEqual([]);
  });

  test("a document without TOC entries prints once, straight to the output", async () => {
    const plain = render({ markdown: `#\n\nno headings with text\n`, toc: true }).html;
    const outs: string[] = [];
    await printWithTocPages(plain, "/nowhere/out.pdf", async (_h, o) => { outs.push(o); });
    expect(outs).toEqual(["/nowhere/out.pdf"]);
  });
});
