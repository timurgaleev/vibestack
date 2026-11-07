/**
 * Offline posture for raw HTML in untrusted markdown. Without --allow-network,
 * nothing in the rendered document may make Chromium (or the DOCX converter)
 * reach a remote host: CSS imports and url()/image-set references, entity- or
 * escape-obfuscated style attributes, SVG hrefs, srcset candidates and media
 * sources are all neutralised. Remote <img src> stays so the image pass can
 * swap it for the visible "remote image blocked" placeholder. With
 * --allow-network the same markup passes through untouched.
 */

import { describe, expect, test } from "bun:test";

import { render, sanitizeUntrustedHtml } from "../src/render";
import { inlineLocalImages } from "../src/diagram-prepass";

const OFFLINE = { allowNetwork: false };
const ONLINE = { allowNetwork: true };

// Every fixture references only evil.test; after neutralisation the host must
// be gone entirely.
const HOSTILE: Array<[string, string]> = [
  ["style @import url()", `<style>@import url("https://evil.test/a.css"); p { color: red; }</style>`],
  ["style @import string", `<style>@import 'https://evil.test/b.css' screen;</style>`],
  ["style @import protocol-relative", `<style>@import url(//evil.test/c.css);</style>`],
  ["style remote url()", `<style>body { background: url(https://evil.test/bg.png) no-repeat; }</style>`],
  ["style @font-face src", `<style>@font-face { font-family: X; src: url('https://evil.test/f.woff2') format('woff2'); }</style>`],
  ["style image-set strings", `<style>.a { background-image: image-set("https://evil.test/1.png" 1x, url(https://evil.test/2.png) 2x); }</style>`],
  ["style -webkit-image-set", `<style>.a { background-image: -webkit-image-set('//evil.test/1.png' 1x); }</style>`],
  ["style CSS-escaped url", `<style>.a { background: url(\\68 ttps://evil.test/esc.png); }</style>`],
  ["style CSS-escaped function name", `<style>.a { background: \\75 rl(https://evil.test/fn.png); }</style>`],
  ["style string with a line continuation", `<style>.a { background-image: image-set("https:/\\\n/evil.test/lc.png" 1x); }</style>`],
  ["style comment-split @import", `<style>@import/**/"https://evil.test/d.css";</style>`],
  ["svg style entity-encoded", `<svg><style>@import "&#104;ttps://evil.test/e.css";</style></svg>`],
  // Inside <svg> a <style> is foreign content, not raw text: comments drop
  // out, CDATA sections unwrap, and only its own text children are CSS, so a
  // URL can be assembled from pieces no raw-text reading sees whole. Chromium
  // fetches each of these.
  ["svg style comment-split scheme", `<svg><style>@import url(ht<!---->tps://evil.test/f1.css);</style></svg>`],
  ["svg style CDATA-wrapped url", `<svg><style>@import url(<![CDATA[https://evil.test/f2.css]]>);</style></svg>`],
  ["svg style child element splits url", `<svg><style>rect{fill:url(ht<x>junk</x>tps://evil.test/f3.svg#a)}</style></svg>`],
  ["svg style comment-split string import", `<svg><style>@import "ht<!---->tps://evil.test/f4.css";</style></svg>`],
  // A CDATA section carries `</style>` past the raw-text end of the element.
  ["svg style split by a child with a quoted >", `<svg><style>body{background:url(ht<x a=">">j</x>tps://evil.test/f6.png)}</style></svg>`],
  ["svg style split by a bogus comment", `<svg><style>body{background:url(ht</ x>tps://evil.test/f7.png)}</style></svg>`],
  ["svg style end tag hidden in CDATA", `<svg><style><![CDATA[ </style> {} ]]> body{background:url(https://evil.test/f5.png)}</style></svg>`],
  ["style attr url()", `<p style="background: url(https://evil.test/a.png)">x</p>`],
  ["style attr entity-decoded", `<p style="background:url(&#104;ttps://evil.test/b.png)">x</p>`],
  ["style attr &quot; quoted", `<p style="background:url(&quot;https://evil.test/c.png&quot;)">x</p>`],
  ["style attr single-quoted", `<div style='background-image: url( "//evil.test/d.png" )'>x</div>`],
  ["style attr unquoted", `<div style=background:url(https://evil.test/e.png)>x</div>`],
  ["svg image href", `<svg><image href="https://evil.test/a.png" width="10" height="10"/></svg>`],
  ["svg use xlink:href", `<svg><use xlink:href="//evil.test/s.svg#i"/></svg>`],
  ["svg feImage", `<svg><filter id="f"><feImage href="https://evil.test/f.png"/></filter></svg>`],
  ["svg animate to", `<svg><use href="#x"><set attributeName="href" to="https://evil.test/set.svg#i"/></use></svg>`],
  ["svg presentation url()", `<svg><rect fill="url(https://evil.test/p.svg#g)" width="1" height="1"/></svg>`],
  ["img srcset", `<img src="local.png" srcset="https://evil.test/a.png 2x">`],
  ["picture source srcset", `<picture><source srcset="https://evil.test/a.webp" type="image/webp"><img src="local.png"></picture>`],
  ["video src + poster", `<video src="https://evil.test/v.mp4" poster="https://evil.test/p.png"></video>`],
  ["audio src", `<audio src="https://evil.test/a.mp3"></audio>`],
  ["video source + track", `<video><source src="https://evil.test/v.webm"><track src="https://evil.test/t.vtt"></video>`],
  ["legacy background attr", `<table background="https://evil.test/bg.png"><tr><td>x</td></tr></table>`],
  ["input type=image", `<input type="image" src="https://evil.test/i.png">`],
  ["image tag outside svg", `<image src="https://evil.test/i.png">`],
  ["slash-separated attribute", `<video/poster=https://evil.test/p.png></video>`],
  ["style without an end tag", `<style>\n@import url(https://evil.test/a.css);\nbody{background:url(https://evil.test/b.png)}\n`],
  ["style end tag with an attribute", `<style>@import url(https://evil.test/a.css);</style x="1">`],
  ["style end tag written as </style/>", `<style>@import url(https://evil.test/a.css);</style/>`],
  ["start tag unfinished at end of input", `<div>\n<video poster=https://evil.test/eof.png`],
  ["start tag with an unterminated quote at end of input", `<div>\n<video poster="https://evil.test/eof.png`],
  ["svg style abrupt <!--> comment", `<svg><style>@import url(https://evil.test/g1.css<!-->);</style></svg>`],
  ["svg style --!> comment", `<svg><style>@import url(https://<!-- x --!>evil.test/g2.css);</style></svg>`],
  ["svg style end tag inside a comment", `<svg><style><!-- </style> -->@import url(https://evil.test/g3.css);</style></svg>`],
  ["SMIL set to url()", `<svg><rect><set attributeName="mask" to="url(https://evil.test/m.svg#a)"/></rect></svg>`],
  ["SMIL values holding url()", `<svg><rect><animate attributeName="mask" values="none;url(https://evil.test/v.svg#a)"/></rect></svg>`],
  ["data: stylesheet that imports a remote URL", `<style>@import url("data:text/css,@import url('https://evil.test/n.css');");</style>`],
];

describe("sanitizeUntrustedHtml — offline (allowNetwork false)", () => {
  for (const [name, html] of HOSTILE) {
    test(`neutralises ${name}`, () => {
      const out = sanitizeUntrustedHtml(html, OFFLINE);
      expect(out).not.toContain("evil.test");
    });
  }

  // The foreign-content reading scans each <style> once; a quadratic pass let
  // a 400 KB style of unclosed tags hold the renderer for seconds.
  test("reads a style full of unclosed tags in linear time", () => {
    const html = `<svg><style>${"a<b ".repeat(100000)}</style></svg>`;
    const t = performance.now();
    sanitizeUntrustedHtml(html, OFFLINE);
    expect(performance.now() - t).toBeLessThan(3000);
  });

  test("keeps a CDATA-wrapped SVG stylesheet with no remote reference byte for byte", () => {
    const html = `<svg><style><![CDATA[ .a { fill: url(#grad); } ]]></style><rect class="a"/></svg>`;
    expect(sanitizeUntrustedHtml(html, OFFLINE)).toBe(html);
  });

  test("keeps the other rules of a CDATA-wrapped SVG stylesheet when only its import is remote", () => {
    const out = sanitizeUntrustedHtml(`<svg><style><![CDATA[@import url(https://evil.test/g.css); .a { fill: red; }]]></style></svg>`, OFFLINE);
    expect(out).not.toContain("evil.test");
    expect(out).toContain(".a { fill: red; }");
  });

  test("keeps local and data references in CSS", () => {
    const html = `<style>.a { background: url(local.png); } .b { background: url("data:image/png;base64,AAAA"); }</style>`;
    expect(sanitizeUntrustedHtml(html, OFFLINE)).toBe(html);
  });

  test("keeps hyperlinks — a link is not a fetch", () => {
    const html = `<p><a href="https://example.com/doc">doc</a></p><svg><a href="https://example.com/x"><text>x</text></a></svg>`;
    expect(sanitizeUntrustedHtml(html, OFFLINE)).toBe(html);
  });

  test("keeps SVG namespace declarations", () => {
    const html = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use href="#a"/></svg>`;
    expect(sanitizeUntrustedHtml(html, OFFLINE)).toBe(html);
  });

  test("a rebuilt tag keeps its other attributes intact", () => {
    const out = sanitizeUntrustedHtml(`<img src="local.png" srcset="https://evil.test/a.png 2x" alt="a &amp; b">`, OFFLINE);
    expect(out).toBe(`<img src="local.png" alt="a &amp; b">`);
  });

  test("keeps remote <img src> for the blocked-remote placeholder", () => {
    const out = sanitizeUntrustedHtml(`<img src="https://evil.test/pixel.png" alt="p">`, OFFLINE);
    expect(out).toContain(`src="https://evil.test/pixel.png"`);
  });

  test("unquoted remote <img src> reaches the image pass as a blocked placeholder", () => {
    const sanitized = sanitizeUntrustedHtml(`<p><img src=https://evil.test/pixel.png alt=p></p>`, OFFLINE);
    const warnings: string[] = [];
    const out = inlineLocalImages(sanitized, {
      inputDir: process.cwd(),
      strict: false,
      allowNetwork: false,
      contentWidthIn: 6.5,
      warn: (m) => warnings.push(m),
      getTab: () => null,
    });
    expect(out).toContain("remote image blocked");
    expect(out).not.toMatch(/<img[^>]*evil\.test/);
    expect(warnings.join("\n")).toContain("remote image blocked");
  });

  test("render() applies the offline posture by default", () => {
    const md = `# T\n\n<p style="background:url(https://evil.test/r.png)">x</p>\n\n<video poster="https://evil.test/p.png"></video>\n`;
    const out = render({ markdown: md });
    expect(out.html).not.toContain("evil.test");
  });

  test("render() checks attributes an entity-decoded quote would add", () => {
    const out = render({ markdown: `<div><video title="a&quot; poster=&quot;https://evil.test/q.png"></video></div>` });
    expect(out.html).not.toContain("evil.test");
  });

  test("render() strips a tag the stripper itself reassembles", () => {
    const out = render({ markdown: `<div><me<meta>ta http-equiv="refresh" content="0;url=https://evil.test/nav"></div>` });
    // What is left is an unknown <me> element; its attributes are inert.
    expect(out.html).not.toMatch(/<meta[^>]*refresh/i);
  });

  // Dropping an attribute splices the text on either side of it, the same
  // way dropping a tag does.
  for (const [name, attr] of [
    ["an event handler", `onx="1"`],
    ["a single-quoted event handler", `onx='1'`],
    ["a srcdoc attribute", `srcdoc="x"`],
  ]) {
    test(`render() strips a tag that removing ${name} reassembles`, () => {
      const out = render({ markdown: `<div><me ${attr}ta http-equiv="refresh" content="0;url=https://evil.test/nav"></div>` });
      expect(out.html).not.toMatch(/<meta[^>]*refresh/i);
    });
  }

  test("strips nested reassembling tags in linear time", () => {
    const depth = 20000;
    const nested = `${"<me".repeat(depth)}<meta>${"ta>".repeat(depth)}`;
    const t = performance.now();
    const out = sanitizeUntrustedHtml(nested, OFFLINE);
    expect(performance.now() - t).toBeLessThan(1500);
    expect(out).not.toMatch(/<meta/i);
  }, 120_000);

  test("render() puts a no-network content policy first in <head>", () => {
    const html = render({ markdown: "# T" }).html;
    const head = html.slice(html.indexOf("<head>"), html.indexOf("<title>"));
    expect(head).toMatch(/<meta http-equiv="Content-Security-Policy" content="default-src 'none';[^"]*">/);
    expect(head).not.toMatch(/https?:/);
  });

  // An unclosed url( made every later url( rescan to the end of the text.
  test("reads a value full of unclosed url( in linear time", () => {
    const t = performance.now();
    sanitizeUntrustedHtml(`<p style="${"url(".repeat(80000)}">x</p><style>${"url(".repeat(80000)}</style>`, OFFLINE);
    expect(performance.now() - t).toBeLessThan(1500);
  }, 120_000);

  test("render() leaves nothing remote for the page template to complete", () => {
    for (const tail of [
      `<style>\n@import url(http://evil.test/a.css);\nbody{background:url(http://evil.test/b.png)}\n`,
      `<div>\n<video poster=http://evil.test/eof.png`,
    ]) {
      const out = render({ markdown: `# Title\n\nHello.\n\n${tail}` });
      expect(out.html).not.toContain("evil.test");
    }
  });
});

describe("sanitizeUntrustedHtml — --allow-network keeps remote assets", () => {
  for (const [name, html] of HOSTILE) {
    test(`passes ${name} through unchanged`, () => {
      expect(sanitizeUntrustedHtml(html, ONLINE)).toBe(html);
    });
  }

  test("render() with allowNetwork sets no content policy", () => {
    expect(render({ markdown: "# T", allowNetwork: true }).html).not.toContain("Content-Security-Policy");
  });

  test("render() with allowNetwork keeps a remote stylesheet font", () => {
    const md = `# T\n\n<style>@import url("https://fonts.example.com/corp.css");</style>\n`;
    const out = render({ markdown: md, allowNetwork: true });
    expect(out.html).toContain(`@import url("https://fonts.example.com/corp.css")`);
  });
});
