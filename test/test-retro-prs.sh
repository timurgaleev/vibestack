#!/usr/bin/env bash
# test-retro-prs.sh — /retro counts merged PRs/MRs from the platform Step 0
# detected.
#
# Step 1 command 16 is executed against stub `gh` and `glab` binaries: a GitLab
# repo must be read through `glab mr list --merged`, never through gh, and an
# unknown platform must say PRS_UNAVAILABLE rather than ask either CLI.
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

out="$(run_cmd github)"
if grep -q '^gh pr list --state merged --base main' "$TMP/stub.log" && ! grep -q '^glab ' "$TMP/stub.log"; then
  ok "GitHub lists merged PRs with gh, never glab"
else
  no "GitHub calls: $(tr '\n' ';' < "$TMP/stub.log")"
fi

out="$(run_cmd unknown)"
[ ! -s "$TMP/stub.log" ] && echo "$out" | grep -q '^PRS_UNAVAILABLE$' \
  && ok "unknown platform says PRS_UNAVAILABLE without asking a CLI" \
  || no "unknown platform: out='$out' calls='$(cat "$TMP/stub.log")'"

: > "$TMP/stub.log"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/glab"
out="$(run_cmd gitlab)"
echo "$out" | grep -q '^PRS_UNAVAILABLE$' \
  && ok "a failing glab is PRS_UNAVAILABLE, never zero MRs" || no "failing glab printed: $out"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
