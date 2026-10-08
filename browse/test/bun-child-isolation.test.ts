import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { BUN_CHILD_FLAGS, spawnTerminalAgent } from '../src/terminal-agent-control';

const REPO = path.resolve(import.meta.dir, '../..');
const LAUNCHER = path.join(REPO, 'browse/bin/browse');
const SRC = path.join(REPO, 'browse/src');

/**
 * An untrusted clone: its .env tries to switch off the Chromium sandbox and
 * its bunfig.toml preloads code that leaves a marker file behind.
 */
function hostileRepo(root: string): { dir: string; marker: string } {
  const dir = path.join(root, 'hostile-repo');
  const marker = path.join(root, 'PRELOAD_RAN');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), 'VIBESTACK_CHROMIUM_NO_SANDBOX=1\nHOSTILE_ENV=from_repo\n');
  fs.writeFileSync(path.join(dir, 'pre.ts'), `require('fs').writeFileSync(${JSON.stringify(marker)}, 'x');\n`);
  fs.writeFileSync(path.join(dir, 'bunfig.toml'), 'preload = ["./pre.ts"]\n');
  return { dir, marker };
}

async function waitFor(file: string, ms: number): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (fs.existsSync(file)) return true;
    await Bun.sleep(50);
  }
  return fs.existsSync(file);
}

describe.skipIf(process.platform === 'win32')('bun children ignore the project .env and bunfig.toml', () => {
  let scratch: string;

  beforeEach(() => {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-bun-child-'));
  });

  afterEach(() => {
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test('the fixture is hostile: plain `bun run` loads both files', async () => {
    const { dir, marker } = hostileRepo(scratch);
    const probe = path.join(scratch, 'probe.ts');
    fs.writeFileSync(probe, 'console.log(process.env.HOSTILE_ENV ?? "unset");\n');
    const proc = Bun.spawnSync([process.execPath, 'run', probe], { cwd: dir, env: { PATH: process.env.PATH ?? '' } });
    expect(proc.stdout.toString().trim()).toBe('from_repo');
    expect(fs.existsSync(marker)).toBe(true);
  });

  test('the terminal agent spawn loads neither file', async () => {
    const { dir, marker } = hostileRepo(scratch);
    const out = path.join(scratch, 'agent-env.json');
    const agent = path.join(scratch, 'fake-agent.ts');
    fs.writeFileSync(agent, `require('fs').writeFileSync(${JSON.stringify(out)}, JSON.stringify({ env: process.env.HOSTILE_ENV ?? null, sandbox: process.env.VIBESTACK_CHROMIUM_NO_SANDBOX ?? null }));\n`);
    const stateDir = path.join(scratch, 'state');
    fs.mkdirSync(stateDir);
    const pid = spawnTerminalAgent({
      stateFile: path.join(stateDir, 'browse.json'),
      serverPort: 1,
      cwd: dir,
      scriptPath: agent,
    });
    expect(pid).toBeTruthy();
    expect(await waitFor(out, 10_000)).toBe(true);
    expect(JSON.parse(fs.readFileSync(out, 'utf-8'))).toEqual({ env: null, sandbox: null });
    expect(fs.existsSync(marker)).toBe(false);
  });

  test('the launcher loads neither file', async () => {
    if (!fs.existsSync(path.join(REPO, 'node_modules/playwright'))) return; // launcher refuses before bun runs
    const { dir, marker } = hostileRepo(scratch);
    const proc = Bun.spawnSync(['bash', LAUNCHER, '--help'], {
      cwd: dir,
      env: { PATH: process.env.PATH ?? '', HOME: scratch },
    });
    expect(proc.exitCode).toBe(0);
    expect(fs.existsSync(marker)).toBe(false);
  });

  test('every bun child spawn in the daemon source carries the flags', () => {
    expect(BUN_CHILD_FLAGS).toContain('--no-env-file');
    expect(BUN_CHILD_FLAGS.some(flag => flag.startsWith('--config='))).toBe(true);
    const offenders: string[] = [];
    for (const file of fs.readdirSync(SRC).filter(f => f.endsWith('.ts'))) {
      const lines = fs.readFileSync(path.join(SRC, file), 'utf-8').split('\n');
      lines.forEach((line, i) => {
        if (line.trim().startsWith('*') || line.trim().startsWith('//')) return;
        if (/(['"])bun\1\s*,\s*\[?\s*['"](run|test)['"]/.test(line) && !line.includes('BUN_CHILD_FLAGS')) {
          offenders.push(`${file}:${i + 1}: ${line.trim()}`);
        }
      });
    }
    expect(offenders).toEqual([]);
  });
});
