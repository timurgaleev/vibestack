import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const CLI = path.resolve(import.meta.dir, '../src/cli.ts');
const ROOT = 'tunnel-cli-root-token-0123456789';
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-tunnel-cli-'));
const stateFile = path.join(scratch, '.vibestack', 'browse.json');
const conn = { requestIP: () => ({ address: '127.0.0.1' }) };
let handle: any;
let server: ReturnType<typeof Bun.serve>;
let daemon: ReturnType<typeof Bun.spawn>;
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
    config: resolveConfig({ BROWSE_STATE_FILE: stateFile }),
    browserManager: new BrowserManager(),
    startTime: Date.now(),
    ownsTerminalAgent: false,
  });
  server = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch: (req) => handle.fetchLocal(req, conn) });
  // Stand-in daemon PID: should the CLI ever fall through to its restart
  // path, it kills this sleeper rather than the test runner.
  daemon = Bun.spawn(['sleep', '120'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify({ pid: daemon.pid, port: server.port, token: ROOT, mode: 'launched' }));
});

afterAll(() => {
  daemon?.kill('SIGKILL');
  server?.stop(true);
  registry.__resetRegistry();
  fs.rmSync(scratch, { recursive: true, force: true });
});

async function pair(clientId: string): Promise<string> {
  const res = await handle.fetchLocal(new Request('http://127.0.0.1:9/pair', {
    method: 'POST',
    headers: { Authorization: `Bearer ${ROOT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ clientId }),
  }), conn);
  return (await res.json()).setup_key;
}

async function exchange(setupKey: string) {
  registry.__resetConnectRateLimit();
  return handle.fetchLocal(new Request('http://127.0.0.1:9/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ setup_key: setupKey }),
  }), conn);
}

async function cli(...args: string[]) {
  const proc = Bun.spawn([process.execPath, 'run', '--no-env-file', CLI, ...args], {
    cwd: scratch,
    env: {
      HOME: scratch,
      BROWSE_STATE_FILE: stateFile,
      // No bun on PATH: a regression that falls through to starting a daemon
      // cannot launch a real browser from this test.
      PATH: '/usr/bin:/bin',
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  return { code, stdout, stderr };
}

describe('browse tunnel', () => {
  test('agents lists live sessions and unexchanged keys as (pending)', async () => {
    await exchange(await pair('cli-live'));
    await pair('cli-waiting');
    const out = await cli('tunnel', 'agents');
    expect(out.code).toBe(0);
    expect(out.stdout).toMatch(/cli-live(?! \(pending\))/);
    expect(out.stdout).toContain('cli-waiting (pending)');
  }, 30_000);

  test('revoke cuts the agent off and confirms it is gone from the list', async () => {
    const res = await exchange(await pair('cli-revoke'));
    const { token } = await res.json();
    const out = await cli('tunnel', 'revoke', 'cli-revoke');
    expect(out.code).toBe(0);
    expect(out.stdout).toContain('Revoked "cli-revoke"');
    expect(registry.validateToken(token)).toBeNull();
    expect(registry.listTokens().map(t => t.clientId)).not.toContain('cli-revoke');
  }, 30_000);

  test('revoking an unknown name fails loudly', async () => {
    const out = await cli('tunnel', 'revoke', 'no-such-agent');
    expect(out.code).toBe(1);
    expect(out.stderr).toContain('no-such-agent');
  }, 30_000);
});
