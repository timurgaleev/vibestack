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

vibestack renders **Mermaid** by wrapping it in a self-contained HTML page
(Mermaid from a CDN) and screenshotting it with the browse shim. No extra
toolchain: the HTML opens in any browser even with no shim, and the PNG is
produced by the same `$B` you already use for QA.

{{include lib/snippets/browse-setup.md}}

### 1. Get the Mermaid source

If the user gave Mermaid, use it. Otherwise write it from their description
(`flowchart`, `sequenceDiagram`, `erDiagram`, `classDiagram`, `gantt`, etc.).
Pick an output base path (default `./diagram`).

### 2. Write the self-contained HTML

```bash
OUT="${OUT:-./diagram}"            # base path; produces $OUT.html and $OUT.png
mkdir -p "$(dirname "$OUT")"
cat > "$OUT.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8">
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<style>body{margin:0;padding:20px;background:#fff;font-family:system-ui}</style>
</head><body>
<pre class="mermaid">
__MERMAID__
</pre>
<script>mermaid.initialize({startOnLoad:true,theme:'default'});</script>
</body></html>
HTML
```

Replace the `__MERMAID__` placeholder with the actual source (write the file with
the Write tool if the diagram has characters awkward for a heredoc).

### 3. Render to PNG with the shim

```bash
if [ -n "${B:-}" ] && [ "$("$B" status 2>/dev/null)" != "BROWSE_NOT_AVAILABLE" ]; then
  "$B" daemon >/dev/null 2>&1 &        # the daemon lets Mermaid finish drawing before capture
  sleep 1
  "$B" chain "goto file://$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT").html" "wait 1200" "screenshot $OUT.png"
  "$B" daemon-stop >/dev/null 2>&1 || true
  echo "DIAGRAM: $OUT.png (and $OUT.html)"
else
  echo "DIAGRAM_HTML_ONLY: $OUT.html — open it in a browser (no shim for PNG)"
fi
```

### 4. Report

Show the PNG path (and the HTML). If the chain reported an error, the Mermaid
likely has a syntax issue — fix the source and re-render.

## Notes

- **Mermaid is the supported format.** Excalidraw, DOCX, and multi-page exports
  are not rendered here — for those, hand the user the HTML or use a dedicated
  tool.
- The HTML is self-contained and offline-friendly except the one CDN script tag;
  it renders in any modern browser.

{{include lib/snippets/capture-learnings.md}}
