#!/usr/bin/env bash
# test-plan-review-contract.sh — contracts between /autoplan and the plan-*-review
# and /office-hours skills it loads from disk.
#
# Covers:
#   - every entry of a "skip these sections" list names the start of a real `## `
#     heading in the rendered skill it skips into (a renamed shared heading would
#     otherwise make /autoplan run the setup twice, or fire the scope gate);
#   - autoplan's restore point is a byte-exact copy of the plan;
#   - the voices' plan-body extract stops at the decision-log marker, drops the
#     restore-point comments, and refuses a plan without the marker;
#   - no `codex exec "...<placeholder>..."` prompt interpolation remains, and no
#     skill calls the removed remote-slug helper;
#   - the shared spec review loop keeps its severity, round-grading, cap-check,
#     incomplete-input and builder-question rules, and both includers render it.
#
# Usage: test/test-plan-review-contract.sh [repo-root]
#   repo-root defaults to this checkout; it must hold skills/ and lib/snippets/.
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

mkdir -p "$TMP/r"
for s in autoplan office-hours plan-ceo-review plan-eng-review plan-design-review plan-devex-review; do
  VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/$s/SKILL.md" "$TMP/r/$s/SKILL.md" \
    >/dev/null 2>&1 || no "$s renders"
done

# skiplist FILE "<text right before the list>" -> one entry per line. A
# backticked entry is a heading prefix; otherwise the whole item is.
skiplist() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
text, anchor = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
at = 0
while True:
    at = text.find(anchor, at)
    if at < 0:
        break
    lines = text[at:].split("\n")[1:]
    while lines and not lines[0].startswith("- "):   # anchor may wrap
        lines = lines[1:]
    for line in lines:
        if line.startswith("  ") and line.strip():   # wrapped item
            continue
        if not line.startswith("- "):
            break
        item = line[2:].strip()
        m = re.match(r"`([^`]+)`", item)
        print(m.group(1) if m else item)
    at += len(anchor)
PY
}
# check_list LABEL LIST_FILE RENDERED... -> every entry starts some `## ` heading
check_list() {
  local label="$1" list="$2" entry bad=""; shift 2
  [ -s "$list" ] || { no "$label: skip list not found"; return; }
  # A file, not a pipe: `grep -q` exits on its first match, and under pipefail
  # the writer's SIGPIPE would turn a found heading into a miss.
  grep -h '^## ' "$@" | sed 's/^## //' > "$TMP/headings"
  while IFS= read -r entry; do
    if ! grep -qF -- "$entry" "$TMP/headings"; then
      bad="$bad [$entry]"
    elif ! awk -v e="$entry" 'index($0, e) == 1 {f=1} END {exit !f}' "$TMP/headings"; then
      bad="$bad [$entry (not a prefix)]"
    fi
  done < "$list"
  [ -z "$bad" ] && ok "$label: $(wc -l < "$list" | tr -d ' ') entries match rendered headings" \
                || no "$label: no matching heading for$bad"
}

echo "skip lists"
REVIEWS="$TMP/r/plan-ceo-review/SKILL.md $TMP/r/plan-eng-review/SKILL.md $TMP/r/plan-design-review/SKILL.md $TMP/r/plan-devex-review/SKILL.md"
skiplist "$SRC/skills/autoplan/SKILL.md" "(they are already handled by /autoplan)" > "$TMP/review-skip"
# shellcheck disable=SC2086
check_list "autoplan review-skill skip list" "$TMP/review-skip" $REVIEWS
grep -q '^Scope gate' "$TMP/review-skip" && ok "autoplan skips the scope gate" \
                                          || no "autoplan's skip list has no Scope gate entry"
OH="$TMP/r/office-hours/SKILL.md"
for s in autoplan plan-ceo-review plan-eng-review; do
  skiplist "$SRC/skills/$s/SKILL.md" "**skipping these sections**" > "$TMP/oh-skip-$s"
  check_list "$s office-hours skip list" "$TMP/oh-skip-$s" "$OH"
done

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

# A plan repo with a plan whose bytes a retype would change: trailing spaces, a
# tab, no newline at the end, characters a shell would expand.
REPO="$TMP/repo"; H="$TMP/home"; mkdir -p "$REPO" "$H"
git -C "$REPO" -c init.defaultBranch=main init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
PLAN="$TMP/plans/my plan.md"; mkdir -p "$TMP/plans"
printf '# Plan $(touch pwned) `x`\n\ttabbed   \nlast line, no newline' > "$PLAN"

echo "restore point"
block="$(bash_after "$SRC/skills/autoplan/SKILL.md" "### Step 1: Capture restore point")" || block=""
block="${block//<plan_path>/$PLAN}"
out="$(cd "$REPO" && HOME="$H" bash -c "$block" 2>&1)"; rc=$?
rp="$(printf '%s\n' "$out" | sed -n 's/^RESTORE_PATH=//p')"
[ "$rc" -eq 0 ] && [ -n "$rp" ] && cmp -s "$PLAN" "$rp" && ok "restore point is a byte-exact copy" \
                                                        || no "restore point: rc=$rc '$out'"
[ ! -e "$REPO/pwned" ] && ok "the plan's text is never executed" || no "plan text ran as a command"

echo "voice input extract"
cat > "$PLAN" <<'EOF'
<!-- /autoplan restore point: /x/first.md -->
<!-- /autoplan restore point: /x/second.md -->
# Plan
Step one.
Amended by phase 1.
<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail
REVIEW OUTPUT FROM PHASE 1
EOF
block="$(bash_after "$SRC/skills/autoplan/SKILL.md" "**1. Extract the plan body")" || block=""
block="${block//<plan_path>/$PLAN}"; block="${block//<ceo|design|dx|eng>/eng}"
out="$(cd "$REPO" && HOME="$H" bash -c "$block" 2>&1)"; rc=$?
pin="$(printf '%s\n' "$out" | sed -n 's/^PLAN_INPUT: //p')"
if [ "$rc" -eq 0 ] && [ -f "$pin" ]; then
  [ "$(cat "$pin")" = "$(printf '# Plan\nStep one.\nAmended by phase 1.')" ] \
    && ok "extract is the plan body with its amendments, nothing else" \
    || no "extract content: $(tr '\n' '|' < "$pin")"
  [ -z "$(git -C "$REPO" status --porcelain)" ] && ok "voice inputs leave the reviewed repo's status clean" \
                                                || no "voice inputs show up in git status: $(git -C "$REPO" status --porcelain | tr '\n' ' ')"
else
  no "extract: rc=$rc '$out'"
fi
printf '# Plan\nno marker here\n' > "$PLAN"
out="$(cd "$REPO" && HOME="$H" bash -c "$block" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a plan without the marker is refused" || no "extract ran without the marker: '$out'"

echo "codex prompts and helpers"
bad="$(python3 -I - "$SRC"/skills/autoplan/SKILL.md "$SRC"/skills/plan-ceo-review/SKILL.md \
        "$SRC"/skills/plan-eng-review/SKILL.md "$SRC"/skills/plan-devex-review/SKILL.md <<'PY'
import re, sys
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r'codex exec "((?:[^"\\]|\\.)*)"', text, re.S):
        if re.search(r"<[^<>\n]+>", m.group(1)):
            print("%s:%d" % (path.rsplit("/skills/", 1)[-1], text.count("\n", 0, m.start()) + 1))
PY
)"
[ -z "$bad" ] && ok "no codex exec prompt interpolates a <placeholder>" \
              || no "codex exec with an interpolated prompt at: $(printf '%s' "$bad" | tr '\n' ' ')"
hits="$(grep -rln 'remote-slug' "$SRC/skills" 2>/dev/null || true)"
[ -z "$hits" ] && ok "no skill calls remote-slug" || no "remote-slug still used in: $hits"

echo "spec review loop"
LOOP="$SRC/lib/snippets/spec-review-loop.md"
loop_has() { grep -qF -- "$1" "$LOOP" && ok "$2" || no "$2 (missing: $1)"; }
loop_has 'Tag every issue `blocking`' "reviewer tags every issue blocking or minor"
loop_has 'Fix only `blocking` issues' "only blocking issues are fixed"
loop_has '`minor` issues go straight to Reviewer Concerns' "minor issues become Reviewer Concerns"
loop_has 'mark each one `resolved` or `persisting`' "rounds 2-3 grade the previous findings"
loop_has 'keep every Reviewer Concern already gathered' "a reviewer failure keeps earlier concerns"
loop_has 'issues confirmed resolved k/N' "the cap verifies each applied fix against the amended text"
loop_has 'INPUT_INCOMPLETE' "truncated or missing input is reported, not graded"
loop_has '**Builder questions**' "reviewer returns ranked builder questions"
loop_has '(my call)' "minor builder questions are decided and marked"
loop_has 'at most 4 questions per call' "user-only builder questions go out in batches of 4"
loop_has 'If the reviewer returns blocking issues or `INPUT_INCOMPLETE`' "incomplete input is re-dispatched, not passed"
loop_has 'If no round produced a grade' "a review that never graded is reported unavailable"
for s in office-hours plan-ceo-review; do
  grep -qF 'issues confirmed resolved k/N' "$TMP/r/$s/SKILL.md" \
    && ok "$s renders the spec review loop" || no "$s does not render the spec review loop"
done

echo "decision log"
# Value: protects=a decision or rationale holding a quote reaches the decision log intact; fails_when=the free text is spliced back into a single-quoted shell argument; why_new=nothing ran these blocks; seam=none (the real vibe-decision-log)
HOSTILE="the user's call: keep \$(touch $TMP/pwned) and \`id\` out"
for s in plan-eng-review plan-ceo-review; do
  R="$TMP/r/$s/SKILL.md"
  blk="$(python3 -I - "$R" <<'PY2'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
hits = [m.group(1) for m in re.finditer(r"^```bash\n(.*?)\n```", text, re.S | re.M) if "DECISION_LOG_NOT_PERSISTED" in m.group(1)]
sys.stdout.write(hits[0] if len(hits) == 1 else "")
PY2
)"
  [ -n "$blk" ] || { no "$s: one decision-log block"; continue; }
  VH="$TMP/dl-$s"; mkdir -p "$VH/bin"; ln -sf "$SRC/bin/vibe-decision-log" "$VH/bin/vibe-decision-log"
  printf '%s\n' "$blk" > "$TMP/dl.sh"
  if grep -qF '<DECISION_FILE>' "$TMP/dl.sh"; then
    python3 -I -c 'import json,sys; json.dump({"decision": sys.argv[2], "rationale": sys.argv[2], "scope": "branch", "source": "skill"}, open(sys.argv[1], "w"))' "$TMP/dec.json" "$HOSTILE"
    python3 -I -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("<DECISION_FILE>", sys.argv[2]))' "$TMP/dl.sh" "$TMP/dec.json"
  else  # the model following the inline form substitutes the text in place
    python3 -I -c 'import sys; p=sys.argv[1]; t=open(p).read()
for k in ("SCOPE_SUMMARY", "VERDICT", "RATIONALE", "DECISION\""): t=t.replace(k, sys.argv[2] + ("\"" if k.endswith("\"") else ""))
open(p,"w").write(t)' "$TMP/dl.sh" "$HOSTILE"
  fi
  (cd "$TMP" && VIBESTACK_HOME="$VH" bash "$TMP/dl.sh") > "$TMP/dl.out" 2>&1
  log="$(cat "$VH"/projects/*/decisions.jsonl 2>/dev/null)"
  if [ ! -e "$TMP/pwned" ] && python3 -I -c 'import json,sys; e=json.loads(sys.argv[1].splitlines()[-1]); sys.exit(sys.argv[2] not in e["decision"] or e["rationale"] != sys.argv[2])' "$log" "$HOSTILE" 2>/dev/null; then
    ok "$s: a decision with quotes and \$(...) is logged byte-for-byte"
  else
    no "$s: decision not logged intact: $(tr '\n' '|' < "$TMP/dl.out") log=[$log]"
  fi
  rm -f "$TMP/pwned" "$TMP/dec.json"
done

echo "outside-voice briefs"
# Value: protects=each reviewer brief asks for the closing Recommendation line the shared grader requires; fails_when=a brief ends on "Just the problems." alone and pulls the reviewer off that line; why_new=test-outside-voice-body.sh checks the body, not the briefs; seam=none
for s in plan-ceo-review plan-eng-review plan-devex-review; do
  grep -qF 'Just the problems, then the closing Recommendation line."' "$SRC/skills/$s/SKILL.md" \
    && ok "$s brief asks for the Recommendation line" || no "$s brief ends without the Recommendation line"
  # Value: protects=text the model copies carries plain backticks; fails_when=a \` escape returns to prose; why_new=the report snippet was fixed alone; seam=none
  n="$(awk '/^[ \t]*```/ {f = !f; next} !f' "$SRC/skills/$s/SKILL.md" | grep -c '\\`' || true)"
  [ "$n" -eq 0 ] && ok "$s prose has no escaped backticks" || no "$s prose has $n escaped backtick lines"
done

# Value: protects=an outside voice that graded unavailable is reported as such, not as ran or skipped; fails_when=a completion summary loses the unavailable value; why_new=nothing checked the summaries; seam=none
grep -qF -- '- Outside voice: ran (codex/claude) / unavailable (<cause>) / skipped' "$SRC/skills/plan-eng-review/SKILL.md" \
  && ok "plan-eng-review summary can say unavailable" || no "plan-eng-review summary offers only ran / skipped"
grep -qF 'ran (codex/claude) / unavailable / skipped' "$SRC/skills/plan-ceo-review/SKILL.md" \
  && ok "plan-ceo-review summary can say unavailable" || no "plan-ceo-review summary lacks unavailable"

echo "merged-branch stop"
# Value: protects=a plan-file review does not stop on a branch the base already contains; fails_when=the plan-file exception after the base-branch include is dropped; why_new=the snippet's stop is written for diff reviews; seam=none
for s in plan-ceo-review plan-devex-review autoplan; do
  grep -qF 'is a plan file rather than the branch diff, a `BASE_CONTAINS_HEAD` line is not a stop' "$SRC/skills/$s/SKILL.md" \
    && ok "$s: BASE_CONTAINS_HEAD does not stop a plan-file review" || no "$s stops a plan-file review on BASE_CONTAINS_HEAD"
done

echo "timeout kill-after"
# Value: protects=a Codex process that ignores SIGTERM cannot outlive the Bash tool limit; fails_when=a _cx wrapper calls timeout without -k; why_new=no test ran the wrappers; seam=none (real timeout binary)
for s in autoplan office-hours design-consultation design-review; do
  n="$(grep -c '"$_CX_TO" "$@"' "$SRC/skills/$s/SKILL.md" || true)"
  [ "$n" -eq 0 ] && ok "$s: every timeout wrapper sends a kill after the grace period" || no "$s: $n timeout wrappers without -k"
done
TO="$(command -v gtimeout || command -v timeout || true)"
if [ -n "$TO" ]; then
  def="$(grep -m1 '^_cx() {' "$SRC/skills/autoplan/SKILL.md")"
  start=$(date +%s)
  ( eval "$def"; _CX_TO="$TO"; _cx 1 sh -c 'trap "" TERM; while :; do sleep 1; done' "vibe-cx-probe-$$" ) >/dev/null 2>&1 &
  wp=$!
  for _ in $(seq 1 25); do kill -0 "$wp" 2>/dev/null || break; sleep 1; done
  if kill -0 "$wp" 2>/dev/null; then
    pkill -KILL -f "vibe-cx-probe-$$" 2>/dev/null; kill -KILL "$wp" 2>/dev/null
    no "autoplan _cx: a TERM-ignoring child outlived 25s"
  else
    ok "autoplan _cx: a TERM-ignoring child is killed ($(( $(date +%s) - start ))s)"
  fi
fi

echo "autoplan urgent findings"
# Value: protects=a critical finding outside the plan reaches the final gate from the phase that found it; fails_when=the producer rule or the pre-gate check is dropped and the gate relies on recall; why_new=the gate section had no producer; seam=none
AP="$SRC/skills/autoplan/SKILL.md"
grep -qF 'Classification `URGENT-OUTSIDE`' "$AP" && ok "phases record urgent out-of-plan findings as they find them" \
  || no "no producer for the Urgent, outside this plan section"
grep -qF -- '- [ ] Every `URGENT-OUTSIDE` row is listed under "Urgent, outside this plan"' "$AP" \
  && ok "pre-gate checks the urgent list" || no "pre-gate has no urgent-list checkbox"

echo "context pressure"
# Value: protects=/plan-devex-review runs every stage under context pressure, like /plan-design-review; fails_when=a priority ranking returns that lets late passes drop; why_new=test-plan-design-review.sh checks only the design skill; seam=none
DX="$TMP/r/plan-devex-review/SKILL.md"
grep -qF 'Priority Hierarchy Under Context Pressure' "$DX" \
  && no "plan-devex-review still ranks passes it may drop under context pressure" || ok "plan-devex-review has no priority ranking"
grep -qF 'Complete every stage; shorten only optional commentary' "$DX" \
  && ok "plan-devex-review completes every stage under context pressure" || no "plan-devex-review lacks the context-pressure rule"

echo
echo "plan review contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
