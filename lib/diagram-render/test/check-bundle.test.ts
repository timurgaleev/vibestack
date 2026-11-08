import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import path from "node:path";
import { bundledDomPurifyVersions, checkBundle, loadInputs, lockVersions, REQUIRED_OVERRIDES } from "../scripts/check-bundle";

const ROOT = path.resolve(import.meta.dir, "..");

describe("committed diagram-render bundle", () => {
  test("passes the integrity check (one DOMPurify at the override, one mermaid, pinned overrides)", async () => {
    expect(checkBundle(await loadInputs(ROOT))).toEqual([]);
  });
});

function fixture(html: string, lock: string) {
  const overrides = Object.fromEntries(REQUIRED_OVERRIDES.map((n) => [n, "9.9.9"]));
  const deps = { mermaid: "11.0.0", "@excalidraw/mermaid-to-excalidraw": "2.0.0" };
  return {
    html,
    buildInfo: { sha256: createHash("sha256").update(html).digest("hex"), deps, overrides },
    pkg: { dependencies: deps, overrides },
    lock,
  };
}

const CLEAN_LOCK = '"mermaid@11.0.0" "@excalidraw/mermaid-to-excalidraw@2.0.0" "dompurify@9.9.9"';
const ONE_PURIFY = 'a;if(B.version="9.9.9",B.removed=[],!u)';

describe("checkBundle", () => {
  test("green: a coherent fixture passes", () => {
    expect(checkBundle(fixture(ONE_PURIFY, CLEAN_LOCK))).toEqual([]);
  });

  test("a second, older DOMPurify copy in the bundle fails", () => {
    const html = ONE_PURIFY + 'b;if(e0.version="3.1.6",e0.removed=[],!g)';
    const problems = checkBundle(fixture(html, CLEAN_LOCK));
    expect(problems.some((p) => p.includes("2 DOMPurify copies"))).toBe(true);
    expect(problems.some((p) => p.includes("DOMPurify 3.1.6"))).toBe(true);
  });

  test("a nested second mermaid in bun.lock fails", () => {
    const problems = checkBundle(fixture(ONE_PURIFY, CLEAN_LOCK + ' "mermaid@10.9.3"'));
    expect(problems.some((p) => p.includes("resolves mermaid to 10.9.3, 11.0.0"))).toBe(true);
  });

  test("a missing or ranged override fails", () => {
    const f = fixture(ONE_PURIFY, CLEAN_LOCK);
    const { nanoid: _drop, ...rest } = f.pkg.overrides;
    const pkg = { ...f.pkg, overrides: { ...rest, chokidar: "^4.0.0" } };
    const problems = checkBundle({ ...f, pkg, buildInfo: { ...f.buildInfo, overrides: pkg.overrides } });
    expect(problems).toContain("package.json overrides is missing nanoid");
    expect(problems).toContain("override chokidar@^4.0.0 is not an exact pin");
  });

  test("a hand-edited dist (sha mismatch) fails", () => {
    const f = fixture(ONE_PURIFY, CLEAN_LOCK);
    expect(checkBundle({ ...f, html: f.html + " " }).some((p) => p.startsWith("dist sha256"))).toBe(true);
  });

  test("helpers parse the real formats", () => {
    expect(lockVersions('"@excalidraw/mermaid-to-excalidraw@2.2.2" "mermaid@11.17.2"', "mermaid")).toEqual(["11.17.2"]);
    expect(bundledDomPurifyVersions('x.version="3.4.17",x.removed=[]')).toEqual(["3.4.17"]);
  });
});
