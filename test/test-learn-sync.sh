#!/usr/bin/env bash
# Tests for bin/vibe-learnings-sync-plan — the deterministic half of /learn sync
# (selection, dedup, watermark, redaction). Self-contained temp VIBESTACK_HOME.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
export VIBESTACK_HOME="$TMP/home"
PROJ="$VIBESTACK_HOME/projects/testproj"
mkdir -p "$PROJ"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
no()   { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

PLAN() { "$BIN/vibe-learnings-sync-plan" --project-dir "$PROJ" "$@"; }

# 1. No learnings file -> nothing to sync, exit 0
out="$(PLAN)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "nothing to sync" \
  && ok "no file -> nothing to sync" || no "no file case got rc=$rc '$out'"

# 2. Fixture: dup (key,type) latest-wins, one secret-bearing entry skipped
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-01T10:00:00Z","skill":"review","type":"pattern","key":"retry-loop","insight":"old insight","confidence":6,"source":"observed"}
{"ts":"2026-07-02T10:00:00Z","skill":"ship","type":"pitfall","key":"token-leak","insight":"fixed by setting GITHUB_TOKEN=ghp_abcdef1234567890 in env","confidence":8,"source":"observed"}
not valid json
{"ts":"2026-07-03T10:00:00Z","skill":"review","type":"pattern","key":"retry-loop","insight":"newer insight wins","confidence":7,"source":"observed"}
EOF
out="$(PLAN)"
echo "$out" | grep -q "newer insight wins" && ok "latest-wins dedup keeps newest" || no "dedup: '$out'"
echo "$out" | grep -q "old insight" && no "stale duplicate leaked into plan" || ok "stale duplicate dropped"
echo "$out" | grep -q "ghp_" && no "secret leaked into plan output facts" || ok "secret entry not emitted as FACT"
echo "$out" | grep -q "1 new / 0 already synced / 1 skipped" && ok "plan summary counts" || no "summary: '$out'"
echo "$out" | grep -q $'^FACT\t' && ok "FACT line format" || no "no FACT line: '$out'"

# 3. Mark + re-plan -> already synced
PLAN --mark "retry-loop" "pattern" >/dev/null 2>&1
out="$(PLAN)"
echo "$out" | grep -q "0 new / 1 already synced / 1 skipped" && ok "watermark skips synced" || no "post-mark: '$out'"

# 4. Mark is idempotent (no duplicate watermark lines)
PLAN --mark "retry-loop" "pattern" >/dev/null 2>&1
n=$(grep -c . "$PROJ/memex-synced.txt")
[ "$n" -eq 1 ] && ok "mark idempotent" || no "watermark has $n lines"

# 5. Corrupt watermark line tolerated (treated unsynced, warns)
echo "garbage-no-tab" >> "$PROJ/memex-synced.txt"
out="$(PLAN)"; rc=$?
[ $rc -eq 0 ] && ok "corrupt watermark line survives" || no "corrupt watermark rc=$rc"

# 6. URL-embedded credential is skipped
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-04T10:00:00Z","skill":"investigate","type":"tool","key":"db-conn","insight":"use postgres://admin:hunter2@db.internal:5432/prod for the fix","confidence":9,"source":"observed"}
EOF
rm -f "$PROJ/memex-synced.txt"
out="$(PLAN)"
echo "$out" | grep -q "hunter2" && no "URL credential leaked" || ok "URL credential skipped"
echo "$out" | grep -q "0 new / 0 already synced / 1 skipped" && ok "URL-cred summary" || no "URL-cred summary: '$out'"

# 7. Env-style assignment mid-sentence is skipped (unanchored match)
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-05T10:00:00Z","skill":"ship","type":"pitfall","key":"env-fix","insight":"resolved after DATABASE_PASSWORD=supersecret123 was exported","confidence":8,"source":"observed"}
EOF
out="$(PLAN)"
echo "$out" | grep -q "supersecret123" && no "env-style secret leaked" || ok "env-style secret skipped"

# 8. Benign kebab words with sk-/key are NOT over-redacted; numeric ts tolerated
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-06T10:00:00Z","skill":"review","type":"pattern","key":"task-management","insight":"split desk-organizer risk-assessment into slices","confidence":7,"source":"observed"}
{"ts":1720000000,"skill":"review","type":"pattern","key":"ssh-key","insight":"rotate host identities quarterly","confidence":6,"source":"observed"}
EOF
rm -f "$PROJ/memex-synced.txt"
out="$(PLAN)"; rc=$?
[ $rc -eq 0 ] && ok "numeric ts survives" || no "numeric ts rc=$rc"
echo "$out" | grep -q "2 new / 0 already synced / 0 skipped" && ok "kebab sk-/key not over-redacted" || no "over-redaction: '$out'"

# 9. Secret smuggled in the type field is caught; shell metachars in key normalized
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-07T10:00:00Z","skill":"x","type":"AKIAABCDEFGHIJKLMNOP","key":"smuggle","insight":"benign text here","confidence":5,"source":"observed"}
{"ts":"2026-07-08T10:00:00Z","skill":"x","type":"pattern","key":"bad$(touch /tmp/pwn)key","insight":"metachar key normalized","confidence":5,"source":"observed"}
EOF
rm -f "$PROJ/memex-synced.txt"
out="$(PLAN)"
echo "$out" | grep -q "AKIA" && no "type-field secret leaked" || ok "type-field secret skipped"
echo "$out" | grep -q '\$(' && no "shell metachars survived in FACT key" || ok "metachar key normalized"
echo "$out" | grep -q "1 new / 0 already synced / 1 skipped" && ok "type-secret summary" || no "type-secret summary: '$out'"

# 10. Dash-leading key: --mark stays idempotent (grep -- guard)
PLAN --mark "-dashkey" "pattern" >/dev/null 2>&1
PLAN --mark "-dashkey" "pattern" >/dev/null 2>&1
n=$(grep -c . "$PROJ/memex-synced.txt")
[ "$n" -eq 1 ] && ok "dash-leading key mark idempotent" || no "dash key watermark has $n lines"

# 11. FACT line carries machine-readable confidence (5 tab-separated fields)
cat > "$PROJ/learnings.jsonl" <<'EOF'
{"ts":"2026-07-09T10:00:00Z","skill":"x","type":"pattern","key":"conf-check","insight":"plain","confidence":9,"source":"observed"}
EOF
rm -f "$PROJ/memex-synced.txt"
out="$(PLAN | grep '^FACT')"
nf=$(printf '%s' "$out" | awk -F'\t' '{print NF}')
[ "$nf" -eq 5 ] && ok "FACT has 5 fields" || no "FACT fields=$nf: '$out'"
printf '%s' "$out" | cut -f4 | grep -qx "9" && ok "confidence field machine-readable" || no "confidence field: '$out'"

echo
echo "== summary =="
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
