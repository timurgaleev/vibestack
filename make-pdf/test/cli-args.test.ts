/**
 * CLI argument parsing: boolean flags never swallow a positional, and a flag
 * the command does not declare fails the run with exit 1 instead of being
 * silently taken as a value flag (`--output out.pdf` used to land the PDF in
 * the default /tmp path).
 */

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { BOOLEAN_FLAGS, parseArgs, unknownFlags } from "../src/cli";
import { COMMANDS } from "../src/commands";
import { ExitCode } from "../src/types";

const CLI = path.resolve(import.meta.dir, "../src/cli.ts");
const parse = (...args: string[]) => parseArgs(["bun", "cli.ts", ...args]);

describe("boolean flags do not swallow positionals", () => {
  test("--toc before the input keeps the input positional", () => {
    const r = parse("generate", "--toc", "essay.md");
    expect(r.flags.toc).toBe(true);
    expect(r.positional).toEqual(["essay.md"]);
  });

  test("--strict before the input keeps the input positional", () => {
    const r = parse("generate", "--strict", "essay.md");
    expect(r.flags.strict).toBe(true);
    expect(r.positional).toEqual(["essay.md"]);
  });

  test("value flags still consume their value", () => {
    const r = parse("generate", "--watermark", "DRAFT", "memo.md", "memo.pdf");
    expect(r.flags.watermark).toBe("DRAFT");
    expect(r.positional).toEqual(["memo.md", "memo.pdf"]);
  });
});

describe("unknown flags", () => {
  test("--output is not a flag", () => {
    expect(unknownFlags(parse("generate", "doc.md", "--output", "out.pdf"))).toEqual(["--output"]);
  });

  test("every documented generate flag is accepted", () => {
    const r = parse(
      "generate", "doc.md", "out.pdf",
      "--to", "pdf", "--page-size", "a4", "--format", "letter", "--margins", "1in",
      "--cover", "--toc", "--no-chapter-breaks", "--watermark", "DRAFT",
      "--confidential", "--no-confidential", "--strict", "--allow-network",
      "--title", "T", "--author", "A", "--date", "D", "--quiet", "--verbose",
    );
    expect(unknownFlags(r)).toEqual([]);
  });

  test("a flag valid for generate is rejected by setup", () => {
    expect(unknownFlags(parse("setup", "--toc"))).toEqual(["--toc"]);
  });

  test("every flag cli.ts reads is declared for its command", () => {
    // Derived from the source so a newly read flag cannot ship undeclared
    // (it would then fail every run that passes it).
    const src = fs.readFileSync(CLI, "utf8");
    const section = (start: string, end: string) => src.slice(src.indexOf(start), src.indexOf(end));
    const reads = (body: string): string[] => {
      const out = new Set<string>();
      for (const m of body.matchAll(/\bf\.([a-zA-Z][\w-]*)\b/g)) out.add(m[1]);
      for (const m of body.matchAll(/\bf\["([\w-]+)"\]/g)) out.add(m[1]);
      for (const m of body.matchAll(/booleanFlag\("([\w-]+)"/g)) {
        out.add(m[1]);
        out.add(`no-${m[1]}`);
      }
      return [...out].map((k) => `--${k}`);
    };
    const gen = reads(section("function generateOptionsFromFlags", "function previewOptionsFromFlags"));
    const prev = reads(section("function previewOptionsFromFlags", "async function main"));
    expect(gen.length).toBeGreaterThan(15);
    expect(gen.filter((f) => !COMMANDS.get("generate")!.flags!.includes(f))).toEqual([]);
    expect(prev.filter((f) => !COMMANDS.get("preview")!.flags!.includes(f))).toEqual([]);
  });

  test("every boolean flag in the registry is in BOOLEAN_FLAGS", () => {
    const valueFlags = new Set([
      "--to", "--margins", "--margin-top", "--margin-right", "--margin-bottom", "--margin-left",
      "--page-size", "--format", "--watermark", "--header-template", "--footer-template",
      "--title", "--author", "--date",
    ]);
    const missing: string[] = [];
    for (const [, spec] of COMMANDS) {
      for (const flag of spec.flags ?? []) {
        if (!valueFlags.has(flag) && !BOOLEAN_FLAGS.has(flag.slice(2))) missing.push(flag);
      }
    }
    expect(missing).toEqual([]);
  });

  test("the CLI exits 1 on an unknown flag and writes nothing", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mkpdf-args-"));
    try {
      const md = path.join(dir, "doc.md");
      const out = path.join(dir, "out.pdf");
      fs.writeFileSync(md, "# Hello\n");
      const r = spawnSync(process.execPath, ["run", CLI, "generate", md, "--output", out], {
        encoding: "utf8",
        timeout: 30_000,
      });
      expect(r.status).toBe(ExitCode.BadArgs);
      expect(r.stderr).toContain("unknown flag: --output");
      expect(r.stderr).toContain("second positional");
      expect(r.stdout).toBe("");
      expect(fs.existsSync(out)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test("an --flag=value argument gets a hint to split the value off", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mkpdf-args-"));
    try {
      const md = path.join(dir, "doc.md");
      fs.writeFileSync(md, "# Hello\n");
      const r = spawnSync(process.execPath, ["run", CLI, "generate", md, "--page-size=a4"], {
        encoding: "utf8",
        timeout: 30_000,
      });
      expect(r.status).toBe(ExitCode.BadArgs);
      expect(r.stderr).toContain("unknown flag: --page-size=a4");
      expect(r.stderr).toContain("separate argument");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
