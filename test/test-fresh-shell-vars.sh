#!/usr/bin/env bash
# test-fresh-shell-vars.sh — no skill block reads shell state another block set.
#
# Every Bash tool call starts a fresh shell. A variable a skill sets in one
# fenced block ($_DESIGN_DIR, $D, $B, $SLUG, $REPORT_DIR, ...) is gone by the
# next block, so a later block that reads it gets an empty string and runs
# against the wrong path, an empty command or the home directory — silently.
# The fix is local to the reading block: assign the value there, either by
# re-deriving it (`eval "$(~/.vibestack/bin/vibe-slug)"`, `D=~/.vibestack/bin/vibe-design`)
# or from a placeholder the model fills with what the earlier block printed
# (`_DESIGN_DIR='<DESIGN_DIR printed above>'`).
#
# Covers:
#   - every rendered skill plus its sub-docs, split into fenced bash/sh blocks:
#     a block that reads $NAME / ${NAME} must assign NAME itself when NAME is
#     cross-block state — a name some other block of the same skill assigns,
#     or one of the always-tracked names below. Single-quoted text, comments
#     and quoted-heredoc bodies are not reads (the shell never expands them);
#   - the allowlist names the variables the environment genuinely provides, each
#     with its reason; an entry nothing matches fails;
#   - the scanner itself, on fixture blocks: it flags a cross-block read and a
#     tracked name, and passes a placeholder assignment, a literal heredoc, a
#     single-quoted string and an allowlisted environment name.
#
# Usage: test/test-fresh-shell-vars.sh [repo-root]
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

# Names flagged whenever a block reads them without assigning them, even in a
# skill where no other block sets them: each is per-run state by convention.
TRACKED="_DESIGN_DIR,D,B,SLUG,REPORT_DIR,PREVIEW_FILE,_PROMPT_FILE,PR_BODY_FILE,BASE,BRIEF_FILE,FINDING_DIR,PLAN_FILE"

# Variables the environment provides to every Bash call: <skill or *> | NAME | reason.
cat > "$TMP/allow.txt" <<'ALLOW'
* | HOME | set by the login environment of every shell
* | VIBESTACK_HOME | an optional user override read from the environment; blocks default it themselves
ALLOW

cat > "$TMP/scan.py" <<'PY'
import re, sys

FENCE = re.compile(r"^([ \t]*)(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+-]*)")
SHELL = {"bash", "sh", "shell", "zsh"}
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3")
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
LEAD = r"(?:^|[;&|(){!]|\bthen|\bdo|\belse|\btime|\bif|\belif|\bwhile|\buntil)[ \t]*"
DECL = r"(?:export|local|readonly|declare|typeset)"
ASSIGN = re.compile(LEAD + r"(?:" + DECL + r"(?:[ \t]+-[A-Za-z]+)*[ \t]+)?(" + NAME + r")(?:\[[^]]*\])?\+?=", re.M)
ASSIGN_MULTI = re.compile(LEAD + DECL + r"((?:[ \t]+(?:-[A-Za-z]+|" + NAME + r"(?:=\S*)?))+)", re.M)
READ = re.compile(r"\bread[ \t]+((?:-[A-Za-z]+(?:[ \t]+(?!-)\S+)?[ \t]+)*)(" + NAME + r"(?:[ \t]+" + NAME + r")*)")
FOR = re.compile(r"\bfor[ \t]+(" + NAME + r")[ \t]+in\b")
GETOPTS = re.compile(r"\bgetopts[ \t]+\S+[ \t]+(" + NAME + r")")
PRINTF_V = re.compile(r"\bprintf[ \t]+-v[ \t]+(" + NAME + r")")
DEFAULT_ASSIGN = re.compile(r"\$\{(" + NAME + r"):?=")
REF = re.compile(r"(?<!\\)\$(?:\{[#!]?(" + NAME + r")|(" + NAME + r"))")
# Helpers whose output is NAME=value lines meant for eval.
EVAL_DEFS = [
    (re.compile(r"vibe-slug\b[^\n]*--identity"), ["SLUG", "PROJECT_REMOTE", "PROJECT_ROOT", "LEGACY_SLUG"]),
    (re.compile(r"eval[^\n]*vibe-slug\b"), ["SLUG"]),
    (re.compile(r"eval[^\n]*vibe-diff-scope\b"), ["SCOPE_FRONTEND", "SCOPE_BACKEND", "SCOPE_PROMPTS", "SCOPE_TESTS",
                                                  "SCOPE_DOCS", "SCOPE_CONFIG", "SCOPE_MIGRATIONS", "SCOPE_API", "SCOPE_AUTH"]),
]


def blocks(text):
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
            yield i + 2, "\n".join(l[len(indent):] if l.startswith(indent) else l.lstrip() for l in lines[i + 1:j])
        i = j + 1


def code_only(src):
    """Blank what the shell never expands — comments, single-quoted strings,
    quoted-heredoc bodies — keeping the line structure."""
    lines = src.split("\n")
    out, k = [], 0
    while k < len(lines):
        line = lines[k]
        out.append(line)
        k += 1
        for h in HEREDOC.finditer(line):
            literal = bool(h.group(2) or h.group(3))
            dash, delim = h.group(1), h.group(4)
            while k < len(lines) and (lines[k].lstrip("\t") if dash else lines[k]) != delim:
                out.append("" if literal else lines[k].replace("'", " "))
                k += 1
            if k < len(lines):
                out.append("")
                k += 1
    s = "\n".join(out)
    res, i, n, dq = [], 0, len(s), False
    while i < n:
        c = s[i]
        if c == "\\":
            res.append(s[i:i + 2]); i += 2; continue
        if not dq and c == "'":
            e = s.find("'", i + 1)
            e = n if e < 0 else e
            res.append("''" + "\n" * s.count("\n", i, e)); i = e + 1; continue
        if not dq and c == "#" and (i == 0 or s[i - 1] in " \t\n;(|&"):
            e = s.find("\n", i)
            i = n if e < 0 else e
            continue
        if c == '"':
            dq = not dq
        res.append(c); i += 1
    return "".join(res)


def assigned(code):
    names = set(m.group(1) for m in ASSIGN.finditer(code))
    for m in ASSIGN_MULTI.finditer(code):
        names.update(t.split("=", 1)[0] for t in m.group(1).split() if not t.startswith("-"))
    for m in READ.finditer(code):
        names.update(m.group(2).split())
    for rx in (FOR, GETOPTS, PRINTF_V, DEFAULT_ASSIGN):
        names.update(m.group(1) for m in rx.finditer(code))
    for rx, defs in EVAL_DEFS:
        if rx.search(code):
            names.update(defs)
    return names


def reads(code):
    out = {}
    for m in REF.finditer(code):
        out.setdefault(m.group(1) or m.group(2), code.count("\n", 0, m.start()))
    return out


allow = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.rstrip("\n")
    if not raw.strip():
        continue
    parts = [p.strip() for p in raw.split(" | ", 2)]
    if len(parts) != 3 or not all(parts):
        sys.exit("bad allowlist line: " + raw)
    allow[(parts[0], parts[1])] = [parts[2], 0]
tracked = set(sys.argv[2].split(","))

# Each unit is "<skill>=<label>=<path>[\x1f<label>=<path>...]": a skill and its sub-docs.
for unit in sys.argv[3:]:
    skill, _, rest = unit.partition("=")
    blks = []
    for spec in rest.split("\x1f"):
        label, path = spec.split("=", 1)
        for first, body in blocks(open(path, encoding="utf-8").read()):
            code = code_only(body)
            blks.append((label, first, assigned(code), reads(code), body.split("\n")))
    state = set(tracked)
    for b in blks:
        state |= b[2]
    for label, first, mine, used, raw in blks:
        for name, row in sorted(used.items(), key=lambda x: x[1]):
            if name in mine or name not in state:
                continue
            key = next((k for k in ((skill, name), ("*", name)) if k in allow), None)
            if key:
                allow[key][1] += 1
                continue
            print(f"BAD\t{label}:{first + row}: ${name} is read but not set in this block :: {raw[row].strip():.90}")
for (scope, name), (why, used) in sorted(allow.items()):
    print(("USED" if used else "STALE") + f"\t{scope} | {name} — {why}")
PY

scan() { python3 -I "$TMP/scan.py" "$@"; }

echo "scanner self-test"
FX="$TMP/fx"; mkdir -p "$FX"
fixture() {  # fixture NAME BODY -> a two-block doc whose first block sets X and HOME
  printf '# fx\n\n```bash\nX=$(mktemp -d)\nHOME=/tmp/h\necho "X: $X"\n```\n\n```bash\n%s\n```\n' "$2" > "$FX/$1.md"
}
fixture cross 'ls "$X"'
fixture placeholder "X='<X printed above>'"$'\n''ls "$X"'
fixture literal "python3 - <<'PY'"$'\n''print("$X")'$'\n''PY'$'\n''echo '"'"'$X'"'"' # $X'
fixture tracked 'ls "$_DESIGN_DIR"'
fixture braced 'ls "${X:-/}"'
fixture env 'ls "$HOME"'
fixture local 'for X in a b; do echo "$X"; done'
fixture caseassign 'case "$1" in a) X=$(date) ;; esac; echo "$X"'
fixture defassign ': "${X:=$(date)}"; echo "$X"'
fixture ifassign 'if X=$(date); then echo "$X"; fi'
for f in cross placeholder literal tracked braced env local caseassign defassign ifassign; do
  scan "$TMP/allow.txt" "$TRACKED" "fx=$f.md=$FX/$f.md" | grep '^BAD' > "$TMP/fx-$f.out" || true
done
[ -s "$TMP/fx-cross.out" ] && ok "a block reading another block's variable is flagged" || no "cross-block read missed"
[ -s "$TMP/fx-braced.out" ] && ok "a \${NAME:-default} read is flagged" || no "braced read missed"
[ -s "$TMP/fx-tracked.out" ] && ok "a tracked name is flagged even when no block sets it" || no "tracked name missed"
[ ! -s "$TMP/fx-placeholder.out" ] && ok "a placeholder assignment in the block passes" || no "placeholder flagged: $(cat "$TMP/fx-placeholder.out")"
[ ! -s "$TMP/fx-literal.out" ] && ok "quoted heredocs, single quotes and comments are not reads" || no "literal flagged: $(cat "$TMP/fx-literal.out")"
[ ! -s "$TMP/fx-env.out" ] && ok "an allowlisted environment name passes" || no "env name flagged: $(cat "$TMP/fx-env.out")"
[ ! -s "$TMP/fx-local.out" ] && ok "a for-loop variable counts as assigned" || no "loop var flagged: $(cat "$TMP/fx-local.out")"
[ ! -s "$TMP/fx-caseassign.out" ] && ok "an assignment after a case pattern counts" || no "case assignment flagged: $(cat "$TMP/fx-caseassign.out")"
[ ! -s "$TMP/fx-defassign.out" ] && ok "a \${X:=...} default assignment counts" || no "default assignment flagged: $(cat "$TMP/fx-defassign.out")"
[ ! -s "$TMP/fx-ifassign.out" ] && ok "an assignment in an if condition counts" || no "if assignment flagged: $(cat "$TMP/fx-ifassign.out")"

echo "every skill block sets the state it reads"
render_root="$TMP/r"
units=()
for s in "$SRC"/skills/*/SKILL.md; do
  n="$(basename "$(dirname "$s")")"
  mkdir -p "$render_root/$n"
  if ! VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$s" "$render_root/$n/SKILL.md" >/dev/null 2>&1; then
    no "$n renders"
    continue
  fi
  u="$n=skills/$n/SKILL.md=$render_root/$n/SKILL.md"
  while IFS= read -r f; do u="$u"$'\x1f'"${f#"$SRC"/}=$f"; done \
    < <(find "$SRC/skills/$n" -name '*.md' ! -name SKILL.md ! -path '*/node_modules/*' | sort)
  units+=("$u")
done
scan "$TMP/allow.txt" "$TRACKED" "${units[@]}" > "$TMP/scan.out"
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
  no "the scanner ran (exit $scan_rc)"
else
  bad="$(grep '^BAD' "$TMP/scan.out" | cut -f2 || true)"
  if [ -z "$bad" ]; then
    ok "no block reads a variable only another block sets (${#units[@]} skills)"
  else
    no "blocks read state a fresh shell does not have ($(printf '%s\n' "$bad" | wc -l | tr -d ' ') sites):"
    printf '%s\n' "$bad" | sed 's/^/       /'
  fi
  stale="$(grep '^STALE' "$TMP/scan.out" | cut -f2 || true)"
  if [ -z "$stale" ]; then
    ok "every allowlist entry still matches a read ($(grep -c '^USED' "$TMP/scan.out") entries)"
  else
    no "allowlist entries match nothing — remove them:"; printf '%s\n' "$stale" | sed 's/^/       /'
  fi
fi

echo
echo "fresh-shell-vars: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
