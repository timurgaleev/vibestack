import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { validateOutputPath } from '../src/path-security';

// A directory that exists on every POSIX host and is outside the safe set
// (the temp dirs and the test's cwd).
const OUTSIDE = '/etc';

describe.skipIf(process.platform === 'win32')('validateOutputPath', () => {
  let scratch: string;

  beforeAll(() => {
    scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-path-security-')));
    fs.mkdirSync(path.join(scratch, 'outside-target'));
    fs.symlinkSync(path.join(OUTSIDE, 'ssh'), path.join(scratch, 'link'));
    fs.symlinkSync(path.join(OUTSIDE, 'vibestack-no-such-file'), path.join(scratch, 'dangling'));
    fs.symlinkSync(path.join(scratch, 'outside-target'), path.join(scratch, 'inside-link'));
  });

  afterAll(() => {
    fs.rmSync(scratch, { recursive: true, force: true });
  });

  test('a new file in a temp dir is allowed', () => {
    expect(() => validateOutputPath(path.join(scratch, 'shot.png'))).not.toThrow();
  });

  test('a new file in a new subdirectory of a temp dir is allowed', () => {
    expect(() => validateOutputPath(path.join(scratch, 'new-dir', 'shot.png'))).not.toThrow();
  });

  test('a symlink whose target stays inside a safe dir is allowed', () => {
    expect(() => validateOutputPath(path.join(scratch, 'inside-link', 'x.png'))).not.toThrow();
  });

  test('a plain path outside the safe dirs is rejected', () => {
    expect(() => validateOutputPath(path.join(OUTSIDE, 'x.png'))).toThrow(/Path must be within/);
  });

  test('link/.. follows the symlink first, the way the kernel does', () => {
    // Lexically this is <scratch>/x.png; the kernel resolves `link` to
    // /etc/ssh first, so `..` lands in /etc.
    const sneaky = `${scratch}/link/../x.png`;
    expect(() => validateOutputPath(sneaky)).toThrow(/Path must be within/);
  });

  test('a dangling symlink is rejected: a write would create its target', () => {
    expect(() => validateOutputPath(path.join(scratch, 'dangling'))).toThrow(/Path must be within/);
  });

  test('a symlink into a directory outside the safe dirs is rejected', () => {
    expect(() => validateOutputPath(path.join(scratch, 'link', 'known_hosts'))).toThrow(/Path must be within/);
  });
});
