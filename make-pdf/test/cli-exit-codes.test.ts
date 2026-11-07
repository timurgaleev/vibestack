/**
 * The exit-code contract callers script against: 0 success, 1 bad arguments
 * (unknown flag, missing input, file not found), 2 render error, 3 TOC page
 * numbers failed, 4 browse unavailable. Runs the real cli.ts in a child bun
 * with the orchestrator swapped for a stub that throws the production error
 * types, so every branch of the mapping is reached without a browser.
 */

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import * as path from "node:path";

const CLI = path.resolve(import.meta.dir, "../src/cli.ts");
const PRELOAD = path.resolve(import.meta.dir, "fixtures/exit-codes/preload.ts");
const INPUT = path.resolve(import.meta.dir, "fixtures/combined-gate.md");

function run(stub: string, ...args: string[]) {
  return spawnSync(process.execPath, ["--preload", PRELOAD, CLI, ...args], {
    env: { ...process.env, MAKE_PDF_STUB: stub },
    encoding: "utf8",
    timeout: 30_000,
  });
}

describe("make-pdf CLI exit codes", () => {
  test("0 — generate prints only the output path", () => {
    const r = run("ok", "generate", INPUT, "--quiet");
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("/stub/out.pdf\n");
  });

  test("0 — preview", () => {
    expect(run("ok", "preview", INPUT, "--quiet").status).toBe(0);
  });

  test("0 — no arguments prints usage", () => {
    expect(run("ok").status).toBe(0);
  });

  test.each([
    ["unknown flag", ["generate", INPUT, "--output", "x.pdf"]],
    ["invalid --to", ["generate", INPUT, "--to", "rtf"]],
    ["missing input", ["generate"]],
    ["unknown command", ["frobnicate"]],
  ])("1 — %s", (_name, args) => {
    const r = run("ok", ...args);
    expect(r.status).toBe(1);
    expect(r.stdout).toBe("");
  });

  test("1 — input file not found", () => {
    const r = run("enoent", "generate", INPUT);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("file not found");
  });

  test("2 — render error", () => {
    const r = run("render", "generate", INPUT);
    expect(r.status).toBe(2);
    expect(r.stdout).toBe("");
  });

  test("3 — TOC page numbers failed", () => {
    const r = run("toc", "generate", INPUT, "--toc");
    expect(r.status).toBe(3);
    expect(r.stderr).toContain("--toc");
  });

  test("4 — browse unavailable", () => {
    const r = run("browse", "generate", INPUT);
    expect(r.status).toBe(4);
  });
});
