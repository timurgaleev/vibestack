/**
 * Without --allow-network every page make-pdf loads into the shared browse
 * daemon goes in with `load-html --offline`, so the daemon keeps that tab off
 * the network even for a navigation the page's content policy cannot stop.
 * A fake browse binary records each invocation and keeps a copy of every
 * page it is handed, so the posture is checked on the pages themselves: each
 * carries the no-network content policy first in <head>, and no <link> hint
 * survives. A dns-prefetch or preconnect hint reaches the network without an
 * HTTP request, so the request-counting gate in e2e/ cannot see it, and the
 * content policy does not cover it. No Chromium is needed, so this runs in CI.
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { generate } from "../src/orchestrator";
import { OFFLINE_PAGE_POLICY, OFFLINE_SCRIPT_PAGE_POLICY } from "../src/offline-html";

const POSIX = process.platform !== "win32";

describe.skipIf(!POSIX)("load-html --offline from make-pdf", () => {
  let dir: string;
  let log: string;
  let pages: string;
  const saved: Record<string, string | undefined> = {};

  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "make-pdf-offline-flag-"));
    log = path.join(dir, "argv.log");
    pages = path.join(dir, "pages");
    const bin = path.join(dir, "browse");
    fs.writeFileSync(bin, [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> '${log}'`,
      `case "$1" in`,
      `  load-html) n=$(ls '${pages}' | wc -l | tr -d ' ')`,
      `    if [ "$2" = --from-file ]; then cp "$3" '${pages}'/"$n".json; else cp "$2" '${pages}'/"$n".html; fi ;;`,
      `  newtab) echo '{"tabId":7}' ;;`,
      `  pdf) : > "$2" ;;`,
      `  js) case "$2" in *__renderMermaid*) echo 'OK:<svg xmlns="http://www.w3.org/2000/svg"></svg>' ;; *) echo true ;; esac ;;`,
      `esac`,
      "",
    ].join("\n"), { mode: 0o755 });
    const bundle = path.join(dir, "bundle.html");
    fs.writeFileSync(bundle, `<!doctype html><html><head></head><body><div id="status">ready</div></body></html>`);
    fs.writeFileSync(path.join(dir, "doc.md"), [
      `<link rel="dns-prefetch" href="//prefetch.invalid">`,
      "",
      "# T",
      "",
      `<div><LINK/rel=preconnect href=https://preconnect.invalid><li onx="1"nk rel="dns-prefetch" href="//rebuilt.invalid"></div>`,
      "",
      "```mermaid\ngraph TD; A-->B\n```",
      "",
    ].join("\n"));
    for (const [k, v] of Object.entries({ VIBE_BROWSE_BIN: bin, VIBESTACK_DIAGRAM_BUNDLE: bundle })) {
      saved[k] = process.env[k];
      process.env[k] = v;
    }
  });

  afterAll(() => {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  });

  async function loads(allowNetwork: boolean): Promise<string[]> {
    fs.rmSync(log, { force: true });
    fs.rmSync(pages, { recursive: true, force: true });
    fs.mkdirSync(pages);
    await generate({ input: path.join(dir, "doc.md"), output: path.join(dir, "out.pdf"), quiet: true, allowNetwork });
    return fs.readFileSync(log, "utf8").split("\n").filter((l) => l.startsWith("load-html "));
  }

  test("the render tab and the print page both load with --offline", async () => {
    const lines = await loads(false);
    // One for the diagram bundle, one for the page that is printed.
    expect(lines.length).toBe(2);
    for (const line of lines) expect(line.split(" ")).toContain("--offline");
  });

  test("every loaded page leads with the no-network policy and keeps no <link> hint", async () => {
    await loads(false);
    const loaded = fs.readdirSync(pages).sort((a, b) => parseInt(a, 10) - parseInt(b, 10)).map((f) => {
      const raw = fs.readFileSync(path.join(pages, f), "utf8");
      return f.endsWith(".json") ? (JSON.parse(raw) as { html: string }).html : raw;
    });
    expect(loaded.length).toBe(2);
    // Only a charset declaration may precede the policy in <head>. The render
    // tab runs the diagram bundle's own scripts; the print page runs none.
    const headBeforePolicy = (page: string, policy: string): string | null => {
      const head = page.split(/<head\b[^>]*>/i)[1] ?? "";
      const at = head.indexOf(`<meta http-equiv="Content-Security-Policy" content="${policy}">`);
      return at === -1 ? null : head.slice(0, at);
    };
    expect(headBeforePolicy(loaded[0], OFFLINE_SCRIPT_PAGE_POLICY)).toMatch(/^\s*(<meta charset="[^"]*">\s*)?$/i);
    expect(headBeforePolicy(loaded[1], OFFLINE_PAGE_POLICY)).toMatch(/^\s*(<meta charset="[^"]*">\s*)?$/i);
    for (const page of loaded) {
      expect(page).not.toMatch(/<link\b/i);
      expect(page).not.toMatch(/prefetch\.invalid|preconnect\.invalid|rebuilt\.invalid/);
    }
  });

  test("--allow-network loads them without it", async () => {
    const lines = await loads(true);
    expect(lines.length).toBe(2);
    for (const line of lines) expect(line.split(" ")).not.toContain("--offline");
  });
});
