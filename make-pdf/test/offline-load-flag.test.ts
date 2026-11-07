/**
 * Without --allow-network every page make-pdf loads into the shared browse
 * daemon goes in with `load-html --offline`, so the daemon keeps that tab off
 * the network even for a navigation the page's content policy cannot stop.
 * A fake browse binary records each invocation; no Chromium is needed.
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { generate } from "../src/orchestrator";

const POSIX = process.platform !== "win32";

describe.skipIf(!POSIX)("load-html --offline from make-pdf", () => {
  let dir: string;
  let log: string;
  const saved: Record<string, string | undefined> = {};

  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "make-pdf-offline-flag-"));
    log = path.join(dir, "argv.log");
    const bin = path.join(dir, "browse");
    fs.writeFileSync(bin, [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> '${log}'`,
      `case "$1" in`,
      `  newtab) echo '{"tabId":7}' ;;`,
      `  pdf) : > "$2" ;;`,
      `  js) case "$2" in *__renderMermaid*) echo 'OK:<svg xmlns="http://www.w3.org/2000/svg"></svg>' ;; *) echo true ;; esac ;;`,
      `esac`,
      "",
    ].join("\n"), { mode: 0o755 });
    const bundle = path.join(dir, "bundle.html");
    fs.writeFileSync(bundle, `<!doctype html><html><head></head><body><div id="status">ready</div></body></html>`);
    fs.writeFileSync(path.join(dir, "doc.md"), "# T\n\n```mermaid\ngraph TD; A-->B\n```\n");
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
    await generate({ input: path.join(dir, "doc.md"), output: path.join(dir, "out.pdf"), quiet: true, allowNetwork });
    return fs.readFileSync(log, "utf8").split("\n").filter((l) => l.startsWith("load-html "));
  }

  test("the render tab and the print page both load with --offline", async () => {
    const lines = await loads(false);
    // One for the diagram bundle, one for the page that is printed.
    expect(lines.length).toBe(2);
    for (const line of lines) expect(line.split(" ")).toContain("--offline");
  });

  test("--allow-network loads them without it", async () => {
    const lines = await loads(true);
    expect(lines.length).toBe(2);
    for (const line of lines) expect(line.split(" ")).not.toContain("--offline");
  });
});
