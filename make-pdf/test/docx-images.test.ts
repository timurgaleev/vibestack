/**
 * The DOCX converter sizes every embedded image by sniffing its bytes, and
 * its ICNS reader loops forever on an icon whose first entry declares length
 * zero. A mislabelled or hostile image must never reach it: ICNS payloads are
 * dropped with a warning, and a DOCX export of such a document still exits 0.
 */

import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { dropIcnsImages, isIcnsDataUri } from "../src/docx-images";

const CLI = path.resolve(import.meta.dir, "../src/cli.ts");

const scratch: string[] = [];
afterAll(() => {
  for (const d of scratch) fs.rmSync(d, { recursive: true, force: true });
});

/** ICNS header whose first icon entry has length 0 — the converter's hang case. */
function hangingIcns(): Buffer {
  const b = Buffer.alloc(64);
  b.write("icns", 0, "ascii");
  b.writeUInt32BE(64, 4);
  b.write("ic07", 8, "ascii");
  b.writeUInt32BE(0, 12);
  return b;
}

describe("DOCX export with an ICNS image", () => {
  test("a .png that is really ICNS is dropped and the export finishes", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mkpdf-icns-"));
    scratch.push(dir);
    fs.writeFileSync(path.join(dir, "icon.png"), hangingIcns());
    fs.writeFileSync(path.join(dir, "doc.md"), "# Icons\n\n![app icon](icon.png)\n\nAfter the icon.\n");
    const out = path.join(dir, "doc.docx");
    const r = spawnSync(process.execPath, [CLI, "generate", path.join(dir, "doc.md"), out, "--to", "docx"], {
      cwd: dir,
      encoding: "utf8",
      timeout: 20_000,
    });
    expect(r.signal).toBeNull();
    expect(r.status).toBe(0);
    expect(fs.existsSync(out)).toBe(true);
    expect(r.stderr).toContain("ICNS");
  });
});

describe("dropIcnsImages", () => {
  const icnsB64 = hangingIcns().toString("base64");
  const pngB64 = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489", "hex").toString("base64");

  test("drops an ICNS data URI whatever its declared type", () => {
    const warnings: string[] = [];
    const out = dropIcnsImages(`<p><img src="data:image/png;base64,${icnsB64}" alt="x"></p>`, (m) => warnings.push(m));
    expect(out).not.toContain(icnsB64);
    expect(out).toContain("ICNS icons are not supported");
    expect(warnings).toHaveLength(1);
  });

  test("sees through percent-encoding, entities and unquoted attributes", () => {
    const pct = icnsB64.replace(/^a/, "%61");
    const ent = icnsB64.replace(/^a/, "&#97;");
    for (const tag of [
      `<img src="data:image/png;base64,${pct}">`,
      `<img alt="a" src='data:image/png;base64,${ent}'>`,
      `<img src=data:application/octet-stream;base64,${icnsB64}>`,
    ]) {
      expect(dropIcnsImages(tag, () => {})).not.toContain("<img");
    }
  });

  test("keeps ordinary images untouched", () => {
    const html = `<img src="data:image/png;base64,${pngB64}" alt="dot"><img src="https://example.com/x.png">`;
    const warnings: string[] = [];
    expect(dropIcnsImages(html, (m) => warnings.push(m))).toBe(html);
    expect(warnings).toHaveLength(0);
  });

  test("fails the export when an ICNS src survives outside an <img>", () => {
    expect(() => dropIcnsImages(`<image src="data:image/png;base64,${icnsB64}">`, () => {})).toThrow(/ICNS/);
  });

  test("isIcnsDataUri ignores non-data and non-base64 URIs", () => {
    expect(isIcnsDataUri("icon.icns")).toBe(false);
    expect(isIcnsDataUri("data:image/png,icns")).toBe(false);
  });
});
