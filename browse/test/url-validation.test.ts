import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import { chromium, type Browser } from 'playwright';
import { blockedNavigationReason, classifyAddress, validateNavigationUrl } from '../src/url-validation';
import { BrowserManager } from '../src/browser-manager';
import { handleMetaCommand } from '../src/meta-commands';
import { META_COMMANDS, META_COMMANDS_WITHOUT_PAGE } from '../src/commands';

describe('classifyAddress', () => {
  test.each([
    '169.254.169.254',
    '169.254.170.2',        // container credential endpoint
    '169.254.0.1',
    '100.100.100.200',      // instance metadata on another cloud
    'fe80::1',
    'fe80::abcd:1',
    'fd00::1',
    'fc00::1',
    '::ffff:169.254.170.2', // IPv4-mapped
    '::ffff:a9fe:aa02',     // IPv4-mapped, hex spelling
    '::a9fe:a9fe',          // IPv4-compatible
    '64:ff9b::a9fe:a9fe',   // NAT64
    '[fe80::1]',
    '0xA9FEAA02',           // hex IPv4
    '2852039166',           // decimal IPv4
    '0251.0376.0251.0376',  // octal IPv4
  ])('%s is blocked', (host) => {
    expect(classifyAddress(host)).toBe('blocked');
  });

  test.each(['127.0.0.1', '::1'])('%s is loopback', (host) => {
    expect(classifyAddress(host)).toBe('loopback');
  });

  test.each(['10.0.0.5', '192.168.1.1', '172.16.0.1', '8.8.8.8', '2001:db8::1'])('%s is other', (host) => {
    expect(classifyAddress(host)).toBe('other');
  });

  test('hostnames are not addresses', () => {
    expect(classifyAddress('fd.example.com')).toBeNull();
    expect(classifyAddress('fcustomer.com')).toBeNull();
  });
});

describe('blockedNavigationReason', () => {
  test('blocks the whole link-local range, not only one metadata IP', async () => {
    expect(await blockedNavigationReason('http://169.254.170.2/v2/credentials')).toMatch(/Blocked/);
    expect(await blockedNavigationReason('http://100.100.100.200/latest/meta-data')).toMatch(/Blocked/);
    expect(await blockedNavigationReason('http://metadata.google.internal/')).toMatch(/Blocked/);
    expect(await blockedNavigationReason('http://[::ffff:169.254.169.254]/')).toMatch(/Blocked/);
  });

  test('allows local dev servers and non-http schemes', async () => {
    expect(await blockedNavigationReason('http://localhost:3000/')).toBeNull();
    expect(await blockedNavigationReason('http://127.0.0.1:8080/')).toBeNull();
    expect(await blockedNavigationReason('http://192.168.1.20/')).toBeNull();
    expect(await blockedNavigationReason('about:blank')).toBeNull();
  });
});

describe('blockedNavigationReason name resolution', () => {
  const noDns = () => Promise.reject(Object.assign(new Error('ENOTFOUND'), { code: 'ENOTFOUND' }));
  const stub = (lookupAnswer: string[]) => ({
    resolve4: noDns,
    resolve6: noDns,
    lookup: async () => lookupAnswer.map(address => ({ address, family: address.includes(':') ? 6 : 4 })),
  });

  test('a name only the system resolver knows (/etc/hosts, search domain) is checked too', async () => {
    expect(await blockedNavigationReason('http://internal-svc.example.invalid/', stub(['169.254.169.254']))).toMatch(/resolves to/);
    expect(await blockedNavigationReason('http://v6-only.example.invalid/', stub(['10.0.0.5', 'fe80::1']))).toMatch(/resolves to/);
  });

  test('an allowed system-resolver answer stays allowed', async () => {
    expect(await blockedNavigationReason('http://dev.example.invalid/', stub(['10.0.0.5']))).toBeNull();
  });

  test('the bare metadata name is blocked without any lookup', async () => {
    expect(await blockedNavigationReason('http://metadata/computeMetadata/v1/', stub([]))).toMatch(/Blocked/);
  });
});

describe('validateNavigationUrl', () => {
  test('rejects explicit navigation to a credential endpoint', async () => {
    await expect(validateNavigationUrl('http://169.254.170.2/v2/credentials')).rejects.toThrow(/Blocked/);
    await expect(validateNavigationUrl('http://[fd12::1]/')).rejects.toThrow(/Blocked/);
  });

  test('passes ordinary URLs through unchanged', async () => {
    expect(await validateNavigationUrl('http://localhost:3000/a?b=c')).toBe('http://localhost:3000/a?b=c');
  });
});

// Redirect hops and page-driven navigations never pass through
// validateNavigationUrl; the browser-level guard has to catch them.
const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
describe.skipIf(!chromiumPath || !fs.existsSync(chromiumPath))('navigation guard (real Chromium)', () => {
  let browser: Browser;
  let server: ReturnType<typeof Bun.serve>;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    server = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch(req) {
        const { pathname } = new URL(req.url);
        if (pathname === '/redirect') {
          return new Response(null, { status: 302, headers: { Location: 'http://169.254.170.2/v2/credentials' } });
        }
        if (pathname === '/timer-nav') {
          return new Response('<script>setTimeout(() => { location.href = "http://169.254.169.254/latest/meta-data/"; }, 100);</script>', {
            headers: { 'Content-Type': 'text/html' },
          });
        }
        if (pathname === '/script-nav') {
          return new Response('<script>location.href = "http://169.254.169.254/latest/meta-data/";</script>', {
            headers: { 'Content-Type': 'text/html' },
          });
        }
        return new Response('<p>ok</p>', { headers: { 'Content-Type': 'text/html' } });
      },
    });
  });

  afterAll(async () => {
    server?.stop(true);
    await browser?.close();
  });

  async function guardedPage() {
    const page = await browser.newPage();
    const bm = new BrowserManager();
    (bm as any).wirePageEvents(page);
    return { page, bm };
  }

  test('a 302 to a credential endpoint is blocked and the tab is blanked', async () => {
    const { page, bm } = await guardedPage();
    const work = page.goto(`http://127.0.0.1:${server.port}/redirect`, { timeout: 10_000 });
    await expect(bm.failIfNavigationBlocked(page, work)).rejects.toThrow(/169\.254\.170\.2/);
    expect(page.url()).toBe('about:blank');
    await page.close();
  }, 30_000);

  test('a page-driven navigation to the metadata IP is blocked', async () => {
    const { page, bm } = await guardedPage();
    const work = page.goto(`http://127.0.0.1:${server.port}/script-nav`, { timeout: 10_000 })
      .then(() => page.waitForTimeout(1_500));
    await expect(bm.failIfNavigationBlocked(page, work)).rejects.toThrow(/169\.254\.169\.254/);
    expect(page.url()).toBe('about:blank');
    await page.close();
  }, 30_000);

  test('a capture waits out a navigation the page started while idle', async () => {
    const { page, bm } = await guardedPage();
    await bm.failIfNavigationBlocked(page, page.goto(`http://127.0.0.1:${server.port}/timer-nav`, { timeout: 10_000 }));
    // Catch the guard mid-check: the request has fired, the tab is not blank yet.
    const guard = (bm as any).navigationGuards.get(page);
    for (let i = 0; i < 200 && guard.pending.size === 0; i++) await new Promise((r) => setTimeout(r, 5));
    expect(guard.pending.size).toBeGreaterThan(0);
    await bm.settleNavigationGuard(page);
    expect(page.url()).toBe('about:blank');
    // The next command reports the block, and says it may be older than itself.
    await expect(bm.failIfNavigationBlocked(page, Promise.resolve('ok'))).rejects.toThrow(/possibly before this command/);
    await page.close();
  }, 30_000);

  test('an allowed navigation is untouched', async () => {
    const { page, bm } = await guardedPage();
    await bm.failIfNavigationBlocked(page, page.goto(`http://127.0.0.1:${server.port}/ok`));
    expect(page.url()).toBe(`http://127.0.0.1:${server.port}/ok`);
    await page.close();
  }, 30_000);
});

describe('navigation guard waits are bounded', () => {
  function guardWith(mainFrame: boolean) {
    const bm = new BrowserManager();
    bm.navigationGuardTimeoutMs = 200;
    const page = {} as any;
    const never = new Promise<void>(() => {});
    const guard = (bm as any).navigationGuards;
    guard.set(page, { pending: new Set([never]), mainFrame: new Set(mainFrame ? [never] : []), blocked: null });
    return { bm, page };
  }

  test('a frame check that never settles does not hang the command', async () => {
    const { bm, page } = guardWith(false);
    expect(await bm.failIfNavigationBlocked(page, Promise.resolve('done'))).toBe('done');
    await bm.settleNavigationGuard(page);
  }, 5_000);

  test('a main-frame check that never settles fails closed', async () => {
    const { bm, page } = guardWith(true);
    await expect(bm.failIfNavigationBlocked(page, Promise.resolve('page text'))).rejects.toThrow(/did not finish/);
    await expect(bm.settleNavigationGuard(page)).rejects.toThrow(/did not finish/);
  }, 5_000);
});

describe('meta commands run under the navigation guard', () => {
  test('every page-touching meta command is guarded', () => {
    for (const cmd of ['diff', 'cdp', 'ux-audit', 'tab-each', 'newtab', 'state', 'frame', 'chain']) {
      expect(META_COMMANDS.has(cmd)).toBe(true);
      expect(META_COMMANDS_WITHOUT_PAGE.has(cmd)).toBe(false);
    }
    const server = fs.readFileSync(new URL('../src/server.ts', import.meta.url), 'utf-8');
    expect(server).toMatch(/else if \(!META_COMMANDS_WITHOUT_PAGE\.has\(command\)\) \{[\s\S]{0,300}?failIfNavigationBlocked\(session\.getPage\(\), runMeta\(\)\)/);
  });
});

// A redirect to a blocked name that actually answers: the metadata host is
// mapped onto the local test server, so a read before the guard settles would
// return its body.
describe.skipIf(!chromiumPath || !fs.existsSync(chromiumPath))('diff and blocked redirects (real Chromium)', () => {
  let browser: Browser;
  let server: ReturnType<typeof Bun.serve>;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true, args: ['--host-resolver-rules=MAP metadata.google.internal 127.0.0.1'] });
    server = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch(req) {
        const { pathname, hostname } = new URL(req.url);
        if (hostname === 'metadata.google.internal') {
          return new Response('<p>METADATA-SECRET-TOKEN</p>', { headers: { 'Content-Type': 'text/html' } });
        }
        if (pathname === '/to-metadata') {
          return new Response(null, { status: 302, headers: { Location: `http://metadata.google.internal:${server.port}/computeMetadata/v1/` } });
        }
        return new Response('<p>public page</p>', { headers: { 'Content-Type': 'text/html' } });
      },
    });
  });

  afterAll(async () => {
    server?.stop(true);
    await browser?.close();
  });

  for (const which of ['first', 'second'] as const) {
    test(`diff refuses when the ${which} URL redirects to a blocked host, never returning its body`, async () => {
      const page = await browser.newPage();
      const bm = new BrowserManager();
      (bm as any).wirePageEvents(page);
      const session = { page, getPage: () => page };
      (bm as any).getActiveSession = () => session;
      (bm as any).getPage = () => page;
      const ok = `http://127.0.0.1:${server.port}/ok`;
      const bad = `http://127.0.0.1:${server.port}/to-metadata`;
      const args = which === 'first' ? [bad, ok] : [ok, bad];
      const out = await handleMetaCommand('diff', args, bm, () => {}).then((r) => r, (e: Error) => `ERROR ${e.message}`);
      expect(out).not.toContain('METADATA-SECRET-TOKEN');
      expect(out).toMatch(/^ERROR Blocked: metadata\.google\.internal/);
      await page.close();
    }, 30_000);
  }
});

