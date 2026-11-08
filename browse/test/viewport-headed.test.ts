import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import { chromium } from 'playwright';
import { BrowserManager } from '../src/browser-manager';
import { handleWriteCommand } from '../src/write-commands';

// A headed browser starts with no viewport override: the page fills the
// window. `viewport auto` has to return there, not to the headless default.

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
const hasChromium = !!chromiumPath && fs.existsSync(chromiumPath);

describe.skipIf(!hasChromium)('viewport auto in a headed session (real Chromium)', () => {
  let bm: BrowserManager;

  beforeAll(async () => {
    bm = new BrowserManager();
    await bm.launch();
    // The window-fit branch keys on the connection mode; a real headed launch
    // needs a display, which CI does not have.
    (bm as any).connectionMode = 'headed';
  }, 60_000);

  afterAll(async () => {
    (bm as any).connectionMode = 'launched';
    await bm?.close();
  }, 15_000);

  async function inner(): Promise<{ width: number; height: number }> {
    return bm.getPage().evaluate(() => ({ width: innerWidth, height: innerHeight }));
  }

  async function windowWidth(): Promise<number> {
    const page = bm.getPage();
    const cdp = await page.context().newCDPSession(page);
    try {
      const { bounds } = await cdp.send('Browser.getWindowForTarget') as any;
      return bounds.width;
    } finally {
      await cdp.detach().catch(() => {});
    }
  }

  test('auto drops the override and the page fills the window', async () => {
    const run = (args: string[]) => handleWriteCommand('viewport', args, bm.getActiveSession(), bm);
    await run(['375x812']);
    expect(await inner()).toEqual({ width: 375, height: 812 });

    const out = await run(['auto']);
    expect(out).not.toContain('1280x720');
    const fitted = await inner();
    expect(fitted.width).toBe(await windowWidth());
    expect(bm.getCurrentViewport()).toEqual(fitted);

    // The size the override had before auto must apply again.
    await run(['375x812']);
    expect(await inner()).toEqual({ width: 375, height: 812 });
  }, 30_000);
});
