import { describe, expect, test } from 'bun:test';
import * as proxyConfig from '../src/proxy-config';
import * as errorHandling from '../src/error-handling';
import { __testInternals__ } from '../src/server';

const pc = proxyConfig as any;
const eh = errorHandling as any;

describe('daemon port range', () => {
  test('random ports stay below the macOS ephemeral range (49152+)', () => {
    const err = __testInternals__.formatRandomPortUnavailableError([]);
    expect(err.message).toContain('10000-49151');
  });
});

describe('effective proxy mode', () => {
  test('Linux with no proxy pins Chromium to a direct connection', () => {
    expect(pc.directProxyArgs?.(null, 'linux')).toEqual(['--proxy-server=direct://']);
  });

  test('a configured proxy, or another platform, adds no direct:// switch', () => {
    expect(pc.directProxyArgs?.({ server: 'http://proxy.test:8080' }, 'linux')).toEqual([]);
    expect(pc.directProxyArgs?.(null, 'darwin')).toEqual([]);
  });

  test('the start-up log names the mode without credentials', () => {
    expect(pc.describeProxyMode?.(null, 'linux')).toBe('[browse] [proxy] mode: direct (--proxy-server=direct://)');
    expect(pc.describeProxyMode?.(null, 'darwin')).toBe('[browse] [proxy] mode: direct');
    const line = pc.describeProxyMode?.({ server: 'socks5://127.0.0.1:4000', username: 'alice', password: 's3cret' }, 'linux');
    expect(line).toBe('[browse] [proxy] mode: socks5://127.0.0.1:4000 (authenticated)');
    expect(line).not.toContain('s3cret');
  });
});

describe('Chromium killed at launch', () => {
  const killed = new Error('browserType.launch: Target page, context or browser has been closed\nBrowser logs:\n<process did exit: exitCode=null, signal=SIGKILL>');

  test('macOS gets a one-line quarantine / reinstall hint', () => {
    const hint = eh.launchKillHint?.(killed, 'darwin');
    expect(typeof hint).toBe('string');
    expect(hint).toContain('xattr');
    expect(hint).toContain('playwright install chromium');
    expect(hint.includes('\n')).toBe(false);
  });

  test('other failures and other platforms get no hint', () => {
    expect(eh.launchKillHint?.(killed, 'linux')).toBeNull();
    expect(eh.launchKillHint?.(new Error('Executable doesn\'t exist at /x'), 'darwin')).toBeNull();
  });
});
