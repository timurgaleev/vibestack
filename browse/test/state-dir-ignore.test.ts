import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ensureStateDir, resolveConfig } from '../src/config';

function git(cwd: string, ...args: string[]): string {
  const proc = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(' ')}: ${proc.stderr.toString()}`);
  return proc.stdout.toString();
}

describe('ensureStateDir keeps the work tree clean', () => {
  let repo: string;

  beforeEach(() => {
    repo = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-state-dir-')));
    git(repo, 'init', '-q');
    git(repo, 'config', 'user.email', 't@example.com');
    git(repo, 'config', 'user.name', 't');
    fs.writeFileSync(path.join(repo, '.gitignore'), 'node_modules/\n');
    git(repo, 'add', '.gitignore');
    git(repo, 'commit', '-qm', 'init');
  });

  afterEach(() => {
    fs.rmSync(repo, { recursive: true, force: true });
  });

  const configFor = (dir: string) =>
    resolveConfig({ BROWSE_STATE_FILE: path.join(dir, '.vibestack', 'browse.json') });

  test('ignores the state dir without editing the tracked .gitignore', () => {
    ensureStateDir(configFor(repo));

    expect(fs.readFileSync(path.join(repo, '.gitignore'), 'utf-8')).toBe('node_modules/\n');
    expect(git(repo, 'status', '--porcelain')).toBe('');
  });

  test('is idempotent: the exclude entry is written once', () => {
    ensureStateDir(configFor(repo));
    ensureStateDir(configFor(repo));

    const exclude = fs.readFileSync(path.join(repo, '.git', 'info', 'exclude'), 'utf-8');
    expect(exclude.match(/^\.vibestack\/$/gm)?.length).toBe(1);
  });

  test('outside a git repo it only creates the state dir', () => {
    const plain = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'browse-state-plain-')));
    try {
      ensureStateDir(configFor(plain));
      expect(fs.existsSync(path.join(plain, '.vibestack'))).toBe(true);
      expect(fs.readdirSync(plain)).toEqual(['.vibestack']);
    } finally {
      fs.rmSync(plain, { recursive: true, force: true });
    }
  });
});
