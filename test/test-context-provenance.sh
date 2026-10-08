#!/usr/bin/env bash
# test-context-provenance.sh — /context-save and /context-restore keep a resumed
# session from acting on the wrong context or on a guessed step.
#
# Runs the shell blocks straight out of the two SKILL.md files:
#   - restore's Step 1 orders current-branch saves first, scans past 20 files,
#     and falls back to other branches when this one has none;
#   - save's Step 3 computes a duration with GNU date as well as BSD date, and
#     never parses an empty process start as midnight.
# The provenance contract (markers on save, "Verify first" on restore) is prose,
# so its load-bearing phrases are checked as text.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# CONTEXT_SAVE_SKILL / CONTEXT_RESTORE_SKILL override the sources.
SAVE="${CONTEXT_SAVE_SKILL:-$ROOT/skills/context-save/SKILL.md}"
RESTORE="${CONTEXT_RESTORE_SKILL:-$ROOT/skills/context-restore/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# First fenced bash block after the given heading.
block_after() {
  awk -v h="$1" '
    index($0, h) == 1 { seen=1; next }
    seen && /^```bash$/ { on=1; next }
    on && /^```$/ { exit }
    on { print }
  ' "$2"
}

block_after '### Step 1: Find saved contexts' "$RESTORE" > "$TMP/restore.sh"
block_after '### Step 3: Compute session duration' "$SAVE" > "$TMP/duration.sh"
[ -s "$TMP/restore.sh" ] || { echo "restore Step 1 block not found" >&2; exit 1; }
[ -s "$TMP/duration.sh" ] || { echo "save Step 3 block not found" >&2; exit 1; }

# --- restore: candidate ordering ------------------------------------------

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.vibestack/bin"
cat > "$FAKE_HOME/.vibestack/bin/vibe-slug" <<'EOF'
#!/usr/bin/env bash
echo "SLUG=fixture"
EOF
chmod +x "$FAKE_HOME/.vibestack/bin/vibe-slug"
CK="$FAKE_HOME/.vibestack/projects/fixture/checkpoints"
mkdir -p "$CK"

mk() { # mk <stamp> <branch> <title>
  printf -- '---\nstatus: in-progress\nbranch: %s\n---\n\n## Working on: %s\n' "$2" "$3" \
    > "$CK/$1-$3.md"
}

run_restore() { # run_restore <branch>
  ( cd "$TMP" && HOME="$FAKE_HOME" VIBESTACK_HOME="$FAKE_HOME/.vibestack" \
      CURRENT_BRANCH="$1" bash "$TMP/restore.sh" 2>/dev/null )
}
first_path() { grep -m1 '^/.*\.md$'; }

# One current-branch save, buried under 25 newer saves from a sibling worktree.
mk 20260101-090000 feat/mine own-task
i=10
while [ "$i" -lt 35 ]; do
  mk "20260102-0900$i" feat/sibling "sibling-$i"
  i=$((i+1))
done

echo "restore ordering"
OUT=$(run_restore feat/mine)
case "$(printf '%s\n' "$OUT" | first_path)" in
  *-own-task.md) ok "current-branch save loads first despite 25 newer sibling saves" ;;
  *) no "first candidate is not the current-branch save: $(printf '%s\n' "$OUT" | first_path)" ;;
esac
printf '%s\n' "$OUT" | grep -q '^NO_CURRENT_BRANCH_CHECKPOINT' \
  && no "NO_CURRENT_BRANCH_CHECKPOINT printed although this branch has a save" \
  || ok "no fallback marker when this branch has a save"
N=$(printf '%s\n' "$OUT" | grep -c '^/.*\.md$')
[ "$N" -eq 20 ] && ok "printed list stays capped at 20" || no "printed $N paths, expected 20"
printf '%s\n' "$OUT" | grep -q 'sibling-34\.md$' \
  && ok "other-branch saves stay in the set as fallback" \
  || no "newest sibling save missing from the candidate list"

# Twenty-one saves on this branch, all newer than the sibling burst: the
# capped list holds none of the sibling's, so the newer one is named apart.
i=10
while [ "$i" -lt 31 ]; do
  mk "20260101-1000$i" feat/busy "busy-$i"
  i=$((i+1))
done
mk 20260103-090000 feat/sibling handoff
OUT=$(run_restore feat/busy)
printf '%s\n' "$OUT" | grep -q '^/.*-handoff\.md$' \
  && no "fixture broken: the handoff save reached the capped list" \
  || ok "capped list holds only this branch's saves"
printf '%s\n' "$OUT" | grep -q '^NEWEST_OTHER: .*-handoff\.md$' \
  && ok "newest other-branch save is named beyond the cap" \
  || no "NEWEST_OTHER does not name the newer handoff save"
rm -f "$CK"/*-busy-*.md "$CK"/*-handoff.md

OUT=$(run_restore feat/elsewhere)
case "$(printf '%s\n' "$OUT" | first_path)" in
  *-sibling-34.md) ok "no save on this branch: newest across all branches loads" ;;
  *) no "fallback did not pick the newest overall: $(printf '%s\n' "$OUT" | first_path)" ;;
esac
printf '%s\n' "$OUT" | grep -q '^NO_CURRENT_BRANCH_CHECKPOINT' \
  && ok "fallback is announced" || no "NO_CURRENT_BRANCH_CHECKPOINT missing on fallback"

rm -rf "$CK"
OUT=$(run_restore feat/mine)
printf '%s\n' "$OUT" | grep -q '^NO_CHECKPOINTS' \
  && ok "missing directory reports NO_CHECKPOINTS" || no "NO_CHECKPOINTS missing"

# --- save: session duration -----------------------------------------------

STUB="$TMP/stub"
mkdir -p "$STUB"
# ps reports the parent's start time as $FAKE_LSTART (may be empty).
cat > "$STUB/ps" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LSTART:-}"
EOF
# A GNU-style date: rejects BSD -j, parses -d, and treats -d "" as midnight
# (epoch 500) so an unguarded empty parse shows up as a bogus duration.
cat > "$STUB/date" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -j*) exit 1 ;;
  -d) [ -z "$2" ] && { echo 500; exit 0; }; echo 1000; exit 0 ;;
  +%s) echo 1100; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB/ps" "$STUB/date"

run_duration() {
  ( unset _TEL_START; PATH="$STUB:$PATH" FAKE_LSTART="$1" bash "$TMP/duration.sh" 2>/dev/null )
}

echo "save duration"
OUT=$(run_duration 'Thu Oct  8 10:00:00 2026')
[ "$OUT" = "SESSION_DURATION_S=100" ] \
  && ok "GNU date computes the duration" || no "GNU date: got '$OUT', expected SESSION_DURATION_S=100"
OUT=$(run_duration '')
[ "$OUT" = "SESSION_DURATION_S=unknown" ] \
  && ok "empty process start stays unknown (not midnight)" || no "empty start: got '$OUT'"

# --- provenance contract (prose) --------------------------------------------

echo "provenance contract"
has() { grep -Fq -- "$1" "$2"; }
for m in '(target state checked)' '(code read)' '(path run)' '(path read)' '(path assumed)'; do
  has "$m" "$SAVE" && ok "save defines $m" || no "save lacks $m"
  has "$m" "$RESTORE" && ok "restore sorts on $m" || no "restore ignores $m"
done
has 'Every item starts with the status' "$SAVE" \
  && ok "save requires the Open. status" || no "save lacks the Open. status rule"
has 'Verify first (inspect read-only before executing anything)' "$RESTORE" \
  && ok "restore prints a Verify first group" || no "restore lacks the Verify first group"
has 'This checkpoint predates provenance markers' "$RESTORE" \
  && ok "restore flags legacy saves" || no "restore lacks the legacy banner"
has 'Never execute a Verify first item' "$RESTORE" \
  && ok "continue never runs an unverified step" || no "continue may run an unverified step"

# Restore reads the marker at the end of an item, so save's examples must end
# in one; restore must still read older saves that put the outcome after it.
echo "marker position"
MARKERS='\((target state checked|code read|path run|path read|path assumed)\)'
EXAMPLES=$(grep -oE '`Open\. [^`]*`' "$SAVE" | grep -E "$MARKERS" || true)
if [ -z "$EXAMPLES" ]; then
  no "save has no marked Open. examples"
elif printf '%s\n' "$EXAMPLES" | grep -vqE "$MARKERS"'`$'; then
  no "a save example has text after its marker: $(printf '%s\n' "$EXAMPLES" | grep -vE "$MARKERS"'`$' | head -1)"
else
  ok "every save example ends in its marker"
fi
grep -qE 'exit 0[^`]*\(path run\)`' "$SAVE" \
  && ok "save example states the run outcome before (path run)" \
  || no "save example does not put the outcome before (path run)"
grep -Fq '(path run) exit 0`' "$RESTORE" \
  && ok "restore reads the older outcome-after-marker form" \
  || no "restore does not recognize (path run) followed by an outcome"
grep -qE 'exit 0[^`]*\(path run\)`' "$RESTORE" \
  && ok "restore reads the outcome-before-marker form" \
  || no "restore does not show the outcome-before-marker form"
has 'counts as the ending even when an outcome follows it' "$RESTORE" \
  && ok "restore states the marker is found despite a trailing outcome" \
  || no "restore only recognizes items ending exactly in the marker"

echo
echo "context provenance: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
