import { beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vm from 'node:vm';

// Content scripts run inside web pages (sender.tab is set). The root token and
// the command proxy are for the extension's own pages only.

const EXT_ID = 'vibestackextensionidforthetests';
const BACKGROUND = path.resolve(import.meta.dir, '../../extension/background.js');

type Listener = (msg: any, sender: any, sendResponse: (r: any) => void) => unknown;

function loadBackground() {
  let onMessage: Listener | null = null;
  const fetched: string[] = [];
  const event = (capture?: (fn: any) => void) => ({ addListener: (fn: any) => capture?.(fn) });
  const chrome = {
    runtime: {
      id: EXT_ID,
      onMessage: event(fn => { onMessage = fn; }),
      onInstalled: event(),
      sendMessage: () => Promise.resolve(),
    },
    storage: { local: { get: async () => ({}), set: async () => {} } },
    tabs: {
      onActivated: event(), onCreated: event(), onRemoved: event(), onUpdated: event(),
      query: (_q: any, cb: (tabs: any[]) => void) => cb([]),
      sendMessage: () => Promise.resolve(),
    },
    sidePanel: { setPanelBehavior: () => Promise.resolve(), open: () => Promise.resolve() },
    action: { setBadgeText: () => {}, setBadgeBackgroundColor: () => {} },
  };
  const context = vm.createContext({
    chrome,
    console: { log() {}, warn() {}, error() {}, debug() {} },
    fetch: async (url: string) => {
      fetched.push(String(url));
      return new Response(JSON.stringify({ ok: true }), { headers: { 'Content-Type': 'application/json' } });
    },
    AbortSignal,
    setInterval: () => 0,
    clearInterval: () => {},
    setTimeout: () => 0,
    clearTimeout: () => {},
  });
  vm.runInContext(fs.readFileSync(BACKGROUND, 'utf-8'), context);
  vm.runInContext("authToken = 'root-token-for-tests'; serverPort = 34567;", context);
  if (!onMessage) throw new Error('background.js registered no onMessage listener');
  return { onMessage: onMessage as Listener, fetched };
}

function send(onMessage: Listener, msg: any, sender: any): Promise<any> {
  return new Promise(resolve => {
    const ret = onMessage(msg, sender, resolve);
    if (ret !== true) setTimeout(() => resolve(undefined), 50);
  });
}

describe('extension background sender gate', () => {
  let bg: ReturnType<typeof loadBackground>;
  const page = { id: EXT_ID, tab: { id: 7 }, url: 'https://example.com/' };
  const sidepanel = { id: EXT_ID, url: `chrome-extension://${EXT_ID}/sidepanel.html` };

  beforeAll(() => { bg = loadBackground(); });

  test('getPort from a content script carries no token', async () => {
    const resp = await send(bg.onMessage, { type: 'getPort' }, page);
    expect(resp?.token ?? null).toBeNull();
  });

  test('a content script cannot spend the command proxy', async () => {
    const before = bg.fetched.length;
    const resp = await send(bg.onMessage, { type: 'command', command: 'goto', args: ['https://evil.test/'] }, page);
    await new Promise(r => setTimeout(r, 20));
    expect(bg.fetched.slice(before).some(u => u.includes('/command'))).toBe(false);
    expect(resp?.error).toBeTruthy();
  });

  test('the side panel still gets the token and the command proxy', async () => {
    const port = await send(bg.onMessage, { type: 'getPort' }, sidepanel);
    expect(port.token).toBe('root-token-for-tests');
    const before = bg.fetched.length;
    await send(bg.onMessage, { type: 'command', command: 'url', args: [] }, sidepanel);
    expect(bg.fetched.slice(before).some(u => u.endsWith('/command'))).toBe(true);
  });
});
