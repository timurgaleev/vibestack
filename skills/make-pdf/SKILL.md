---
name: make-pdf
description: |
  Generate professional PDFs from code, markdown, or HTML in the current repository.
  Supports cover pages, tables of contents, watermarks, custom margins, and page sizes.
  Use when asked to "make pdf", "generate pdf", "export to pdf", "create pdf report",
  or "pdf preview".
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

## Preamble

```bash
eval "$(~/.tstackvibe/bin/tvibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${TSTACKVIBE_HOME:-$HOME/.tstackvibe}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.tstackvibe/bin/tvibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

## Step 0: Find the make-pdf binary

```bash
# Check environment override first, then tstackvibe repo path as fallback
P="${MAKE_PDF_BIN:-}"
if [ -z "$P" ]; then
  _TVIBE_PDF="$HOME/.claude/skills/tstackvibe-repo/make-pdf/dist/pdf"
  [ -x "$_TVIBE_PDF" ] && P="$_TVIBE_PDF"
fi
[ -n "$P" ] && echo "FOUND: $P" || echo "NOT_FOUND"
```

If `NOT_FOUND`, stop and tell the user:

> make-pdf binary not found. The binary must be built from the tstackvibe repo.
> Run: `cd ~/.claude/skills/tstackvibe-repo && bun install && bun run build:make-pdf`
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
- `--margins "<top> <right> <bottom> <left>"` — custom margins in mm (default: `20 20 20 20`)
- `--page-size <size>` — A4 (default), Letter, Legal
- `--title "<title>"` — override document title
- `--author "<name>"` — set author metadata

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

Run the setup wizard to configure defaults for this project:

```bash
"$P" setup
```

This writes a `.make-pdf.json` config file in the project root. Show the user what was configured.

---

## Core patterns

### 80% case — memo/letter

One command, no flags. Gets a clean PDF with running header + page numbers.

```bash
"$P" generate letter.md                 # writes /tmp/letter.pdf
"$P" generate letter.md letter.pdf      # explicit output path
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

### Fast iteration via preview

```bash
"$P" preview essay.md
```

Renders with print CSS and opens in browser. Skip the PDF round trip until you're ready.

---

## Common flags

```
Page layout:
  --margins <dim>            1in (default) | 72pt | 2.54cm | 25mm
  --page-size letter|a4|legal

Structure:
  --cover                    Cover page (title, author, date)
  --toc                      Clickable TOC with page numbers
  --no-chapter-breaks        Don't start a new page at every H1

Branding:
  --watermark <text>         Diagonal watermark ("DRAFT", "CONFIDENTIAL")
  --header-template <html>   Custom running header
  --footer-template <html>   Custom footer (mutex with --page-numbers)

Output:
  --page-numbers             "N of M" footer (default on)
  --quiet                    Suppress progress on stderr
  --verbose                  Per-stage timings

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

exit code: 0 success / 1 bad args / 2 render error / 3 timeout / 4 binary unavailable
```

Capture the path: `PDF=$("$P" generate letter.md)` — then use `$PDF`.

---

## Debugging

- **Blank output** → check binary is executable: `ls -la "$P"`
- **Fragmented text on copy-paste** → remove fenced code blocks and regenerate
- **Timeout** → no headings in the markdown, drop `--toc`
- **External image missing** → the binary fetches external images only when `--allow-network` is set

---

## Capture Learnings

If you discovered a non-obvious make-pdf behavior, flag pattern, or conversion quirk
during this session, log it for future sessions:

```bash
~/.tstackvibe/bin/tvibe-learnings-log '{"skill":"make-pdf","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `tool`
(binary behavior), `operational` (env/path/dependency quirk).

**Only log genuine discoveries.** A good test: would this save time in a future session?
