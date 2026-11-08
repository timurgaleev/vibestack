#!/usr/bin/env bash
# test-outside-voice-body.sh — the shared outside-voice body grades a reviewer's
# output fail-closed and records the result under the right review-log name.
#
# Covers:
#   - the grading block, cut from lib/snippets/outside-voice-body.md and run on
#     fixture outputs under bash (and zsh when present): a missing or empty file,
#     findings without the closing `Recommendation:` line, a refusal and a bare
#     marker with no findings and no stated reason, a "no findings" phrase
#     inside a refusal or a non-proceed recommendation, and text after the
#     closing line all grade `unavailable`;
#     severity-tagged findings grade `issues_found`; a marker with an explicit
#     "no findings because" reason grades `clean`;
#   - the persist and disabled blocks, rendered into scratch includers and run
#     against the real vibe-review-log in a scratch VIBESTACK_HOME: plan reviews
#     write `codex-plan-review`, /document-release `codex-doc-review`, the design
#     voice `design-outside-voices`, each with `via` naming the includer — never
#     the includer's own name, which the readiness dashboard reads as its gate;
#   - a failed log write prints REVIEW_LOG_NOT_PERSISTED with the exit code;
#   - /plan-ceo-review, /plan-eng-review, /plan-devex-review and the design voice
#     of /plan-design-review render the body byte-identically with no Codex run
#     of their own, eng and devex carry no
#     stale Step 0D-POST pointer, eng's fallback asks for a read-only subagent,
#     and each overrides the preflight's disabled skip so the record is written.
#
# Usage: test/test-outside-voice-body.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
BODY="$SRC/lib/snippets/outside-voice-body.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# bash_after FILE "<text before the block>" -> the first ```bash block after it
bash_after() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError as e:
    sys.exit(str(e))
at = text.find(sys.argv[2])
m = re.search(r"```bash\n(.*?)\n[ \t]*```", text[at:], re.S) if at >= 0 else None
if not m:
    sys.exit("no bash block after: " + sys.argv[2])
sys.stdout.write(m.group(1) + "\n")
PY
}

echo "grading"
GRADE="$(bash_after "$BODY" "**Grade the output:**" 2>/dev/null)" || GRADE=""
[ -n "$GRADE" ] && ok "the body has a grading block" || no "no grading block in $BODY"

F="$TMP/fx"; mkdir -p "$F"
: > "$F/empty"
printf '%s\n' '[High] The migration has no rollback step.' \
  'Ship it after adding a rollback.' > "$F/no-marker"
printf '%s\n' "I can't help with reviewing this plan." > "$F/refusal"
printf '%s\n' 'Looks fine.' '' 'Recommendation: proceed' > "$F/bare-marker"
printf '%s\n' '1. [Critical] Two writers race on the same state file.' \
  '- [Low] The log line omits the branch.' '' \
  'Recommendation: add a lock before merging because the race corrupts state' > "$F/findings"
printf '%s\n' 'I checked sequencing, rollback and the test plan.' '' \
  'Recommendation: proceed as written — no findings because every step has a rollback and a test' > "$F/clean"
printf '%s\n' '**Recommendation:** proceed — no findings because it is fine' > "$F/bold-marker"
printf '%s\n' 'Recommendation: do not proceed; there are no findings because I was unable to read the repository' > "$F/refusal-reason"
printf '%s\n' 'Recommendation: block — I cannot report no findings because the material was empty' > "$F/cannot-report"
printf '%s\n' 'Recommendation: proceed — no findings because ok' '' \
  'Actually, wait: the migration drops a column with no backfill.' > "$F/trailing-text"

grade() {  # SHELL FIXTURE -> the OUTSIDE_GRADE value the block prints
  local block
  block="$(printf '%s' "$GRADE" | F_PATH="$2" python3 -I -c 'import os,sys; sys.stdout.write(sys.stdin.read().replace("<output-file>", os.environ["F_PATH"]))')"
  (cd "$TMP" && "$1" -c "$block" 2>&1) | sed -n 's/^OUTSIDE_GRADE: //p' | head -1
}

shells="bash"
command -v zsh >/dev/null 2>&1 && shells="bash zsh"
for sh in $shells; do
  expect() {  # FIXTURE WANT LABEL
    local got; got="$(grade "$sh" "$1")"
    [ "$got" = "$2" ] && ok "$sh: $3 → $2" || no "$sh: $3 graded '${got:-<nothing>}', want $2"
  }
  expect "$F/missing"     unavailable  "missing output file"
  expect "$F/empty"       unavailable  "empty output"
  expect "$F/no-marker"   unavailable  "findings without the Recommendation line"
  expect "$F/refusal"     unavailable  "a refusal"
  expect "$F/bare-marker" unavailable  "marker with no findings and no reason"
  expect "$F/bold-marker" unavailable  "a decorated marker"
  expect "$F/refusal-reason" unavailable "a no-findings phrase inside a refusal"
  expect "$F/cannot-report"  unavailable "a recommendation that is not proceed"
  expect "$F/trailing-text"  unavailable "text after the Recommendation line"
  expect "$F/findings"    issues_found "severity-tagged findings"
  expect "$F/clean"       clean        "an explicit no-findings reason"
done

echo "review-log records"
REPO="$TMP/repo"; VH="$TMP/vh"; mkdir -p "$REPO" "$VH/bin"
git -C "$REPO" -c init.defaultBranch=main init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
ln -s "$SRC/bin/vibe-review-log" "$VH/bin/vibe-review-log"

render_includer() {  # NAME -> path of the rendered includer
  mkdir -p "$TMP/src/$1" "$TMP/r/$1"
  printf -- '---\nname: %s\n---\n\n{{include lib/snippets/outside-voice-body.md}}\n' "$1" > "$TMP/src/$1/SKILL.md"
  VIBESTACK_REPO_ROOT="$SRC" "$SRC/bin/vibe-render-skill" "$TMP/src/$1/SKILL.md" "$TMP/r/$1/SKILL.md" >/dev/null 2>&1 \
    && printf '%s' "$TMP/r/$1/SKILL.md"
}
last_entry() { find "$VH/projects" -name '*-reviews.jsonl' -exec tail -n 1 {} \; 2>/dev/null | tail -n 1; }
field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null; }

persist() {  # INCLUDER STATUS SOURCE OUTSIDE_STATUS -> runs the persist block
  local r block
  r="$(render_includer "$1")" || { echo "render failed"; return 1; }
  block="$(bash_after "$r" "**Persist the result:**")" || return 1
  block="$(printf '%s' "$block" | python3 -I -c 'import sys; a=sys.argv; sys.stdout.write(sys.stdin.read().replace("OUTSIDE_STATUS", a[3]).replace("STATUS", a[1]).replace("SOURCE", a[2]))' "$2" "$3" "$4")"
  (cd "$REPO" && VIBESTACK_HOME="$VH" bash -c "$block" 2>&1)
}

for row in "plan-eng-review codex-plan-review" "plan-ceo-review codex-plan-review" \
           "plan-devex-review codex-plan-review" "document-release codex-doc-review" \
           "plan-design-review design-outside-voices"; do
  set -- $row
  persist "$1" issues_found codex completed >/dev/null
  e="$(last_entry)"
  if [ "$(field "$e" skill)" = "$2" ] && [ "$(field "$e" via)" = "$1" ] \
     && [ "$(field "$e" status)" = issues_found ] && [ "$(field "$e" outside_status)" = completed ]; then
    ok "$1 logs $2 via $1"
  else
    no "$1 logged '${e:-nothing}', want skill $2 via $1"
  fi
done

r="$(render_includer plan-eng-review)" || r=""
block="$(bash_after "$r" "**If \`CODEX_MODE\` is \`disabled\`:**" 2>/dev/null)" || block=""
if [ -n "$block" ]; then
  (cd "$REPO" && VIBESTACK_HOME="$VH" bash -c "$block" >/dev/null 2>&1)
  e="$(last_entry)"
  [ "$(field "$e" status)" = disabled ] && [ "$(field "$e" outside_status)" = disabled ] \
    && [ "$(field "$e" source)" = none ] && [ "$(field "$e" skill)" = codex-plan-review ] \
    && ok "the disabled branch logs a disabled record" || no "disabled branch logged '${e:-nothing}'"
else
  no "no disabled-branch log block"
fi

# A logger that refuses the write: the failure must be printed, not swallowed.
rm -f "$VH/bin/vibe-review-log"
printf '#!/usr/bin/env bash\necho refused >&2\nexit 1\n' > "$VH/bin/vibe-review-log"
chmod +x "$VH/bin/vibe-review-log"
out="$(persist plan-eng-review clean codex completed)"
printf '%s\n' "$out" | grep -q '^REVIEW_LOG_NOT_PERSISTED (exit 1)' \
  && ok "a failed log write is reported" || no "a failed log write was swallowed: '$out'"

echo "plan-review includers"
# Each plan review renders the shared body verbatim; a skill that re-inlines its
# own Codex run is the drift this snippet exists to stop.
for s in plan-ceo-review plan-eng-review plan-devex-review plan-design-review document-release; do
  mkdir -p "$TMP/real/$s"
  if ! VIBESTACK_REPO_ROOT="$SRC" "$SRC/bin/vibe-render-skill" "$SRC/skills/$s/SKILL.md" "$TMP/real/$s/SKILL.md" >/dev/null 2>&1; then
    no "$s renders"; continue
  fi
  if python3 -I - "$BODY" "$TMP/real/$s/SKILL.md" "$s" <<'PY'
import sys
body = open(sys.argv[1], encoding="utf-8").read().replace("{SKILL_NAME}", sys.argv[3])
sys.exit(0 if body.strip() in open(sys.argv[2], encoding="utf-8").read() else 1)
PY
  then ok "$s renders the outside-voice body byte-identically"
  else no "$s does not render the outside-voice body verbatim"; fi
  grep -qE 'TMPERR_(PV|DESIGN|DOC)' "$SRC/skills/$s/SKILL.md" \
    && no "$s still carries its own Codex run" || ok "$s has no inlined Codex run"
  # The preflight says "skip this section entirely" on disabled; without an
  # override before the body, the body's disabled record is never reached and a
  # switched-off outside voice reads as a review that never ran.
  awk '/^\{\{include lib\/snippets\/outside-voice-preflight\.md\}\}$/{on=1;next}
       /^\{\{include lib\/snippets\/outside-voice-body\.md\}\}$/{on=0}
       on' "$SRC/skills/$s/SKILL.md" | tr '\n' ' ' \
    | grep -qF 'On `disabled`, still write the `disabled` record' \
    && ok "$s writes the disabled record despite the preflight's skip" \
    || no "$s lets the preflight skip the disabled record"
done
for s in plan-eng-review plan-devex-review; do
  grep -qF 'Step 0D-POST' "$SRC/skills/$s/SKILL.md" \
    && no "$s points at a Step 0D-POST it does not have" || ok "$s has no stale Step 0D-POST reference"
done
r="$TMP/real/plan-eng-review/SKILL.md"
sec="$(sed -n '/^## Outside Voice — Independent Plan Challenge/,/^### Outside Voice Integration Rule/p' "$r" 2>/dev/null)"
printf '%s' "$sec" | grep -qF 'subagent_type: "Plan"' \
  && ok "plan-eng-review fallback asks for a read-only subagent type" \
  || no "plan-eng-review fallback subagent type is unrestricted"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
