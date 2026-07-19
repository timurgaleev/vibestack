---
name: scrape
description: |
  Pull structured data from a web page with the browse shim — navigate, extract, return JSON. Read-only.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
triggers:
  - scrape this page
  - get data from
  - pull from
  - extract from
  - what is on this page
---

## When to invoke

Use to extract data from a page — "scrape", "get data from", "pull", "extract
from", "what's on this page". Read-only: for form fills, clicks, or submissions
use the browse daemon's interaction verbs, not this skill.

# /scrape — Pull data from a page

{{include lib/snippets/browse-setup.md}}

If `BROWSE_NOT_AVAILABLE`: fall back to `curl` + an HTML parse for static pages
(note that JS-rendered content and screenshots are unavailable), or stop and tell
the user the browse shim is needed.

### 0. Match — is this already a skill?

Before prototyping a new scrape, check whether a codified skill already covers
this target:

```bash
ls ~/.claude/skills/ 2>/dev/null | grep -iE '<site-or-domain-keyword>' || echo "NO_MATCH"
```

If a matching skill exists, suggest running it (`/that-skill`) instead of
re-deriving the flow. Only prototype when there's no match.

### 1. Pin the target

Confirm the URL and exactly which fields the user wants (single record, or a list
with per-item fields). If it's ambiguous, ask once with AskUserQuestion.

### 2. Navigate and inspect

```bash
"$B" goto <url>
"$B" text          # full visible text — orient yourself
```

For structured values, pull them by selector with `js` (the stateless shim
evaluates against a fresh load) — e.g. a list of prices:

```bash
"$B" js "Array.from(document.querySelectorAll('.price')).map(e => e.textContent.trim())"
```

If the page is interactive (needs a click to reveal data), start the daemon and
use a chain or refs: `"$B" daemon &` then `"$B" chain "goto <url>" "click <sel>" "text"`.

### 3. Extract to JSON

Assemble a JSON object (single record) or array (list) of the requested fields,
mapping each item's selectors. Verify the count matches what's visible. Quote
selectors exactly — never guess a value that isn't on the page.

### 4. Return

**Output discipline: emit ONE pipeable JSON document and nothing else** — no
surrounding prose, no markdown fences, so the output can be piped into `jq` or a
file. Name any requested field that couldn't be found (as `null` with a short
note in a `_missing` array) rather than fabricating it. If JS-heavy content is
missing, retry once via the daemon with a short wait
(`"$B" chain "goto <url>" "wait 1500" "text"`).

### Failure protocol

Scraping fails in known ways (selector drift, JS-gated content, anti-bot walls).
Handle them, don't paper over them:

- **Attempt budget: 3.** Stateless pass → daemon + wait → daemon + interaction.
  After the third failed attempt, STOP.
- **No partial results as success.** If some requested fields are unreachable,
  return what you have with an explicit `_missing` list — never present a partial
  scrape as complete.
- **On a hard stop, offer the choice** (AskUserQuestion): A) try `/connect-chrome`
  (the page needs a real logged-in session), B) adjust the target/fields,
  C) give up — the site is protected or JS-gated beyond the shim.

### Codify a repeat

If this scrape worked and the user is likely to run it again, offer to `/skillify`
it into a reusable `/<name>` so the flow becomes one command next time.

## Discipline

- **Read-only.** No form submits or destructive clicks here.
- **One pass, gently.** Don't hammer the site. If the target is behind a login or
  looks protected (ToS / robots), ask the user before proceeding; for an
  authenticated page, `/connect-chrome` reuses their real session.

{{include lib/snippets/capture-learnings.md}}
