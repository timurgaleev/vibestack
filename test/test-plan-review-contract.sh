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
#     skill calls the removed remote-slug helper.
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
  while IFS= read -r entry; do
    if ! grep -h '^## ' "$@" | sed 's/^## //' | grep -qF -- "$entry"; then
      bad="$bad [$entry]"
    elif ! grep -h '^## ' "$@" | sed 's/^## //' | awk -v e="$entry" 'index($0, e) == 1 {f=1} END {exit !f}'; then
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

echo
echo "plan review contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
