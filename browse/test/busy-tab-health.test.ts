import { afterAll, afterEach, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { chromium } from 'playwright';
import { BrowserManager } from '../src/browser-manager';

// A renderer stuck in a script must not take the daemon down with it: health,
// tab listing and state capture all stay bounded while one tab spins.

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
const hasChromium = !!chromiumPath && fs.existsSync(chromiumPath);

const BUSY_HTML = '<title>busy</title><script>setTimeout(() => { for (;;) {} }, 100);</script>';
const IDLE_HTML = '<title>idle</title><p>idle</p>';

function within<T>(ms: number, work: Promise<T>): Promise<T | 'TIMED OUT'> {
  return Promise.race([work, new Promise<'TIMED OUT'>(r => setTimeout(() => r('TIMED OUT'), ms))]);
}

describe.skipIf(!hasChromium)('a busy tab next to an idle one (real Chromium)', () => {
  let server: ReturnType<typeof Bun.serve>;
  let bm: BrowserManager;
  let busyId: number;
  let idleId: number;

  beforeAll(async () => {
    server = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch(req) {
        const html = new URL(req.url).pathname === '/busy' ? BUSY_HTML : IDLE_HTML;
        return new Response(html, { headers: { 'Content-Type': 'text/html' } });
      },
    });
    bm = new BrowserManager();
    await bm.launch();
    idleId = bm.getActiveTabId();
    await bm.getPage().goto(`http://localhost:${server.port}/idle`);
    busyId = await bm.newTab(`http://127.0.0.1:${server.port}/busy`);
    await new Promise(r => setTimeout(r, 400));
  }, 60_000);

  afterAll(async () => {
    await bm?.close();
    server?.stop(true);
  }, 15_000);

  test('the daemon stays healthy while the active tab spins', async () => {
    expect(bm.getActiveTabId()).toBe(busyId);
    const started = Date.now();
    expect(await bm.isHealthy()).toBe(true);
    expect(Date.now() - started).toBeLessThan(500);
  }, 10_000);

  test('the active-tab probe names the unresponsive tab within its bound', async () => {
    const started = Date.now();
    const probe = await bm.probeActiveTab();
    expect(Date.now() - started).toBeLessThan(1_800);
    expect(probe).toEqual({ id: busyId, url: `http://127.0.0.1:${server.port}/busy`, responsive: false });
  }, 10_000);

  test('listing tabs does not wait on the busy tab', async () => {
    const tabs = await within(3_000, bm.getTabListWithTitles());
    expect(tabs).not.toBe('TIMED OUT');
    const byId = new Map((tabs as Array<{ id: number; title: string }>).map(t => [t.id, t.title]));
    expect(byId.get(idleId)).toBe('idle');
    expect(byId.get(busyId)).toBe('');
  }, 10_000);

  test('saving state skips the busy tab storage and keeps the idle one', async () => {
    const state = await within(3_000, bm.saveState());
    expect(state).not.toBe('TIMED OUT');
    const pages = (state as Awaited<ReturnType<BrowserManager['saveState']>>).pages;
    const busy = pages.find(p => p.url.endsWith('/busy'));
    const idle = pages.find(p => p.url.endsWith('/idle'));
    expect(busy?.storage).toBeNull();
    expect(idle?.storage).not.toBeNull();
  }, 10_000);

  // Each health poll probes the active tab. A stuck renderer never answers, so
  // a fresh evaluate per poll would pile up for as long as the tab spins.
  test('repeated probes of a stuck tab share one pending evaluate', async () => {
    const page = bm.getPageForTab(busyId)!;
    const original = page.evaluate.bind(page);
    let calls = 0;
    (page as any).evaluate = (...a: Parameters<typeof page.evaluate>) => { calls++; return original(...a); };
    try {
      for (let i = 0; i < 3; i++) {
        expect((await bm.probeActiveTab())?.responsive).toBe(false);
      }
      expect(calls).toBeLessThanOrEqual(1);
    } finally {
      (page as any).evaluate = original;
    }
  }, 15_000);

  test('an idle active tab probes as responsive', async () => {
    bm.switchTab(idleId, { bringToFront: false });
    expect(await bm.probeActiveTab()).toEqual({ id: idleId, url: `http://localhost:${server.port}/idle`, responsive: true });
    bm.switchTab(busyId, { bringToFront: false });
  }, 10_000);
});

/** Chromium browser processes that are direct children of this test process. */
function browserPids(): number[] {
  const out = Bun.spawnSync(['ps', '-A', '-o', 'pid=,ppid=,command=']).stdout.toString();
  return out.split('\n').map(l => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
    .filter(m => Number(m![2]) === process.pid && /chrom/i.test(m![3]) && !/--type=/.test(m![3]))
    .map(m => Number(m![1]));
}

describe.skipIf(!hasChromium || process.platform === 'win32')('a hung browser process (real Chromium)', () => {
  let bm: BrowserManager;
  let stopped: number[] = [];

  beforeAll(async () => {
    bm = new BrowserManager();
    await bm.launch();
  }, 60_000);

  afterAll(async () => {
    for (const pid of stopped) { try { process.kill(pid, 'SIGCONT'); } catch {} }
    await bm?.close();
  }, 15_000);

  // The pipe to a stopped browser stays open, so a connection check alone
  // keeps answering healthy while every command against it would hang.
  test('reads unhealthy within the probe bound', async () => {
    expect(await bm.isHealthy()).toBe(true);
    stopped = browserPids();
    expect(stopped.length).toBe(1);
    process.kill(stopped[0], 'SIGSTOP');
    try {
      const started = Date.now();
      expect(await within(3_000, bm.isHealthy())).toBe(false);
      expect(Date.now() - started).toBeLessThan(1_800);
    } finally {
      process.kill(stopped[0], 'SIGCONT');
      stopped = [];
    }
    expect(await bm.isHealthy()).toBe(true);
  }, 20_000);

  // Closing the last tab reopens a blank one. A request that needs a tab
  // while that is under way must join it, not open a second blank tab.
  test('closing the last tab and a concurrent recovery open one blank tab', async () => {
    while (bm.getTabCount() > 1) await bm.closeTab();
    const closing = bm.closeTab();
    while (bm.getTabCount() > 0) await new Promise(r => setTimeout(r, 0));
    const [, warning] = await Promise.all([closing, bm.ensureActiveTab()]);
    expect(bm.getTabCount()).toBe(1);
    expect(warning).toBeNull();
  }, 20_000);
});

describe('handoff launches on the resolved profile and Chromium binary', () => {
  const saved = {
    HOME: process.env.HOME,
    VIBESTACK_HOME: process.env.VIBESTACK_HOME,
    VIBESTACK_CHROMIUM_PATH: process.env.VIBESTACK_CHROMIUM_PATH,
    CHROMIUM_PROFILE: process.env.CHROMIUM_PROFILE,
  };
  const realLaunch = chromium.launchPersistentContext;
  let scratch: string;

  afterEach(() => {
    (chromium as any).launchPersistentContext = realLaunch;
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test('VIBESTACK_HOME, VIBESTACK_CHROMIUM_PATH and a stale lock from a crash', async () => {
    scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-handoff-')));
    process.env.HOME = scratch;
    process.env.VIBESTACK_HOME = path.join(scratch, 'vs-home');
    process.env.VIBESTACK_CHROMIUM_PATH = path.join(scratch, 'custom-chromium');
    delete process.env.CHROMIUM_PROFILE;
    const profile = path.join(scratch, 'vs-home', 'chromium-profile');
    fs.mkdirSync(profile, { recursive: true });
    fs.symlinkSync(`${os.hostname()}-999999`, path.join(profile, 'SingletonLock'));

    let seen: { dir: string; opts: any; lockPresent: boolean } | null = null;
    (chromium as any).launchPersistentContext = async (dir: string, opts: any) => {
      let lockPresent = true;
      try { fs.lstatSync(path.join(dir, 'SingletonLock')); } catch { lockPresent = false; }
      seen = { dir, opts, lockPresent };
      throw new Error('launch intercepted');
    };

    const bm = new BrowserManager();
    (bm as any).browser = {};
    (bm as any).context = { cookies: async () => [] };
    const out = await bm.handoff('sign in');

    expect(out).toContain('launch intercepted');
    expect(seen).not.toBeNull();
    expect(seen!.dir).toBe(profile);
    expect(seen!.opts.executablePath).toBe(path.join(scratch, 'custom-chromium'));
    expect(seen!.lockPresent).toBe(false);
  });
});
