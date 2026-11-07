/**
 * `load-html --offline` keeps the tab it loads into off the network: nothing
 * but file:, data:, blob: and about: is fetched or navigated to, including a
 * meta refresh a content policy cannot stop. The daemon's other tabs share
 * the browser context, so they must keep their network.
 */

import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { chromium, type Browser, type Page } from 'playwright';

import { TabSession } from '../src/tab-session';
import { handleWriteCommand } from '../src/write-commands';
import { TEMP_DIR } from '../src/platform';

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();

describe.skipIf(!chromiumPath || !fs.existsSync(chromiumPath))('load-html --offline (real Chromium)', () => {
  let browser: Browser;
  let server: ReturnType<typeof Bun.serve>;
  const hits = new Map<string, number>();
  const payloads: string[] = [];

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    server = Bun.serve({
      port: 0,
      hostname: '127.0.0.1',
      fetch(req) {
        const tag = new URL(req.url).pathname.split('/')[1] ?? '';
        hits.set(tag, (hits.get(tag) ?? 0) + 1);
        return new Response('<p>remote</p>', { headers: { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' } });
      },
    });
  });

  afterAll(async () => {
    for (const p of payloads) fs.rmSync(p, { force: true });
    server?.stop(true);
    await browser?.close();
  });

  function page(tag: string): string {
    const o = `http://127.0.0.1:${server.port}/${tag}`;
    return `<!doctype html><html><head><meta http-equiv="refresh" content="0;url=${o}/nav"></head>` +
      `<body><img src="${o}/img.png"><img id="local" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">` +
      `<p>x</p></body></html>`;
  }

  async function load(p: Page, html: string, flags: string[]): Promise<void> {
    const file = path.join(TEMP_DIR, `load-html-offline-${process.pid}-${payloads.length}.json`);
    payloads.push(file);
    fs.writeFileSync(file, JSON.stringify({ html, waitUntil: 'load' }));
    await handleWriteCommand('load-html', ['--from-file', file, ...flags], new TabSession(p), null as any);
    await p.waitForTimeout(500);
  }

  test('reaches no host, follows no refresh, and still shows data: images', async () => {
    const p = await browser.newPage();
    try {
      await load(p, page('off'), ['--offline']);
      expect(hits.get('off') ?? 0).toBe(0);
      // The refused refresh leaves the loaded page in place, not an error page.
      expect(p.url()).toBe('about:blank');
      expect(await p.textContent('body')).toBe('x');
      expect(await p.evaluate(() => (document.getElementById('local') as HTMLImageElement).naturalWidth)).toBe(1);
    } finally {
      await p.close();
    }
  }, 30_000);

  test('without the flag the same page reaches the host (the case is live)', async () => {
    const p = await browser.newPage();
    try {
      await load(p, page('on'), []);
      expect(hits.get('on') ?? 0).toBeGreaterThan(0);
    } finally {
      await p.close();
    }
  }, 30_000);

  test('a later load without the flag puts the tab back on the network', async () => {
    const p = await browser.newPage();
    try {
      await load(p, '<p>x</p>', ['--offline']);
      await load(p, page('back'), []);
      expect(hits.get('back') ?? 0).toBeGreaterThan(0);
    } finally {
      await p.close();
    }
  }, 30_000);

  test('leaves the other tabs in the same context on the network', async () => {
    const ctx = await browser.newContext();
    try {
      const offline = await ctx.newPage();
      await load(offline, '<p>x</p>', ['--offline']);
      const other = await ctx.newPage();
      await other.goto(`http://127.0.0.1:${server.port}/other/`);
      expect(hits.get('other') ?? 0).toBeGreaterThan(0);
    } finally {
      await ctx.close();
    }
  }, 30_000);
});
