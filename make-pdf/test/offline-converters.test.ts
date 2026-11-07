/**
 * Without --allow-network the converters behind the print page stay offline
 * too: the render tab that runs untrusted diagram sources carries the same
 * no-network content policy, and the DOCX converter, which downloads any
 * http(s) <img> it is handed, cannot reach a host while it runs.
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";

import { bundlePageHtml } from "../src/diagram-prepass";
import { convertHtmlToDocx } from "../src/docx-images";

const BUNDLE = `<!doctype html><html><head><meta charset="utf-8"></head><body><script type="module">window.ready=1</script></body></html>`;

describe("render tab bundle page", () => {
  test("gets a no-network policy that still runs its inline scripts", () => {
    const out = bundlePageHtml(BUNDLE, false);
    expect(out.startsWith(`<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none';`)).toBe(true);
    expect(out).toMatch(/content="[^"]*script-src 'unsafe-inline' 'unsafe-eval'[^"]*"/);
    expect(out.endsWith(BUNDLE.slice(BUNDLE.indexOf("<head>") + 6))).toBe(true);
  });

  test("is left byte for byte with --allow-network", () => {
    expect(bundlePageHtml(BUNDLE, true)).toBe(BUNDLE);
  });
});

describe("DOCX conversion", () => {
  let hits = 0;
  let server: ReturnType<typeof Bun.serve>;
  beforeAll(() => {
    server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() { hits++; return new Response("", { status: 404 }); } });
  });
  afterAll(() => server.stop(true));

  const page = () => `<!doctype html><html><body><p>x</p><p><img src="http://127.0.0.1:${server.port}/a.png"></p></body></html>`;

  test("reaches no host without --allow-network, and still writes the document", async () => {
    hits = 0;
    const docx = await convertHtmlToDocx(page(), { title: "t" }, { allowNetwork: false });
    expect(hits).toBe(0);
    expect(Buffer.from(docx.subarray(0, 2)).toString("latin1")).toBe("PK");
  });

  test("puts the network back once the conversion is done", () => {
    expect(typeof globalThis.fetch).toBe("function");
    expect(String(globalThis.fetch)).not.toContain("network access is off");
  });

  test("still downloads with --allow-network (the case is live)", async () => {
    hits = 0;
    await convertHtmlToDocx(page(), { title: "t" }, { allowNetwork: true }).catch(() => null);
    expect(hits).toBeGreaterThan(0);
  });
});
