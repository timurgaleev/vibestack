#!/usr/bin/env bash
# test-untrusted-shell-text.sh — untrusted text never becomes shell source.
#
# Plan, spec and PR text, issue bodies, user questions, custom instructions,
# focus areas, design briefs and pasted tool output reach a command only through
# a file the model writes with its Write tool. Shell source carries the file's
# PATH, never its text: inside double quotes backticks and $(...) run, a single
# quote ends a single-quoted argument, and a line equal to a heredoc's terminator
# ends the heredoc and runs everything after it.
#
# Covers:
#   - every rendered skill, every skill sub-doc and every snippet, scanned per
#     fenced shell block, for (a) a heredoc whose body holds a <placeholder>,
#     {placeholder} or paste-here prose standing for external text, (b) a quoted
#     argument holding a placeholder for an untrusted role (brief, body, plan,
#     spec, question, focus, instructions, feedback, description, prompt,
#     comment, reply, user message), and (c) a file's text spliced into a
#     `-d`/`--data`/`-F` argument, bare or as name=value, with $(cat ...). A
#     short allowlist below names the justified exceptions by block signature,
#     each with its reason. The allowlist holds only model-authored or fixed
#     text (the model's own questions, ledger lines and commit messages, or a
#     comment in a fixed helper) and must stay that way: untrusted text is
#     fixed by moving it into a file, never by allowlisting it;
#   - a scanner self-test on a fixture doc: each unsafe shape is flagged and
#     each file-based shape passes, so a scanner that silently matches nothing
#     cannot report the tree clean;
#   - the fixed blocks of /claude, /spec, /ship, /pr-summary, /address-pr-review,
#     /office-hours, /design-consultation and /design-review, run with hostile
#     text (terminator lines, $(...), backticks, quote breakouts) in the file the
#     model writes: the consumer receives it byte-for-byte and nothing runs.
#
# Usage: test/test-untrusted-shell-text.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# Justified exceptions: <doc or *> | <text the flagged line contains> | <reason>.
# Matched by content, so they survive line moves; an entry nothing matches fails.
cat > "$TMP/allow.txt" <<'ALLOW'
* | vibe-question-check --id "<skill>:<question-id>" | the summary is the model's own one-line question, not user text
skills/plan-tune/SKILL.md | vibe-question-check --id "<id>" --summary "<question text>" | the summary is the model's own one-line question, not user text
skills/spec/SKILL.md | vibe-decision-log '{"decision":"Spec filed | model-authored one-line ledger entry
skills/kb-review/SKILL.md | --arg text '<question only tenant B can answer>' | a probe question the model invents; jq --arg takes it as data
skills/bedrock-guardrails/SKILL.md | <<'PROBE' | a fixed helper; <control-label> is in a comment of trusted code
skills/ship/SKILL.md | git commit -m "$(cat <<'EOF' | model-authored commit message
skills/document-generate/SKILL.md | git commit -m "$(cat <<'EOF' | model-authored commit message
ALLOW

render_root="$TMP/r"
docs=()
for s in "$SRC"/skills/*/SKILL.md; do
  n="$(basename "$(dirname "$s")")"
  mkdir -p "$render_root/$n"
  if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$s" "$render_root/$n/SKILL.md" >/dev/null 2>&1; then
    docs+=("skills/$n/SKILL.md=$render_root/$n/SKILL.md")
  else
    no "$n renders"
  fi
done
while IFS= read -r f; do docs+=("${f#"$SRC"/}=$f"); done \
  < <(find "$SRC/skills" -name '*.md' ! -name SKILL.md | sort; ls "$SRC"/lib/snippets/*.md)

cat > "$TMP/scan.py" <<'PY'
import re, sys

allow = []
for raw in open(sys.argv[1], encoding="utf-8"):
    parts = [p.strip() for p in raw.rstrip("\n").split(" | ", 2)]
    if len(parts) != 3 or not all(parts):
        sys.exit("bad allowlist line: " + raw)
    allow.append(parts + [0])

FENCE = re.compile(r"^([ \t]*)(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+-]*)")
SHELL = {"bash", "sh", "shell", "zsh"}
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*\\?(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
# Code the heredoc feeds to an interpreter: braces there are code, not slots.
PROGRAM = re.compile(r"(^|[\s|;&(])(python3?|node|bun|awk|gawk|jq|ruby|perl|sqlite3|psql)(\s|$)")
ANGLE = re.compile(r"(?<!<)<(?![<=/!-])([A-Za-z\[][^<>\n]*?)>(?!>)")
BRACE = re.compile(r"(?<![$\\{])\{([A-Za-z][A-Za-z0-9 _./:-]*)\}(?!\})")
SQUARE = re.compile(r"\[[A-Z][A-Za-z /_-]{2,}\]")
PROSE = re.compile(r"(?i)\b(paste (it |the |your )?here|insert (the|your) |full text of|verbatim (text|copy) of)")
ROLE = re.compile(r"(?i)\b(brief|body|plan|spec|question|focus|instructions?|feedback|description|prompt|comment|reply|user|message)s?\b")
IDENT = re.compile(r"(?i)(id|file|name|path|dir|number|url|sha|slug|key)$")
ROLE_FLAG = re.compile(r"(?:^|\s)--(brief|body|description|prompt|message|comment|feedback|focus|question|instructions?)[ =]*$")
CAT_DATA = re.compile(r"(?:^|\s)(-d|--data(?:-raw|-binary|-urlencode)?|-F|--form)\s+[\"']?(?:[A-Za-z0-9_.-]+=)?[\"']?\$\(\s*cat\b")
HTML_ATTR = re.compile(r"^[A-Za-z][A-Za-z0-9]*\s+[A-Za-z-]+=")


def slots(text, braces):
    out = [m.group(0) for m in ANGLE.finditer(text) if not HTML_ATTR.match(m.group(1))]
    if braces:
        out += [m.group(0) for m in BRACE.finditer(text)] + SQUARE.findall(text)
    return out


def shell_blocks(text):
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        indent, fence, lang = m.group(1), m.group(2), m.group(3).lower()
        j = i + 1
        while j < len(lines):
            e = re.match(r"^[ \t]*(`{3,}|~{3,})[ \t]*$", lines[j])
            if e and e.group(1)[0] == fence[0] and len(e.group(1)) >= len(fence):
                break
            j += 1
        if lang in SHELL:
            yield i + 2, [l[len(indent):] if l.startswith(indent) else l.lstrip() for l in lines[i + 1:j]]
        i = j + 1


def quoted(src):
    """(start offset, quote, content) of each quoted string, nesting through $(...)."""
    out, stack, k, n = [], [("top", 0, 0)], 0, len(src)
    while k < n:
        kind = stack[-1][0]
        c = src[k]
        if c == "\\":
            k += 2
            continue
        if kind in ("top", "sub"):
            if c == "'":
                e = src.find("'", k + 1)
                e = n if e < 0 else e
                out.append((k, "'", src[k + 1:e]))
                k = e + 1
                continue
            if c == "#" and (k == 0 or src[k - 1] in " \t\n;"):
                e = src.find("\n", k)
                k = n if e < 0 else e
                continue
            if c == '"':
                stack.append(("dq", k, 0))
            elif src.startswith("$(", k):
                stack.append(("sub", k, 1))
                k += 2
                continue
            elif kind == "sub" and c == "(":
                stack[-1] = ("sub", stack[-1][1], stack[-1][2] + 1)
            elif kind == "sub" and c == ")":
                depth = stack[-1][2] - 1
                stack[-1] = ("sub", stack[-1][1], depth)
                if depth == 0:
                    stack.pop()
        else:  # inside double quotes
            if c == '"':
                start = stack.pop()[1]
                out.append((start, '"', src[start + 1:k]))
            elif src.startswith("$(", k):
                stack.append(("sub", k, 1))
                k += 2
                continue
        k += 1
    return out


findings = []
for spec in sys.argv[2:]:
    label, path = spec.split("=", 1)
    text = open(path, encoding="utf-8").read()
    for first, body in shell_blocks(text):
        kept = []  # the block with heredoc bodies blanked out
        k = 0
        while k < len(body):
            line = body[k]
            kept.append(line)
            end = k + 1
            for h in HEREDOC.finditer(line):
                dash, delim = h.group(1), h.group(3)
                program = bool(PROGRAM.search(line[:h.start()]))
                b, hb = end, []
                while b < len(body) and (body[b].lstrip("\t") if dash else body[b]) != delim:
                    hb.append(body[b])
                    b += 1
                joined = "\n".join(hb)
                hits = slots(joined, braces=not program)
                prose = PROSE.search(joined)
                if hits or prose:
                    findings.append((label, first + k, "heredoc", line.strip(),
                                     hits[0] if hits else prose.group(0)))
                kept.extend([""] * (b + 1 - end))
                end = b + 1
            k = end
        src = "\n".join(kept)
        for off, q, s in quoted(src):
            if "</" in s:
                continue  # an HTML literal, not a slot
            row = src.count("\n", 0, off)
            line = kept[row]
            prefix = src[src.rfind("\n", 0, off) + 1:off]
            for ph in slots(s, braces=True):
                inner = ph.strip("<>{}[] ")
                if (ROLE.search(inner) and not IDENT.search(inner)) or ROLE_FLAG.search(prefix):
                    findings.append((label, first + row, "quoted", line.strip(), ph))
                    break
        for row, line in enumerate(kept):
            if CAT_DATA.search(line):
                findings.append((label, first + row, "cat-into-arg", line.strip(), "$(cat"))

seen, bad = set(), []
for f in findings:
    key = (f[0], f[1], f[2])
    if key in seen:
        continue
    seen.add(key)
    hit = next((a for a in allow if a[0] in ("*", f[0]) and a[1] in f[3]), None)
    if hit:
        hit[3] += 1
    else:
        bad.append(f)
for label, ln, kind, line, slot in bad:
    print(f"BAD\t{label}:{ln}: {kind} {slot!s:.60} :: {line:.140}")
for a in allow:
    print(("USED" if a[3] else "STALE") + f"\t{a[0]} | {a[1]} — {a[2]}")
PY

echo "scanner self-test"
: > "$TMP/allow-none.txt"
cat > "$TMP/selftest.md" <<'SELFTEST_DOC'
```bash
codex exec "<prompt>"
```

```bash
claude -p "<review instructions>"
```

```bash
gh pr create --title "t" --body "<body>"
```

```bash
gh api repos/o/r/pulls/7/comments -f body="<reply text>"
```

```bash
cat > "$PLAN_FILE" <<'EOF'
<plan content>
EOF
```

```bash
curl -s -F body="$(cat "$F")" https://example.invalid/upload
```

```bash
gh pr create --title "t" --body-file "$BODY_FILE"
```

```bash
gh api repos/o/r/issues/7/comments -F body=@"$F"
```

```bash
codex exec - < "$PROMPT_FILE"
```

```bash
cat "$PROMPT_FILE" | claude -p
```
SELFTEST_DOC
if python3 -I "$TMP/scan.py" "$TMP/allow-none.txt" "selftest.md=$TMP/selftest.md" > "$TMP/self.out"; then
  for want in 'codex exec "<prompt>"' 'claude -p "<review instructions>"' '--body "<body>"' \
              '-f body="<reply text>"' 'cat > "$PLAN_FILE" <<' 'curl -s -F body="$(cat'; do
    grep '^BAD' "$TMP/self.out" | grep -qF -- "$want" && ok "flagged: $want" || no "not flagged: $want"
  done
  for safe in '--body-file "$BODY_FILE"' '-F body=@"$F"' 'codex exec - < "$PROMPT_FILE"' 'cat "$PROMPT_FILE" | claude -p'; do
    grep '^BAD' "$TMP/self.out" | grep -qF -- "$safe" && no "false positive: $safe" || ok "passes: $safe"
  done
else
  no "the scanner ran on the self-test doc"
fi

echo "no untrusted text in shell source"
python3 -I "$TMP/scan.py" "$TMP/allow.txt" "${docs[@]}" > "$TMP/scan.out"
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
  no "the scanner ran (exit $scan_rc)"
else
  bad="$(grep '^BAD' "$TMP/scan.out" || true)"
  if [ -z "$bad" ]; then
    ok "no fenced shell block puts untrusted text into a heredoc or quoted argument"
  else
    no "untrusted text reaches shell source ($(printf '%s\n' "$bad" | wc -l | tr -d ' ') sites):"
    printf '%s\n' "$bad" | cut -f2 | sed 's/^/       /'
  fi
  stale="$(grep '^STALE' "$TMP/scan.out" | cut -f2 || true)"
  if [ -z "$stale" ]; then
    ok "every allowlist entry still matches a block ($(grep -c '^USED' "$TMP/scan.out") entries)"
  else
    no "allowlist entries match nothing — remove them:"; printf '%s\n' "$stale" | sed 's/^/       /'
  fi
fi

# ---------------------------------------------------------------------------
# Behaviour: the fixed blocks, run with hostile text in the model-written file.

SENT="$TMP/sentinel"; mkdir -p "$SENT"
HOSTILE="$TMP/hostile.txt"
cat > "$HOSTILE" <<HOSTILE_END
Summary with "double" and 'single' quotes and a \\ backslash
EOF
SPEC_BODY_EOF
VIBE_PY_EOF
PY
touch $SENT/delimiter
\$(touch $SENT/subst)
\`touch $SENT/backtick\`
'; touch $SENT/squote; '
"; touch $SENT/dquote; "
last line
HOSTILE_END
no_sentinel() { [ -z "$(ls -A "$SENT")" ]; }

R="$render_root"
# block_with FILE NEEDLE -> the one fenced bash block that contains NEEDLE
block_with() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys, textwrap
text, needle = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
blocks = [textwrap.dedent(m.group(2)) for m in re.finditer(r"^([ \t]*)```bash\n(.*?)\n\1```", text, re.S | re.M)]
hits = [b for b in blocks if needle in b]
if len(hits) != 1:
    sys.exit("expected one bash block containing %r, found %d" % (needle, len(hits)))
sys.stdout.write(hits[0] + "\n")
PY
}
# subst FILE OLD NEW ... -> FILE with each OLD replaced by NEW
subst() {
  python3 -I - "$@" <<'PY'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
s = open(path, encoding="utf-8").read()
for old, new in zip(pairs[::2], pairs[1::2]):
    if old not in s:
        sys.exit("not in block: " + old)
    s = s.replace(old, new)
open(path, "w", encoding="utf-8").write(s)
PY
}
# fill FILE OLD NEW ... -> subst for each pair the block actually contains
fill() { local f="$1"; shift; while [ $# -ge 2 ]; do grep -qF -- "$1" "$f" && subst "$f" "$1" "$2"; shift 2; done; return 0; }
# same A B -> files identical, ignoring one trailing newline on either side
same() { python3 -I -c 'import sys
a,b=(open(p,encoding="utf-8").read().rstrip("\n") for p in sys.argv[1:3]); sys.exit(a!=b)' "$1" "$2" 2>/dev/null; }
contains() { python3 -I -c 'import sys
sys.exit(open(sys.argv[2],encoding="utf-8").read().rstrip("\n") not in open(sys.argv[1],encoding="utf-8").read())' "$1" "$2" 2>/dev/null; }

# Stubs: each records what it was handed, then succeeds.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP/gh.argv"
prev=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && cp "$a" "$CAP/gh.body"
  [ "$prev" = "--title" ] && printf '%s' "$a" > "$CAP/gh.title"
  case "$a" in body=*) [ "$prev" = "-f" ] && printf '%s' "${a#body=}" > "$CAP/gh.body" ;; esac
  prev="$a"
done
case "$1 $2" in
  "repo view") echo "o/r" ;;
  "pr view") echo "7" ;;
  "issue create") echo "https://github.com/o/r/issues/42" ;;
  "api graphql")
    case "$*" in
      *addPullRequestReviewThreadReply*) echo "https://github.com/o/r/pull/7#r1" ;;
      *resolveReviewThread*) echo "true" ;;
      *) printf '#pr:o/r#7\n#resolved:false\n' ;;
    esac ;;
esac
exit 0
SH
cat > "$STUB/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP/glab.argv"
prev=""
for a in "$@"; do [ "$prev" = "-d" ] && printf '%s' "$a" > "$CAP/glab.body"; prev="$a"; done
exit 0
SH
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CAP/codex.argv"
cat > "$CAP/codex.stdin"
echo "SCORE: 9"
SH
cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
cat > "$CAP/claude.stdin"
echo '{"result":"ok"}'
SH
chmod +x "$STUB"/*
CAP="$TMP/cap"
fresh_cap() { rm -rf "$CAP" "$SENT"; mkdir -p "$CAP" "$SENT"; }
run_block() { # run_block BLOCK_FILE [-u VAR ... | VAR=VAL ...]
  local blk="$1"; shift
  (cd "$TMP" && env "$@" PATH="$STUB:$PATH" CAP="$CAP" HOME="$TMP/home" bash "$blk") >"$TMP/run.out" 2>&1
}

echo "/claude: user text reaches nested Claude through USER_TEXT_FILE"
CL="$R/claude/SKILL.md"
printf 'diff --git a/x b/x\n+line\n' > "$TMP/diff.patch"
for spec in "review:Additional user instructions, if any:" "challenge:Focus area, if any:" "consult:USER QUESTION:"; do
  mode="${spec%%:*}"; anchor="${spec#*:}"
  fresh_cap
  if block_with "$CL" "$anchor" > "$TMP/cl-$mode.sh" 2>"$TMP/err"; then
    cp "$HOSTILE" "$TMP/user.txt"
    fill "$TMP/cl-$mode.sh" "<PROMPT_FILE>" "$TMP/prompt-$mode.txt" "<USER_TEXT_FILE>" "$TMP/user.txt" "<DIFF_FILE>" "$TMP/diff.patch"
    run_block "$TMP/cl-$mode.sh" PROMPT_FILE="$TMP/prompt-$mode.txt" USER_TEXT_FILE="$TMP/user.txt" DIFF_FILE="$TMP/diff.patch"
    if [ -f "$TMP/prompt-$mode.txt" ] && contains "$TMP/prompt-$mode.txt" "$HOSTILE" && no_sentinel; then
      ok "$mode: the prompt carries the user text verbatim and none of it ran"
    else
      no "$mode: prompt assembly ($(cat "$TMP/run.out" | head -3)); sentinels: $(ls "$SENT")"
    fi
  else
    no "$mode: $(cat "$TMP/err")"
  fi
done
if grep -qE '^<(custom review instructions|focus|user prompt)>$' "$CL"; then
  no "/claude still has a user-text placeholder inside a heredoc"
else
  ok "/claude has no user-text placeholder inside a heredoc"
fi

echo "/spec: the draft, body and title reach codex, gh and the archive through files"
SP="$R/spec/SKILL.md"
fresh_cap
if block_with "$SP" 'GATE_PROMPT=$(mktemp' > "$TMP/sp-gate.sh" 2>"$TMP/err"; then
  cp "$HOSTILE" "$TMP/draft.txt"
  fill "$TMP/sp-gate.sh" "<SPEC_DRAFT>" "$TMP/draft.txt"
  run_block "$TMP/sp-gate.sh" SPEC_DRAFT="$TMP/draft.txt"
  if [ -f "$CAP/codex.stdin" ] && contains "$CAP/codex.stdin" "$HOSTILE" && no_sentinel \
     && grep -q '^exec - ' "$CAP/codex.argv" 2>/dev/null; then
    ok "quality gate: codex reads the spec verbatim on stdin and none of it ran"
  else
    no "quality gate ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
else
  no "quality gate: $(cat "$TMP/err")"
fi
fresh_cap
if block_with "$SP" 'gh issue create --title' > "$TMP/sp-file.sh" 2>"$TMP/err"; then
  cp "$HOSTILE" "$TMP/body.md"; printf 'Fix `touch %s/title` $(touch %s/title2) it'"'"'s\n' "$SENT" "$SENT" > "$TMP/title.txt"
  fill "$TMP/sp-file.sh" "<BODY_FILE>" "$TMP/body.md" "<TITLE_FILE>" "$TMP/title.txt"
  run_block "$TMP/sp-file.sh" BODY_FILE="$TMP/body.md" TITLE_FILE="$TMP/title.txt"
  if same "$CAP/gh.body" "$HOSTILE" && same "$CAP/gh.title" "$TMP/title.txt" && no_sentinel; then
    ok "filing: gh receives the body and title verbatim and none of it ran"
  else
    no "filing ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
else
  no "filing: $(cat "$TMP/err")"
fi
fresh_cap
if block_with "$SP" 'ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_NAME"' > "$TMP/sp-arch.sh" 2>"$TMP/err"; then
  cp "$HOSTILE" "$TMP/body.md"; printf 'Title $(touch %s/arch) `touch %s/arch2`\n' "$SENT" "$SENT" > "$TMP/title.txt"
  cp "$TMP/title.txt" "$TMP/title.want"
  mkdir -p "$TMP/home"
  fill "$TMP/sp-arch.sh" "<BODY_FILE>" "$TMP/body.md" "<TITLE_FILE>" "$TMP/title.txt"
  run_block "$TMP/sp-arch.sh" BODY_FILE="$TMP/body.md" TITLE_FILE="$TMP/title.txt" VIBESTACK_HOME="$TMP/vh"
  arch="$(ls "$TMP"/vh/projects/*/specs/*.md 2>/dev/null | head -1)"
  if [ -n "$arch" ] && contains "$arch" "$HOSTILE" && grep -qxF "# $(head -n1 "$TMP/title.want")" "$arch" && no_sentinel; then
    ok "archive: the body and title land verbatim and none of it ran"
  else
    no "archive (${arch:-none}: $(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
else
  no "archive: $(cat "$TMP/err")"
fi

echo "/ship: the PR/MR and issue bodies are published from the written file"
SH_="$R/ship/SKILL.md"
for spec in "gh:gh pr create --base" "glab:\"glab\",\"mr\",\"create\""; do
  cli="${spec%%:*}"; needle="${spec#*:}"
  fresh_cap
  if block_with "$SH_" "$needle" > "$TMP/ship-$cli.sh" 2>"$TMP/err"; then
    cp "$HOSTILE" "$TMP/pr-body.md"
    subst "$TMP/ship-$cli.sh" "<PR_BODY_FILE>" "$TMP/pr-body.md" "<base>" "main"
    run_block "$TMP/ship-$cli.sh" NEW_VERSION=1.2.3
    if same "$CAP/$cli.body" "$HOSTILE" && no_sentinel; then
      ok "$cli: the PR/MR body arrives verbatim and none of it ran"
    else
      no "$cli publish ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
    fi
  else
    no "$cli publish: $(cat "$TMP/err")"
  fi
done
fresh_cap
if block_with "$SH_" '"glab","issue","create"' > "$TMP/ship-issue.sh" 2>"$TMP/err"; then
  cp "$HOSTILE" "$TMP/issue.md"
  subst "$TMP/ship-issue.sh" "<ISSUE_BODY_FILE>" "$TMP/issue.md"
  run_block "$TMP/ship-issue.sh"
  if same "$CAP/glab.body" "$HOSTILE" && no_sentinel; then
    ok "glab issue: the body arrives verbatim and none of it ran"
  else
    no "glab issue ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
else
  no "glab issue: $(cat "$TMP/err")"
fi
grep -q "<PR body from above>" "$SH_" && no "/ship still renders the PR body into a heredoc" \
  || ok "/ship has no PR-body heredoc"

echo "/pr-summary: the description is published from the written file"
fresh_cap
if block_with "$R/pr-summary/SKILL.md" 'gh pr edit {PR_NUMBER} --body-file' > "$TMP/prs.sh" 2>"$TMP/err"; then
  cp "$HOSTILE" "$TMP/prs-body.md"
  subst "$TMP/prs.sh" "<PR_BODY_FILE>" "$TMP/prs-body.md" "{PR_NUMBER}" "7"
  run_block "$TMP/prs.sh"
  if same "$CAP/gh.body" "$HOSTILE" && no_sentinel; then
    ok "the PR body arrives verbatim and none of it ran"
  else
    no "pr-summary publish ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
else
  no "pr-summary: $(cat "$TMP/err")"
fi

echo "/address-pr-review: replies are posted from the written file"
fresh_cap
cp "$HOSTILE" "$TMP/reply.md"
(cd "$TMP" && PATH="$STUB:$PATH" CAP="$CAP" bash "$SRC/skills/address-pr-review/bin/pr-thread-reply.sh" \
  PRRT_x --body-file "$TMP/reply.md" --resolve) >"$TMP/run.out" 2>&1
if same "$CAP/gh.body" "$HOSTILE" && no_sentinel && grep -q 'pull/7#r1' "$TMP/run.out"; then
  ok "pr-thread-reply --body-file posts the reply verbatim and none of it ran"
else
  no "pr-thread-reply --body-file ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
fi
grep -qF -- '--body-file' "$R/address-pr-review/SKILL.md" && ! grep -qF '"<reply text>"' "$R/address-pr-review/SKILL.md" \
  && ok "the skill posts replies with --body-file" || no "the skill still quotes reply text on the command line"

echo "design briefs: \$D reads the brief from the written file"
DSTUB="$STUB/design"
cat > "$DSTUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAP/design.argv"
prev=""
for a in "$@"; do [ "$prev" = "--brief-file" ] && cp "$a" "$CAP/design.brief"; prev="$a"; done
echo "requested: 1"
SH
chmod +x "$DSTUB"
# Each block runs in a fresh shell: it binds $D to the installed path itself and
# names the printed directory as a placeholder, so neither is injected here.
mkdir -p "$TMP/home/.vibestack/bin"; cp "$DSTUB" "$TMP/home/.vibestack/bin/vibe-design"
for spec in "design-consultation:<DESIGN_DIR>" "office-hours:<DESIGN_DIR>" "design-review:<REPORT_DIR>"; do
  skill="${spec%%:*}"; ph="${spec#*:}"
  fresh_cap
  if block_with "$R/$skill/SKILL.md" '--brief-file "$BRIEF_FILE"' > "$TMP/d-$skill.sh" 2>"$TMP/err"; then
    dd="$TMP/dd-$skill"; mkdir -p "$dd" "$dd/mockups/finding-NNN"
    if [ "$skill" = design-review ]; then cp "$HOSTILE" "$dd/mockups/finding-NNN/brief.txt"; else cp "$HOSTILE" "$dd/brief.txt"; fi
    subst "$TMP/d-$skill.sh" "$ph" "$dd"
    run_block "$TMP/d-$skill.sh" -u D -u _DESIGN_DIR -u REPORT_DIR
    if same "$CAP/design.brief" "$HOSTILE" && no_sentinel; then
      ok "$skill: \$D gets the brief file verbatim and none of it ran"
    else
      no "$skill brief ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
    fi
  else
    no "$skill: $(cat "$TMP/err")"
  fi
done

echo "/office-hours: approved.json is built from the feedback file"
fresh_cap
if block_with "$R/office-hours/SKILL.md" 'approved-feedback.txt' > "$TMP/oh-approve.sh" 2>"$TMP/err"; then
  od="$TMP/oh-design"; mkdir -p "$od"; cp "$HOSTILE" "$od/approved-feedback.txt"
  # A same-day rerun saved variant-B-2.png; the record must name it, not variant-B.png.
  : > "$od/variant-B.png"; : > "$od/variant-B-2.png"
  cp "$TMP/oh-approve.sh" "$TMP/oh-approve-out.sh"
  subst "$TMP/oh-approve.sh" '"<V>"' '"B"' "<IMAGE>" "$od/variant-B-2.png" "<DESIGN_DIR>" "$od"
  run_block "$TMP/oh-approve.sh" -u _DESIGN_DIR
  if python3 -I -c 'import json,os,sys
rec=json.load(open(sys.argv[1])); fb=open(sys.argv[2]).read().strip()
sys.exit(not (rec["approved_variant"]=="B" and rec["feedback"]==fb and rec["screen"]=="mockup"
              and rec.get("approved_path")==os.path.realpath(sys.argv[3])))' "$od/approved.json" "$HOSTILE" "$od/variant-B-2.png" 2>/dev/null \
     && no_sentinel; then
    ok "the feedback lands in approved.json verbatim, approved_path names the saved image, and none of it ran"
  else
    no "approved.json ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
  # An image outside the design dir is refused and no record is written.
  rm -f "$od/approved.json"; : > "$TMP/outside.png"
  subst "$TMP/oh-approve-out.sh" '"<V>"' '"B"' "<IMAGE>" "$TMP/outside.png" "<DESIGN_DIR>" "$od"
  run_block "$TMP/oh-approve-out.sh" -u _DESIGN_DIR
  [ ! -e "$od/approved.json" ] && ok "an image outside the design dir is refused" \
    || no "approved.json written for an image outside the design dir"
else
  no "office-hours approve: $(cat "$TMP/err")"
fi

# The file-based pattern only works when the skill may write: a skill that tells
# the model to use the Write tool must grant it in allowed-tools.
echo "Write tool granted where it is required"
for s in "$SRC"/skills/*/SKILL.md; do
  n="$(basename "$(dirname "$s")")"
  grep -q 'Write tool' "$s" || continue
  fm="$(awk 'NR==1 && /^---$/ {on=1; next} on && /^---$/ {exit} on' "$s")"
  if printf '%s\n' "$fm" | grep -Eq '^allowed-tools:.*(^|[ ,])Write([ ,]|$)|^[[:space:]]*-[[:space:]]*Write[[:space:]]*$'; then
    ok "$n grants Write"
  else
    no "$n tells the model to use the Write tool but allowed-tools does not grant Write"
  fi
done

echo
echo "untrusted-shell-text: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
