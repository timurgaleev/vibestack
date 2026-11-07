/**
 * Document structure the reader never asked for: YAML frontmatter must not
 * print as a rule plus a setext heading, a preamble holding only styles or
 * comments must not become its own (blank) chapter page, and quotes opened
 * after CJK punctuation must curl as openers.
 */

import { describe, expect, test } from "bun:test";

import { render } from "../src/render";
import { smartypants } from "../src/smartypants";

const chapters = (html: string) => (html.match(/<section class="chapter">/g) ?? []).length;

describe("frontmatter", () => {
  test("YAML frontmatter is not rendered", () => {
    const out = render({ markdown: "---\ntitle: Quarterly\nauthor: Ops\n---\n\n# Real heading\n\nBody.\n" });
    expect(out.bodyHtml).not.toContain("<hr");
    expect(out.bodyHtml).not.toContain("Quarterly");
    expect(out.bodyHtml).not.toContain("<h2");
    expect(out.meta.title).toBe("Real heading");
    expect(chapters(out.html)).toBe(1);
  });

  test("CRLF frontmatter closed by ... is not rendered", () => {
    const out = render({ markdown: "---\r\ntags: [a, b]\r\n...\r\n\r\n# H\r\n\r\nBody.\r\n" });
    expect(out.bodyHtml).not.toContain("tags:");
    expect(chapters(out.html)).toBe(1);
  });

  test("a leading horizontal rule that is not YAML stays", () => {
    const out = render({ markdown: "---\n\nPlain opening paragraph.\n\n---\n\n# H\n" });
    expect(out.bodyHtml).toContain("<hr");
    expect(out.bodyHtml).toContain("Plain opening paragraph.");
  });
});

describe("non-rendering preamble", () => {
  test("a style/comment-only preamble joins the first chapter", () => {
    const md = "<!-- build note -->\n<style>p { color: #333; }</style>\n\n# One\n\nA\n\n# Two\n\nB\n";
    const out = render({ markdown: md });
    expect(chapters(out.html)).toBe(2);
    const first = out.html.slice(out.html.indexOf(`<section class="chapter">`));
    expect(first.indexOf("<style>p")).toBeLessThan(first.indexOf("<h1"));
  });

  test("a preamble with visible text keeps its own chapter", () => {
    const out = render({ markdown: "Intro text.\n\n# One\n\nA\n" });
    expect(chapters(out.html)).toBe(2);
  });
});

describe("smartypants after CJK punctuation", () => {
  test.each([
    ["他说：\"你好\"", "他说：“你好”"],
    ["（\"引用\"）", "（“引用”）"],
    ["【\"注\"】", "【“注”】"],
    ["「'内'」", "「‘内’」"],
    ["『\"书\"』", "『“书”』"],
    ["〈\"a\"〉《\"b\"》", "〈“a”〉《“b”》"],
  ])("%s", (input, expected) => {
    expect(smartypants(`<p>${input}</p>`)).toBe(`<p>${expected}</p>`);
  });
});
