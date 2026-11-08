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
in_repo() { ( cd "$REPO" && HOME="$FAKE_HOME" VIBESTACK_HOME="$FAKE_HOME/.vibestack" CURRENT_BRANCH=main "$@" ); }
SLUG_NOW=$(in_repo "$FAKE_HOME/.vibestack/bin/vibe-slug" --identity | sed -n 's/^SLUG=//p')
CK="$FAKE_HOME/.vibestack/projects/$SLUG_NOW/checkpoints"
mkdir -p "$CK"
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
printf '#!/usr/bin/env bash\necho "SLUG=%s"\n' "$SLUG_NOW" > "$FAKE_HOME/.vibestack/bin/vibe-slug"
chmod +x "$FAKE_HOME/.vibestack/bin/vibe-slug"
OUT=$(in_repo bash "$TMP/restore.sh" 2>/dev/null)
printf '%s\n' "$OUT" | grep -q '^IDENTITY_CHECK_UNAVAILABLE' \
  && ok "an old bin is announced, not mistaken for an empty bucket" || no "IDENTITY_CHECK_UNAVAILABLE missing: $OUT"
printf '%s\n' "$OUT" | grep -qx "$BOB" \
  && ok "without classification every save stays listed" || no "candidates lost without classification: $OUT"

# --- restore after a migration from the old name-only bucket ----------------

echo "restore after migrating the old bucket"
cp "$ROOT/bin/vibe-slug" "$FAKE_HOME/.vibestack/bin/vibe-slug"
REPO="$TMP/work2/web"
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" remote add origin git@github.com:carol/web.git
OLDCK="$FAKE_HOME/.vibestack/projects/web/checkpoints"
mkdir -p "$OLDCK"
printf -- '---\nstatus: in-progress\nbranch: main\nremote: github.com/carol/web\nproject_root: /elsewhere/web\n---\n\n## Working on: carol\n' > "$OLDCK/20260103-090000-carol.md"
printf -- '---\nstatus: in-progress\nbranch: main\n---\n\n## Working on: whose\n' > "$OLDCK/20260104-090000-whose.md"
OUT=$(in_repo bash "$TMP/restore.sh" 2>/dev/null)
printf '%s\n' "$OUT" | grep -q '20260103-090000-carol.md$' \
  && ok "the stamped checkpoint comes across and is offered" || no "stamped checkpoint missing after migration: $OUT"
printf '%s\n' "$OUT" | grep -q '20260104-090000-whose.md' \
  && no "an unstamped checkpoint from the shared old bucket is offered as this project's" || ok "an unstamped checkpoint from the old bucket is not offered"

# --- save: the stamp records HEAD (and the worktree of a linked one) ----------

echo "stamp records head and worktree"
HREPO="$TMP/work3/svc"
mkdir -p "$HREPO" && git -C "$HREPO" init -q -b main \
  && git -C "$HREPO" remote add origin git@github.com:dave/svc.git
gcommit() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }
gcommit "$HREPO" one
in_h() { ( cd "$1" && HOME="$FAKE_HOME" VIBESTACK_HOME="$FAKE_HOME/.vibestack" bash "$2" ); }
HCK="$TMP/h.md"
printf -- '---\nstatus: in-progress\nbranch: main\nhead: stale\n---\n\n## Working on: h\n' > "$HCK"
sed "s|{FILE}|$HCK|g" "$TMP/stamp.sh" > "$TMP/stamp-h.sh"
in_h "$HREPO" "$TMP/stamp-h.sh" >/dev/null 2>&1
HEAD1=$(git -C "$HREPO" rev-parse HEAD)
[ "$(grep -c '^head:' "$HCK")" = 1 ] && grep -qx "head: $HEAD1" "$HCK" \
  && ok "stamp writes head: once, replacing a stale one" || no "head: wrong after stamp: $(grep '^head:' "$HCK")"
grep -q '^worktree:' "$HCK" \
  && no "main checkout stamped worktree:" || ok "main checkout carries no worktree:"
git -C "$HREPO" worktree add -q "$TMP/work3/svc-wt" -b side 2>/dev/null
printf -- '---\nstatus: in-progress\nbranch: side\n---\n\n## Working on: w\n' > "$HCK"
in_h "$TMP/work3/svc-wt" "$TMP/stamp-h.sh" >/dev/null 2>&1
WT_REAL=$(cd "$TMP/work3/svc-wt" && git rev-parse --show-toplevel)
grep -qx "worktree: $WT_REAL" "$HCK" \
  && ok "linked worktree stamps worktree:" || no "worktree: missing in a linked worktree: $(cat "$HCK")"

# --- restore: the head check ---------------------------------------------

block_after '#### Head check' "$RESTORE" > "$TMP/headcheck.sh"
if [ ! -s "$TMP/headcheck.sh" ]; then
  no "restore has no '#### Head check' block"
else
  hc() { # hc <checkpoint-file>
    sed "s|<CHECKPOINT_FILE>|$1|g" "$TMP/headcheck.sh" > "$TMP/hc-run.sh"
    ( cd "$HREPO" && bash "$TMP/hc-run.sh" 2>/dev/null )
  }
  ck_head() { printf -- '---\nstatus: in-progress\nbranch: main\nhead: %s\n---\n' "$1" > "$TMP/c.md"; }
  echo "restore head check"
  ck_head "$HEAD1"
  hc "$TMP/c.md" | grep -qx 'HEAD_UNCHANGED' && ok "same commit: HEAD_UNCHANGED" || no "HEAD_UNCHANGED missing: $(hc "$TMP/c.md")"
  gcommit "$HREPO" two; gcommit "$HREPO" three
  OUT=$(hc "$TMP/c.md")
  printf '%s\n' "$OUT" | grep -qx 'HEAD_MOVED 2' && printf '%s\n' "$OUT" | grep -q ' three$' \
    && ok "fast-forward: HEAD_MOVED 2 with the new commits listed" || no "HEAD_MOVED wrong: $OUT"
  git -C "$HREPO" checkout -q -b other "$HEAD1" && gcommit "$HREPO" fork
  ck_head "$(git -C "$HREPO" rev-parse main)"
  OUT=$(hc "$TMP/c.md")
  printf '%s\n' "$OUT" | grep -qx 'HEAD_DIVERGED' && printf '%s\n' "$OUT" | grep -q ' fork$' \
    && ok "saved commit not an ancestor: HEAD_DIVERGED with commits listed" || no "HEAD_DIVERGED wrong: $OUT"
  ck_head "0123456789abcdef0123456789abcdef01234567"
  hc "$TMP/c.md" | grep -qx 'HEAD_UNKNOWN' && ok "commit absent from this clone: HEAD_UNKNOWN" || no "HEAD_UNKNOWN missing"
  ck_head "--output=/tmp/x"
  hc "$TMP/c.md" | grep -qx 'HEAD_UNKNOWN' && ok "a non-hex head is never handed to git" || no "malformed head not rejected"
  printf -- '---\nstatus: in-progress\nbranch: main\n---\n' > "$TMP/c.md"
  hc "$TMP/c.md" | grep -qx 'HEAD_UNTRACKED' && ok "no head: field: HEAD_UNTRACKED" || no "HEAD_UNTRACKED missing"
fi

# --- prose contract -------------------------------------------------------

echo "prose"
tr '\n' ' ' < "$RESTORE" | grep -qE 'HEAD_MOVED.{0,120}HEAD_DIVERGED.{0,160}HEAD_UNKNOWN.{0,200}every Remaining Work item under \*\*Verify first' \
  && ok "moved/diverged/unknown put every item under Verify first" || no "head states do not force Verify first"
tr '\n' ' ' < "$RESTORE" | grep -qiE 'translated.{0,120}\(path assumed\)' \
  && ok "restore reads an unknown or translated marker as (path assumed)" || no "restore lacks the unknown-marker rule"
tr '\n' ' ' < "$RESTORE" | grep -qE 'titles differ.{0,160}AskUserQuestion' \
  && ok "no usable branch and differing titles asks the user" || no "restore lacks the no-branch ask"
tr '\n' ' ' < "$RESTORE" | grep -qF 'line to the user **before any summary' \
  && ok "restore reports PROJECT MISMATCH before any summary" || no "restore ordering rule missing"
grep -q 'never hand-write `remote:` or `project_root:`' "$SAVE" \
  && ok "save forbids hand-written identity fields" || no "save hand-write rule missing"

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
