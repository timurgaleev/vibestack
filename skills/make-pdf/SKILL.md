---
name: make-pdf
description: |
  Generate professional PDFs from code, markdown, or HTML in the current repository. Supports cover pages, tables of contents, watermarks, custom margins, and page sizes.
triggers:
  - make pdf
  - generate pdf
  - create pdf
  - export pdf
  - pdf preview
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - AskUserQuestion
---

## When to invoke

Use when asked to "make pdf", "generate pdf", "export to pdf", "create pdf report", or "pdf preview".

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## Step 0: Find the make-pdf renderer

```bash
# Env override first, then the launcher installed with this skill (resolves
# the repo's compiled binary or runs the CLI on bun).
P="${MAKE_PDF_BIN:-${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/make-pdf}/bin/vibe-make-pdf}"
[ -x "$P" ] && "$P" version >/dev/null 2>&1 && echo "FOUND: $P" || echo "NOT_FOUND"
```

If `NOT_FOUND`, stop and tell the user:

> make-pdf renderer not found. It ships with the vibestack repo.
> Run: `cd ~/data/vibestack && bun install && bun run build:make-pdf && ./install`
> Or set `$MAKE_PDF_BIN` to the path of an existing `make-pdf` binary.
>
> After building, re-run `/make-pdf`.

---

## Step 1: Detect intent

Parse the user's input to determine what to do:

1. `/make-pdf` with no args — **Auto-detect**: look for markdown files or ask what to convert
2. `/make-pdf preview <file>` — **Preview mode**: generate and open a PDF preview
3. `/make-pdf setup` — **Setup mode**: run `$P setup` to configure defaults
4. `/make-pdf <file or description>` — **Generate mode**: produce a PDF from the specified input

---

## Step 2A: Generate mode

1. Identify the source file(s). If the user provided a path, use it. If not, ask:
   ```
   What should I turn into a PDF?
   A) A specific file (provide path)
   B) All markdown files in this directory
   C) A generated report (I'll describe what to include)
   D) Something else
   ```

2. Determine output filename. Default: `<source-basename>.pdf` in the same directory.

3. Run the generator:

```bash
"$P" generate "<source>" --output "<output.pdf>" [flags]
```

Common flags:
- `--cover` — add a cover page (uses repo name + date)
- `--toc` — add a table of contents
- `--watermark "<text>"` — overlay watermark text (e.g., "DRAFT", "CONFIDENTIAL")
- `--margins <dim>` — one dimension for all four margins (default: `1in`; also `72pt`, `2.54cm`, `25mm`)
- `--page-size <size>` — A4 (default), Letter, Legal
- `--title "<title>"` — override document title
- `--author "<name>"` — set author metadata
- `--to pdf|html|docx` — output format (default: `pdf`)
- `--no-confidential` — suppress the CONFIDENTIAL footer stamped by default
- `--strict` — missing or remote images fail the run instead of warning

4. Report the result:

```
PDF GENERATED
═══════════════════════════════════════════
Output:  <output.pdf>
Size:    <file size>
Pages:   <page count>
═══════════════════════════════════════════
```

---

## Step 2B: Preview mode

Generate the PDF and open it:

```bash
"$P" preview "<source>" [flags]
```

This generates a temporary PDF and opens it in the system PDF viewer. Report the path if the user wants to save it.

---

## Step 2C: Setup mode

Verify the render toolchain — browse binary, Chromium launch, `pdftotext` (optional) — then
generate and open a smoke-test PDF:

```bash
"$P" setup
```

It writes no config file. Report which checks passed and, if Chromium or the browse binary
failed, relay the fix it printed before attempting any other mode.

---

## Core patterns

### 80% case — memo/letter

One command, no flags. Gets a clean PDF with running header, page numbers, and a
CONFIDENTIAL right-footer.

```bash
"$P" generate letter.md                 # writes /tmp/letter.pdf
"$P" generate letter.md letter.pdf      # explicit output path
```

### Brand-free — no CONFIDENTIAL footer

The footer is on by default, so anything meant to leave the building needs it turned off:

```bash
"$P" generate --no-confidential memo.md memo.pdf
```

### Publication mode — cover + TOC + chapter breaks

```bash
"$P" generate --cover --toc --title "On Horizons" essay.md essay.pdf
```

Each top-level H1 starts a new page. Disable with `--no-chapter-breaks` for memos that happen to have multiple H1s.

### Draft-stage watermark

```bash
"$P" generate --watermark DRAFT memo.md draft.pdf
```

Diagonal DRAFT across every page. Drop the flag when final.

### Diagrams — mermaid and excalidraw fences render as pictures

A column-0 ```` ```mermaid ```` or ```` ```excalidraw ```` fence renders as a vector diagram,
offline. Indented fences are left alone, so a fence quoted inside a list stays a code block.

Info-string options on the opening fence:

- `title="Auth flow"` — accessible label for the rendered figure
- `render=false` — leave this fence as a plain code block (the escape hatch when the source
  is what the reader needs to see)
- `page=landscape` / `page=portrait` — force or veto a landscape page for this diagram

A fence whose source fails to parse becomes a visible red diagnostic block carrying the error
and an excerpt — never a silently missing figure. When that shows up, fix the diagram source
rather than dropping the fence.

### Images — scaled right, never truncated

A directive suffix on a markdown image tunes its placement:

```markdown
![chart](data.png){width=full}
![chart](data.png){width=50%}
![diagram](wide.svg){page=landscape}
![diagram](wide.svg){page=portrait}
```

`width` takes `full`, a percentage, or an absolute dimension (`in`, `cm`, `mm`, `pt`, `px`).
By default an image renders at its intrinsic size, capped at the content box and never
upscaled.

Wide, small-text images auto-promote to their own landscape page. The heuristic is deliberately
conservative — aspect ratio at least 1.8, intrinsic width over roughly 2.5x the content box,
*and* either diagram provenance or a diagram-ish word in the alt text — so it misses more often
than it fires. `{page=landscape}` forces promotion; `{page=portrait}` vetoes it.

Local images are inlined as data URIs and rasters wider than print resolution are downscaled.
An image that is missing, not a regular file, or over 64MB degrades to a visible placeholder
with a warning; one resolving outside the markdown's own directory is inlined but warned about,
because an agent rendering untrusted markdown should not quietly embed a file from elsewhere on
the machine into a shareable document.

### Other formats — single-file HTML and Word

```bash
"$P" generate readme.md out.html --to html     # one self-contained file, no network refs
"$P" generate readme.md out.docx --to docx     # content fidelity; diagrams become PNG
```

`--to` is the output format. `--format` is something else entirely — an alias for
`--page-size` — so `--format html` asks for a page size named "html", not HTML output.

### CI mode — fail loud on missing assets

```bash
"$P" generate docs.md --strict
```

Missing, unreadable, oversized, out-of-tree, and remote images become hard failures instead of
warnings, so a broken asset path fails the build rather than shipping a placeholder.

### Fast iteration via preview

```bash
"$P" preview essay.md
```

Renders with print CSS and opens in browser. Skip the PDF round trip until you're ready.

---

## Common flags

```
Output format:
  --to pdf|html|docx         What to produce (default: pdf)

Page layout:
  --margins <dim>            1in (default) | 72pt | 2.54cm | 25mm
  --page-size letter|a4|legal   (alias --format — page SIZE, not --to)

Structure:
  --cover                    Cover page (title, author, date)
  --toc                      Clickable TOC with page numbers
  --no-chapter-breaks        Don't start a new page at every H1

Branding:
  --watermark <text>         Diagonal watermark ("DRAFT", "CONFIDENTIAL")
  --header-template <html>   Custom running header
  --footer-template <html>   Custom footer (mutex with --page-numbers)
  --no-confidential          Suppress the CONFIDENTIAL right-footer (on by default)

Output:
  --page-numbers             "N of M" footer (default on)
  --tagged                   Accessible PDF (default on)
  --outline                  PDF bookmarks from headings (default on)
  --quiet                    Suppress progress on stderr
  --verbose                  Per-stage timings

Images:
  --strict                   Missing/remote images fail the run (CI mode)

Network:
  --allow-network            Fetch external images. Off by default
                             (blocks tracking pixels).

Metadata:
  --title "..."              Document title (defaults to first H1)
  --author "..."             Author for cover + PDF metadata
  --date "..."               Date for cover (defaults to today)
```

---

## When to run it

Watch for markdown-to-PDF intent. Any of these → run `"$P" generate`:

- "Can you make this markdown a PDF"
- "Export it as a PDF"
- "Turn this into a PDF"
- "I need a PDF of this"
- "Print this as a PDF for me"

If the user has a `.md` file open and says "make it look nice", propose `"$P" generate --cover --toc` and ask before running.

---

## Output contract

```
stdout: /tmp/letter.pdf          ← just the path, one line
stderr: Rendering HTML...        ← progress (unless --quiet)
        Generating PDF...
        Done in 1.5s. 43 words · 22KB · /tmp/letter.pdf

exit code: 0 success / 1 bad args / 2 render error / 3 Paged.js timeout / 4 binary unavailable
```

Capture the path: `PDF=$("$P" generate letter.md)` — then use `$PDF`.

---

## Debugging

- **Blank output** → check binary is executable: `ls -la "$P"`
- **Fragmented text on copy-paste** → remove fenced code blocks and regenerate
- **Timeout** → no headings in the markdown, drop `--toc`
- **External image missing** → the binary fetches external images only when `--allow-network` is set
- **Wrong text metrics or ▯ boxes where emoji should be (Linux, containers)** → the print CSS
  falls back to Liberation Sans and a system color-emoji font; install `fonts-liberation` and a
  Noto color-emoji package, neither of which the vibestack installer provides

---

## Capture Learnings

If you discovered a non-obvious make-pdf behavior, flag pattern, or conversion quirk
during this session, log it for future sessions:

```bash
~/.vibestack/bin/vibe-learnings-log '{"skill":"make-pdf","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `tool`
(binary behavior), `operational` (env/path/dependency quirk).

**Only log genuine discoveries.** A good test: would this save time in a future session?
