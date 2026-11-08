import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import { chromium } from 'playwright';
import { BrowserManager } from '../src/browser-manager';

// A headed session tracks tabs opened outside browse through the context's
// 'page' event, which also fires for browse's own newtab. A pinned newtab
// there must still leave the shared active tab alone and register once.

const chromiumPath = (() => { try { return chromium.executablePath(); } catch { return ''; } })();
const hasChromium = !!chromiumPath && fs.existsSync(chromiumPath);

describe.skipIf(!hasChromium)('headed page listener and pinned newtab (real Chromium)', () => {
  let bm: BrowserManager;

  beforeAll(async () => {
    bm = new BrowserManager();
    await bm.launch();
    // A real headed launch needs a display, which CI does not have; attach the
    // headed listener to the headless context instead.
    (bm as any).trackExternalPages(() => {});
  }, 60_000);

  afterAll(async () => {
    await bm?.close();
  }, 15_000);

  test('a pinned newtab moves only the pin and registers the page once', async () => {
    const shared = bm.getActiveTabId();
    const pinned = await bm.newTab();
    bm.switchTab(shared);
    const before = bm.getTabCount();

    const opened = await bm.runPinned(pinned, () => bm.newTab());
    await Bun.sleep(200);

    expect(bm.getActiveTabId()).toBe(shared);
    expect(bm.getTabCount()).toBe(before + 1);
    expect(opened).toBeGreaterThan(pinned);
  }, 30_000);

  test('a page opened outside browse is still tracked and becomes active', async () => {
    const before = bm.getTabCount();
    const page = await (bm as any).context.newPage();
    await Bun.sleep(200);

    expect(bm.getTabCount()).toBe(before + 1);
    expect(bm.getPage()).toBe(page);
  }, 30_000);
});
