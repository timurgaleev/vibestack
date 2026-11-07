import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const ROOT = 'pair-revoke-root-token-0123456789';
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-pair-revoke-'));
const conn = { requestIP: () => ({ address: '127.0.0.1' }) };
let handle: any;
let registry: typeof import('../src/token-registry');

beforeAll(async () => {
  registry = await import('../src/token-registry');
  registry.__resetRegistry();
  const { buildFetchHandler } = await import('../src/server');
  const { BrowserManager } = await import('../src/browser-manager');
  const { resolveConfig } = await import('../src/config');
  handle = buildFetchHandler({
    authToken: ROOT,
    browsePort: 0,
    idleTimeoutMs: 60_000,
    config: resolveConfig({ BROWSE_STATE_FILE: path.join(scratch, 'state', 'browse.json') }),
    browserManager: new BrowserManager(),
    startTime: Date.now(),
    ownsTerminalAgent: false,
  });
});

beforeEach(() => {
  registry.__resetConnectRateLimit();
});

afterAll(() => {
  registry.__resetRegistry();
  fs.rmSync(scratch, { recursive: true, force: true });
});

function rootCall(method: string, pathname: string, body?: unknown) {
  return handle.fetchLocal(new Request(`http://127.0.0.1:9${pathname}`, {
    method,
    headers: { Authorization: `Bearer ${ROOT}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), conn);
}

async function pair(clientId: string, extra: Record<string, unknown> = {}): Promise<string> {
  const res = await rootCall('POST', '/pair', { clientId, ...extra });
  expect(res.status).toBe(200);
  return (await res.json()).setup_key;
}

function exchange(setupKey: string) {
  return handle.fetchLocal(new Request('http://127.0.0.1:9/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ setup_key: setupKey }),
  }), conn);
}

async function session(setupKey: string): Promise<string> {
  const res = await exchange(setupKey);
  expect(res.status).toBe(200);
  return (await res.json()).token;
}

/**
 * Status a remote agent's token gets on the tunnel surface. `disconnect` is
 * off the tunnel allowlist, so a live token gets 403 without touching the
 * browser and a dead one gets 401 from the auth gate.
 */
async function tunnelStatus(token: string): Promise<number> {
  const res = await handle.fetchTunnel(new Request('http://127.0.0.1:9/command', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ command: 'disconnect', args: [] }),
  }), conn);
  return res.status;
}

describe('revoking a paired agent', () => {
  test('revoke kills the exchanged session, not just the spent setup key', async () => {
    const token = await session(await pair('revoke-me'));
    expect(await tunnelStatus(token)).toBe(403);

    const res = await rootCall('DELETE', '/token/revoke-me');
    expect(res.status).toBe(200);
    expect(await tunnelStatus(token)).toBe(401);
    expect((await res.json()).count).toBe(2);
  });

  test('revoke also kills a setup key that was never exchanged', async () => {
    const key = await pair('pending-agent');
    expect((await rootCall('DELETE', '/token/pending-agent')).status).toBe(200);
    expect((await exchange(key)).status).toBe(401);
  });

  test('revoking an unknown name is a 404', async () => {
    expect((await rootCall('DELETE', '/token/nobody-by-this-name')).status).toBe(404);
  });

  test('/agents lists pending setup keys without their secret', async () => {
    const key = await pair('listed-pending');
    const body = await (await rootCall('GET', '/agents')).json();
    expect(body.pending.map((p: any) => p.clientId)).toContain('listed-pending');
    expect(JSON.stringify(body)).not.toContain(key);
    await rootCall('DELETE', '/token/listed-pending');
  });
});

describe('re-pairing an existing name', () => {
  test('a narrower re-pair before exchange retires the broad setup key', async () => {
    const broad = await pair('narrow-before-exchange');
    const narrow = await pair('narrow-before-exchange', { scopes: ['read'] });

    expect((await exchange(broad)).status).toBe(401);
    const res = await exchange(narrow);
    expect(res.status).toBe(200);
    expect((await res.json()).scopes).toEqual(['read']);
    await rootCall('DELETE', '/token/narrow-before-exchange');
  });

  test('a narrower re-pair revokes the live broad session at once', async () => {
    const token = await session(await pair('narrow-live'));
    await pair('narrow-live', { scopes: ['read'] });
    expect(await tunnelStatus(token)).toBe(401);
    await rootCall('DELETE', '/token/narrow-live');
  });

  test('adding a domain restriction counts as narrowing', async () => {
    const token = await session(await pair('narrow-domain'));
    await pair('narrow-domain', { domains: ['example.com'] });
    expect(await tunnelStatus(token)).toBe(401);
    await rootCall('DELETE', '/token/narrow-domain');
  });

  test('a broader re-pair keeps the live session until the new key is used', async () => {
    const token = await session(await pair('broaden-live', { scopes: ['read'] }));
    const broad = await pair('broaden-live');
    expect(await tunnelStatus(token)).toBe(403);

    await session(broad);
    expect(await tunnelStatus(token)).toBe(401);
    await rootCall('DELETE', '/token/broaden-live');
  });

  test('an invalid scope is refused before anything is revoked', async () => {
    const token = await session(await pair('bad-scope'));
    const res = await rootCall('POST', '/pair', { clientId: 'bad-scope', scopes: ['read', 'bogus'] });
    expect(res.status).toBe(400);
    expect(await tunnelStatus(token)).toBe(403);
    await rootCall('DELETE', '/token/bad-scope');
  });
});

const chromiumPath = (() => {
  try { return require('playwright').chromium.executablePath() as string; } catch { return ''; }
})();

describe.skipIf(!chromiumPath || !fs.existsSync(chromiumPath))('revoke releases tabs (real Chromium)', () => {
  const TAB_ROOT = 'pair-revoke-tabs-root-0123456789';
  let bm: any;
  let tabs: any;

  beforeAll(async () => {
    registry.__resetRegistry();
    const { buildFetchHandler } = await import('../src/server');
    const { BrowserManager } = await import('../src/browser-manager');
    const { resolveConfig } = await import('../src/config');
    bm = new BrowserManager();
    await bm.launch();
    tabs = buildFetchHandler({
      authToken: TAB_ROOT,
      browsePort: 0,
      idleTimeoutMs: 60_000,
      config: resolveConfig({ BROWSE_STATE_FILE: path.join(scratch, 'tabs-state', 'browse.json') }),
      browserManager: bm,
      startTime: Date.now(),
      ownsTerminalAgent: false,
    });
  }, 60_000);

  afterAll(async () => {
    await bm?.close().catch(() => {});
    registry.__resetRegistry();
  }, 30_000);

  test('a revoked name no longer owns the tabs it opened', async () => {
    registry.createToken({ clientId: 'tab-owner' });
    const tabId = await bm.newTab(undefined, 'tab-owner');
    expect(bm.getTabOwner(tabId)).toBe('tab-owner');

    const revoked = await tabs.fetchLocal(new Request('http://127.0.0.1:9/token/tab-owner', {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${TAB_ROOT}` },
    }), conn);
    expect(revoked.status).toBe(200);
    expect(bm.getTabOwner(tabId)).not.toBe('tab-owner');
  }, 60_000);

  // A page that never answers its title must not leave the revoked name owning
  // its tabs: ownership is released without asking any page for anything.
  test('tabs are released even when a page never answers its title', async () => {
    registry.createToken({ clientId: 'stalled-owner' });
    const tabId = await bm.newTab(undefined, 'stalled-owner');
    const original = bm.getTabListWithTitles;
    bm.getTabListWithTitles = () => new Promise(() => {});
    try {
      const revoked = await tabs.fetchLocal(new Request('http://127.0.0.1:9/token/stalled-owner', {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${TAB_ROOT}` },
      }), conn);
      expect(revoked.status).toBe(200);
      expect(bm.getTabOwner(tabId)).toBe('root');
    } finally {
      bm.getTabListWithTitles = original;
    }
  }, 60_000);
});
