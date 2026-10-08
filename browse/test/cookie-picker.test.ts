import { afterEach, beforeAll, describe, expect, mock, setSystemTime, test } from 'bun:test';

// The picker's decrypt path reads real browser databases; stand it in with a
// fixed result so the route logic can be exercised on its own. The rest of the
// module stays real: bun shares mocked modules across test files.
const realImport = await import('../src/cookie-import-browser');
mock.module('../src/cookie-import-browser', () => ({
  ...realImport,
  findInstalledBrowsers: () => [{ name: 'Chrome', aliases: ['chrome'] }],
  hasV20Cookies: () => false,
  importCookies: async (_browser: string, domains: string[]) => ({
    cookies: domains.map(domain => ({ name: 'sid', value: 'secret', domain, path: '/' })),
    count: domains.length,
    failed: 0,
    domainCounts: Object.fromEntries(domains.map(domain => [domain, 1])),
  }),
}));

const { handleCookiePickerRoute, generatePickerCode } = await import('../src/cookie-picker-routes');
const { BrowserManager } = await import('../src/browser-manager');

const ORIGIN = 'http://127.0.0.1:9555';
const ROOT_TOKEN = 'root-token-for-picker-tests';

function fakeBrowserManager() {
  const bm = new BrowserManager();
  const added: any[] = [];
  const context = {
    addCookies: async (cookies: any[]) => { added.push(...cookies); },
    clearCookies: async () => {},
  };
  (bm as any).getActiveSession = () => ({ getPage: () => ({ context: () => context }) });
  return { bm, added };
}

async function route(bm: any, pathAndQuery: string, init: RequestInit = {}) {
  const url = new URL(ORIGIN + pathAndQuery);
  return handleCookiePickerRoute(url, new Request(url, init), bm, ROOT_TOKEN);
}

/** Exchange a fresh code for a session; return its cookie and bound instance id. */
async function openPicker(bm: any): Promise<{ cookie: string; instance: string }> {
  const code = generatePickerCode();
  const exchange = await route(bm, `/cookie-picker?code=${code}`);
  expect(exchange.status).toBe(302);
  const cookie = (exchange.headers.get('set-cookie') || '').split(';')[0];
  const page = await route(bm, '/cookie-picker', { headers: { cookie } });
  expect(page.status).toBe(200);
  const html = await page.text();
  const instance = /const PICKER_INSTANCE = "([^"]+)";/.exec(html)?.[1];
  expect(instance).toBeTruthy();
  return { cookie, instance: instance! };
}

function importRequest(cookie: string, headers: Record<string, string> = {}): RequestInit {
  return {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', cookie, ...headers },
    body: JSON.stringify({ browser: 'chrome', domains: ['.example.com'] }),
  };
}

describe('cookie picker routes', () => {
  afterEach(() => setSystemTime());

  test('a picker import registers its domains with the cross-origin JS guard', async () => {
    const { bm, added } = fakeBrowserManager();
    expect(bm.hasCookieImports()).toBe(false);
    const { cookie, instance } = await openPicker(bm);
    const res = await route(bm, '/cookie-picker/import', importRequest(cookie, {
      Origin: ORIGIN,
      'X-Vibestack-Picker-Instance': instance,
    }));
    expect(res.status).toBe(200);
    expect(added.length).toBe(1);
    expect(bm.hasCookieImports()).toBe(true);
    expect([...bm.getCookieImportedDomains()]).toContain('.example.com');
  });

  test('a cookie-authenticated POST from another local origin is refused', async () => {
    const { bm, added } = fakeBrowserManager();
    const { cookie, instance } = await openPicker(bm);
    const res = await route(bm, '/cookie-picker/import', importRequest(cookie, {
      Origin: 'http://127.0.0.1:5173',
      'X-Vibestack-Picker-Instance': instance,
    }));
    expect(res.status).toBe(403);
    expect((await res.json()).code).toBe('invalid_origin');
    expect(added.length).toBe(0);
  });

  test('a cookie-authenticated POST without an Origin header is refused', async () => {
    const { bm } = fakeBrowserManager();
    const { cookie, instance } = await openPicker(bm);
    const res = await route(bm, '/cookie-picker/import', importRequest(cookie, {
      'X-Vibestack-Picker-Instance': instance,
    }));
    expect(res.status).toBe(403);
  });

  test('the bearer token path needs no Origin or instance header', async () => {
    const { bm } = fakeBrowserManager();
    const res = await route(bm, '/cookie-picker/import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ROOT_TOKEN}` },
      body: JSON.stringify({ browser: 'chrome', domains: ['.example.com'] }),
    });
    expect(res.status).toBe(200);
  });

  test('an older picker window fails closed once a new picker is opened', async () => {
    const { bm } = fakeBrowserManager();
    const first = await openPicker(bm);
    const second = await openPicker(bm);
    // The browser now holds the second session's cookie; the first window
    // still sends its own instance id.
    const stale = await route(bm, '/cookie-picker/imported', {
      headers: { cookie: second.cookie, 'X-Vibestack-Picker-Instance': first.instance },
    });
    expect(stale.status).toBe(403);
    expect((await stale.json()).code).toBe('picker_changed');
    const fresh = await route(bm, '/cookie-picker/imported', {
      headers: { cookie: second.cookie, 'X-Vibestack-Picker-Instance': second.instance },
    });
    expect(fresh.status).toBe(200);
  });

  test('a handoff code is still valid after a minute, and expired after five', async () => {
    const { bm } = fakeBrowserManager();
    const start = Date.now();
    const code = generatePickerCode();
    setSystemTime(new Date(start + 60_000));
    expect((await route(bm, `/cookie-picker?code=${code}`)).status).toBe(302);

    setSystemTime(new Date(start));
    const late = generatePickerCode();
    setSystemTime(new Date(start + 5 * 60_000 + 1_000));
    expect((await route(bm, `/cookie-picker?code=${late}`)).status).toBe(403);
  });
});
