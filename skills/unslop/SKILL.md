---
name: unslop
description: |
  Finds machine-sounding writing patterns in English prose (README, release notes, CHANGELOG, PR bodies, articles, posts, chat replies) and rewrites the text in a specific human voice while keeping every fact, number, name and claim. Use when a draft reads like a bot wrote it and it should read like the author did.
triggers:
  - unslop
  - humanize this text
  - de-ai this
  - remove ai writing patterns
  - make this sound human
  - clean up the prose
  - this reads like a bot
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "unslop", "humanize this", "de-ai this", "this reads like a bot", "make it sound like me", "clean up the prose before I post it", or when a README, CHANGELOG entry, release note, PR body or article draft needs a voice pass before it goes public.

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

## User-invocable
When the user types `/unslop`, run this skill. `/unslop --report <input>` lists hits and stops; `/unslop <input>` lists hits and rewrites.

---

## Step 1: Take the input

Accept one of three forms and normalise it to a numbered text buffer so every hit can cite a line.

- **File path.** Read the file. Note whether git tracks it, because that decides how Step 5 writes back:
  `git ls-files --error-unmatch <path> >/dev/null 2>&1 && echo TRACKED || echo UNTRACKED`
- **PR number.** Pull the body into a scratch file: `gh pr view <n> --json body -q .body > "${TMPDIR:-/tmp}/unslop-pr-<n>.md"`. Work on that file.
- **Pasted text.** Save it to `${TMPDIR:-/tmp}/unslop-paste.md` so the same commands apply.

Fix the scratch names now and use them unchanged for the rest of the run. `<stem>` is the input file's basename without its extension for a file path, `pr-<n>` for a PR, `paste` for pasted text. The rewrite always goes to `${TMPDIR:-/tmp}/unslop-<stem>.rewrite.md` — so a PR body lands in `${TMPDIR:-/tmp}/unslop-pr-<n>.rewrite.md`, beside the `${TMPDIR:-/tmp}/unslop-pr-<n>.md` it was pulled into.

Then number the lines for citation: `nl -ba <file>`.

Two checks before scanning:

1. **Mode.** `--report` means Steps 2 and 5 only: list the hits, no rewrite, no write-back. Default mode runs every step.
2. **Language.** Skim the first 20 lines. If the text is not English, run Step 2 and report; do not rewrite. Name the language in the output header. Mixed files (English prose with a few foreign strings) count as English.

If the input is empty or the PR has no body, stop and say so.

---

## Step 2: Scan against the catalogue

Read the whole text once for meaning, then walk it against the catalogue below. Record every hit as `line | pattern # | original phrase | proposed fix | severity`. The number is the key the user will see in the report, so keep it stable.

Severity: **high** means a reader would spot it as machine output on first read; **medium** means it weakens the text but might pass; **low** means a habit worth breaking, not a tell on its own.

### Content

1. **Puffery** (medium). Praise without a measurement: "powerful", "cutting-edge", "world-class", "best-in-class", "game-changing". Fix: state the measured thing, or delete.
2. **Name-dropping without context** (medium). A company, tool or person named for weight rather than for what they did. Fix: say what they did, or drop the name.
3. **Hollow -ing phrases** (high). A trailing participial clause that asserts significance: "ensuring reliability", "highlighting the importance of", "showcasing", "underscoring". Fix: cut it, or replace with the mechanism.
4. **Promotional adjectives** (medium). "elegant", "intuitive", "effortless", "blazing-fast", "lightweight" with no number behind them. Fix: the number, or nothing.
5. **Vague attribution** (medium). "experts agree", "many developers find", "studies show", "it is widely known". Fix: cite the source or own the claim in first person.
6. **Generic obstacles** (low). "despite challenges", "overcoming hurdles", "in the face of complexity" with no named problem. Fix: name the problem or cut the sentence.

### Language

7. **Stock vocabulary** (high). delve, tapestry, testament, pivotal, crucial, robust, seamless, leverage, landscape, journey, unlock, empower, elevate, harness, navigate, streamline, foster, realm, meticulous, comprehensive, "in today's fast-paced world". Fix: the plain word ("use" for leverage, "important" or nothing for crucial).
8. **Inflated copulas** (medium). "serves as", "stands as", "boasts", "acts as", "represents" where "is" or "has" is meant. Fix: "is", "has".
9. **"Not just X but Y"** (high). Also "not only ... but also" and "it's not about X, it's about Y". Fix: say Y.
10. **Forced rule of three** (medium). Three adjectives, three verbs or three bullets where the content has two or four. Fix: keep the count the content has.
11. **Synonym cycling** (medium). The same thing renamed each mention: "the tool ... the utility ... the solution ... the platform". Fix: one name, repeated.
12. **False ranges** (low). "from X to Y" where X and Y are not ends of a scale: "from startups to enterprises", "from bugs to features". Fix: list the actual items, or drop the frame.

### Style

13. **Em-dash overuse** (medium). More than one per paragraph, or an em-dash where a comma or full stop does the job. Fix: comma, period, or parentheses.
14. **Colon as connector** (low). "The result: faster builds." "One thing is clear: ..." used as a dramatic pause. Fix: a plain sentence.
15. **Scattered bold** (medium). Bold on random mid-sentence phrases for emphasis. Fix: unbold. Structural bold stays (see the keep list in Step 3).
16. **Header-restating lists** (medium). Every bullet opens with a bold lead, a colon and one sentence; or bullets that repeat the heading they sit under. Fix: plain bullets, or prose.
17. **Title Case headings** (low). "Getting Started With The Tool". Fix: sentence case, "Getting started with the tool". Product and proper names keep their capitals.
18. **Decorative emoji** (high). Emoji in headings, as bullet markers, or as a full stop. Fix: remove. Emoji that carry meaning in a status table (a pass/fail column) may stay.
19. **Curly quotes and typographic apostrophes** (low). `“ ” ‘ ’` in technical text; they break pasted commands. Fix: straight quotes.

### Communication artifacts

20. **Chatbot phrases** (high). "Great question", "Certainly!", "I hope this helps", "Let me know if you need anything else", "Here's a breakdown", an opening "In summary". Fix: delete the sentence.
21. **Cutoff disclaimers** (high). "As of my last update", "I don't have access to real-time data", "as an AI". Fix: delete, and check whether the surrounding claim still stands.
22. **Sycophancy** (high). "You're absolutely right", "excellent point", praise for the reader ahead of the content. Fix: delete.

### Filler

23. **Verbose phrases** (low). "in order to" (to), "due to the fact that" (because), "at this point in time" (now), "a wide variety of" (many), "it is important to note that" (nothing). Fix: the short form.
24. **Over-hedging** (low). "may potentially", "it could be argued", "to some extent", stacked "arguably ... somewhat". Fix: one hedge at most, and only where the author is unsure.
25. **Generic conclusions** (medium). "In conclusion", "Ultimately", "The future looks bright", "Only time will tell", a closing paragraph that restates the opening. Fix: end on the last concrete point.

### Jargon

26. **Abstract metaphor nouns** (medium). "ecosystem", "paradigm", "synergy", "north star", "flywheel", "the observability space", "framework" outside its software meaning. Fix: the concrete noun the metaphor stands for.

### Plain speech

27. **Feelings over mechanisms** (medium). "We're excited to announce", "we believe", "we're passionate about" where the reader needs what changed and how. Fix: what changed, how, and what it costs.
28. **Dense sentences** (low). Over about 30 words, or three clauses carrying three ideas. Fix: split.
29. **Passive voice hiding the actor** (low). "mistakes were made", "the file is read by the parser". Fix: name the actor. Passive stays when the actor is unknown or irrelevant.
30. **Weak verb + adverb** (low). "really improves", "significantly reduces", "quickly runs", "effectively handles". Fix: a strong verb, or the number.

### Mechanical first pass

Run these before the manual read. They catch the cheap cases and give exact line numbers; they do not replace the read.

```bash
F="<file>"
# 7: stock vocabulary
grep -niE '(^|[^[:alnum:]_])(delve|tapestry|testament|pivotal|crucial|robust|seamless(ly)?|leverag(e|es|ing)|landscape|journey|unlock(s|ing)?|empower(s|ing)?|elevat(e|es|ing)|harness(es|ing)?|navigat(e|es|ing)|streamlin(e|es|ing)|foster(s|ing)?|realm|meticulous(ly)?|comprehensive|cutting-edge|world-class|best-in-class|game-chang(er|ing))([^[:alnum:]_]|$)' "$F"
# 9: not just / not only
grep -niE 'not (just|only|simply|merely) .* but' "$F"
# 13: em-dash count per line
grep -nE '—.*—' "$F"; echo "em-dashes total: $(grep -o '—' "$F" | wc -l | tr -d ' ')"
# 17: Title Case headings (three or more capitalised words)
grep -nE '^#+ ([A-Z][a-z]+ ){2,}[A-Z]' "$F"
# 18: emoji (pictographs, dingbats, common symbols)
grep -nE '[🌀-🫿✀-➿⚡⭐]' "$F"
# 19: curly quotes
grep -nE '[“”‘’]' "$F"
# 20-22: chatbot phrases
grep -niE "great question|certainly!|i hope this helps|let me know if|you're absolutely right|as an ai|as of my last update" "$F"
# 23: verbose phrases
grep -niE 'in order to|due to the fact that|at this point in time|a wide variety of|it is important to note' "$F"
```

Skip fenced code blocks, inline code, URLs and tables when reading grep output; a hit inside a code fence is not a hit.

A finding looks like: `L14 | #7 | "leverage the cache" | "use the cache" | high`.

If the mode is `--report`, go to Step 5.

---

## Step 3: Rewrite

Rewrite the text top to bottom, not hit by hit. Fixing hits one at a time leaves the shape of the original, and the shape is usually the problem.

Keep, exactly:

- every number, date, version, percentage, name, URL, path, command and code block
- every claim the author makes, including ones you would not make yourself
- data tables and enumerable lists (a list of the platforms the tool runs on is a list, not a rule-of-three hit)
- the author's own domain terms, even ones that look like jargon to an outsider
- structural bold: the lead phrase of a list item, a label, a key figure
- short sentences; do not merge them to look fluent

Change:

- **Say what the author thinks.** If the text carries an opinion under the hedging ("some users may find the old flag confusing"), state it ("the old flag was confusing"). Do not add opinions the author does not hold; if you cannot tell, leave it neutral and flag it.
- **Concrete over abstract.** Replace "improves performance" with the number if it is anywhere in the source, and with the mechanism if it is not.
- **Vary rhythm.** Mix short and long sentences. A paragraph of same-length sentences reads generated even when each sentence is fine.
- **First person where natural.** README and release notes from a single maintainer read better as "I". Team docs read as "we". Do not switch a text that is already consistent.
- **Allow imperfection.** A sentence fragment, a paragraph of one line, a heading with no intro sentence: all fine. Symmetry is the tell.
- **Do not shorten for its own sake.** A rewrite that drops content to look tight fails the fact check in Step 4. Shorter is a side effect of cutting filler, not a goal.

Write the rewrite to `${TMPDIR:-/tmp}/unslop-<stem>.rewrite.md` so Step 5 can diff it.

---

## Step 4: Audit the rewrite

Run the rewrite through Step 2 again, headings included. Headings are where Title Case, emoji and rule-of-three come back.

Then fact-check against the original:

```bash
ORIG="<file>"
REWRITE="${TMPDIR:-/tmp}/unslop-<stem>.rewrite.md"
# Numbers, versions and URLs that appear in the original but not the rewrite
EXTRACT='[0-9][0-9.,%]*|v[0-9]+\.[0-9]+(\.[0-9]+)?|https?://[^[:space:])]+'
# sed drops the trailing . or , the character class swallowed at the end of a sentence
grep -oE "$EXTRACT" "$ORIG" | sed -E 's/[.,]+$//' | sort -u > "${TMPDIR:-/tmp}/unslop-facts-orig.txt"
grep -oE "$EXTRACT" "$REWRITE" | sed -E 's/[.,]+$//' | sort -u > "${TMPDIR:-/tmp}/unslop-facts-new.txt"
comm -23 "${TMPDIR:-/tmp}/unslop-facts-orig.txt" "${TMPDIR:-/tmp}/unslop-facts-new.txt"
```

Read each line that prints and find it in the rewrite before restoring it. Most are facts the rewrite lost; put those back. The rest is extractor noise, where the rewrite still carries the fact in another shape: "1,000" regrouped as "1000", a version quoted without its `v`. Do the same by eye for proper names and product names, which the grep does not catch.

If the second scan still finds high-severity hits, fix them and scan a third time. Stop when a scan returns no high hits; leftover low hits go in the report and are not chased.

---

## Step 5: Deliver and write back

Print the report from the Output section. In `--report` mode, that is the end.

In default mode, what happens next depends on where the input came from:

- **Pasted text.** The rewritten text in the report is the deliverable. Nothing is written anywhere.
- **Untracked file.** Show the diff, then ask before overwriting:
  `diff -u <path> "${TMPDIR:-/tmp}/unslop-<stem>.rewrite.md"`
- **Tracked file.** Same diff. Write back only after the user answers yes. Copy the rewrite over the original with `cp`; do not stage or commit anything.
- **PR body.** Show the diff between the scratch body and the rewrite. After a yes:
  `gh pr edit <n> --body-file "${TMPDIR:-/tmp}/unslop-pr-<n>.rewrite.md"`

The question is one line: "Apply this rewrite to <target>? (yes/no)". Anything other than a plain yes means no. Never write back for non-English input; there is no rewrite to apply.

---

## Output

```
UNSLOP REPORT
=============

Input:    <path | PR #n | pasted text>   Mode: <report | rewrite>   Language: <detected language>
Lines:    <n>   Hits: <n> (<h> high, <m> medium, <l> low)

Line | #  | Original                                  | Fix                                   | Severity
-----|----|-------------------------------------------|---------------------------------------|----------
3    | 20 | Great question! Here's a breakdown of ... | (deleted)                             | high
7    | 7  | leverage the existing cache               | use the existing cache                | high
7    | 9  | not just faster but more reliable         | faster, and it no longer drops writes | high
12   | 18 | ## 🚀 Getting Started                     | ## Getting started                    | high
19   | 13 | two em-dashes in one sentence             | split into two sentences              | medium
24   | 25 | In conclusion, the future looks bright    | (deleted; ends on the migration note) | medium

Kept on purpose: <structural bold in the options list; "sidecar" is the project's own term>
Facts checked: <n> numbers, <n> URLs, <n> names, all present in the rewrite.

--- REWRITE ---

<the full rewritten text>
```

For `--report` mode, stop after "Kept on purpose". Sort hits by line number, not severity; the reader walks the text top to bottom.

---

## Important Rules

1. **Never change numbers, names, URLs, code blocks or commands.** Step 4's fact check is the gate. If a fact would have to change for a sentence to read well, the sentence changes instead.
2. **Keep every claim.** Cutting a claim you disagree with is editing the author, not the prose. Flag it in "Kept on purpose" if it bothers you.
3. **Do not shorten for its own sake.** Length falls out of cutting filler. A rewrite that is half the length of the original almost always lost something.
4. **Anything that is not English: report only.** The catalogue is calibrated on English. List what looks off, say the rewrite was skipped, and stop.
5. **Read-only until the user says yes.** No file is overwritten, no PR body edited, no commit made, before a diff is shown and a plain yes comes back. Pasted text is never written anywhere.
6. **The catalogue is a lens, not a linter.** A grep hit inside a code block, a quoted phrase, or a product name is not a finding. A sentence that trips no pattern can still read generated; say so and fix it under the closest number.
7. **Structural bold and real lists stay.** Pattern 15 and 16 target decoration. A label, a key figure, a list of five file formats: keep them.
8. **The author's voice wins over the catalogue.** If the author uses "we" in every doc, do not switch to "I". If the project calls its component a "sidecar", do not rename it.

{{include lib/snippets/capture-learnings.md}}
