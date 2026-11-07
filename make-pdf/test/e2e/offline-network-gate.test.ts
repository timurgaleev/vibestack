/**
 * Offline posture, checked in a real Chromium against a local HTTP server
 * that counts hits. Each case is markup that slipped past the string
 * sanitizer at some point; without --allow-network the page make-pdf builds
 * must reach the server zero times, with --allow-network it must reach it
 * (proving the case is live, not inert).
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import { chromium, type Browser } from "playwright";

import { render } from "../../src/render";

// A missing browser is a visible skip, never a silent pass.
const CHROMIUM = (() => { try { return chromium.executablePath(); } catch { return ""; } })();
const HAVE_CHROMIUM = CHROMIUM !== "" && fs.existsSync(CHROMIUM);

let browser: Browser | null = null;
let server: ReturnType<typeof Bun.serve> | null = null;
const hits = new Map<string, number>();

beforeAll(async () => {
  server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const segment = new URL(req.url).pathname.split("/")[1] ?? "";
      const tag = segment.split("-")[0];
      hits.set(tag, (hits.get(tag) ?? 0) + 1);
      if (segment.endsWith("-css")) {
        return new Response("body{color:red}", { headers: { "content-type": "text/css", "cache-control": "no-store" } });
      }
      return new Response("", { status: 404, headers: { "cache-control": "no-store" } });
    },
  });
  if (!HAVE_CHROMIUM) return;
  browser = await chromium.launch();
});

afterAll(async () => {
  await browser?.close();
  server?.stop(true);
});

function origin(): string {
  return `http://127.0.0.1:${server!.port}`;
}

type Build = (o: string, tag: string) => string;

// Each case gets a unique path tag. Payloads sit in a <div> so marked passes
// them through as an HTML block. A case the renderer refuses even with
// --allow-network names, as its third element, the raw page that proves the
// payload would reach the server.
const CASES: Array<[string, Build, Build?]> = [
  ["svg style <!--> comment", (o, t) => `<div><svg><style>@import url(${o}/${t}-css<!-->);</style></svg></div>`],
  ["svg style --!> comment", (o, t) => `<div><svg><style>@import url(${o}/<!-- x --!>${t}-css);</style></svg></div>`],
  ["</style> inside a comment", (o, t) => `<div><svg><style><!-- </style> -->@import url(${o}/${t}-css);</style></svg></div>`],
  ["> inside the style start tag", (o, t) => `<div><style media="a>b">@import url(${o}/${t}-css);</style></div>`],
  ["quote inside a malformed url()", (o, t) => `<div><style>@import url(${o}/${t}-css);p{background:url(x")}</style></div>`],
  ["SMIL set to url()", (o, t) => `<div><svg width="9" height="9"><rect width="9" height="9"><set attributeName="mask" to="url(${o}/${t}-x.svg#a)"/></rect></svg></div>`],
  ["SMIL values list with url()", (o, t) => `<div><svg width="9" height="9"><rect width="9" height="9"><animate attributeName="mask" values="none;url(${o}/${t}-y.svg#a)" dur="0.01s" fill="freeze"/></rect></svg></div>`],
  ["&quot; decoded inside an untouched attribute", (o, t) => `<div><video title="a&quot; poster=&quot;${o}/${t}-p.png"></video></div>`],
  ["meta refresh rebuilt by the tag stripper",
    (o, t) => `<div><me<meta>ta http-equiv="refresh" content="0;url=${o}/${t}-nav"></div>`,
    (o, t) => `<!doctype html><body><meta http-equiv="refresh" content="0;url=${o}/${t}-nav"></body>`],
  ["data: stylesheet importing a remote URL", (o, t) =>
    `<div><style>@import url("data:text/css,@import url('${o}/${t}-css');");</style></div>`],
  ["> inside the style start tag, then image-set()", (o, t) =>
    `<div><style x=">">p{background:image-set("${o}/${t}-i.png" 1x)}</style><p>x</p></div>`],
  ["quote inside a malformed url(), then image-set()", (o, t) =>
    `<div><style>q{background:url(x"y)}p{background:image-set("${o}/${t}-i.png" 1x)}</style><p>x</p></div>`],
  ["&quot; decoded into a style attribute", (o, t) =>
    `<div><p title="a&quot; style=&quot;background:image-set(&#39;${o}/${t}-i.png&#39; 1x)">x</p></div>`],
  ["nested style start tag inside svg", (o, t) =>
    `<div><svg><style><style></style>@import url(${o}/${t}-css);</style></svg></div>`],
  ["meta refresh rebuilt by dropping an event handler",
    (o, t) => `<div><me onx="1"ta http-equiv="refresh" content="0;url=${o}/${t}-nav"></div>`,
    (o, t) => `<!doctype html><body><meta http-equiv="refresh" content="0;url=${o}/${t}-nav"></body>`],
  ["meta refresh rebuilt by dropping srcdoc",
    (o, t) => `<div><me srcdoc="x"ta http-equiv="refresh" content="0;url=${o}/${t}-nav"></div>`,
    (o, t) => `<!doctype html><body><meta http-equiv="refresh" content="0;url=${o}/${t}-nav"></body>`],
];

async function hitsFor(markdown: string, tag: string, allowNetwork: boolean): Promise<number> {
  return hitsForPage(render({ markdown, allowNetwork }).html, tag);
}

async function hitsForPage(html: string, tag: string): Promise<number> {
  const page = await browser!.newPage();
  try {
    await page.setContent(html, { waitUntil: "load", timeout: 10_000 }).catch(() => {});
    await page.pdf({ format: "letter" }).catch(() => {});
    await page.waitForTimeout(300);
  } finally {
    await page.close();
  }
  return hits.get(tag) ?? 0;
}

describe("offline posture in a real Chromium", () => {
  CASES.forEach(([name, build, control], i) => {
    test.skipIf(!HAVE_CHROMIUM)(`${name}: no request without --allow-network, a request with it`, async () => {
      const offTag = `c${i}off`;
      const onTag = `c${i}on`;
      expect(await hitsFor(build(origin(), offTag), offTag, false)).toBe(0);
      const live = control
        ? await hitsForPage(control(origin(), onTag), onTag)
        : await hitsFor(build(origin(), onTag), onTag, true);
      expect(live).toBeGreaterThan(0);
    }, 30_000);
  });

  // The page policy is the first layer: with the sanitizer bypassed entirely,
  // Chromium still refuses every fetch. A navigation is outside its reach.
  CASES.forEach(([name, build, control], i) => {
    if (control) return;
    test.skipIf(!HAVE_CHROMIUM)(`${name}: the page policy alone refuses the fetch`, async () => {
      const tag = `p${i}raw`;
      const page = render({ markdown: "# T" }).html.replace("</body>", `${build(origin(), tag)}</body>`);
      expect(await hitsForPage(page, tag)).toBe(0);
    }, 30_000);
  });
});
