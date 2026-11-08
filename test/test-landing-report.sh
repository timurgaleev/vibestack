#!/usr/bin/env bash
# test-landing-report.sh — /landing-report says when the version queue may be
# incomplete instead of presenting a partial read as the whole queue.
#
# Runs Step 3's block against a stubbed vibe-next-version:
#   - a run that read every open PR (complete:true) is stored as is;
#   - a failed run stores an offline record that is not complete;
# and checks Step 4/5 render `.complete == false` as "queue may be incomplete".
#
# Usage: test/test-landing-report.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
SK="$SRC/skills/landing-report/SKILL.md"
[ -f "$SK" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

BLOCK="$TMP/step3.sh"
awk '/for LEVEL in patch minor major/{f=1} {b=b $0 "\n"} /^```bash$/{b=""} /^```$/{if(f){printf "%s", b; exit}}' "$SK" \
  | sed '$d' | sed "s/'<BASE_BRANCH>'/main/; s/'<BASE_VERSION>'/1.2.3/" > "$BLOCK"
grep -q 'vibe-next-version' "$BLOCK" && ok "Step 3 block extracted" || no "Step 3 block not found"

VH="$TMP/vh"; mkdir -p "$VH/bin"
run3() { # run3 STUB_BODY -> patch.json path
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$VH/bin/vibe-next-version"; chmod +x "$VH/bin/vibe-next-version"
  local dir; dir=$( cd "$TMP" && TMPDIR="$TMP" VIBESTACK_HOME="$VH" bash "$BLOCK" 2>/dev/null | sed -n 's/^LANDING_DIR: //p')
  printf '%s/patch.json' "$dir"
}
if command -v jq >/dev/null 2>&1; then
  f=$(run3 "echo '{\"version\":\"1.2.4\",\"claimed\":[],\"warnings\":[],\"offline\":false,\"complete\":true}'")
  [ "$(jq -r '.complete' "$f" 2>/dev/null)" = true ] && ok "a complete read is stored as complete" || no "complete read: $(cat "$f" 2>/dev/null)"
  f=$(run3 "exit 1")
  [ "$(jq -r '.complete' "$f" 2>/dev/null)" = false ] && ok "a failed run is recorded as not complete" || no "failed run record: $(cat "$f" 2>/dev/null)"
else
  no "jq is required"
fi

grep -q '`.complete`' "$SK" && ok "Step 4 lists the .complete field" || no "Step 4 ignores .complete"
grep -qi 'queue may be incomplete' "$SK" && awk '/^## Step 4/{on=1} on' "$SK" | grep -q 'complete` is `false`' \
  && ok "complete:false renders as a possibly incomplete queue" || no "complete:false is not rendered"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
