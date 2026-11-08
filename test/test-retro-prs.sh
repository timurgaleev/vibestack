#!/usr/bin/env bash
# test-retro-prs.sh — /retro counts merged PRs/MRs from the platform Step 0
# detected.
#
# Step 1 command 16 is executed against stub `gh` and `glab` binaries: a GitLab
# repo must be read through `glab mr list --merged`, never through gh, and an
# unknown platform must say PRS_UNAVAILABLE rather than ask either CLI. Both
# ends of the window bound the count, so a compare-mode prior window does not
# absorb the current window's merges.
#
# Usage: test-retro-prs.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SK="$TMP/retro.md"
"$ROOT/bin/vibe-render-skill" "$ROOT/skills/retro/SKILL.md" "$SK" >/dev/null 2>&1 \
  || { echo "cannot render skills/retro/SKILL.md" >&2; exit 1; }

# Command 16 runs from its "# 16." comment up to the "# 17." one.
CMD="$TMP/cmd16.sh"
awk '/^# 16\./{on=1} /^# 17\./{on=0} on' "$SK" > "$CMD"
[ -s "$CMD" ] || { echo "command 16 not found in retro" >&2; exit 1; }

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
echo '[{"number":7,"title":"gh pr","mergedAt":"2026-03-12T10:00:00Z"}]'
EOF
cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >> "$STUB_LOG"
cat <<'JSON'
[{"iid":3,"title":"before the window","merged_at":"2026-03-03T23:00:00Z"},
 {"iid":4,"title":"first day","merged_at":"2026-03-04T09:00:00Z"},
 {"iid":5,"title":"last day","merged_at":"2026-03-10T22:00:00Z"},
 {"iid":6,"title":"after the window","merged_at":"2026-03-11T01:00:00Z"}]
JSON
EOF
chmod +x "$STUBS/gh" "$STUBS/glab"

# run_cmd PLATFORM — command 16 with its placeholders filled for a window of
# 2026-03-04..2026-03-10 on branch main.
run_cmd() {
  : > "$TMP/stub.log"
  sed -e "s|<PLATFORM>|$1|g" -e 's|<default>|main|g' \
      -e 's|<start-date>|2026-03-04|g' -e 's|<end-date>|2026-03-10|g' "$CMD" > "$TMP/run.sh"
  STUB_LOG="$TMP/stub.log" PATH="$STUBS:/usr/bin:/bin" bash "$TMP/run.sh" 2>&1
}

echo "retro: merged PRs/MRs follow the platform"
out="$(run_cmd gitlab)"
if grep -q '^glab mr list .*--merged' "$TMP/stub.log" && ! grep -q '^gh ' "$TMP/stub.log"; then
  ok "GitLab lists merged MRs with glab, never gh"
else
  no "GitLab calls: $(tr '\n' ';' < "$TMP/stub.log")"
fi
grep -q -- '--target-branch main' "$TMP/stub.log" \
  && ok "GitLab MRs are limited to the default branch" || no "glab call lacks --target-branch main: $(cat "$TMP/stub.log")"
echo "$out" | grep -q '!4 ' && ok "GitLab keeps an MR merged inside the window" || no "GitLab output lost !4: $out"
echo "$out" | grep -q '!3 ' && no "GitLab kept an MR merged before the window: $out" || ok "GitLab drops an MR merged before the window"
echo "$out" | grep -q '!5 ' && ok "GitLab keeps an MR merged on the window's last day" || no "GitLab output lost !5: $out"
echo "$out" | grep -q '!6 ' && no "GitLab kept an MR merged after the window ends: $out" || ok "GitLab drops an MR merged after the window ends"

out="$(run_cmd github)"
if grep -q '^gh pr list --state merged --base main' "$TMP/stub.log" && ! grep -q '^glab ' "$TMP/stub.log"; then
  ok "GitHub lists merged PRs with gh, never glab"
else
  no "GitHub calls: $(tr '\n' ';' < "$TMP/stub.log")"
fi
grep -q -- '--search merged:2026-03-04..2026-03-10 ' "$TMP/stub.log" \
  && ok "GitHub search is bounded at both ends of the window" || no "gh search is not merged:<start>..<end>: $(cat "$TMP/stub.log")"

# Compare mode reruns command 16 for the prior window; its end date must be the
# day before the current window starts, or the prior count includes this week.
COMPARE="$(awk '/^## Compare Mode/{on=1;next} /^## /{on=0} on' "$SK" | tr '\n' ' ')"
printf '%s' "$COMPARE" | grep -q 'command 16' && printf '%s' "$COMPARE" | grep -q '<end-date>' \
  && ok "compare mode bounds the prior window's merged PRs with <end-date>" \
  || no "compare mode never bounds command 16 at the prior window's end"

out="$(run_cmd unknown)"
[ ! -s "$TMP/stub.log" ] && echo "$out" | grep -q '^PRS_UNAVAILABLE$' \
  && ok "unknown platform says PRS_UNAVAILABLE without asking a CLI" \
  || no "unknown platform: out='$out' calls='$(cat "$TMP/stub.log")'"

# More merged MRs than one page holds: page 1 is a full 100, page 2 has the
# rest. Stopping at page 1 would undercount the window.
cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >> "$STUB_LOG"
page=1
while [ $# -gt 0 ]; do case "$1" in --page) page="$2"; shift ;; esac; shift; done
python3 -I -c 'import json, sys
page = int(sys.argv[1])
if page == 1:
    mrs = [{"iid": 100 + i, "title": "p1", "merged_at": "2026-03-05T10:00:00Z"} for i in range(100)]
elif page == 2:
    mrs = [{"iid": 204, "title": "p2 in", "merged_at": "2026-03-06T10:00:00Z"},
           {"iid": 205, "title": "p2 out", "merged_at": "2026-02-01T10:00:00Z"}]
else:
    mrs = []
print(json.dumps(mrs))' "$page"
EOF
out="$(run_cmd gitlab)"
n="$(echo "$out" | grep -c '^!')"
[ "$n" = 101 ] && echo "$out" | grep -q '^!204 ' \
  && ok "GitLab reads every page of merged MRs (101 in the window across 2 pages)" \
  || no "GitLab paging: $n MRs, calls: $(tr '\n' ';' < "$TMP/stub.log")"
grep -q -- '--page 2' "$TMP/stub.log" && ! grep -q -- '--page 3' "$TMP/stub.log" \
  && ok "GitLab stops at the first short page" || no "GitLab page calls: $(tr '\n' ';' < "$TMP/stub.log")"

# A page that fails part-way is unavailable, not a partial count.
cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --page 2 "*) exit 1 ;; esac
python3 -I -c 'import json; print(json.dumps([{"iid": 300 + i, "title": "t", "merged_at": "2026-03-05T10:00:00Z"} for i in range(100)]))'
EOF
out="$(run_cmd gitlab)"
echo "$out" | grep -q '^PRS_UNAVAILABLE$' && ! echo "$out" | grep -q '^!' \
  && ok "a glab failure on a later page is PRS_UNAVAILABLE with no partial list" \
  || no "later-page failure printed: $(echo "$out" | head -3)"

: > "$TMP/stub.log"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/glab"
out="$(run_cmd gitlab)"
echo "$out" | grep -q '^PRS_UNAVAILABLE$' \
  && ok "a failing glab is PRS_UNAVAILABLE, never zero MRs" || no "failing glab printed: $out"

# --- history store, follow-through, questions by skill ----------------------

block_after() { # first ```bash block after the line starting with $(1)
  awk -v h="$1" 'index($0, h) == 1 { seen=1; next }
    seen && /^```bash$/ { on=1; next } on && /^```$/ { exit } on { print }' "$SK"
}
VSH="$TMP/vs"; mkdir -p "$VSH/bin"
printf '#!/usr/bin/env bash\necho SLUG=retroproj\n' > "$VSH/bin/vibe-slug"; chmod +x "$VSH/bin/vibe-slug"
STORE="$VSH/projects/retroproj/retros"
WORK="$TMP/work"; mkdir -p "$WORK/.context/retros" "$STORE"
echo '{"date":"2026-03-01","old":true}' > "$WORK/.context/retros/2026-03-01-1.json"
echo '{"date":"2026-03-08","from":"checkout"}' > "$WORK/.context/retros/2026-03-08-2.json"
echo '{"date":"2026-03-08","from":"store"}' > "$STORE/2026-03-08-2.json"
echo '{"date":"2026-03-08"}' > "$STORE/2026-03-08-10.json"
echo '{"date":"2026-03-08"}' > "$STORE/2026-03-08-9.json"

echo "retro: shared history store"
block_after '#### Retro history store' > "$TMP/hist.sh"
if [ -s "$TMP/hist.sh" ]; then
  out="$(cd "$WORK" && HOME="$TMP" VIBESTACK_HOME="$VSH" bash "$TMP/hist.sh" 2>&1)"
  [ -f "$STORE/2026-03-01-1.json" ] && ok "history from .context/retros is copied into the store" \
    || no "old checkout history not migrated: $out"
  grep -q '"from":"store"' "$STORE/2026-03-08-2.json" && ok "migration never overwrites a stored snapshot" \
    || no "migration overwrote 2026-03-08-2.json"
  [ -f "$WORK/.context/retros/2026-03-01-1.json" ] && ok "migration leaves the old files in place" || no "migration moved the old file"
  first="$(printf '%s\n' "$out" | sed -n 's/^PRIOR_RETRO: //p' | head -1)"
  case "$first" in */2026-03-08-10.json) ok "newest prior is picked by YYYY-MM-DD-N, N numeric" ;;
    *) no "newest prior wrong: '$first' ($out)" ;; esac
else
  no "retro has no '#### Retro history store' block"
fi

block_after '### Step 13' | sed "s|<TODAY>|2026-03-08|" > "$TMP/save.sh"
out="$(cd "$WORK" && HOME="$TMP" VIBESTACK_HOME="$VSH" bash "$TMP/save.sh" 2>&1)"
echo "$out" | grep -qx "SAVE_AS: $STORE/2026-03-08-1.json" \
  && ok "the snapshot is saved into the shared store" || no "SAVE_AS not in the store: $out"

echo "retro: questions by skill"
block_after '#### Questions by skill' | sed "s|<START_DATE>|2026-03-04|" > "$TMP/q.sh"
if [ -s "$TMP/q.sh" ]; then
  cat > "$VSH/projects/retroproj/question-log.jsonl" <<'EOF'
{"skill":"ship","ts":"2026-03-05T10:00:00Z","followed_recommendation":false}
{"skill":"ship","ts":"2026-03-06T10:00:00Z","followed_recommendation":true}
{"skill":"review","ts":"2026-03-07T10:00:00Z"}
{"skill":"ship","ts":"2026-03-01T10:00:00Z"}
{"skill":"Evil Skill; rm -rf","ts":"2026-03-07T10:00:00Z"}
not json
EOF
  out="$(cd "$WORK" && HOME="$TMP" VIBESTACK_HOME="$VSH" bash "$TMP/q.sh" 2>&1)"
  echo "$out" | grep -qx 'QUESTIONS: ship 2 overridden=1' && echo "$out" | grep -qx 'QUESTIONS: review 1 overridden=0' \
    && ok "questions are counted per skill inside the window" || no "question counts wrong: $out"
  echo "$out" | grep -q 'Evil' && no "a skill name outside the allowlist reached the output" || ok "skill names are allowlisted"
else
  no "retro has no '#### Questions by skill' block"
fi

echo "retro: recommendations"
grep -q '"recommendations": \[' "$SK" && ok "snapshot schema carries recommendations" || no "schema lacks recommendations"
tr '\n' ' ' < "$SK" | grep -qE 'always present.{0,80}\[\]' && ok "recommendations is always present, [] when none" \
  || no "recommendations may be omitted"
grep -q 'Recommendation follow-through' "$SK" && grep -q 'addressed' "$SK" && grep -q 'partial' "$SK" \
  && ok "Step 12 scores the last retro's recommendations" || no "no recommendation follow-through"
grep -q '^echo "BASE_BRANCH: ' "$SK" && ok "Step 0 uses the shared base-branch detection" || no "base-branch-detect not included"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
