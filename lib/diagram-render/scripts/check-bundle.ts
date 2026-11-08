/**
 * Integrity check for the committed diagram-render bundle.
 *
 *   bun run scripts/check-bundle.ts      (exit 0 = clean, 1 = problems listed)
 *
 * Needs no node_modules, so CI runs it on a plain checkout. It proves:
 *  - dist/diagram-render.html is the file BUILD_INFO.json describes, and
 *    BUILD_INFO records the same pins and overrides as package.json;
 *  - every security override in package.json is an exact pin and is the only
 *    version of that package bun.lock resolves;
 *  - mermaid and mermaid-to-excalidraw resolve to exactly one version each, so
 *    excalidraw's own converter shares the copy entry.ts uses — a second copy
 *    drags in a second, older mermaid with its own DOMPurify;
 *  - the bundle embeds exactly one DOMPurify, at the overridden version.
 */
import { createHash } from "node:crypto";
import path from "node:path";

export const REQUIRED_OVERRIDES = ["dompurify", "nanoid", "lodash-es", "chokidar", "source-map-js"];
const SINGLE_COPY = ["mermaid", "@excalidraw/mermaid-to-excalidraw"];
const EXACT = /^\d+\.\d+\.\d+$/;

export interface BundleInputs {
  html: string;
  buildInfo: { sha256?: string; deps?: Record<string, string>; overrides?: Record<string, string> };
  pkg: { dependencies?: Record<string, string>; overrides?: Record<string, string> };
  lock: string;
}

/** Versions bun.lock resolves for one package name (`"name@1.2.3"` entries). */
export function lockVersions(lock: string, name: string): string[] {
  const esc = name.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
  const re = new RegExp(`"${esc}@(\\d+\\.\\d+\\.\\d+[^"]*)"`, "g");
  return [...new Set([...lock.matchAll(re)].map((m) => m[1]))].sort();
}

/** DOMPurify copies embedded in the minified bundle (its `version` + `removed` init). */
export function bundledDomPurifyVersions(html: string): string[] {
  const re = /\.version="(\d+\.\d+\.\d+)",[\w$]+\.removed=\[\]/g;
  return [...html.matchAll(re)].map((m) => m[1]);
}

export function checkBundle(i: BundleInputs): string[] {
  const problems: string[] = [];
  const deps = i.pkg.dependencies ?? {};
  const overrides = i.pkg.overrides ?? {};

  const sha = createHash("sha256").update(i.html).digest("hex");
  if (sha !== i.buildInfo.sha256) problems.push(`dist sha256 ${sha} != BUILD_INFO.sha256 ${i.buildInfo.sha256}`);
  if (JSON.stringify(i.buildInfo.deps ?? {}) !== JSON.stringify(deps)) {
    problems.push("BUILD_INFO.deps differs from package.json dependencies — rebuild dist");
  }
  if (JSON.stringify(i.buildInfo.overrides ?? {}) !== JSON.stringify(overrides)) {
    problems.push("BUILD_INFO.overrides differs from package.json overrides — rebuild dist");
  }

  for (const name of REQUIRED_OVERRIDES) {
    const want = overrides[name];
    if (!want) {
      problems.push(`package.json overrides is missing ${name}`);
      continue;
    }
    if (!EXACT.test(want)) problems.push(`override ${name}@${want} is not an exact pin`);
    const got = lockVersions(i.lock, name);
    if (got.length && (got.length !== 1 || got[0] !== want)) {
      problems.push(`bun.lock resolves ${name} to ${got.join(", ")}; override pins ${want}`);
    }
  }

  for (const name of SINGLE_COPY) {
    const got = lockVersions(i.lock, name);
    if (got.length !== 1 || got[0] !== deps[name]) {
      problems.push(`bun.lock resolves ${name} to ${got.join(", ") || "nothing"}; package.json pins ${deps[name]}`);
    }
  }

  const purify = bundledDomPurifyVersions(i.html);
  if (purify.length !== 1) {
    problems.push(`bundle embeds ${purify.length} DOMPurify copies (${purify.join(", ")}); expected exactly 1`);
  }
  for (const v of purify) {
    if (v !== overrides.dompurify) problems.push(`bundled DOMPurify ${v} != override ${overrides.dompurify}`);
  }
  return problems;
}

export async function loadInputs(root: string): Promise<BundleInputs> {
  return {
    html: await Bun.file(path.join(root, "dist", "diagram-render.html")).text(),
    buildInfo: await Bun.file(path.join(root, "dist", "BUILD_INFO.json")).json(),
    pkg: await Bun.file(path.join(root, "package.json")).json(),
    lock: await Bun.file(path.join(root, "bun.lock")).text(),
  };
}

if (import.meta.main) {
  const problems = checkBundle(await loadInputs(path.resolve(import.meta.dir, "..")));
  for (const p of problems) console.error(`BUNDLE_CHECK_FAIL: ${p}`);
  if (problems.length) process.exit(1);
  console.log("BUNDLE_CHECK_OK");
}
