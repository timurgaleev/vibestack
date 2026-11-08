import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';
import { chromium } from 'playwright';
import { COMMAND_DESCRIPTIONS } from '../src/commands';

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
const hasChromium = !!chromiumPath && fs.existsSync(chromiumPath) && process.platform !== 'win32';

const SERVER = path.resolve(import.meta.dir, '../src/server.ts');
const TOKEN = 'verb-refinements-root-token-0123456789';

function browserCache(): string {
  let dir = chromiumPath;
  while (dir !== path.dirname(dir) && !/^chromium-\d+$/.test(path.basename(dir))) dir = path.dirname(dir);
  return path.dirname(dir);
}

function daemonEnv(scratch: string, extra: Record<string, string> = {}) {
  return {
    ...process.env,
    HOME: scratch,
    VIBESTACK_HOME: path.join(scratch, 'vs-home'),
    PLAYWRIGHT_BROWSERS_PATH: process.env.PLAYWRIGHT_BROWSERS_PATH || browserCache(),
    AUTH_TOKEN: TOKEN,
    BROWSE_STATE_FILE: path.join(scratch, 'state', 'browse.json'),
    BROWSE_PARENT_PID: '0',
    BROWSE_IDLE_TIMEOUT: '600000',
    ...extra,
  };
}

const FIXTURE = `<meta name="viewport" content="width=device-width"><title>fixture</title>
<p>outside text</p>
<div id="scoped">inside <b>only</b></div>
<input id="first"><input id="second">
<button id="btn">tap me</button>
<script>
  window.touched = 0;
  document.getElementById('btn').addEventListener('touchstart', () => { window.touched++; });
  document.getElementById('first').focus();
</script>`;

test('cleanup usage advertises every category the handler accepts', () => {
  expect(COMMAND_DESCRIPTIONS.cleanup.usage).toContain('--overlays');
  expect(COMMAND_DESCRIPTIONS.cleanup.usage).toContain('--clutter');
});

describe.skipIf(!hasChromium)('verb refinements (real daemon)', () => {
  let scratch: string;
  let daemon: ReturnType<typeof Bun.spawn>;
  let port: number;
  let site: ReturnType<typeof Bun.serve>;
  let logFile: string;

  beforeAll(async () => {
    site = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch: () => new Response(FIXTURE, { headers: { 'Content-Type': 'text/html' } }),
    });
    scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-verbs-')));
    logFile = path.join(scratch, 'daemon.log');
    const env = daemonEnv(scratch);
    daemon = Bun.spawn(['bun', 'run', SERVER], { env, stdin: 'ignore', stdout: Bun.file(logFile), stderr: 'ignore' });
    for (let i = 0; i < 200 && !fs.existsSync(env.BROWSE_STATE_FILE); i++) await Bun.sleep(100);
    port = JSON.parse(fs.readFileSync(env.BROWSE_STATE_FILE, 'utf-8')).port;
  }, 60_000);

  afterAll(async () => {
    await run('stop').catch(() => {});
    await Promise.race([daemon.exited, Bun.sleep(5_000)]);
    daemon.kill('SIGKILL');
    site?.stop(true);
    fs.rmSync(scratch, { recursive: true, force: true });
  }, 20_000);

  async function run(command: string, args: string[] = []): Promise<{ status: number; text: string }> {
    const res = await fetch(`http://127.0.0.1:${port}/command`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ command, args }),
      signal: AbortSignal.timeout(20_000),
    });
    return { status: res.status, text: await res.text() };
  }

  async function js(expr: string): Promise<string> {
    const r = await run('js', [expr]);
    expect(r.status).toBe(200);
    return r.text.trim();
  }

  async function freshFixture() {
    expect((await run('goto', [`http://127.0.0.1:${site.port}/`])).status).toBe(200);
  }

  test('the daemon logs its effective proxy mode at start', () => {
    expect(fs.readFileSync(logFile, 'utf-8')).toContain('[browse] [proxy] mode: direct');
  });

  test('text <selector> returns only that element', async () => {
    await freshFixture();
    const r = await run('text', ['#scoped']);
    expect(r.status).toBe(200);
    expect(r.text).toContain('inside only');
    expect(r.text).not.toContain('outside text');
  }, 30_000);

  test('type --selector types into that field, not the focused one', async () => {
    await freshFixture();
    expect((await run('type', ['--selector', '#second', 'hello'])).status).toBe(200);
    expect(await js("document.getElementById('second').value")).toContain('hello');
    expect(await js("document.getElementById('first').value === '' ? 'empty' : 'filled'")).toContain('empty');
  }, 30_000);

  test('viewport auto returns to the default size', async () => {
    await freshFixture();
    expect((await run('viewport', ['375x812'])).status).toBe(200);
    const r = await run('viewport', ['auto']);
    expect(r.status).toBe(200);
    expect(await js('innerWidth + "x" + innerHeight')).toContain('1280x720');
  }, 30_000);

  test('tap without device emulation says how to enable it', async () => {
    await freshFixture();
    const r = await run('tap', ['#btn']);
    expect(r.status).not.toBe(200);
    expect(r.text).toContain('device');
  }, 30_000);

  test('device emulates a phone with touch, tap fires touch handlers, off restores desktop', async () => {
    const list = await run('device', ['--list']);
    expect(list.status).toBe(200);
    expect(list.text).toContain('iPhone 13');

    expect((await run('device', ['iPhone 13'])).status).toBe(200);
    await freshFixture();
    expect(await js('innerWidth')).toContain('390');
    expect(await js("matchMedia('(pointer: coarse)').matches && navigator.maxTouchPoints > 0")).toContain('true');

    const refused = await run('viewport', ['800x600']);
    expect(refused.status).not.toBe(200);
    expect(refused.text).toContain('device off');

    expect((await run('tap', ['#btn'])).status).toBe(200);
    expect((await run('tap', ['5', '5'])).status).toBe(200);
    expect(await js('window.touched')).toContain('1');

    expect((await run('device', ['off'])).status).toBe(200);
    await freshFixture();
    expect(await js('innerWidth')).toContain('1280');
    expect(await js('navigator.maxTouchPoints')).toContain('0');
  }, 60_000);
});

async function occupiedPort(): Promise<{ port: number; close: () => void }> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      resolve({ port: (srv.address() as net.AddressInfo).port, close: () => srv.close() });
    });
  });
}

describe.skipIf(!hasChromium)('daemon start order', () => {
  test('the port is picked only after Chromium launched', async () => {
    const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-order-')));
    const held = await occupiedPort();
    try {
      const logFile = path.join(scratch, 'daemon.log');
      const errFile = path.join(scratch, 'daemon.err');
      const proc = Bun.spawn(['bun', 'run', SERVER], {
        env: daemonEnv(scratch, { BROWSE_PORT: String(held.port) }),
        stdin: 'ignore', stdout: Bun.file(logFile), stderr: Bun.file(errFile),
      });
      await Promise.race([proc.exited, Bun.sleep(45_000)]);
      proc.kill('SIGKILL');
      const out = fs.readFileSync(logFile, 'utf-8');
      const err = fs.readFileSync(errFile, 'utf-8');
      expect(err).toContain(`Port ${held.port} (from BROWSE_PORT env) is in use`);
      expect(out).toContain('[browse] Launched headless Chromium');
    } finally {
      held.close();
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  }, 60_000);
});
