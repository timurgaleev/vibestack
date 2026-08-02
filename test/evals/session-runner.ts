/**
 * Claude CLI subprocess runner for skill E2E evals.
 *
 * Spawns `claude -p` as a completely independent process (array-form args, no
 * shell interpolation; prompt piped via stdin as a Blob), streams NDJSON for
 * real-time progress, and is hardened against the two ways a timed-out child
 * can hang the suite:
 *
 *   - `proc.kill()` signals claude itself, but tool subprocesses claude spawned
 *     can survive as orphans that inherited our stdout pipe — without
 *     `reader.cancel()` the read loop blocks until the orphan finally exits.
 *   - The same orphan hazard applies to stderr: the drain is raced against
 *     child exit plus a 5s grace window, so the runner returns everything it
 *     collected instead of blocking past the per-test timeout.
 *
 * Sandboxing: skills are rendered from this repo's sources into the sandbox's
 * project-level `.claude/skills/` (the path real installs resolve), and
 * VIBESTACK_HOME points into the sandbox so evals never touch real state.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// --- Testable NDJSON parser (pure — no I/O) --------------------------------

export interface ParsedNDJSON {
  transcript: any[];
  resultLine: any | null;
  turnCount: number;
  toolCallCount: number;
  toolCalls: Array<{ tool: string; input: any }>;
}

export function parseNDJSON(lines: string[]): ParsedNDJSON {
  const transcript: any[] = [];
  let resultLine: any = null;
  let turnCount = 0;
  let toolCallCount = 0;
  const toolCalls: ParsedNDJSON["toolCalls"] = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      transcript.push(event);
      if (event.type === "assistant") {
        turnCount++;
        for (const item of event.message?.content || []) {
          if (item.type === "tool_use") {
            toolCallCount++;
            toolCalls.push({ tool: item.name || "unknown", input: item.input || {} });
          }
        }
      }
      if (event.type === "result") resultLine = event;
    } catch { /* skip malformed lines */ }
  }
  return { transcript, resultLine, turnCount, toolCallCount, toolCalls };
}

// --- Sandbox helpers -------------------------------------------------------

/** Render a skill from repo sources into the sandbox's project-level skills dir. */
function installSkill(sandbox: string, skill: string) {
  const src = path.join(REPO, "skills", skill);
  const dst = path.join(sandbox, ".claude", "skills", skill);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.cpSync(src, dst, { recursive: true });
  execSync(
    `bash "${path.join(REPO, "bin", "vibe-render-skill")}" "${path.join(src, "SKILL.md")}" "${path.join(dst, "SKILL.md")}"`,
    { stdio: "pipe" },
  );
}

export function makeSandbox(skills: string[]): string {
  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-eval-"));
  fs.mkdirSync(path.join(sandbox, "home"), { recursive: true });
  for (const s of skills) installSkill(sandbox, s);
  return sandbox;
}

/** Minimal git repo the smoke evals run inside. */
export function gitFixture(sandbox: string, opts?: { onFeatureBranch?: boolean }) {
  const run = (cmd: string) => execSync(cmd, { cwd: sandbox, stdio: "pipe" });
  run("git init -q -b main");
  run("git config user.email eval@example.com && git config user.name Eval");
  fs.writeFileSync(path.join(sandbox, "README.md"), "# eval fixture\n");
  fs.writeFileSync(path.join(sandbox, "app.js"), "export const add = (a, b) => a + b;\n");
  run("git add -A && git commit -qm init");
  if (opts?.onFeatureBranch) {
    run("git checkout -qb feat/eval-change");
    fs.writeFileSync(path.join(sandbox, "app.js"),
      "export const add = (a, b) => a + b;\nexport const sub = (a, b) => a - b;\n");
    run("git add -A && git commit -qm 'feat: sub'");
  }
}

export function hasClaudeCli(): boolean {
  try { execSync("command -v claude", { stdio: "pipe" }); return true; } catch { return false; }
}

/** Child env: scrub host-session context so the eval is hermetic-ish. */
function childEnv(sandbox: string, extra?: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (k === "CLAUDECODE" || k.startsWith("CONDUCTOR_") || k.startsWith("VIBESTACK_")) continue;
    env[k] = v;
  }
  // bun test prepends node_modules/.bin dirs to PATH; a stale shim there can
  // shadow the real claude binary (observed: ENOEXEC on ~/node_modules/.bin/claude).
  if (env.PATH) {
    env.PATH = env.PATH.split(":").filter((p) => !p.includes("node_modules/.bin")).join(":");
  }
  return {
    ...env,
    VIBESTACK_HOME: path.join(sandbox, "home"),
    VIBESTACK_HEADLESS: "1", // evals classify as headless: block, don't prose-ask
    ...extra,
  };
}

/** Resolve an executable by name against a specific PATH string. */
function resolveCmd(name: string, pathVar: string | undefined): string {
  for (const dir of (pathVar ?? "").split(":")) {
    if (!dir) continue;
    const cand = path.join(dir, name);
    try { fs.accessSync(cand, fs.constants.X_OK); return cand; } catch { /* next */ }
  }
  return name; // fall back to bare name; spawn will surface the error
}

// --- Main runner -----------------------------------------------------------

export interface SkillTestResult {
  toolCalls: Array<{ tool: string; input: any }>;
  exitReason: string;   // success | timeout | error_api | error_max_turns | exit_code_N
  duration: number;
  output: string;       // final result text
  transcript: any[];
  allText: string;      // transcript JSON + stderr, for vocabulary assertions
  turnsUsed: number;
  costUsd: number;
  firstResponseMs: number;
  /** Kept only on failure (holds eval-failure.json); removed on success. */
  sandboxDir: string | null;
}

export async function runSkillTest(options: {
  /** Skill to render into the sandbox. Omit for runner-infra tests (fake CLI). */
  skill?: string;
  prompt: string;
  setup?: (sandbox: string) => void;
  maxTurns?: number;
  allowedTools?: string[];
  timeout?: number;
  model?: string;
  /** Extra env for the child; spreads last, so PATH overrides win. */
  env?: Record<string, string>;
}): Promise<SkillTestResult> {
  const {
    skill, prompt, setup,
    maxTurns = 15,
    allowedTools = ["Bash", "Read", "Write", "Grep", "Glob"],
    timeout = 240_000,
  } = options;
  const model = options.model ?? process.env.EVALS_MODEL ?? "claude-sonnet-5";

  const sandbox = makeSandbox(skill ? [skill] : []);
  setup?.(sandbox);
  const startTime = Date.now();

  const args = [
    "-p",
    "--model", model,
    "--output-format", "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
    "--max-turns", String(maxTurns),
    "--allowed-tools", ...allowedTools,
    "--strict-mcp-config", // zero MCP servers reach the child
  ];

  const env = childEnv(sandbox, options.env);
  const proc = Bun.spawn([resolveCmd("claude", env.PATH), ...args], {
    cwd: sandbox,
    env,
    stdin: new Blob([prompt]),
    stdout: "pipe",
    stderr: "pipe",
  });

  let timedOut = false;
  const stderrPromise = new Response(proc.stderr).text();
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  const collectedLines: string[] = [];
  let buf = "";
  let firstResponseMs = 0;

  const timeoutId = setTimeout(() => {
    timedOut = true;
    proc.kill();
    reader.cancel().catch(() => { /* stream already closed */ });
    // Escalate: a child that ignores SIGTERM must not hang the runner.
    (setTimeout(() => { try { proc.kill("SIGKILL"); } catch { /* gone */ } }, 5_000) as any).unref?.();
  }, timeout);

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const lines = buf.split("\n");
      buf = lines.pop() || "";
      for (const line of lines) {
        if (!line.trim()) continue;
        if (firstResponseMs === 0) firstResponseMs = Date.now() - startTime;
        collectedLines.push(line);
        try {
          const event = JSON.parse(line);
          if (event.type === "assistant") {
            for (const item of event.message?.content || []) {
              if (item.type === "tool_use") {
                const elapsed = Math.round((Date.now() - startTime) / 1000);
                process.stderr.write(`  [${elapsed}s] ${skill ?? "runner"}: ${item.name}\n`);
              }
            }
          }
        } catch { /* parseNDJSON handles it later */ }
      }
    }
  } catch { /* stream read error — fall through */ }
  if (buf.trim()) collectedLines.push(buf);

  // Race the stderr drain against child exit + 5s grace (orphan hazard), and
  // bound the whole tail with a hard cap so even a SIGKILL-resistant zombie
  // (unlikely, but e.g. an uninterruptible-sleep child) can't hang the runner.
  const boundedExit = Promise.race([
    proc.exited,
    new Promise<null>((r) => { (setTimeout(() => r(null), 15_000) as any).unref?.(); }),
  ]);
  const stderr = await Promise.race([
    stderrPromise,
    (async () => {
      await boundedExit;
      await new Promise((r) => { (setTimeout(r, 5_000) as any).unref?.(); });
      return "";
    })(),
  ]);
  const exitCode = await boundedExit;
  clearTimeout(timeoutId);

  const parsed = parseNDJSON(collectedLines);
  const { transcript, resultLine, toolCalls } = parsed;

  let exitReason = timedOut ? "timeout" : exitCode === 0 ? "success" : `exit_code_${exitCode}`;
  // A result event refines the reason only for runs that actually finished —
  // a timed-out child that already emitted a result line must stay "timeout".
  if (resultLine && !timedOut) {
    if (resultLine.subtype === "success" && resultLine.is_error) exitReason = "error_api";
    else if (resultLine.subtype === "success") exitReason = "success";
    else if (resultLine.subtype) exitReason = resultLine.subtype;
  }

  const allText = transcript.map((e) => JSON.stringify(e)).join("\n") + "\n" + stderr;

  // Keep the evidence on failure (compact record in the sandbox); remove the
  // sandbox entirely on success so repeated runs don't litter the temp dir.
  let sandboxDir: string | null = null;
  if (exitReason !== "success") {
    sandboxDir = sandbox;
    try {
      fs.writeFileSync(path.join(sandbox, "eval-failure.json"), JSON.stringify({
        skill, prompt: prompt.slice(0, 500), exitReason,
        duration: Date.now() - startTime,
        stderr: stderr.slice(0, 2000),
        result: resultLine?.result?.slice?.(0, 500) ?? null,
      }, null, 2));
      process.stderr.write(`  eval failure record: ${path.join(sandbox, "eval-failure.json")}\n`);
    } catch { /* non-fatal */ }
  } else {
    try { fs.rmSync(sandbox, { recursive: true, force: true }); } catch { /* non-fatal */ }
  }

  return {
    toolCalls,
    exitReason,
    duration: Date.now() - startTime,
    output: resultLine?.result || "",
    transcript,
    allText,
    turnsUsed: resultLine?.num_turns || 0,
    costUsd: resultLine?.total_cost_usd || 0,
    firstResponseMs,
    sandboxDir,
  };
}
