/**
 * Sandbox seeds for compliance specs. Each fixture is a small git repo with a
 * planted bug, so every task has real work to do and real files to touch.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";

type Fixture = (sandbox: string) => void;

function write(sandbox: string, rel: string, body: string) {
  const p = path.join(sandbox, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body);
}

function commitAll(sandbox: string) {
  const run = (cmd: string) => execSync(cmd, { cwd: sandbox, stdio: "pipe" });
  run("git init -q -b main");
  run("git config user.email eval@example.com && git config user.name Eval");
  run("git add -A && git commit -qm init");
}

const BUGGY_MATH =
  "export const add = (a, b) => a + b;\n" +
  "export const sub = (a, b) => a + b; // wrong operator\n";

// A neighbor file with its own quirky style: the surgical-change spec checks
// that it stays untouched.
const QUIRKY_UTIL =
  "export function   pad (s,n){ return String(s).padStart(n,'0') }\n" +
  "var unused_legacy = 1\n";

const NODE_TEST_PKG = JSON.stringify({ name: "fixture", type: "module", scripts: { test: "node --test" } }, null, 2) + "\n";
const MATH_TEST =
  "import { test } from 'node:test';\n" +
  "import assert from 'node:assert/strict';\n" +
  "import { add, sub } from './math.js';\n\n" +
  "test('add', () => assert.equal(add(2, 3), 5));\n" +
  "test('sub', () => assert.equal(sub(5, 3), 2));\n";

/**
 * A bare origin inside the sandbox, with main pushed. The origin and the
 * session's HOME dirs are excluded, so a ship or review sees a clean tree.
 */
function addOrigin(sandbox: string) {
  const run = (cmd: string) => execSync(cmd, { cwd: sandbox, stdio: "pipe" });
  fs.appendFileSync(path.join(sandbox, ".git", "info", "exclude"), "/origin.git/\n/home/\n/user-home/\n");
  run("git init -q --bare -b main origin.git");
  run("git remote add origin ./origin.git && git push -q -u origin main");
}

/** Commit `body` to `rel` on a new branch, one commit ahead of origin/main. */
function branchWith(sandbox: string, branch: string, rel: string, body: string) {
  const run = (cmd: string) => execSync(cmd, { cwd: sandbox, stdio: "pipe" });
  run(`git checkout -q -b ${branch}`);
  write(sandbox, rel, body);
  run(`git commit -qam ${JSON.stringify(`change ${rel}`)}`);
}

export const FIXTURES: Record<string, Fixture> = {
  "git-bugfix": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "math.js", BUGGY_MATH);
    commitAll(sb);
  },
  "surgical-bugfix": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "math.js", BUGGY_MATH);
    write(sb, "util.js", QUIRKY_UTIL);
    commitAll(sb);
  },
  "stale-data-dir": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "data/customers.csv", "id,name\n1,Ada\n2,Grace\n");
    write(sb, "data/orders.csv", "id,customer\n10,1\n");
    commitAll(sb);
  },
  "frozen-src": (sb) => {
    write(sb, "README.md", "# fixture\n\nTeh math helpers live in src/.\n");
    write(sb, "src/math.js", BUGGY_MATH);
    commitAll(sb);
  },
  // `npm test` is red on the planted sub bug.
  "failing-test": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "package.json", NODE_TEST_PKG);
    write(sb, "math.js", BUGGY_MATH);
    write(sb, "math.test.js", MATH_TEST);
    commitAll(sb);
  },
  // The sub fix is committed on fix/sub; the suite is green and origin accepts a push.
  "ship-ready-branch": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "package.json", NODE_TEST_PKG);
    write(sb, "math.js", BUGGY_MATH);
    write(sb, "math.test.js", MATH_TEST);
    commitAll(sb);
    addOrigin(sb);
    branchWith(sb, "fix/sub", "math.js", BUGGY_MATH.replace("a + b; // wrong operator", "a - b;"));
  },
  // The branch adds a feature with dead code a review auto-fixes.
  "review-branch": (sb) => {
    write(sb, "README.md", "# fixture\n");
    write(sb, "app.js", "export const add = (a, b) => a + b;\n");
    commitAll(sb);
    addOrigin(sb);
    branchWith(sb, "feat/retry", "app.js",
      "export const add = (a, b) => a + b;\n\n" +
      "const unusedRetries = 3;\n\n" +
      "export async function fetchWithRetry(fn, tries = 2) {\n" +
      "  for (let i = 0; i < tries; i++) {\n" +
      "    try { return await fn(); } catch (e) { if (i === tries - 1) throw e; }\n" +
      "  }\n" +
      "}\n");
  },
};

export const FIXTURE_NAMES = Object.keys(FIXTURES);
