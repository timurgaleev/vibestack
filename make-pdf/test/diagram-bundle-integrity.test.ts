/**
 * make-pdf renders diagrams with the committed lib/diagram-render bundle. The
 * bundle's own integrity check (one DOMPurify at the pinned override, one
 * mermaid, overrides pinned, BUILD_INFO hash matching the file) lives with the
 * bundle; it runs here too so the make-pdf CI job catches a bundle that drifted
 * from its lockfile or build record.
 */

import { expect, test } from "bun:test";
import path from "node:path";

import { checkBundle, loadInputs } from "../../lib/diagram-render/scripts/check-bundle";

test("the committed diagram-render bundle passes its integrity check", async () => {
  const root = path.resolve(import.meta.dir, "../../lib/diagram-render");
  expect(checkBundle(await loadInputs(root))).toEqual([]);
});
