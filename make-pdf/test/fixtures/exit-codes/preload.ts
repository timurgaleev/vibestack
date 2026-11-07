// Serves the stub's source in place of src/orchestrator.ts, so cli.ts runs
// unchanged and only the pipeline behind it is replaced.
import { plugin } from "bun";
import * as fs from "node:fs";
import * as path from "node:path";

const STUB = path.join(import.meta.dir, "orchestrator-stub.ts");

plugin({
  name: "make-pdf-orchestrator-stub",
  setup(build) {
    build.onLoad({ filter: /[\\/]src[\\/]orchestrator\.ts$/ }, () => ({
      contents: fs.readFileSync(STUB, "utf8"),
      loader: "ts",
    }));
  },
});
