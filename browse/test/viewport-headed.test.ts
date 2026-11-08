import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import { chromium } from 'playwright';
import { BrowserManager } from '../src/browser-manager';
import { handleWriteCommand } from '../src/write-commands';
import { handleMetaCommand } from '../src/meta-commands';
import { TEMP_DIR } from '../src/platform';
import * as path from 'node:path';

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

  test('responsive after auto restores the window fit, not the old override', async () => {
    const run = (args: string[]) => handleWriteCommand('viewport', args, bm.getActiveSession(), bm);
    await run(['375x812']);
    await run(['auto']);
    // Headless keeps the last size when the override drops, so pixels cannot
    // tell a stale restore from a fit; the restore has to go back through the fit.
    let fits = 0;
    const fit = bm.fitViewportToWindow.bind(bm);
    bm.fitViewportToWindow = async (p?: any) => { fits++; return fit(p); };
    const dir = fs.mkdtempSync(path.join(TEMP_DIR, 'vp-resp-'));
    try {
      await handleMetaCommand('responsive', [path.join(dir, 'shot')], bm, async () => {});
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    expect(fits).toBe(1);
    await run(['1280x720']);
    fits = 0;
    const dir2 = fs.mkdtempSync(path.join(TEMP_DIR, 'vp-resp-'));
    try {
      await handleMetaCommand('responsive', [path.join(dir2, 'shot')], bm, async () => {});
    } finally {
      fs.rmSync(dir2, { recursive: true, force: true });
    }
    expect(fits).toBe(0);

    // The fit belongs to the tab it was set on: sizing another tab leaves it.
    await run(['auto']);
    const a = bm.getActiveTabId();
    const b = await bm.newTab();
    bm.switchTab(b);
    await run(['375x812']);
    bm.switchTab(a);
    fits = 0;
    const dir3 = fs.mkdtempSync(path.join(TEMP_DIR, 'vp-resp-'));
    try {
      await handleMetaCommand('responsive', [path.join(dir3, 'shot')], bm, async () => {});
    } finally {
      fs.rmSync(dir3, { recursive: true, force: true });
    }
    expect(fits).toBe(1);
    await bm.closeTab(b);
  }, 60_000);
});
