/**
 * TOC labels and link targets come from ONE heading inventory. If ids were
 * numbered over every H1-H3 while entries skipped empty headings, one empty
 * heading would shift every later link; a user `id="toc-1"`, a duplicate id
 * or a `data-id` attribute would do the same.
 *
 * The oracle here is the HTML fragment rule: a link `#x` lands on the FIRST
 * element whose id is x. Every TOC entry must land on a heading with the
 * entry's own text.
 */
import { describe, expect, test } from "bun:test";
import { render } from "../src/render";

function stripTags(s: string): string {
  return s.replace(/<[^>]+>/g, "").trim();
}

function decode(s: string): string {
  return s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

/** [entry label, text of the element the link lands on] for every TOC entry. */
function tocLandings(html: string): Array<{ label: string; landsOn: string | null }> {
  const toc = html.match(/<section class="toc">[\s\S]*?<\/section>/)?.[0] ?? "";
  const body = html.slice(html.indexOf(toc) + toc.length);
  const entries = [...toc.matchAll(/<a href="#([^"]*)">([\s\S]*?)<\/a>/g)];
  return entries.map(([, href, label]) => {
    const id = decode(href);
    let landsOn: string | null = null;
    for (const m of body.matchAll(/<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>/g)) {
      const attr = m[2].match(/\sid\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i);
      if (!attr || decode(attr[1] ?? attr[2] ?? attr[3]) !== id) continue;
      const rest = body.slice(m.index! + m[0].length);
      landsOn = /^h[1-3]$/i.test(m[1]) ? decode(stripTags(rest.slice(0, rest.search(new RegExp(`</${m[1]}>`, "i"))))) : `<${m[1]}>`;
      break;
    }
    return { label: decode(label), landsOn };
  });
}

describe("TOC anchors: one inventory for labels and targets", () => {
  test("an empty H1 does not shift the links after it", () => {
    const { html } = render({ markdown: `#\n\n# Alpha\n\nx\n\n# Beta\n\ny\n`, toc: true });
    const landings = tocLandings(html);
    expect(landings.map((l) => l.label)).toEqual(["Alpha", "Beta"]);
    for (const l of landings) expect(l.landsOn).toBe(l.label);
  });

  test("an image-only heading gets no entry and shifts nothing", () => {
    const { html } = render({ markdown: `# ![logo](data:image/png;base64,AAAA)\n\n## Real\n\nx\n`, toc: true });
    expect(tocLandings(html)).toEqual([{ label: "Real", landsOn: "Real" }]);
  });

  test("custom ids are kept; a user id that squats toc-N never captures a generated link", () => {
    const md = [
      "# Intro", "",
      "## Plain", "",
      `<h2 id="toc-1">Squatter</h2>`, "",
      `<h2 id="custom">Custom</h2>`, "",
    ].join("\n");
    const { html } = render({ markdown: md, toc: true });
    const landings = tocLandings(html);
    expect(landings.map((l) => l.label)).toEqual(["Intro", "Plain", "Squatter", "Custom"]);
    for (const l of landings) expect(l.landsOn).toBe(l.label);
    expect(html).toContain(`<a href="#custom">Custom</a>`);
    expect(html).toContain(`<a href="#toc-1">Squatter</a>`);
  });

  test("a duplicate id (first owner wins) gets a fresh id instead of linking to the first heading", () => {
    const md = [`<h2 id="dup">First</h2>`, "", `<h2 id="dup">Second</h2>`, "", `<div id="taken">x</div>`, "", `<h2 id="taken">Third</h2>`, ""].join("\n");
    const { html } = render({ markdown: md, toc: true });
    const landings = tocLandings(html);
    expect(landings.map((l) => l.label)).toEqual(["First", "Second", "Third"]);
    for (const l of landings) expect(l.landsOn).toBe(l.label);
  });

  test("data-id, unquoted and empty id attributes are read as what they are", () => {
    const md = [`<h2 data-id="z">DataId</h2>`, "", `<h2 id=bare>Bare</h2>`, "", `<h2 id="">EmptyId</h2>`, ""].join("\n");
    const { html } = render({ markdown: md, toc: true });
    const landings = tocLandings(html);
    expect(landings.map((l) => l.label)).toEqual(["DataId", "Bare", "EmptyId"]);
    for (const l of landings) expect(l.landsOn).toBe(l.label);
    expect(html).toContain(`<a href="#bare">Bare</a>`);
  });

  test("each TOC page cell targets the same id as its link", () => {
    const { html } = render({ markdown: `#\n\n# A\n\n<h2 id="k&amp;v">B</h2>\n`, toc: true });
    const toc = html.match(/<section class="toc">[\s\S]*?<\/section>/)![0];
    const hrefs = [...toc.matchAll(/href="#([^"]*)"/g)].map((m) => m[1]);
    const cells = [...toc.matchAll(/data-toc-target="([^"]*)"/g)].map((m) => m[1]);
    expect(cells).toEqual(hrefs);
    expect(hrefs).toHaveLength(2);
  });
});
