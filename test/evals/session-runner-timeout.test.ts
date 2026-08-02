import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { runSkillTest } from "./session-runner";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

// Regression test for the runSkillTest timeout path (free — no API call, the
// spawned "claude" is a local fake). Always runs; not gated on RUN_EVALS.
//
// proc.kill() signals claude itself, but tool subprocesses it spawned can
// survive as orphans that inherited our stdout/stderr pipes. Without the
// reader.cancel() + stderr-race fix, the runner blocks on the pipe drain until
// the orphan exits — a 3s timeout stretching to ~45s and tripping bun's
// per-test timeout instead of returning collected evidence.

const ORPHAN_LINGER_SECS = 45; // without the fix the runner blocks this long

describe.skipIf(process.platform === "win32")("session-runner timeout path", () => {
  let fixtureBin: string;

  beforeAll(() => {
    fixtureBin = fs.mkdtempSync(path.join(os.tmpdir(), "fake-claude-bin-"));
    // Fake claude: emits minimal stream-json, spawns a pipe-holding orphan,
    // then lingers in the foreground.
    fs.writeFileSync(
      path.join(fixtureBin, "claude"),
      `#!/bin/sh
cat > /dev/null &
echo '{"type":"system","subtype":"init"}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}'
sleep ${ORPHAN_LINGER_SECS} &
exec sleep ${ORPHAN_LINGER_SECS}
`,
      { mode: 0o755 },
    );
  });

  afterAll(() => {
    if (fixtureBin && fs.existsSync(fixtureBin)) fs.rmSync(fixtureBin, { recursive: true, force: true });
  });

  test(
    "returns promptly when a killed child leaves a pipe-holding orphan",
    async () => {
      const started = Date.now();
      const result = await runSkillTest({
        prompt: "irrelevant — the fake claude ignores stdin",
        timeout: 3_000,
        env: { PATH: `${fixtureBin}:${process.env.PATH ?? ""}` },
      });
      const wall = Date.now() - started;

      expect(result.exitReason).toBe("timeout");
      // Streamed lines collected before the kill must survive the cancel.
      expect(result.transcript.some((e: any) => e?.type === "assistant")).toBe(true);
      // Timeout (3s) + stderr grace (5s) + slack must stay well under the
      // orphan's ~45s linger.
      expect(wall).toBeLessThan(20_000);
    },
    30_000,
  );
});
