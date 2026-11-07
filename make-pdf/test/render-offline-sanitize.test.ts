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
];

describe("sanitizeUntrustedHtml — offline (allowNetwork false)", () => {
  for (const [name, html] of HOSTILE) {
    test(`neutralises ${name}`, () => {
      const out = sanitizeUntrustedHtml(html, OFFLINE);
      expect(out).not.toContain("evil.test");
    });
  }

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

  test("render() with allowNetwork keeps a remote stylesheet font", () => {
    const md = `# T\n\n<style>@import url("https://fonts.example.com/corp.css");</style>\n`;
    const out = render({ markdown: md, allowNetwork: true });
    expect(out.html).toContain(`@import url("https://fonts.example.com/corp.css")`);
  });
});
