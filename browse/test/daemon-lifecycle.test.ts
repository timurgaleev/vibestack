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
  let orphans: number[];

  beforeEach(() => {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-daemon-lifecycle-'));
    holders = [];
    orphans = [];
  });

  afterEach(async () => {
    for (const child of holders) child.kill('SIGKILL');
    await Promise.all(holders.map(child => child.exited));
    for (const pid of orphans) { try { process.kill(pid, 'SIGKILL'); } catch {} }
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

  /** A browser-shaped process on `profile` whose parent is this test (alive). */
  function spawnBrowser(profile: string) {
    const child = Bun.spawn(['bash', '-c', `sleep 60; : --user-data-dir=${profile}`], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    holders.push(child);
    return child;
  }

  /** The same, re-parented: its launcher exited, as when a daemon dies under its Chromium. */
  async function spawnOrphanBrowser(profile: string): Promise<number> {
    const launcher = Bun.spawn(['bash', '-c', `bash -c 'sleep 60; : --user-data-dir=${profile}' >/dev/null 2>&1 & echo $!`], { stdout: 'pipe', stderr: 'ignore' });
    const pid = parseInt((await new Response(launcher.stdout).text()).trim(), 10);
    await launcher.exited;
    orphans.push(pid);
    return pid;
  }

  function lockGone(profile: string): boolean {
    try { fs.lstatSync(path.join(profile, 'SingletonLock')); return false; } catch { return true; }
  }

  test('a headed start reaps a verified orphan holding the lock and clears the locks', async () => {
    const profile = profileOwnedBy(0);
    fs.unlinkSync(path.join(profile, 'SingletonLock'));
    const orphan = await spawnOrphanBrowser(profile);
    fs.symlinkSync(`${os.hostname()}-${orphan}`, path.join(profile, 'SingletonLock'));
    await prepareChromiumProfile(true, profile);
    for (let i = 0; i < 40 && isProcessAlive(orphan); i++) await Bun.sleep(50);
    expect(isProcessAlive(orphan)).toBe(false);
    expect(fs.existsSync(path.join(profile, 'SingletonCookie'))).toBe(false);
    expect(lockGone(profile)).toBe(true);
  });

  test("a headed start refuses another project's live browser: nothing killed, no lock removed", async () => {
    const profile = path.join(scratch, 'chromium-profile');
    const browser = spawnBrowser(profile);
    const locked = profileOwnedBy(browser.pid);
    await expect(prepareChromiumProfile(true, locked)).rejects.toThrow(/in use by a live browser.*Nothing was killed or removed/);
    expect(isProcessAlive(browser.pid)).toBe(true);
    expect(lockGone(locked)).toBe(false);
    expect(fs.existsSync(path.join(locked, 'SingletonCookie'))).toBe(true);
  });

  test('the browser of the daemon this CLI just stopped counts as ours', async () => {
    const profile = path.join(scratch, 'chromium-profile');
    const browser = spawnBrowser(profile);
    const locked = profileOwnedBy(browser.pid);
    await prepareChromiumProfile(true, locked, process.pid);
    await browser.exited;
    expect(isProcessAlive(browser.pid)).toBe(false);
    expect(lockGone(locked)).toBe(true);
  });

  test('a lock naming a reused PID is stale: the lock goes, the process stays', async () => {
    const unrelated = spawnHolder();
    const profile = profileOwnedBy(unrelated.pid);
    await prepareChromiumProfile(true, profile);
    expect(isProcessAlive(unrelated.pid)).toBe(true);
    expect(lockGone(profile)).toBe(true);
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
