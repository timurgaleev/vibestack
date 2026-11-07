import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { chromium } from 'playwright';

// Drives a real daemon over HTTP, the way the CLI and parallel agents do.

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
const hasChromium = !!chromiumPath && fs.existsSync(chromiumPath) && process.platform !== 'win32';

const SERVER = path.resolve(import.meta.dir, '../src/server.ts');

/** The Playwright cache holding chromium-<rev>/, found from the binary's path. */
function browserCache(): string {
  let dir = chromiumPath;
  while (dir !== path.dirname(dir) && !/^chromium-\d+$/.test(path.basename(dir))) dir = path.dirname(dir);
  return path.dirname(dir);
}
const TOKEN = 'daemon-tabs-root-token-0123456789';

describe.skipIf(!hasChromium)('daemon tabs (real daemon)', () => {
  let scratch: string;
  let daemon: ReturnType<typeof Bun.spawn>;
  let port: number;
  let site: ReturnType<typeof Bun.serve>;

  beforeAll(async () => {
    site = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch(req) {
        const { pathname } = new URL(req.url);
        const body = pathname === '/busy'
          ? '<title>busy</title><script>setTimeout(() => { for (;;) {} }, 100);</script>'
          : `<title>${pathname.slice(1)}</title><p>${pathname}</p>`;
        return new Response(body, { headers: { 'Content-Type': 'text/html' } });
      },
    });

    scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-daemon-tabs-')));
    const stateFile = path.join(scratch, 'state', 'browse.json');
    daemon = Bun.spawn(['bun', 'run', SERVER], {
      env: {
        ...process.env,
        HOME: scratch,
        VIBESTACK_HOME: path.join(scratch, 'vs-home'),
        // A scratch HOME would otherwise point Playwright at an empty cache.
        PLAYWRIGHT_BROWSERS_PATH: process.env.PLAYWRIGHT_BROWSERS_PATH || browserCache(),
        AUTH_TOKEN: TOKEN,
        BROWSE_STATE_FILE: stateFile,
        BROWSE_PARENT_PID: '0',
        BROWSE_IDLE_TIMEOUT: '600000',
      },
      stdin: 'ignore', stdout: 'ignore', stderr: 'ignore',
    });
    for (let i = 0; i < 200 && !fs.existsSync(stateFile); i++) await Bun.sleep(100);
    port = JSON.parse(fs.readFileSync(stateFile, 'utf-8')).port;
  }, 60_000);

  afterAll(async () => {
    await run('stop').catch(() => {});
    await Promise.race([daemon.exited, Bun.sleep(5_000)]);
    daemon.kill('SIGKILL');
    site?.stop(true);
    fs.rmSync(scratch, { recursive: true, force: true });
  }, 20_000);

  async function run(command: string, args: string[] = [], tabId?: number): Promise<{ status: number; text: string }> {
    const res = await fetch(`http://127.0.0.1:${port}/command`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ command, args, ...(tabId === undefined ? {} : { tabId }) }),
      signal: AbortSignal.timeout(15_000),
    });
    return { status: res.status, text: await res.text() };
  }

  async function newTab(pathname: string): Promise<number> {
    const r = await run('newtab', [`http://127.0.0.1:${site.port}${pathname}`, '--json']);
    expect(r.status).toBe(200);
    return JSON.parse(r.text).tabId;
  }

  test('a headless daemon never hands its token to /health callers', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/health`, {
      headers: { Origin: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop' },
    });
    const health = await res.json() as any;
    expect(health.mode).toBe('launched');
    expect(health.token).toBeUndefined();
  }, 15_000);

  test('a busy tab leaves /health and status answering, and names the stuck tab', async () => {
    const busy = await newTab('/busy');
    try {
    await Bun.sleep(400);

    const started = Date.now();
    const res = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(5_000) });
    const health = await res.json() as any;
    // The CLI gives /health 2 s; the answer has to arrive well inside that.
    expect(Date.now() - started).toBeLessThan(1_800);
    expect(health.status).toBe('healthy');
    expect(health.activeTab).toEqual({ id: busy, url: `http://127.0.0.1:${site.port}/busy`, responsive: false });

    const status = await run('status');
    expect(status.status).toBe(200);
    expect(status.text).toContain(`Active tab [${busy}] is not responding`);
    } finally {
      expect((await run('closetab', [String(busy)])).status).toBe(200);
    }
  }, 30_000);

  test('two pinned requests leave the shared active tab alone', async () => {
    const a = await newTab('/a');
    const b = await newTab('/b');
    const c = await newTab('/c');
    expect((await run('url')).text).toContain('/c');

    const slow = (ms: number) => [`new Promise(r => setTimeout(() => r(location.pathname), ${ms}))`];
    const first = run('js', slow(300), a);
    await Bun.sleep(50);
    const second = run('js', slow(700), b);
    await Bun.sleep(100);
    const unpinned = await run('url');

    expect((await first).text).toContain('/a');
    expect((await second).text).toContain('/b');
    expect(unpinned.text).toContain('/c');
    expect((await run('url')).text).toContain('/c');
  }, 30_000);

  test('tab-each leaves the shared active tab alone while it runs', async () => {
    const a = await newTab('/ea');
    const b = await newTab('/eb');
    const c = await newTab('/ec');
    try {
      expect((await run('url')).text).toContain('/ec');
      const each = run('tab-each', ['js', 'new Promise(r => setTimeout(() => r(location.pathname), 400))']);
      await Bun.sleep(150);
      // An unpinned request in the middle of the fan-out still sees the tab
      // the user left active, not the one tab-each is visiting.
      const mid = await run('url');
      expect((await each).status).toBe(200);
      expect(mid.text).toContain('/ec');
      expect((await run('url')).text).toContain('/ec');
    } finally {
      for (const id of [a, b, c]) await run('closetab', [String(id)]);
    }
  }, 60_000);

  test('after every tab is closed outside browse, status and goto recover', async () => {
    const tabs = (await run('tabs')).text;
    const ids = [...tabs.matchAll(/\[(\d+)\]/g)].map(m => Number(m[1]));
    const blank = JSON.parse((await run('newtab', ['--json'])).text).tabId;
    for (const id of ids) expect((await run('closetab', [String(id)])).status).toBe(200);
    // window.close() from the page itself: browse never hears about it until
    // the tab is gone.
    await run('js', ['window.close()'], blank);
    for (let i = 0; i < 50 && (await tabCount()) > 0; i++) await Bun.sleep(100);
    expect(await tabCount()).toBe(0);

    const status = await run('status');
    expect(status.status).toBe(200);
    expect(status.text).toContain('Status: healthy');
    expect(status.text).toContain('opened a blank tab');

    const goto = await run('goto', [`http://127.0.0.1:${site.port}/back`]);
    expect(goto.status).toBe(200);
    expect((await run('url')).text).toContain('/back');
  }, 30_000);

  async function tabCount(): Promise<number> {
    const health = await (await fetch(`http://127.0.0.1:${port}/health`)).json() as any;
    return health.tabs;
  }
});
