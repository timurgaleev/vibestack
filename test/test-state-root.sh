#!/usr/bin/env bash
# test-state-root.sh — every state path a skill runs honours VIBESTACK_HOME.
#
# A command that hardcodes ~/.vibestack reads and writes the real state root
# even when VIBESTACK_HOME points somewhere else, so an isolated install or a
# test run quietly touches the user's own learnings, reviews and projects. The
# safe spelling is `${VIBESTACK_HOME:-$HOME/.vibestack}`.
#
# Only fenced code blocks are scanned: those are what the model runs. Prose may
# name ~/.vibestack to tell the reader where state lives. A fenced line that
# names `~/.vibestack` or `$HOME/.vibestack` without `VIBESTACK_HOME` on the
# same line fails, printed as file:line.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# scan FILE... -> prints `file:line` for each fenced line with a bare state root
scan() {
  python3 -I - "$@" <<'PY'
import re, sys
fence = re.compile(r"^\s*```")
bare = re.compile(r"(~|\$HOME|\$\{HOME\})/\.vibestack")
for path in sys.argv[1:]:
    inside = False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if fence.match(line):
                inside = not inside
                continue
            if inside and bare.search(line) and "VIBESTACK_HOME" not in line:
                print(f"{path}:{n}")
PY
}

# prose FILE... -> prints `file:line` for each prose instruction (Write, Read,
# save, append, generate) that names a literal ~/.vibestack path. The Write and
# Read tools expand nothing, so the path they get must be the one a block
# printed (a `<PROJECT_DIR>`-style placeholder), not the default root.
prose() {
  python3 -I - "$@" <<'PY'
import re, sys
fence = re.compile(r"^\s*```")
instr = re.compile(r"(?<!is )(?<!are )\b(Write|Read|read|write|[Ss]ave[sd]?|[Aa]ppend|[Gg]enerate)\b[^`\n]{0,40}`(~|\$HOME)/\.vibestack/")
for path in sys.argv[1:]:
    inside = False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if fence.match(line):
                inside = not inside
                continue
            if not inside and instr.search(line):
                print(f"{path}:{n}")
PY
}

echo "self-test"
CLEAN="$TMP/clean.md"; DIRTY="$TMP/dirty.md"
cat > "$CLEAN" <<'EOF'
State lives under ~/.vibestack/projects unless VIBESTACK_HOME says otherwise.

```bash
ls "${VIBESTACK_HOME:-$HOME/.vibestack}/projects"
```
EOF
cat > "$DIRTY" <<'EOF'
Prose may mention ~/.vibestack freely.

```bash
~/.vibestack/bin/vibe-slug
```
EOF
out="$(scan "$CLEAN")"
[ -z "$out" ] && ok "VIBESTACK_HOME fallback in a fence passes; prose mention passes" \
  || no "clean fixture flagged: $out"
out="$(scan "$DIRTY")"
[ "$out" = "$DIRTY:4" ] && ok "bare ~/.vibestack in a fence is flagged at its line" \
  || no "dirty fixture: want $DIRTY:4, got '$out'"

PROSE="$TMP/prose.md"
cat > "$PROSE" <<'EOF'
The boundary is saved in `~/.vibestack/freeze-dir.txt` for later sessions.
Write to `<PROJECT_DIR>/report.md`.
Write to `~/.vibestack/projects/{slug}/report.md`.
EOF
out="$(prose "$PROSE")"
[ "$out" = "$PROSE:3" ] && ok "a prose Write to a literal ~/.vibestack path is flagged; a description is not" \
  || no "prose fixture: want $PROSE:3, got '$out'"

echo "repo"
# skills/*/*.md covers every SKILL.md and its sub-docs; symlinked sub-docs
# point at another skill's file, which is scanned under its own name.
files=()
for f in "$ROOT"/skills/*/*.md "$ROOT"/lib/snippets/*.md; do
  [ -f "$f" ] && [ ! -L "$f" ] && files+=("$f")
done
hits=""
if [ "${#files[@]}" -gt 0 ]; then
  ok "found ${#files[@]} skill and snippet files"
  hits="$(scan "${files[@]}")"
else
  no "no files to scan"
fi
if [ -z "$hits" ]; then
  ok "no fenced command hardcodes the state root"
else
  no "fenced commands hardcode the state root ($(printf '%s\n' "$hits" | wc -l | tr -d ' ') lines):"
  printf '%s\n' "$hits" | sed "s|^$ROOT/|       |"
fi

phits=""
[ "${#files[@]}" -gt 0 ] && phits="$(prose "${files[@]}")"
if [ -z "$phits" ]; then
  ok "no prose Write/Read instruction names a literal ~/.vibestack path"
else
  no "prose instructions name a literal ~/.vibestack path ($(printf '%s\n' "$phits" | wc -l | tr -d ' ') lines):"
  printf '%s\n' "$phits" | sed "s|^$ROOT/|       |"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
