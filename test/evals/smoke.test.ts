/**
 * Smoke evals — do the flagship skills actually fire in a real `claude -p`
 * session? Each case asserts on skill-specific vocabulary in the transcript,
 * which catches the "slash command didn't resolve / skill not registered"
 * regression class that unit suites are structurally blind to.
 *
 * Opt-in: costs real tokens. Run with `bun run test:evals` (sets RUN_EVALS=1).
 * Skipped silently under plain `bun test` or when the claude CLI is absent.
 */
import { describe, test, expect } from "bun:test";
import { runSkillTest, gitFixture, hasClaudeCli } from "./session-runner";

const enabled = process.env.RUN_EVALS === "1" && hasClaudeCli();
const t = enabled ? test : test.skip;
const TIMEOUT = 360_000;

describe("skill smoke evals", () => {
  t("/review resolves and starts its review flow", async () => {
    const r = await runSkillTest({
      skill: "review",
      prompt: "/review",
      setup: (sb) => gitFixture(sb, { onFeatureBranch: true }),
      timeout: 300_000,
      maxTurns: 25,
    });
    expect(r.allText).not.toContain("Unknown command");
    expect(["timeout", "error_api"]).not.toContain(r.exitReason);
    expect(r.toolCalls.length).toBeGreaterThan(0);
    // Vocabulary unique to the /review body: readiness/scope/checklist flow.
    expect(r.allText).toMatch(/Scope Check|Pre-Landing|Review Readiness|checklist/i);
  }, TIMEOUT);

  t("/ship resolves and aborts on the base branch", async () => {
    const r = await runSkillTest({
      skill: "ship",
      prompt: "/ship",
      setup: (sb) => gitFixture(sb), // stays on main → deterministic early abort
      timeout: 300_000,
    });
    expect(r.allText).not.toContain("Unknown command");
    expect(["timeout", "error_api"]).not.toContain(r.exitReason);
    expect(r.allText).toMatch(/base branch|feature branch/i);
  }, TIMEOUT);

  t("/investigate resolves and opens its investigation phases", async () => {
    const r = await runSkillTest({
      skill: "investigate",
      prompt: "/investigate the add function returns wrong results",
      setup: (sb) => gitFixture(sb),
      timeout: 300_000,
    });
    expect(r.allText).not.toContain("Unknown command");
    expect(["timeout", "error_api"]).not.toContain(r.exitReason);
    expect(r.allText).toMatch(/root cause|investigat|hypothes/i);
  }, TIMEOUT);
});
