import { afterAll, afterEach, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { isPairAgentEnabled } from '../src/config';

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-pair-consent-'));
const saved = { home: process.env.VIBESTACK_HOME, pair: process.env.VIBESTACK_PAIR_AGENT };

function writeConfig(value: unknown) {
  fs.writeFileSync(path.join(scratch, 'config.json'), JSON.stringify(value));
}

beforeAll(() => {
  process.env.VIBESTACK_HOME = scratch;
  delete process.env.VIBESTACK_PAIR_AGENT;
});

afterEach(() => {
  delete process.env.VIBESTACK_PAIR_AGENT;
  fs.rmSync(path.join(scratch, 'config.json'), { force: true });
});

afterAll(() => {
  if (saved.home === undefined) delete process.env.VIBESTACK_HOME; else process.env.VIBESTACK_HOME = saved.home;
  if (saved.pair === undefined) delete process.env.VIBESTACK_PAIR_AGENT; else process.env.VIBESTACK_PAIR_AGENT = saved.pair;
  fs.rmSync(scratch, { recursive: true, force: true });
});

describe('isPairAgentEnabled', () => {
  test('fails closed with no config', () => {
    expect(isPairAgentEnabled()).toBe(false);
  });

  test('reads the key vibe-config writes', () => {
    writeConfig({ pair_agent: 'on' });
    expect(isPairAgentEnabled()).toBe(true);
    writeConfig({ pair_agent: 'off' });
    expect(isPairAgentEnabled()).toBe(false);
  });

  test('a malformed config fails closed', () => {
    fs.writeFileSync(path.join(scratch, 'config.json'), '{not json');
    expect(isPairAgentEnabled()).toBe(false);
  });

  test('the env override wins over the file', () => {
    writeConfig({ pair_agent: 'on' });
    process.env.VIBESTACK_PAIR_AGENT = 'off';
    expect(isPairAgentEnabled()).toBe(false);
  });
});

describe('/tunnel/start enforces consent in the daemon', () => {
  const ROOT = 'pair-consent-root-token-0123456789';
  let handle: any;

  beforeAll(async () => {
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

  test('a root-token call is refused while pair_agent is off', async () => {
    const res = await handle.fetchLocal(new Request('http://127.0.0.1:9/tunnel/start', {
      method: 'POST',
      headers: { Authorization: `Bearer ${ROOT}` },
    }), { requestIP: () => ({ address: '127.0.0.1' }) });
    expect(res.status).toBe(403);
    const body = await res.json();
    expect(body.error).toMatch(/pair-agent is off/);
    expect(body.hint).toMatch(/vibe-config set pair_agent on/);
  });
});
