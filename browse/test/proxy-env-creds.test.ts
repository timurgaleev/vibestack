import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';
import { buildRestartEnv, extractGlobalFlags } from '../src/cli';

const SERVER = path.resolve(import.meta.dir, '../src/server.ts');

/** A port nothing listens on, so the SOCKS pre-flight fails fast instead of launching a browser. */
async function closedPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address() as net.AddressInfo;
      srv.close(() => resolve(port));
    });
  });
}

describe.skipIf(process.platform === 'win32')('proxy creds supplied through the environment', () => {
  let scratch: string;

  beforeEach(() => {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'browse-proxy-env-'));
  });

  afterEach(() => {
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test('the daemon accepts the env the CLI hands it and reaches the proxy pre-flight', async () => {
    const port = await closedPort();
    const userEnv = { BROWSE_PROXY_USER: 'alice', BROWSE_PROXY_PASS: 's3cret' };
    const flags = extractGlobalFlags(['--proxy', `socks5://127.0.0.1:${port}`, 'status'], userEnv);
    // The CLI resolved the env creds into the URL; the daemon inherits the
    // shell's env as well, which is exactly how the user ran it.
    const proc = Bun.spawn([process.execPath, 'run', '--no-env-file', SERVER], {
      cwd: scratch,
      env: {
        HOME: scratch,
        PATH: process.env.PATH || '/usr/bin:/bin',
        BROWSE_STATE_FILE: path.join(scratch, '.vibestack', 'browse.json'),
        BROWSE_PARENT_PID: '0',
        ...userEnv,
        ...buildRestartEnv(flags, null),
      },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const timer = setTimeout(() => proc.kill('SIGKILL'), 20_000);
    const [, stdout, stderr] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    clearTimeout(timer);
    const output = stdout + stderr;
    expect(output).not.toContain('pick one source');
    expect(output).toContain('Testing SOCKS5 reference');
    expect(output).not.toContain('s3cret');
  }, 30_000);
});
