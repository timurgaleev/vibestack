#!/usr/bin/env bash
# The host rewrites $N in an invoked skill's text before the model reads it:
# /\$(\d+)(?!\w)/g, arguments counted from 0, an out-of-range index left as
# typed. A bare $1 in an awk program or a shell function therefore reaches the
# model as the user's argument, or as nothing on a host that empties unmatched
# indexes. Render every skill, apply both behaviours, and require the text to
# come through unchanged; then run the land-and-deploy CI gate as delivered.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$ROOT/bin/vibe-render-skill"
TMP="$(mktemp -d)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# host_subst <args|empty>: args = ten placeholder arguments ARG0..ARG9 with any
# higher index left literal; empty = every index replaced by nothing.
host_subst() {
  case "$1" in
    args)  perl -pe 's/\$(\d+)(?!\w)/$1 < 10 ? "ARG$1" : "\$$1"/ge' ;;
    empty) perl -pe 's/\$(\d+)(?!\w)//g' ;;
  esac
}

mkdir -p "$TMP/r" "$TMP/s"
rendered=0
for src in "$ROOT"/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$src")")
  if bash "$RENDER" "$src" "$TMP/r/$name.md" >/dev/null 2>&1; then
    rendered=$((rendered + 1))
  else
    no "$name: render failed"
  fi
done
[ "$rendered" -gt 0 ] && ok "rendered $rendered skills" || no "no skill rendered"

for mode in args empty; do
  bad=0
  for r in "$TMP"/r/*.md; do
    name=$(basename "$r" .md)
    host_subst "$mode" < "$r" > "$TMP/s/$name.$mode.md"
    if ! cmp -s "$r" "$TMP/s/$name.$mode.md"; then
      bad=$((bad + 1))
      first=$(diff "$r" "$TMP/s/$name.$mode.md" | grep -m1 '^<' | cut -c3-140)
      no "$name ($mode): $(diff "$r" "$TMP/s/$name.$mode.md" | grep -c '^<') line(s) rewritten, first: $first"
    fi
  done
  [ "$bad" -eq 0 ] && ok "every rendered skill survives the $mode substitution unchanged"
done

# The sites a substitution used to break, named so a regression points at them.
S="$TMP/s"
[ "$(grep -c '_cl_s=${1}; shift' "$S/claude.args.md")" -eq 4 ] \
  && ok "claude: all four watchdogs keep \${1}" || no "claude: watchdog session arg rewritten"
[ "$(grep -c '_cx_s=${1}; shift' "$S/codex.args.md")" -eq 4 ] \
  && ok "codex: all four watchdogs keep \${1}" || no "codex: watchdog session arg rewritten"
grep -qF 'jq -r ".data.repository.pullRequest | ${1}"' "$S/land-and-deploy.args.md" \
  && ok "land-and-deploy: _pr() jq filter keeps \${1}" || no "land-and-deploy: _pr() jq filter rewritten"
grep -qF "STATE=\$(printf '%s' \"\$PR_STATE\" | awk '{print \$(1)}')" "$S/ship.empty.md" \
  && ok "release-after-merge: STATE field survives inside ship" || no "release-after-merge: STATE field rewritten in ship"

# Run the CI gate's row builder as the model receives it. A completed failing
# check must come out FAIL, never NO_CHECKS or PENDING.
for mode in args empty; do
  awk -v dir="$TMP" -v m="$mode" '
    /^  _rows=\$\( \{/ { on = 1; n++; f = dir "/gate." m "." n ".sh" }
    on { print > f }
    on && /^  fi$/ { on = 0; close(f) }' "$S/land-and-deploy.$mode.md"
  blocks=$(ls "$TMP"/gate."$mode".*.sh 2>/dev/null | wc -l | tr -d ' ')
  [ "$blocks" -ge 2 ] || no "land-and-deploy ($mode): CI gate block not found ($blocks)"
  for g in "$TMP"/gate."$mode".*.sh; do
    [ -f "$g" ] || continue
    for fx in 'completed	failure	build:FAIL' 'completed	success	build:PASS'; do
      row=${fx%:*}; want=${fx##*:}
      got=$(bash -c '_runs=$1; _stats=""; _suites=""; . "$2" 2>/dev/null; echo "${_v:-unset}"' _ "$row" "$g")
      [ "$got" = "$want" ] \
        && ok "land-and-deploy ($mode) $(basename "$g" .sh): '${row//	/ }' -> $want" \
        || no "land-and-deploy ($mode) $(basename "$g" .sh): '${row//	/ }' gave $got, want $want"
    done
  done
done

echo
echo "== summary =="
echo "  passed: $pass"
echo "  failed: $fail"
[ "$fail" -eq 0 ]
