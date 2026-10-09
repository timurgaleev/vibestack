#!/usr/bin/env bash
# test-design-consultation.sh — /design-consultation contracts: nothing is
# written before the user approves, outside voices get real context through
# files, fonts are verified rather than picked from a fixed menu, and the
# design knowledge does not contradict itself.
#
# Covers:
#   - Phase 0 routes cancel / update / start fresh, leaves a lone
#     design-system.md untouched, and defers every write to Q-final;
#   - Q-final comes before the DESIGN.md and CLAUDE.md writes, B/C write
#     nothing, start fresh backs up the old file, CLAUDE.md is never appended
#     twice;
#   - the outside voices run behind the shared preflight snippet, read the
#     product brief from a file on stdin, use the current web-search flag,
#     follow the agent's own draft, and never log `clean` without a voice;
#   - approved.json is built from a feedback file: the block runs with hostile
#     feedback and that text lands verbatim without executing;
#   - fonts go through a verification step and the overused list covers the
#     faces the skill once recommended;
#   - the Brutalist, Retro-Futuristic and light/dark lines no longer contradict
#     the slop rules.
#
# Usage: test/test-design-consultation.sh [repo-root]
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

R="$TMP/r/design-consultation/SKILL.md"
VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/design-consultation/SKILL.md" "$R" \
  >/dev/null 2>&1 || { echo "design-consultation: render failed" >&2; exit 1; }

has() { grep -Fq -- "$2" "$1"; }
# before FILE A B -> A occurs, B occurs, and the first A precedes the first B
before() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = t.find(sys.argv[2]), t.find(sys.argv[3])
sys.exit(0 if 0 <= a < b else 1)
PY
}
# section FILE "<heading>" -> text from that heading to the next `## ` heading
section() {
  python3 -I - "$1" "$2" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find(sys.argv[2])
if i < 0:
    sys.exit("no section: " + sys.argv[2])
# Headings inside fenced blocks (the DESIGN.md template) do not end a section.
out, fence = [], False
for n, line in enumerate(t[i:].split("\n")):
    if line.lstrip().startswith("```"):
        fence = not fence
    elif n and not fence and line.startswith("## "):
        break
    out.append(line)
sys.stdout.write("\n".join(out))
PY
}

echo "Phase 0: routing and no early writes"
section "$R" "## Phase 0: Pre-checks" > "$TMP/p0"
for w in '**Cancel:**' '**Update:**' '**Start fresh:**'; do
  has "$TMP/p0" "$w" && ok "Phase 0 routes $w" || no "Phase 0 has no route for $w"
done
grep -q 'design-system.md.*never modify' "$TMP/p0" \
  && ok "a lone design-system.md is read, never modified" || no "design-system.md handling missing"
has "$TMP/p0" "waits for Q-final" && ok "Phase 0 defers every write to Q-final" || no "Phase 0 does not defer writes"

echo "Phase 6: approval before writes"
section "$R" "## Phase 6: Write DESIGN.md & Confirm" > "$TMP/p6"
before "$TMP/p6" "AskUserQuestion Q-final" 'write `DESIGN.md` to the repo root' \
  && ok "Q-final precedes the DESIGN.md write" || no "DESIGN.md is written before Q-final"
before "$TMP/p6" "AskUserQuestion Q-final" "**Update CLAUDE.md**" \
  && ok "Q-final precedes the CLAUDE.md update" || no "CLAUDE.md is updated before Q-final"
has "$TMP/p6" "B and C write nothing" && ok "B and C write nothing" || no "B/C write rule missing"
has "$TMP/p6" "DESIGN.md.bak-" && ok "start fresh backs up the old DESIGN.md" || no "no backup before a fresh replacement"
has "$TMP/p6" "Never append a second copy" && ok "CLAUDE.md section is replaced, not re-appended" \
  || no "CLAUDE.md section may be appended twice"
grep -q 'append this section' "$TMP/p6" && no "Phase 6 still says to append to CLAUDE.md" \
  || ok "no blind append to CLAUDE.md"

echo "outside voices"
section "$R" "## Design Outside Voices" > "$TMP/ov"
has "$TMP/ov" 'CODEX_MODE="under_codex"' && ok "the shared outside-voice preflight is included" \
  || no "outside voices skip the preflight snippet"
grep -Fq 'codex exec - ' "$TMP/ov" && grep -Fq '< "$_PROMPT_FILE"' "$TMP/ov" \
  && ok "Codex reads the prompt file on stdin" || no "Codex prompt is not read from a file"
grep -Fq 'web_search_cached' "$R" && no "the retired --enable web_search_cached flag is still used" \
  || ok "no retired web-search flag"
grep -Fq -e "-c 'web_search=\"cached\"'" "$TMP/ov" && ok "current web-search flag" || no "current web-search flag missing"
grep -Fq 'PRODUCT BRIEF:' "$TMP/ov" && ok "the outside prompt carries the product brief" \
  || no "the outside prompt has no product context"
before "$TMP/ov" "Draft your own direction first" "Use AskUserQuestion" \
  && ok "the agent drafts before offering outside voices" || no "outside voices run before the agent's draft"
grep -Fq 'missing coverage is never clean' "$TMP/ov" && ok "no clean log without a voice" \
  || no "the log may record clean when nothing ran"
grep -Fq 'is `disabled`, remove the brief file' "$R" && ok "the disabled path removes the private brief" \
  || no "the disabled path leaves the brief in TMPDIR"
grep -Fq 'Agreement is not a vote' "$TMP/ov" && ok "agreement is not counted as a vote" || no "vote rule missing"
grep -Eq 'codex exec "[^-]' "$R" && no "a codex prompt is spliced into shell source" || ok "no inline codex prompt"

echo "approved.json from a feedback file"
python3 -I - "$R" > "$TMP/approve.sh" <<'PY' || no "approved.json block not found"
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
hits = [b for b in re.findall(r"```bash\n(.*?)\n```", t, re.S) if "approved-feedback.txt" in b]
if len(hits) != 1:
    sys.exit(1)
sys.stdout.write(hits[0] + "\n")
PY
if [ -s "$TMP/approve.sh" ]; then
  dd="$TMP/design"; mkdir -p "$dd/round-2"; SENT="$TMP/sent"; mkdir -p "$SENT"
  # The chosen image is a later round's de-duplicated name, which the letter alone cannot find.
  : > "$dd/round-2/variant-B-2.png"
  fill() {
    sed -e "s|'<DESIGN_DIR>'|'$dd'|" -e 's|"<V>"|"B"|' -e "s|\"<IMAGE>\"|\"$1\"|" \
        -e 's|"<SCREEN>"|"dashboard"|' "$TMP/approve.sh" > "$TMP/approve-filled.sh"
  }
  fill "$dd/round-2/variant-B-2.png"
  # Every way text can break out of shell: quotes, $(...), backticks, a heredoc terminator.
  printf '%s\n' "it's \"great\" \$(touch $SENT/dollar) \`touch $SENT/tick\`" 'VIBE_PY_EOF' "touch $SENT/eof" > "$dd/approved-feedback.txt"
  ( cd "$TMP" && env -u _DESIGN_DIR bash "$TMP/approve-filled.sh" ) > "$TMP/run.out" 2>&1
  if python3 -I -c 'import json,sys
rec=json.load(open(sys.argv[1])); fb=open(sys.argv[2]).read().strip()
sys.exit(not (rec["approved_variant"]=="B" and rec["feedback"]==fb and rec["screen"]=="dashboard"
              and rec.get("approved_path")==sys.argv[3]))' \
       "$dd/approved.json" "$dd/approved-feedback.txt" "$dd/round-2/variant-B-2.png" 2>/dev/null && [ -z "$(ls -A "$SENT")" ]; then
    ok "hostile feedback lands in approved.json verbatim, with the chosen image's path, and none of it ran"
  else
    no "approved.json ($(head -3 "$TMP/run.out")); sentinels: $(ls "$SENT")"
  fi
  rm -f "$dd/approved.json"
  fill "$dd/variant-Z.png"
  if ( cd "$TMP" && bash "$TMP/approve-filled.sh" ) > "$TMP/run.out" 2>&1 || [ -f "$dd/approved.json" ]; then
    no "approved.json was written for an image that does not exist"
  else
    ok "a missing approved image stops the record instead of guessing"
  fi
  grep -Fq "echo '{\"approved_variant\"" "$R" && no "approved.json is still hand-built with echo" \
    || ok "approved.json is not hand-built with echo"
fi

echo "fonts"
section "$R" "## Phase 3: The Complete Proposal" > "$TMP/p3"
grep -Fq 'Verify every face you propose' "$TMP/p3" && ok "font selection has a verification step" \
  || no "fonts are not verified"
grep -Fq 'pending verification' "$TMP/p3" && ok "unverifiable fonts are marked pending" || no "no offline fallback"
grep -Fq 'Font recommendations by purpose' "$TMP/p3" && no "the fixed font menu is still there" \
  || ok "no fixed font menu"
overused=$(grep -F '**Overused as display**' -A1 "$TMP/p3" | tail -1)
for f in Fraunces Geist 'DM Sans' 'Instrument Sans' 'Plus Jakarta Sans' Outfit; do
  case "$overused" in *"$f"*) ok "overused list covers $f" ;; *) no "overused list misses $f" ;; esac
done

echo "design knowledge is consistent"
grep -Fq 'Exposed structure, system fonts' "$TMP/p3" && no "Brutalist still recommends system fonts" \
  || ok "Brutalist no longer recommends system fonts"
grep -Fq 'CRT glow' "$TMP/p3" && no "Retro-Futuristic still recommends CRT glow" || ok "no CRT glow"
python3 -I -c 'import re,sys
t=re.sub(r"\s+"," ",open(sys.argv[1]).read())
sys.exit(1 if "VARY light/dark" in t else 0)' "$TMP/p3" \
  && ok "light/dark is not varied across generations" || no "anti-convergence still varies light/dark"
grep -Fq 'the three looks' "$TMP/p3" && ok "three-looks calibration present" || no "three-looks calibration missing"
grep -Fq 'balanced (primary + secondary' "$TMP/p3" && no "old color-approach scale still present" \
  || ok "color approaches updated"

echo "design-consultation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
