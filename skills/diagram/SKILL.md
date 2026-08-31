---
name: diagram
description: |
  Render a Mermaid diagram to a self-contained HTML file and a PNG, using the browse shim as the renderer — no heavy diagram toolchain to install.
allowed-tools:
  - Bash
  - Read
  - Write
triggers:
  - draw a diagram
  - make a mermaid diagram
  - render this flowchart
  - diagram this
  - visualize this as a graph
---

## When to invoke

Use to turn a description or some Mermaid source into a picture — "draw a
diagram", "make a flowchart", "diagram this architecture", "visualize this as a
graph".

# /diagram — Render a Mermaid diagram

vibestack renders **Mermaid** offline. The repo ships the whole renderer as one
self-contained page (`lib/diagram-render/dist/diagram-render.html`, mermaid
pinned at build time), so the browse shim turns your source into SVG with no
network at all. The SVG is inlined into the HTML artifact you keep — it opens in
any browser, on any machine, forever, with nothing to fetch — and the PNG comes
from the same `$B` you already use for QA.

{{include lib/snippets/browse-setup.md}}

### 1. Get the Mermaid source

If the user gave Mermaid, use it. Otherwise write it from their description
(`flowchart`, `sequenceDiagram`, `erDiagram`, `classDiagram`, `gantt`, etc.).
Pick an output base path (default `./diagram`).

Write the Mermaid source to `$OUT.mmd` with the Write tool. Passing it through a
heredoc mangles quotes and backslashes in edge labels, and it is the artifact the
user edits to re-render anyway.

### 2. Render the source to SVG with the offline bundle

The staged copy is content-addressed, so concurrent sessions and mixed vibestack
versions never clobber each other:

```bash
OUT="${OUT:-./diagram}"            # base path; produces $OUT.mmd, $OUT.html, $OUT.png
mkdir -p "$(dirname "$OUT")"

# The renderer is linked into this skill's own directory at install time
# (skills/diagram/renderer -> lib/diagram-render), so it resolves the same way
# in a user-scope install, a project-scope install, and the checkout itself.
BUNDLE=""
for c in "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/diagram}/renderer/dist/diagram-render.html" \
         "$(git rev-parse --show-toplevel 2>/dev/null)/lib/diagram-render/dist/diagram-render.html"; do
  [ -f "$c" ] && BUNDLE="$c" && break
done
if [ -z "$BUNDLE" ] || [ -z "${B:-}" ] || [ "$("$B" status 2>/dev/null)" = "BROWSE_NOT_AVAILABLE" ]; then
  echo "RENDER_UNAVAILABLE"
else
  SHA=$(shasum -a 256 "$BUNDLE" | cut -c1-16)
  STAGED="${TMPDIR:-/tmp}/vibestack-diagram-render-$SHA.html"
  [ -f "$STAGED" ] || { cp "$BUNDLE" "$STAGED.$$" && mv "$STAGED.$$" "$STAGED"; }
  TAB=$("$B" newtab --json | sed -n 's/.*"tabId":[[:space:]]*\([0-9]*\).*/\1/p')
  [ -z "$TAB" ] && { echo "TAB_OPEN_FAILED — daemon busy? check browse status"; } || {
    "$B" load-html "$STAGED" --tab-id "$TAB"
    "$B" wait '#done' --tab-id "$TAB"
    echo "RENDER_TAB_READY: tab $TAB"
  }
fi
```

**Both failure lines are terminal — STOP, do not continue to Step 3.** With no
`$TAB` and no `$OUT.svg`, the steps below would build an HTML file around a
file that does not exist and screenshot a blank page, reporting success. On
`RENDER_UNAVAILABLE`, say which half is missing. A missing bundle means an
incomplete checkout — re-run `./install` from it. A missing shim means the
browse dependencies were never fetched; `$B status` bootstraps them on first
use and prints `BROWSE_NOT_AVAILABLE` when it cannot (npm absent). On
`TAB_OPEN_FAILED`, report what `$B status` says — the daemon is busy, wedged,
or unable to open a tab — and re-run.

Every `$B js` / `$B wait` / `$B closetab` below MUST pass `--tab-id $TAB`. Without
it the call hits whatever tab is active, which may be a live `/qa` or `/scrape`
session sharing the daemon.

Render the source, reading it from disk inside the page call so no shell quoting
touches the Mermaid text:

```bash
"$B" js "__renderMermaid('diagram-1', $(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$OUT.mmd"))" \
  --tab-id "$TAB" --out "$OUT.svg"
"$B" closetab "$TAB" >/dev/null 2>&1 || true
```

If the call errors, the Mermaid has a syntax problem — read the error, fix
`$OUT.mmd`, and re-render. Do not fall back to a CDN page: rendering is offline
by design, and a silent network fallback turns an air-gapped failure into a
blank diagram nobody notices.

### 3. Inline the SVG into the HTML artifact, then screenshot it

```bash
{
  printf '%s' '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Diagram</title>'
  printf '%s' '<style>body{margin:0;padding:20px;background:#fff;font-family:system-ui}svg{max-width:100%}</style>'
  printf '%s' '</head><body>'
  cat "$OUT.svg"
  printf '%s' '</body></html>'
} > "$OUT.html"

if [ -n "${B:-}" ] && [ "$("$B" status 2>/dev/null)" != "BROWSE_NOT_AVAILABLE" ]; then
  "$B" chain "goto file://$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT").html" "wait --load" "screenshot $OUT.png"
  echo "DIAGRAM: $OUT.png (and $OUT.html, $OUT.svg, $OUT.mmd)"
else
  echo "DIAGRAM_HTML_ONLY: $OUT.html — open it in a browser (no shim for PNG)"
fi
```

The SVG is already drawn, so the capture waits on page load rather than on a
fixed timer — nothing is still rendering when the screenshot fires.

### 4. Report

List the artifacts: `.mmd` (the source to edit), `.svg` (vector for docs),
`.html` (opens anywhere, offline), `.png` (for chat and READMEs).

## Notes

- **Mermaid is the supported format.** Excalidraw, DOCX, and multi-page exports
  are not rendered here — for those, hand the user the HTML or use a dedicated
  tool.
- **Fully offline.** The renderer is vendored in the repo, and the HTML artifact
  carries the finished SVG inline — no CDN, no network, at render time or later.
- If `RENDER_UNAVAILABLE` printed, say what is missing and how to get it back
  (`./install` from the checkout for the bundle; `$B status` to bootstrap the
  browse dependencies). Never fall back to a CDN behind the user's back.

{{include lib/snippets/capture-learnings.md}}
