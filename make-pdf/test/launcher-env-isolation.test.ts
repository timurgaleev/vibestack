/**
 * The launcher and the CLI shebang run make-pdf on bun from whatever directory
 * the user is in. Bun reads that directory's bunfig.toml (whose `preload`
 * runs arbitrary code) and .env by default, so both must start bun with
 * --no-env-file --config=/dev/null. Below the install's bun floor the
 * launcher must refuse rather than fall back to an unflagged run.
 */

import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const REPO = path.resolve(import.meta.dir, "../..");
const LAUNCHER = path.join(REPO, "skills/make-pdf/bin/vibe-make-pdf");
const CLI = path.join(REPO, "make-pdf/src/cli.ts");
const BUN_DIR = path.dirname(process.execPath);

const scratch: string[] = [];
function tmp(prefix: string): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  scratch.push(d);
  return d;
}
afterAll(() => {
  for (const d of scratch) fs.rmSync(d, { recursive: true, force: true });
});

/** A repo layout with the launcher and the CLI sources but no compiled binary. */
function sourceOnlyRepo(): { launcher: string } {
  const root = tmp("mkpdf-repo-");
  fs.mkdirSync(path.join(root, "skills/make-pdf/bin"), { recursive: true });
  fs.mkdirSync(path.join(root, "make-pdf"), { recursive: true });
  const launcher = path.join(root, "skills/make-pdf/bin/vibe-make-pdf");
  fs.copyFileSync(LAUNCHER, launcher);
  fs.chmodSync(launcher, 0o755);
  fs.symlinkSync(path.join(REPO, "make-pdf/src"), path.join(root, "make-pdf/src"));
  return { launcher };
}

/** A directory whose bunfig.toml preload drops a marker file when it runs. */
function hostileCwd(): { dir: string; marker: string } {
  const dir = tmp("mkpdf-hostile-");
  const marker = path.join(dir, "PRELOAD_RAN");
  fs.writeFileSync(path.join(dir, "bunfig.toml"), `preload = ["./evil.ts"]\n`);
  fs.writeFileSync(path.join(dir, "evil.ts"), `require("node:fs").writeFileSync(${JSON.stringify(marker)}, "x");\n`);
  fs.writeFileSync(path.join(dir, ".env"), "MAKE_PDF_HOSTILE=1\n");
  return { dir, marker };
}

describe("make-pdf bun environment isolation", () => {
  test("launcher's bun fallback ignores a hostile bunfig.toml preload", () => {
    const { launcher } = sourceOnlyRepo();
    const { dir, marker } = hostileCwd();
    const r = spawnSync("bash", [launcher, "version"], {
      cwd: dir,
      env: { PATH: `${BUN_DIR}:/usr/bin:/bin`, HOME: dir },
      encoding: "utf8",
      timeout: 30_000,
    });
    expect(r.stderr).not.toContain("MAKE_PDF_NOT_AVAILABLE");
    expect(r.status).toBe(0);
    expect(fs.existsSync(marker)).toBe(false);
  });

  test("cli.ts shebang ignores a hostile bunfig.toml preload", () => {
    const shebang = fs.readFileSync(CLI, "utf8").split("\n")[0];
    const m = shebang.match(/^#!\/usr\/bin\/env -S (.+)$/);
    expect(m).not.toBeNull();
    const [cmd, ...args] = m![1].trim().split(/\s+/);
    expect(cmd).toBe("bun");
    const { dir, marker } = hostileCwd();
    const r = spawnSync(process.execPath, [...args, CLI, "version"], {
      cwd: dir,
      env: { PATH: `${BUN_DIR}:/usr/bin:/bin`, HOME: dir },
      encoding: "utf8",
      timeout: 30_000,
    });
    expect(r.status).toBe(0);
    expect(fs.existsSync(marker)).toBe(false);
  });

  test("below the bun floor the launcher refuses instead of running unflagged", () => {
    const { launcher } = sourceOnlyRepo();
    const fakeBin = tmp("mkpdf-oldbun-");
    const ran = path.join(fakeBin, "BUN_RAN");
    fs.writeFileSync(
      path.join(fakeBin, "bun"),
      `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.2.0; exit 0; fi\necho ran > ${JSON.stringify(ran)}\n`,
    );
    fs.chmodSync(path.join(fakeBin, "bun"), 0o755);
    const r = spawnSync("bash", [launcher, "version"], {
      cwd: fakeBin,
      env: { PATH: `${fakeBin}:/usr/bin:/bin`, HOME: fakeBin },
      encoding: "utf8",
      timeout: 30_000,
    });
    expect(r.stderr).toContain("MAKE_PDF_NOT_AVAILABLE");
    expect(r.status).toBe(4);
    expect(fs.existsSync(ran)).toBe(false);
  });

  test("the launcher's bun floor matches the installer's", () => {
    const floorOf = (file: string) =>
      fs.readFileSync(file, "utf8").match(/^VIBE_BUN_FLOOR="([0-9.]+)"/m)?.[1];
    const installFloor = floorOf(path.join(REPO, "install"));
    expect(installFloor).toBeDefined();
    expect(floorOf(LAUNCHER)).toBe(installFloor);
  });
});
