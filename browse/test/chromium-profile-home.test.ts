import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { chromiumProfileDir } from '../src/cli';

describe('chromiumProfileDir', () => {
  let scratch: string;
  const saved = {
    VIBESTACK_HOME: process.env.VIBESTACK_HOME,
    CHROMIUM_PROFILE: process.env.CHROMIUM_PROFILE,
  };

  beforeAll(() => {
    scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-profile-home-')));
    process.env.VIBESTACK_HOME = scratch;
    delete process.env.CHROMIUM_PROFILE;
  });

  afterAll(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test('lives under VIBESTACK_HOME, not a hardcoded $HOME/.vibestack', () => {
    expect(chromiumProfileDir()).toBe(path.join(scratch, 'chromium-profile'));
  });
});
