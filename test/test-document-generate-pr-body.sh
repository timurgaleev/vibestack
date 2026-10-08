#!/usr/bin/env bash
# /document-generate Step 9: the commit carries no assistant trailer unless the
# ship_attribution key turns it on, and the PR/MR body update reads through the
# trust envelope, secret-scans the outgoing text, and refuses to publish a body
# the envelope banner leaked into.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/document-generate/SKILL.md"
TMP="$(mktemp -d)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }
trap 'rm -rf "$TMP"' EXIT

# Step 9 only, so matches elsewhere in the skill cannot satisfy the checks.
STEP9="$TMP/step9.md"
awk '/^## Step 9:/{on=1} on && /^## / && !/^## Step 9:/ && !/^## Documentation Generated/{exit} on' "$SKILL" > "$STEP9"
[ -s "$STEP9" ] && ok "Step 9 located" || no "Step 9 not found"

# 1. No hard-coded co-author trailer anywhere in the skill.
if grep -Eq '^[[:space:]]*Co-Authored-By:' "$SKILL"; then
  no "hard-coded Co-Authored-By trailer present"
else
  ok "no hard-coded Co-Authored-By trailer"
fi

# 2. Attribution is gated on the shared ship_attribution key, default off.
grep -q 'vibe-config get ship_attribution' "$STEP9" && ok "reads ship_attribution" || no "ship_attribution not read"
grep -Eq '`off` or unset \(the default\)' "$STEP9" && ok "attribution defaults to off" || no "default-off wording missing"

# 3. The body is read through the trust envelope and snapshotted.
grep -q 'vibe-untrusted --source pr-body --file <body-file>' "$STEP9" && ok "envelope read" || no "envelope read missing"
grep -q 'cp <body-file> <body-orig>' "$STEP9" && ok "snapshot taken" || no "snapshot missing"
grep -q 'already contains a `## Documentation Generated` section' "$STEP9" && ok "idempotent section replace" || no "idempotent replace missing"

# 4. Outgoing body is secret-scanned before the write-back, and the scan
#    precedes the gh/glab write.
scan_line=$(grep -n 'Secret scan before external write' "$STEP9" | head -1 | cut -d: -f1)
edit_line=$(grep -n 'gh pr edit --body-file <body-file>' "$STEP9" | head -1 | cut -d: -f1)
if [ -n "$scan_line" ] && [ -n "$edit_line" ] && [ "$scan_line" -lt "$edit_line" ]; then
  ok "secret scan precedes write-back"
else
  no "secret scan missing or after write-back (scan=$scan_line edit=$edit_line)"
fi
grep -q 'include lib/snippets/secret-scan-patterns.md' "$STEP9" && ok "scan patterns included" || no "scan patterns not included"

# 5. The tripwire block, run as written, blocks a leaked banner and missing inputs.
TRIP="$TMP/trip.sh"
awk '/^\[ -f <body-file> \] && \[ -f <body-orig> \]/{on=1} on{print} on && /envelope banner leaked/{exit}' "$STEP9" > "$TRIP"
# Only ever execute the four expected lines: a broken extraction would otherwise
# run the rest of Step 9 as shell, including the gh/glab write-back.
trip_ok=0
if [ "$(wc -l < "$TRIP")" -eq 4 ] \
   && ! grep -Evq '^(\[ -f <body-file> \]|_BEFORE=|_AFTER=|\[ "\$_AFTER" -le "\$_BEFORE" \])' "$TRIP"; then
  trip_ok=1; ok "tripwire block extracted"
else
  no "tripwire block not found or not the expected shape; tripwire cases skipped"
fi

run_trip() { # run_trip <body-file> <body-orig>
  sed -e "s#<body-file>#$1#g" -e "s#<body-orig>#$2#g" "$TRIP" > "$TMP/trip-run.sh"
  bash "$TMP/trip-run.sh" >/dev/null 2>&1
}

if [ "$trip_ok" -eq 1 ]; then
printf 'Summary\n' > "$TMP/orig.md"
printf 'Summary\n\n## Documentation Generated\n\n| a | b |\n' > "$TMP/clean.md"
run_trip "$TMP/clean.md" "$TMP/orig.md" && ok "clean body passes tripwire" || no "clean body blocked"

printf 'hello\n' > "$TMP/raw.md"
bash "$ROOT/bin/vibe-untrusted" --source pr-body --file "$TMP/raw.md" > "$TMP/leaked.md"
if run_trip "$TMP/leaked.md" "$TMP/orig.md"; then no "leaked banner published"; else ok "leaked banner blocked"; fi

if run_trip "$TMP/clean.md" "$TMP/missing-orig.md"; then no "missing snapshot published"; else ok "missing snapshot blocked"; fi
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
