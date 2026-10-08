import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { decideDaemonRestart, extractGlobalFlags, prepareChromiumProfile } from '../src/cli';
import { isProcessAlive } from '../src/error-handling';

const CLI = path.resolve(import.meta.dir, '../src/cli.ts');

describe('decideDaemonRestart', () => {
  test('a live daemon is never replaced without --force-restart', () => {
    expect(decideDaemonRestart({ pidAlive: true, healthyAfterProbe: true, forceRestart: false })).toBe('retry-command');
    expect(decideDaemonRestart({ pidAlive: true, healthyAfterProbe: false, forceRestart: false })).toBe('report-busy');
  });

  test('--force-restart is the only consent that replaces a live daemon', () => {
    expect(decideDaemonRestart({ pidAlive: true, healthyAfterProbe: true, forceRestart: true })).toBe('force-restart');
    expect(decideDaemonRestart({ pidAlive: true, healthyAfterProbe: false, forceRestart: true })).toBe('force-restart');
  });

  test('a dead daemon may be cleaned up and restarted', () => {
    expect(decideDaemonRestart({ pidAlive: false, healthyAfterProbe: false, forceRestart: false })).toBe('restart-dead');
  });

  test('--force-restart is a global flag, stripped from the command args', () => {
    const flags = extractGlobalFlags(['connect', '--force-restart'], {});
    expect(flags.forceRestart).toBe(true);
    expect(flags.args).toEqual(['connect']);
    expect(extractGlobalFlags(['connect'], {}).forceRestart).toBe(false);
  });
});

describe.skipIf(process.platform === 'win32')('daemon and profile ownership', () => {
  let scratch: string;
  let holders: ReturnType<typeof Bun.spawn>[];

  beforeEach(() => {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-daemon-lifecycle-'));
    holders = [];
  });

  afterEach(async () => {
    for (const child of holders) child.kill('SIGKILL');
    await Promise.all(holders.map(child => child.exited));
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  function spawnHolder() {
    const child = Bun.spawn(['sleep', '60'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    holders.push(child);
    return child;
  }

  /** A profile whose SingletonLock names a live process, as Chromium leaves it. */
  function profileOwnedBy(pid: number): string {
    const profile = path.join(scratch, 'chromium-profile');
    fs.mkdirSync(profile, { recursive: true });
    fs.symlinkSync(`${os.hostname()}-${pid}`, path.join(profile, 'SingletonLock'));
    fs.writeFileSync(path.join(profile, 'SingletonCookie'), '');
    return profile;
  }

  test('a headless start leaves a headed browser and its profile locks alone', async () => {
    const owner = spawnHolder();
    const profile = profileOwnedBy(owner.pid);
    await prepareChromiumProfile(false, profile);
    expect(isProcessAlive(owner.pid)).toBe(true);
    expect(fs.lstatSync(path.join(profile, 'SingletonLock')).isSymbolicLink()).toBe(true);
    expect(fs.existsSync(path.join(profile, 'SingletonCookie'))).toBe(true);
  });

  test('a headed start reaps the orphan holding the lock and clears the locks', async () => {
    const orphan = spawnHolder();
    const profile = profileOwnedBy(orphan.pid);
    await prepareChromiumProfile(true, profile);
    await orphan.exited;
    expect(isProcessAlive(orphan.pid)).toBe(false);
    expect(fs.existsSync(path.join(profile, 'SingletonCookie'))).toBe(false);
    expect(() => fs.lstatSync(path.join(profile, 'SingletonLock'))).toThrow();
  });

  test('connect refuses to kill a healthy live daemon without --force-restart', async () => {
    const daemon = spawnHolder();
    const health = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch: () => Response.json({ status: 'healthy' }) });
    try {
      const stateFile = path.join(scratch, '.vibestack', 'browse.json');
      fs.mkdirSync(path.dirname(stateFile), { recursive: true });
      fs.writeFileSync(stateFile, JSON.stringify({ pid: daemon.pid, port: health.port, token: 't', mode: 'launched' }));
      const proc = Bun.spawn([process.execPath, 'run', '--no-env-file', CLI, 'connect'], {
        cwd: scratch,
        env: {
          HOME: scratch,
          BROWSE_STATE_FILE: stateFile,
          // No bun on PATH: should the refusal ever regress, the replacement
          // daemon cannot launch a real browser from this test.
          PATH: '/usr/bin:/bin',
        },
        stdout: 'pipe',
        stderr: 'pipe',
      });
      const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
      expect(code).toBe(1);
      expect(stderr).toContain('--force-restart');
      expect(isProcessAlive(daemon.pid)).toBe(true);
    } finally {
      health.stop(true);
    }
  }, 30_000);
});
