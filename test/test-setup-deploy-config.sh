#!/usr/bin/env bash
# test-setup-deploy-config.sh — /setup-deploy writes a Deploy Configuration the
# user confirmed, and /canary alerts only on confirmed findings at a bounded cadence.
#
# Covers, for /setup-deploy:
#   - the CLAUDE.md template hard-codes no branch: the deploy trigger names the
#     repo's resolved default branch;
#   - the Step 4 repo-settings block is pulled out of the rendered SKILL.md and
#     run against a stub `gh` (canned JSON, filtered with jq like gh's --jq) and a
#     fixture repo: it prints the default branch and only the merge methods the
#     repo allows, and falls back to origin/HEAD with the methods `unknown` when
#     gh cannot answer;
#   - several detected platforms are asked about, the project type is confirmed,
#     Heroku and Railway go through Custom / Manual with the platform prefilled,
#     "not deployed yet" stops without writing and "never deploys" records `none`;
#   - the full block is shown and confirmed before anything is written, and the
#     merge-method readback after the write stays;
#   - per-platform details: the GitHub Actions status command reads one workflow's
#     runs, Vercel counts as auto-deploy only when Git-connected, the Netlify URL
#     is asked for, Fly's /health is used only on a 2xx probe.
# Covers, for /canary:
#   - a CRITICAL/HIGH finding notifies only once confirmed on two consecutive
#     checks; a first occurrence is pending;
#   - the monitoring cadence: start and deadline recorded, a bounded background
#     wait of max(0, 60 - round) seconds, rounds never overlap, the actual cadence
#     is reported, the run stops at the deadline after the current round;
#   - the no-baseline reference is called a monitoring-start reference, and the
#     report says errors already present then cannot be detected without --baseline;
#   - Step 0 carries the shared base-branch-detect fallback.
#
# Usage: test/test-setup-deploy-config.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

render() {
  if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/$1/SKILL.md" "$TMP/$1.md" >/dev/null 2>&1; then
    ok "$1 renders"
  else
    no "$1 renders"; echo "$pass passed, $fail failed"; exit 1
  fi
}
render setup-deploy
render canary

SKILL=""
has()   { if grep -qF -- "$2" "$SKILL"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$SKILL"; then no "$1 (still present: $2)"; else ok "$1"; fi; }
line_of() { awk -v n="$1" 'index($0, n) { print NR; exit }' "$SKILL"; }
before() {
  local a b
  a="$(line_of "$2")"; b="$(line_of "$3")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else no "$1 ('$2' line ${a:-none} not before '$3' line ${b:-none})"; fi
}
# block_with <marker> — the first fenced bash block whose body contains marker.
block_with() {
  awk -v m="$1" '
    /^```bash[[:space:]]*$/ { inb = 1; buf = ""; next }
    inb && /^```[[:space:]]*$/ { inb = 0; if (index(buf, m)) { printf "%s", buf; exit } next }
    inb { buf = buf $(0) "\n" }' "$SKILL"
}

SKILL="$TMP/setup-deploy.md"
echo "setup-deploy: template"
awk 'index($0, "## Deploy Configuration (configured by /setup-deploy)") { f = 1 } f && /^```/ { exit } f' "$SKILL" > "$TMP/template"
if [ -s "$TMP/template" ]; then ok "template block found"; else no "template block found"; fi
if grep -qwi 'main' "$TMP/template"; then
  no "template hard-codes no branch (found: $(grep -wi 'main' "$TMP/template" | head -1))"
else
  ok "template hard-codes no branch"
fi
if grep -qF '{default branch}' "$TMP/template"; then ok "deploy trigger names the resolved default branch"; else no "deploy trigger names the resolved default branch"; fi
hasnt "no push-to-main assumption in the steps" 'push to main'
hasnt "no merge-to-main assumption in the steps" 'merge to main'

echo "setup-deploy: repo settings block"
block_with 'MERGE_METHODS_ALLOWED' > "$TMP/settings.sh"
if [ -s "$TMP/settings.sh" ]; then ok "repo-settings block found"; else no "repo-settings block found"; fi

mkdir -p "$TMP/shim"
cat > "$TMP/shim/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -n "${GH_FAIL:-}" ] && { echo "gh: not authenticated" >&2; exit 1; }
q=""
while [ $# -gt 0 ]; do case "$1" in -q|--jq) q="$2"; shift 2 ;; *) shift ;; esac; done
if [ -n "$q" ]; then printf '%s' "$GH_JSON" | jq -r "$q"; else printf '%s' "$GH_JSON"; fi
SHIM
chmod +x "$TMP/shim/gh"

# run_settings <dir> <json|FAIL> — runs the block there under $SH (the blocks
# execute in the user's shell); sets OUT.
SH=bash
run_settings() {
  : > "$TMP/gh.log"
  if [ "$2" = FAIL ]; then
    OUT="$(cd "$1" && GH_LOG="$TMP/gh.log" GH_FAIL=1 PATH="$TMP/shim:$PATH" "$SH" "$TMP/settings.sh" 2>&1)"
  else
    OUT="$(cd "$1" && GH_LOG="$TMP/gh.log" GH_JSON="$2" PATH="$TMP/shim:$PATH" "$SH" "$TMP/settings.sh" 2>&1)"
  fi
}
expect() { if printf '%s\n' "$OUT" | grep -qxF -- "$2"; then ok "$1"; else no "$1 (want '$2', got: $(printf '%s' "$OUT" | tr '\n' '|'))"; fi; }

mkdir -p "$TMP/plain"
run_settings "$TMP/plain" '{"defaultBranchRef":{"name":"trunk"},"squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":false}'
expect "default branch comes from the repo" "DEFAULT_BRANCH: trunk"
expect "only the allowed method is offered" "MERGE_METHODS_ALLOWED: squash"
if grep -q 'squashMergeAllowed' "$TMP/gh.log" && grep -q 'mergeCommitAllowed' "$TMP/gh.log" && grep -q 'rebaseMergeAllowed' "$TMP/gh.log"; then
  ok "gh is asked for all three merge settings"
else
  no "gh is asked for all three merge settings ($(tr '\n' '|' < "$TMP/gh.log"))"
fi

run_settings "$TMP/plain" '{"defaultBranchRef":{"name":"main"},"squashMergeAllowed":false,"mergeCommitAllowed":true,"rebaseMergeAllowed":true}'
expect "two allowed methods, squash left out" "MERGE_METHODS_ALLOWED: merge rebase"

git init -q --bare -b develop "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" commit -q --allow-empty -m init
git -C "$TMP/seed" push -q origin develop
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
run_settings "$TMP/work" FAIL
expect "gh down: default branch from origin/HEAD" "DEFAULT_BRANCH: develop"
expect "gh down: merge methods unknown, never guessed" "MERGE_METHODS_ALLOWED: unknown"

run_settings "$TMP/plain" FAIL
expect "no gh and no remote: default branch unknown" "DEFAULT_BRANCH: unknown"

if command -v zsh >/dev/null 2>&1; then
  SH=zsh
  run_settings "$TMP/plain" '{"defaultBranchRef":{"name":"trunk"},"squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":true}'
  expect "zsh: allowed methods" "MERGE_METHODS_ALLOWED: squash rebase"
  run_settings "$TMP/work" FAIL
  expect "zsh: default branch from origin/HEAD" "DEFAULT_BRANCH: develop"
  SH=bash
fi

echo "setup-deploy: detection and choices"
has    "several platforms: ask which serves production" 'more than one `PLATFORM:` line'
has    "project type is confirmed"                       'Confirm the project type'
has    "Heroku / Railway section"                        '#### Heroku / Railway'
has    "Heroku / Railway prefill the platform"           'with the platform prefilled'
has    "not deployed yet: stop, write nothing"           'Not deployed yet'
has    "never deploys: record none"                      '- Platform: none'
hasnt  "old catch-all no-deploy option gone"             "E) This project doesn't deploy (library, CLI, tool)"

echo "setup-deploy: write step"
has    "unconfirmed fields are collected"                'every field not yet confirmed'
has    "only allowed merge methods are offered"          'Offer only the methods on the `MERGE_METHODS_ALLOWED:` line'
has    "full block shown and confirmed"                  'Show the complete block exactly as it will be written'
before "confirmation comes before the write"            'Show the complete block exactly as it will be written' 'Only on A: read CLAUDE.md (or create it)'
has    "merge-method readback kept"                      "grep -i '^[[:space:]]*-[[:space:]]*Merge method:' CLAUDE.md"

echo "setup-deploy: platform details"
has    "GitHub Actions status command"                   'gh run list --workflow <file> --json headSha,status,conclusion'
has    "Vercel auto-deploys only when Git-connected"     'only when the Vercel project is connected to this Git repository'
has    "Netlify URL asked and confirmed"                 'Ask for the production URL and confirm it'
has    "Fly /health only on a 2xx probe"                 'only when the probe answers 2xx'

SKILL="$TMP/canary.md"
echo "canary: alert after confirm"
has    "notify only once confirmed on two checks"        'confirmed on two consecutive checks'
has    "first occurrence is pending"                     'A first occurrence is **pending**'
hasnt  "no immediate notification"                       'immediately notify'

echo "canary: cadence"
has    "start and deadline recorded"                     'record the start time and the deadline'
has    "wait max(0, 60 - round)"                         'max(0, 60 − <round seconds>)'
has    "the wait is a bounded background wait"           'bounded background wait'
has    "rounds never overlap"                            'Rounds never overlap'
has    "actual cadence reported"                         'Cadence:'
has    "stop at the deadline after the current round"    'finish the current round and stop'
hasnt  "no start-within-30-seconds promise"              'within 30 seconds'

echo "canary: monitoring-start reference"
hasnt  "no pre-deploy snapshot claim"                    'Pre-Deploy Snapshot'
has    "monitoring-start reference named"                'monitoring-start reference'
has    "report says start-time errors are undetectable"  'cannot be detected without `--baseline`'

echo "canary: base branch"
if grep -qxF '{{include lib/snippets/base-branch-detect.md}}' "$SRC/skills/canary/SKILL.md"; then
  ok "Step 0 includes base-branch-detect"
else
  no "Step 0 includes base-branch-detect"
fi
has    "rendered fallback prints BASE_BRANCH"            'echo "BASE_BRANCH: $_BD_BASE"'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
