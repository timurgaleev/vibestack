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
HOSTILE="$TMP/hostile.txt"
cat > "$HOSTILE" <<'EOF'
Hero says "Ship it" — no `touch pwned-tick` here, nor $(touch pwned-sub)
single ' quote, $HOME stays literal, backslash \n stays too
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

run_block() {  # run_block NAME BLOCK_FILE -> exit code; cwd is the scratch dir
  (cd "$WORK" && STUB_LOG="$TMP/log-$1" D="$TMP/stub-design" _DESIGN_DIR="$TMP/designs/home-page-20260101" \
     HOME="$TMP/home" bash -c 'mkdir -p "$_DESIGN_DIR"; '"$(cat "$2")") >"$TMP/out-$1" 2>&1
}

bash_after "$R" "construct a design brief from the plan's description" > "$TMP/variants.sh" || no "variants block found"
fill "$TMP/variants.sh" "Replace this line with the brief" "$HOSTILE" > "$TMP/variants-filled.sh" || no "variants brief placeholder"
run_block variants "$TMP/variants-filled.sh"; rc=$?
[ "$rc" -eq 0 ] && cmp -s <(printf '%s' "$(cat "$HOSTILE")") "$TMP/log-variants.variants" \
  && ok "the variants brief reaches \$D byte-for-byte" \
  || no "variants brief: rc=$rc out='$(cat "$TMP/out-variants")'"

bash_after "$R" "run a cross-model quality check on each variant" > "$TMP/check.sh" || no "check block found"
run_block check "$TMP/check.sh"; rc=$?
[ "$rc" -eq 0 ] && cmp -s <(printf '%s' "$(cat "$HOSTILE")") "$TMP/log-check.check" \
  && ok "the check reads the same brief file" || no "check brief: rc=$rc out='$(cat "$TMP/out-check")'"

: > "$TMP/empty.txt"
fill "$TMP/variants.sh" "Replace this line with the brief" "$TMP/empty.txt" > "$TMP/variants-empty.sh"
rm -f "$TMP/log-empty.variants"
run_block empty "$TMP/variants-empty.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/log-empty.variants" ] && grep -q BRIEF_MISSING "$TMP/out-empty" \
  && ok "an empty brief stops before \$D runs" || no "empty brief: rc=$rc out='$(cat "$TMP/out-empty")'"
rm -f "$TMP/log-unfilled.variants"
run_block unfilled "$TMP/variants.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/log-unfilled.variants" ] \
  && ok "a brief left as the placeholder stops before \$D runs" || no "unfilled brief: rc=$rc out='$(cat "$TMP/out-unfilled")'"

bash_after "$R" "**Save the approved choice." > "$TMP/approved.sh" || no "approved block found"
fill "$TMP/approved.sh" "Replace this line with the feedback summary" "$HOSTILE" > "$TMP/approved-filled.sh"
sed 's/"<V>"/"B"/' "$TMP/approved-filled.sh" > "$TMP/approved-b.sh"
run_block approved "$TMP/approved-b.sh"; rc=$?
if [ "$rc" -eq 0 ] && python3 -I - "$TMP/designs/home-page-20260101/approved.json" "$HOSTILE" <<'PY'
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
run_block badv "$TMP/approved-filled.sh"; rc=$?
[ "$rc" -ne 0 ] && ok "an unsubstituted variant letter is refused" || no "approved.json written with variant '<V>'"
rm -f "$TMP/designs/home-page-20260101/approved.json"
sed 's/"<V>"/"B"/' "$TMP/approved.sh" > "$TMP/approved-unfilled.sh"
run_block fbunfilled "$TMP/approved-unfilled.sh"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/designs/home-page-20260101/approved.json" ] \
  && ok "feedback left as the placeholder is refused" || no "approved.json written with placeholder feedback"

ls "$WORK" "$TMP" 2>/dev/null | grep -q pwned && no "brief or feedback text ran as a command" \
                                              || ok "brief and feedback text never execute"

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
