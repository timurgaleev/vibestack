#!/usr/bin/env bash
# test-context-identity.sh — /context-save stamps each checkpoint with its
# project, and /context-restore never offers another project's checkpoint.
#
# Runs the shell blocks straight out of the two SKILL.md files against the real
# bin/vibe-slug, inside throwaway git repositories with fixture remotes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAVE="${CONTEXT_SAVE_SKILL:-$ROOT/skills/context-save/SKILL.md}"
RESTORE="${CONTEXT_RESTORE_SKILL:-$ROOT/skills/context-restore/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# First fenced bash block after the line starting with the given text.
block_after() {
  awk -v h="$1" '
    index($0, h) == 1 { seen=1; next }
    seen && /^```bash$/ { on=1; next }
    on && /^```$/ { exit }
    on { print }
  ' "$2"
}

block_after '### Step 1: Find saved contexts' "$RESTORE" > "$TMP/restore.sh"
block_after 'Then stamp the project identity' "$SAVE" > "$TMP/stamp.sh"
[ -s "$TMP/restore.sh" ] || { echo "restore Step 1 block not found" >&2; exit 1; }
[ -s "$TMP/stamp.sh" ] || { echo "save stamp block not found" >&2; exit 1; }

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.vibestack/bin"
cp "$ROOT/bin/vibe-slug" "$FAKE_HOME/.vibestack/bin/vibe-slug"

REPO="$TMP/work/api"
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" remote add origin git@github.com:alice/api.git
CK="$FAKE_HOME/.vibestack/projects/alice-api/checkpoints"
mkdir -p "$CK"

in_repo() { ( cd "$REPO" && HOME="$FAKE_HOME" VIBESTACK_HOME="$FAKE_HOME/.vibestack" CURRENT_BRANCH=main "$@" ); }
first_path() { grep -m1 '^/.*\.md$'; }

# --- save: the stamp block -------------------------------------------------

echo "save stamps the checkpoint"
OWN="$CK/20260101-090000-own.md"
printf -- '---\nstatus: in-progress\nbranch: main\n---\n\n## Working on: own\n' > "$OWN"
sed "s|{FILE}|$OWN|g" "$TMP/stamp.sh" > "$TMP/stamp-run.sh"
OUT=$(in_repo bash "$TMP/stamp-run.sh" 2>&1)
grep -qx 'remote: github.com/alice/api' "$OWN" \
  && ok "save writes remote: from the origin" || no "remote: missing after the stamp block: $OUT"
grep -q '^project_root: /' "$OWN" \
  && ok "save writes project_root:" || no "project_root: missing after the stamp block"
printf '%s\n' "$OUT" | grep -q '^remote: ' \
  && ok "the stamp block shows what it wrote" || no "stamp block printed nothing: $OUT"

# --- restore: identity filtering -----------------------------------------

echo "restore skips another project's checkpoint"
BOB="$CK/20260105-090000-bobs-work.md"
printf -- '---\nstatus: in-progress\nbranch: main\nremote: github.com/bob/api\nproject_root: /elsewhere/api\n---\n\n## Working on: bob\n' > "$BOB"
OLD="$CK/20260102-090000-legacy.md"
printf -- '---\nstatus: in-progress\nbranch: main\n---\n\n## Working on: legacy\n' > "$OLD"

OUT=$(in_repo bash "$TMP/restore.sh" 2>/dev/null)
printf '%s\n' "$OUT" | grep -q "^PROJECT MISMATCH: $BOB (remote: github.com/bob/api" \
  && ok "foreign checkpoint is reported as PROJECT MISMATCH" || no "no PROJECT MISMATCH line: $OUT"
printf '%s\n' "$OUT" | grep -qx "$BOB" \
  && no "foreign checkpoint is still a candidate" || ok "foreign checkpoint is not a candidate"
case "$(printf '%s\n' "$OUT" | first_path)" in
  "$OLD") ok "newest same-project save loads first, not the newer foreign one" ;;
  *) no "first candidate wrong: $(printf '%s\n' "$OUT" | first_path)" ;;
esac
printf '%s\n' "$OUT" | grep -qx "$OWN" \
  && ok "stamped own checkpoint stays a candidate" || no "own stamped checkpoint dropped"

rm -f "$OWN" "$OLD"
OUT=$(in_repo bash "$TMP/restore.sh" 2>/dev/null)
printf '%s\n' "$OUT" | grep -q '^NO_CHECKPOINTS' && printf '%s\n' "$OUT" | grep -q '^PROJECT MISMATCH' \
  && ok "only foreign saves: NO_CHECKPOINTS plus the mismatch" || no "only-foreign case wrong: $OUT"

echo "restore with a slug bin that cannot classify"
cat > "$FAKE_HOME/.vibestack/bin/vibe-slug" <<'EOF'
#!/usr/bin/env bash
echo "SLUG=alice-api"
EOF
chmod +x "$FAKE_HOME/.vibestack/bin/vibe-slug"
OUT=$(in_repo bash "$TMP/restore.sh" 2>/dev/null)
printf '%s\n' "$OUT" | grep -q '^IDENTITY_CHECK_UNAVAILABLE' \
  && ok "an old bin is announced, not mistaken for an empty bucket" || no "IDENTITY_CHECK_UNAVAILABLE missing: $OUT"
printf '%s\n' "$OUT" | grep -qx "$BOB" \
  && ok "without classification every save stays listed" || no "candidates lost without classification: $OUT"

# --- prose contract -------------------------------------------------------

echo "prose"
tr '\n' ' ' < "$RESTORE" | grep -qF 'line to the user **before any summary' \
  && ok "restore reports PROJECT MISMATCH before any summary" || no "restore ordering rule missing"
grep -q 'never hand-write `remote:` or `project_root:`' "$SAVE" \
  && ok "save forbids hand-written identity fields" || no "save hand-write rule missing"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
