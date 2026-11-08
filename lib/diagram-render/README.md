# diagram-render

Offline diagram rendering for make-pdf and /diagram. One self-contained HTML
page (`dist/diagram-render.html`, ~9MB) bundles mermaid, the excalidraw export
utilities, and the official mermaid→excalidraw converter. The browse daemon
loads it with `load-html`; callers drive it through `browse js` and pull bytes
back with `js --out`.

The built page is **committed** (eng-review D2): rendering works with zero
network at install time and render time, and there is no npm supply-chain
surface in `./setup`. `scripts/check-bundle.ts` (run by `test/check-bundle.test.ts`)
fails if `dist/` is edited by hand or falls out of sync with `BUILD_INFO.json`,
if a security override in `package.json` did not take, or if the bundle carries
more than one DOMPurify.

## Page API (window functions)

| Function | In → Out |
|---|---|
| `__renderMermaid(id, text)` | mermaid text → SVG string. `id` must be unique per fence (`mermaid-fence-<n>`) — it namespaces every internal SVG id. |
| `__mermaidToExcalidraw(text)` | mermaid text → `.excalidraw` scene JSON (flowcharts fully; other types degrade upstream). |
| `__excalidrawToSvg(sceneJson)` | scene JSON → SVG string (Excalifont embedded, offline). |
| `__rasterize(svg, targetWidthPx)` | SVG → PNG data URL. Callers own DPI math: `targetWidthPx = placed width (in) × 300`. Throws on tainted canvas. |
| `__downscaleRaster(dataUri, targetWidthPx, mime)` | raster data URI → smaller data URI at `targetWidthPx` (same mime). make-pdf uses it to normalize oversized photos to print resolution. |
| `__mountForScreenshot(svg, px)` | taint-proof fallback: mounts SVG at `#raster-stage` for `browse screenshot --selector`. |
| `__probeImage(src)` | data URI/URL → `{width, height}` JSON. |
| `__bundleInfo` | `{ name, deps }` — pinned dependency versions baked at build. |

Readiness: poll until `#status` text is `ready` (or `browse wait '#done'`).
Page errors accumulate in `window.__errors`.

## Updating

```bash
# 1. edit the exact pin in package.json
cd lib/diagram-render && bun install
# 2. rebuild (deterministic; build twice → same sha)
bun run build
# 3. verify, then commit package.json + bun.lock + dist/ together
bun run scripts/check-bundle.ts
```

Keep the excalidraw triplet coherent: `@excalidraw/excalidraw` pins its own
`@excalidraw/mermaid-to-excalidraw`, and that one names a mermaid range. Pin all
three so bun.lock holds one copy of each — a mismatch nests a second, older
mermaid (with its own DOMPurify) inside the bundle. `overrides` force one
patched version of the transitive packages with published advisories.

Render contract details (securityLevel strict, htmlLabels false, print-css font
lock, `<base href>` + `</scri` escaping) are documented in `src/entry.ts` and
`scripts/build.ts` — read both before touching either.
