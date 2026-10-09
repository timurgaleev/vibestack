#!/usr/bin/env bash
# test-plan-design-review.sh — /plan-design-review contracts that keep plan text
# out of the shell, keep every fix behind the user's approval, and keep the
# review log honest.
#
# Covers:
#   - the scope gate comes before any bash the skill runs (preamble, session
#     detection, base-branch detection);
#   - mockup briefs and confirmed feedback reach `$D` and approved.json through
#     files: the blocks run with hostile text in the brief and the feedback, and
#     that text arrives byte-for-byte without ever executing;
#   - no `$D` command interpolates a <placeholder> brief or feedback;
#   - the first failed generation routes to DESIGN_NOT_AVAILABLE and the skill
#     forbids hand-built wireframes;
#   - fixes are proposed and approved per issue, never applied first;
#   - the overall score is the lowest of Passes 1-6 and `clean` is defined by it.
#
# Usage: test/test-plan-design-review.sh [repo-root]
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

R="$TMP/r/plan-design-review/SKILL.md"
VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/plan-design-review/SKILL.md" "$R" \
  >/dev/null 2>&1 || { no "plan-design-review renders"; R=""; }
[ -n "$R" ] && [ -f "$R" ] || { echo "plan-design-review: render failed" >&2; exit 1; }

# bash_after FILE "<text before the block>" -> the first ```bash block after it
bash_after() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
text, anchor = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
at = text.find(anchor)
m = re.search(r"```bash\n(.*?)\n[ \t]*```", text[at:], re.S) if at >= 0 else None
if not m:
    sys.exit("no bash block after: " + anchor)
sys.stdout.write(m.group(1) + "\n")
PY
}
# fill BLOCK_FILE "<placeholder line prefix>" CONTENT_FILE -> block with that
# placeholder line replaced by the content, verbatim
fill() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
block = open(sys.argv[1], encoding="utf-8").read()
content = open(sys.argv[3], encoding="utf-8").read().rstrip("\n")
lines = block.split("\n")
hits = [i for i, l in enumerate(lines) if l.startswith(sys.argv[2])]
if len(hits) != 1:
    sys.exit("placeholder not found exactly once: " + sys.argv[2])
lines[hits[0]] = content
sys.stdout.write("\n".join(lines))
PY
}
first_line() { grep -n -m1 -F -- "$2" "$1" | cut -d: -f1; }

echo "scope gate order"
gate="$(first_line "$R" "## Scope gate (FIRST")"
pre="$(first_line "$R" "## Preamble")"
host="$(first_line "$R" "## Session & host detection")"
base="$(first_line "$R" "## Step 0: Detect platform and base branch")"
fence="$(first_line "$R" '```bash')"
if [ -n "$gate" ] && [ -n "$pre" ] && [ -n "$host" ] && [ -n "$base" ] && [ -n "$fence" ] \
   && [ "$gate" -lt "$pre" ] && [ "$gate" -lt "$host" ] && [ "$gate" -lt "$base" ] && [ "$gate" -lt "$fence" ]; then
  ok "the scope gate precedes the preamble, session detection, base-branch detection and every bash block"
else
  no "scope gate at line ${gate:-?}, preamble ${pre:-?}, session ${host:-?}, base branch ${base:-?}, first bash ${fence:-?}"
fi

echo "briefs and feedback go through files"
# The model writes briefs and feedback with its Write tool; the test stands in for
# it by copying the hostile text into place. Terminator lines prove no heredoc
# carries the text: under a heredoc, the line after one would run as a command.
HOSTILE="$TMP/hostile.txt"
cat > "$HOSTILE" <<'EOF'
Hero says "Ship it" — no `touch pwned-tick` here, nor $(touch pwned-sub)
single ' quote, $HOME stays literal, backslash \n stays too
VIBE_BRIEF_EOF
touch pwned-brief-delim
VIBE_FEEDBACK_EOF
touch pwned-feedback-delim
EOF
WORK="$TMP/work"; mkdir -p "$WORK"
# A stub designer that records the brief it was handed and saves one image.
cat > "$TMP/stub-design" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
verb="$1"; shift; brief=""; out="."
while [ $# -gt 0 ]; do
  case "$1" in --brief) brief="$2"; shift 2 ;; --output-dir) out="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' "$brief" > "$STUB_LOG.$verb"
[ "$verb" = variants ] && { mkdir -p "$out"; : > "$out/variant-A.png"; echo "saved: $out/variant-A.png"; }
exit 0
EOF
chmod +x "$TMP/stub-design"
DDIR="$TMP/designs/home-page-20260101"; mkdir -p "$DDIR"

# Every Bash call is a fresh shell: blocks run with D and _DESIGN_DIR unset, bind
# $D to the installed path themselves, and get the directory from the placeholder.
mkdir -p "$TMP/home/.vibestack/bin"; cp "$TMP/stub-design" "$TMP/home/.vibestack/bin/vibe-design"
run_block() {  # run_block NAME BLOCK_FILE -> exit code; cwd is the scratch dir
  mkdir -p "$DDIR"
  (cd "$WORK" && env -u D -u _DESIGN_DIR STUB_LOG="$TMP/log-$1" HOME="$TMP/home" \
     bash -c "$(sed "s|<DESIGN_DIR>|$DDIR|g" "$2")") >"$TMP/out-$1" 2>&1
}
same_as_hostile() { cmp -s <(printf '%s' "$(cat "$HOSTILE")") "$1"; }

bash_after "$R" "construct a design brief from the plan's description" > "$TMP/variants.sh" || no "variants block found"
cp "$HOSTILE" "$DDIR/brief.txt"
run_block variants "$TMP/variants.sh"; rc=$?
[ "$rc" -eq 0 ] && same_as_hostile "$TMP/log-variants.variants" \
  && ok "the variants brief reaches \$D byte-for-byte" \
  || no "variants brief: rc=$rc out='$(cat "$TMP/out-variants")'"

bash_after "$R" "run a cross-model quality check on each variant" > "$TMP/check.sh" || no "check block found"
run_block check "$TMP/check.sh"; rc=$?
[ "$rc" -eq 0 ] && same_as_hostile "$TMP/log-check.check" \
  && ok "the check reads the same brief file" || no "check brief: rc=$rc out='$(cat "$TMP/out-check")'"

: > "$DDIR/brief.txt"
run_block empty "$TMP/variants.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/log-empty.variants" ] && grep -q BRIEF_MISSING "$TMP/out-empty" \
  && ok "an empty brief stops before \$D runs" || no "empty brief: rc=$rc out='$(cat "$TMP/out-empty")'"
rm -f "$DDIR/brief.txt"
run_block nobrief "$TMP/variants.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/log-nobrief.variants" ] && grep -q BRIEF_MISSING "$TMP/out-nobrief" \
  && ok "a brief never written stops before \$D runs" || no "missing brief: rc=$rc out='$(cat "$TMP/out-nobrief")'"

# The 10/10 mockup: the second block after the anchor runs \$D on the written brief.
python3 -I - "$R" > "$TMP/ideal.sh" <<'PY' || no "ideal blocks found"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
at = text.find("Show me what 10/10 looks like")
blocks = re.findall(r"```bash\n(.*?)\n[ \t]*```", text[at:], re.S) if at >= 0 else []
if len(blocks) < 2:
    sys.exit("expected a setup block and a generate block")
sys.stdout.write(blocks[1].replace("<dimension>", "typography") + "\n")
PY
IDIR="$TMP/home/.vibestack/projects/designs/ideal-typography-$(date +%Y%m%d)"
mkdir -p "$IDIR"; cp "$HOSTILE" "$IDIR/brief.txt"
run_block ideal "$TMP/ideal.sh"; rc=$?
[ "$rc" -eq 0 ] && same_as_hostile "$TMP/log-ideal.variants" \
  && ok "the 10/10 brief reaches \$D byte-for-byte" || no "ideal brief: rc=$rc out='$(cat "$TMP/out-ideal")'"

bash_after "$R" "**Save the approved choice." > "$TMP/approved.sh" || no "approved block found"
sed 's/"<V>"/"B"/' "$TMP/approved.sh" > "$TMP/approved-b.sh"
cp "$HOSTILE" "$DDIR/approved-feedback.txt"
run_block approved "$TMP/approved-b.sh"; rc=$?
if [ "$rc" -eq 0 ] && python3 -I - "$DDIR/approved.json" "$HOSTILE" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1], encoding="utf-8"))
want = open(sys.argv[2], encoding="utf-8").read().strip()
assert rec["approved_variant"] == "B", rec
assert rec["feedback"] == want, rec["feedback"]
assert rec["screen"] == "home-page", rec["screen"]
assert set(rec) == {"approved_variant", "feedback", "date", "screen", "branch"}, rec
PY
then ok "approved.json is valid JSON carrying the feedback verbatim"
else no "approved.json: rc=$rc out='$(cat "$TMP/out-approved")'"; fi
run_block badv "$TMP/approved.sh"; rc=$?
[ "$rc" -ne 0 ] && ok "an unsubstituted variant letter is refused" || no "approved.json written with variant '<V>'"
rm -f "$DDIR/approved.json" "$DDIR/approved-feedback.txt"
run_block fbmissing "$TMP/approved-b.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$DDIR/approved.json" ] \
  && ok "feedback never written is refused" || no "approved.json written without feedback"

ls "$WORK" "$TMP" 2>/dev/null | grep -q pwned && no "brief or feedback text ran as a command" \
                                              || ok "brief and feedback text never execute"

echo "no untrusted text in shell source"
# Every skill this flow touches: a heredoc body that is a placeholder for plan,
# brief, feedback or DESIGN.md text ends at the first line equal to its terminator.
heredocs="$(python3 -I - "$SRC" <<'PY'
import re, sys, os
root = sys.argv[1]
skills = ["plan-design-review", "plan-ceo-review", "plan-eng-review", "autoplan",
          "design-consultation", "design-html", "design-review", "design-shotgun", "office-hours"]
start = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
hole = re.compile(r"Replace this line|<[^<>\n]*(brief|feedback|plan|DESIGN|summary|description)[^<>\n]*>|\{brief\}", re.I)
for name in skills:
    path = os.path.join(root, "skills", name, "SKILL.md")
    if not os.path.isfile(path):
        continue
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        m = start.search(lines[i]) if "<<<" not in lines[i] else None
        if not m:
            i += 1; continue
        term, j, body = m.group(2), i + 1, []
        while j < len(lines) and lines[j].strip() != term:
            body.append(lines[j]); j += 1
        if any(hole.search(b) for b in body):
            print(f"{name}:{i+1}: heredoc {term} wraps a text placeholder")
        i = j + 1
PY
)"
[ -z "$heredocs" ] && ok "no heredoc wraps a plan, brief or feedback placeholder" \
                   || no "heredoc placeholders: $heredocs"
grep -qF '**Write the brief with the Write tool**' "$R" \
  && grep -qF '**write the feedback summary the user just confirmed with the Write' "$R" \
  && grep -qF '**write the description with the Write tool**' "$R" \
  && ok "brief, feedback and 10/10 text are written with the Write tool" \
  || no "a brief or feedback is not routed through the Write tool"
awk '/^---$/{n++; next} n==1' "$R" | grep -qE '^[[:space:]]+- Write$' \
  && ok "allowed-tools grants Write" || no "allowed-tools lacks Write"

bad="$(grep -nE '\$D [a-z]+ .*--brief "<|"<(brief|feedback|FB)[^"]*>"|feedback":"<' "$R" || true)"
[ -z "$bad" ] && ok "no \$D command or approved.json write interpolates a <placeholder>" \
              || no "placeholder interpolation: $bad"

echo "failed generation"
grep -qF 'The first `$D variants` call fails before saving any image' "$R" \
  && grep -qF 'Treat that exactly as `DESIGN_NOT_AVAILABLE`' "$R" \
  && ok "the first failed generation is treated as DESIGN_NOT_AVAILABLE" \
  || no "no first-failure route to DESIGN_NOT_AVAILABLE"
grep -qF 'Do not substitute hand-built HTML/CSS wireframes' "$R" \
  && ok "hand-built wireframes are forbidden" || no "hand-built wireframes not forbidden"

echo "approval before edit"
grep -qF 'fix the obvious ones' "$R" && no "Design Philosophy still says to fix the obvious ones" \
                                    || ok "no fix-first instruction in the Design Philosophy"
grep -qE '^[0-9]\. Fix: Edit the plan' "$R" && no "the rating method still edits before asking" \
                                           || ok "the rating method has no edit-first step"
grep -qF 'Even obvious fixes need approval' "$R" && grep -qF 'Never edit first and ask afterward' "$R" \
  && grep -qF '**Carry decisions across passes.**' "$R" \
  && ok "per-issue approval and carried decisions are stated" || no "approval protocol missing"
grep -qF 'genuinely trivial AND there are no meaningful design alternatives' "$R" \
  && no "the escape hatch still lets a trivial fix skip the question" || ok "no trivial-fix exemption"
grep -qF 'then fixes the plan to get there' "$R" \
  && no "the description still promises fix-first" || ok "the description matches the approval flow"

echo "score and status"
grep -qF 'is the lowest of the six rated pass scores (Passes 1-6)' "$R" \
  && ok "overall score is the lowest of Passes 1-6" || no "overall score has no definition"
grep -qF '"clean" only if the after-fix overall score (lowest of Passes 1-6) is 8+ AND 0 unresolved' "$R" \
  && ok "clean is defined by the minimum score" || no "clean status not tied to the minimum"
grep -qF 'number of decisions the user individually approved' "$R" \
  && ok "decisions_made counts approved decisions only" || no "decisions_made still counts plan additions"

echo
echo "plan-design-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
