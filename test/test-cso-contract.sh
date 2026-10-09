#!/usr/bin/env bash
# test-cso-contract.sh — contracts the /cso skill text must keep.
#
# Covers:
#   - trend tracking resolves a finding only on new evidence from a run that
#     covered its phase and scope; everything else is "not re-assessed", and
#     `--recheck <id>` exists;
#   - every report leads with complete / partial / not assessed and records
#     per-phase coverage, and the saved-report JSON schema still parses;
#   - Phase 2 never prints secret-bearing patches, and its redaction filter
#     hides quoted, multi-word, short and bare credentials both in git-history
#     hits and in CI-config matches (run against fixture repos);
#   - a secret commit reachable only from a local, unpushed tag is not remote
#     exposure, and the same tag pushed is (run against fixture repos);
#   - the incident playbook does not advise rewriting or force-pushing history;
#   - OWASP Top 10:2025, API Security Top 10:2023 and ASVS 5.0.0 labels;
#   - agentic and MCP coverage in Phase 7;
#   - the blanket exclusions for own skills, UUIDs, env vars, dev dependencies,
#     removed secrets and pull_request_target are gone.
#
# Usage: test/test-cso-contract.sh [repo-root]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

SKILL="$TMP/cso/SKILL.md"
if VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$SRC/skills/cso/SKILL.md" "$SKILL" >/dev/null 2>&1; then
  ok "cso renders"
else
  no "cso renders"; echo "$pass passed, $fail failed"; exit 1
fi

has()  { if grep -qF -- "$2" "$SKILL"; then ok "$1"; else no "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$SKILL"; then no "$1 (still present: $2)"; else ok "$1"; fi; }

echo "trend tracking"
has   "--recheck argument"                 '`/cso --recheck <id>`'
has   "--recheck is a scope flag"          '`--scope`, `--recheck`) are **mutually exclusive**'
has   "absence is not a fix"               "A finding's absence from this run is not evidence that it was fixed."
has   "resolved needs phase coverage"      "its phase is in this run's \`phases_run\` with coverage \`ran\`"
has   "resolved needs new evidence"        "you re-read the original location and can state the new evidence"
has   "not re-assessed state"              '**Not re-assessed**'
has   "trend table shows not re-assessed"  'Not re-assessed:  N findings'
has   "carried forward in schema"          '"carried_forward": []'
has   "retitled finding is persistent"     'that is the same finding, retitled'
hasnt "old trend line"                     'Resolved:    N findings fixed since last audit'

echo "completion status"
has   "status line"                        'AUDIT STATUS: complete | partial | not assessed'
has   "empty result wording"               'No supported findings in the assessed scope.'
has   "status in schema"                   '"status": "complete | partial | not assessed"'
has   "coverage in schema"                 '"coverage": ['
has   "missing tool is a coverage gap"     'it is a coverage gap'

python3 -I - "$SKILL" > "$TMP/schema.out" 2>&1 <<'PY' && ok "report schema is valid JSON" || { no "report schema is valid JSON"; cat "$TMP/schema.out"; }
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
anchor = "using this schema:"
at = text.index(anchor)
start = text.index("```json\n", at) + len("```json\n")
end = text.index("\n```", start)
doc = json.loads(text[start:end])
for key in ("status", "coverage", "phases_run", "trend"):
    assert key in doc, key
for key in ("not_reassessed", "carried_forward", "partial_comparison"):
    assert key in doc["trend"], key
PY

echo "secrets handling"
if grep -qE '^[[:space:]]*git log -p' "$SKILL"; then no "no secret-bearing git log -p command"; else ok "no secret-bearing git log -p command"; fi
has   "locate by name only"                "--format='%h %an %ad' --name-only"
hasnt "no force-push step"                 'Force-push'
hasnt "no history scrub step"              'git filter-repo'
has   "history rewrite is not the fix"     'This audit never rewrites history'

# Run the skill's own redaction filter, and the two blocks that use it, against
# fixtures holding fake credentials.
extract() {
  python3 -I - "$SKILL" "$1" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
at = text.index(sys.argv[2])
start = text.index("```bash\n", at) + len("```bash\n")
end = text.index("\n```", start)
print(text[start:end].replace("<sha>", '"$SHA"').replace("<file>", '"$FILE"'))
PY
}
FILTER="$(extract '**Redaction filter.**' 2>/dev/null || true)"
INSPECT="$(extract '**Inspect one hit, redacted.**' 2>/dev/null || true)"
CICHECK="$(extract '**CI configs with inline secrets' 2>/dev/null || true)"
printf '%s\n%s\n' "$FILTER" "$INSPECT" > "$TMP/redact.sh"
printf '%s\n%s\n' "$FILTER" "$CICHECK" > "$TMP/ci.sh"
if [ -n "$FILTER" ] && [ -n "$INSPECT" ] && [ -n "$CICHECK" ]; then ok "redaction blocks present"; else no "redaction blocks present"; fi
case "$INSPECT" in *'| redact'*) ok "inspect block uses the filter";; *) no "inspect block uses the filter";; esac
case "$CICHECK" in *'| redact'*) ok "CI-config block uses the filter";; *) no "CI-config block uses the filter";; esac

FAKE_AWS="AKIAZZQQ7XEXAMPLEKEY"
FAKE_PW="hunter2pass"
FAKE_GH="ghp_0123456789abcdefghijABCDEFGHIJ012345"
FAKE_PHRASE="my secret pass phrase"
FAKE_SHORT="abc"
FAKE_SIX="hunter"
FAKE_BARE="Zq9xLm2Pw8Rt5Yv3Nb7Kc4Hd"
FAKE_YAML_TAIL="w0rd!"
FAKE_SPACED="pw7short"
FAKE_NETRC="n3trcpw"
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
{
  printf 'AWS_ACCESS_KEY_ID=%s\n' "$FAKE_AWS"
  printf 'DB_PASSWORD="%s"\n' "$FAKE_PW"
  printf 'GH_TOKEN: %s\n' "$FAKE_GH"
  printf 'ADMIN_PASSWORD="%s"\n' "$FAKE_PHRASE"
  printf 'password: p@ss %s\n' "$FAKE_YAML_TAIL"
  printf 'password=%s\n' "$FAKE_SHORT"
  printf 'SMTP_PASSWORD=%s\n' "$FAKE_SIX"
  printf 'export TOKEN %s\n' "$FAKE_BARE"
  printf 'password %s\n' "$FAKE_SPACED"
  printf 'machine example.invalid login me Password %s\n' "$FAKE_NETRC"
  printf 'NAME=demo\n'
} > "$REPO/app.env"
git -C "$REPO" add app.env
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm add
SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && SHA="$SHA" FILE=app.env bash "$TMP/redact.sh" 2>&1 || true)"
case "$OUT" in *AKIA*redacted*) ok "redaction keeps the key prefix";; *) no "redaction keeps the key prefix (got: $OUT)";; esac
case "$OUT" in *ADMIN_PASSWORD*) ok "redaction keeps the variable name";; *) no "redaction keeps the variable name (got: $OUT)";; esac
leaked=""
for v in "$FAKE_AWS" "$FAKE_PW" "$FAKE_GH" "$FAKE_PHRASE" "secret pass" "$FAKE_YAML_TAIL" "=$FAKE_SHORT" "$FAKE_SIX" "=hunt" "$FAKE_BARE" "$FAKE_SPACED" "$FAKE_NETRC"; do
  case "$OUT" in *"$v"*) leaked="$leaked [$v]";; esac
done
if [ -z "$leaked" ]; then ok "redaction hides every fixture secret"; else no "redaction leaked:$leaked"; fi
case "$OUT" in *NAME=demo*) no "redaction prints only matching lines";; *) ok "redaction prints only matching lines";; esac

CI="$TMP/ci"
mkdir -p "$CI/.github/workflows"
{
  printf 'jobs:\n  build:\n    env:\n'
  printf '      password: "%s"\n' "$FAKE_PHRASE"
  printf '      token: %s\n' "$FAKE_GH"
  printf '      secret: %s\n' "$FAKE_SHORT"
  printf '      api_key: ${{ secrets.API_KEY }}\n'
} > "$CI/.github/workflows/ci.yml"
CIOUT="$(cd "$CI" && bash "$TMP/ci.sh" 2>&1 || true)"
case "$CIOUT" in *"ci.yml line 4"*) ok "CI check cites file and line";; *) no "CI check cites file and line (got: $CIOUT)";; esac
leaked=""
for v in "$FAKE_PHRASE" "secret pass" "$FAKE_GH" ": $FAKE_SHORT"; do
  case "$CIOUT" in *"$v"*) leaked="$leaked [$v]";; esac
done
if [ -z "$leaked" ]; then ok "CI check hides inline secrets"; else no "CI check leaked:$leaked"; fi

# Without the filter in the same call, both blocks must say they did not run
# instead of printing nothing, which would read as a clean result.
printf '%s\n' "$CICHECK" > "$TMP/ci-nofilter.sh"
NOF="$(cd "$CI" && bash "$TMP/ci-nofilter.sh" 2>&1 || true)"
case "$NOF" in *"did not run"*) ok "CI check reports a missing filter";; *) no "CI check reports a missing filter (got: $NOF)";; esac
printf '%s\n' "$INSPECT" > "$TMP/inspect-nofilter.sh"
NOF="$(cd "$REPO" && SHA="$SHA" FILE=app.env bash "$TMP/inspect-nofilter.sh" 2>&1 || true)"
case "$NOF" in *"nothing was inspected"*) ok "inspect reports a missing filter";; *) no "inspect reports a missing filter (got: $NOF)";; esac
case "$NOF" in *"$FAKE_AWS"*) no "inspect without filter leaked";; *) ok "inspect without filter prints no secret";; esac

echo "remote exposure"
# A tag that only exists locally is not remote exposure; the same tag pushed is.
hasnt "local tags alone are not exposure"  '`git tag --contains <sha>` both empty'
EXPOSE="$(extract '**Remote exposure of a commit.**' 2>/dev/null || true)"
printf '%s\n' "$EXPOSE" > "$TMP/expose.sh"
case "$EXPOSE" in *'EXPOSURE:'*) ok "exposure block present";; *) no "exposure block present";; esac
G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid "${@:2}"; }
XR="$TMP/xrepo"; XB="$TMP/xremote.git"
git init -q --bare "$XB"
git init -q "$XR"
G "$XR" commit -q --allow-empty -m base
G "$XR" remote add origin "$XB"
G "$XR" push -q origin HEAD:refs/heads/main
G "$XR" fetch -q origin
G "$XR" checkout -q -b leak
printf 'API_KEY=%s\n' "$FAKE_GH" > "$XR/leak.env"
G "$XR" add leak.env
G "$XR" commit -qm leak
XSHA="$(git -C "$XR" rev-parse HEAD)"
G "$XR" tag -a v-leak -m leak
G "$XR" tag v-light
G "$XR" checkout -q --detach HEAD~1
G "$XR" branch -q -D leak
expose() { (cd "$XR" && SHA="$XSHA" bash "$TMP/expose.sh" 2>&1 | grep '^EXPOSURE:' || true); }
X="$(expose)"
[ "$X" = "EXPOSURE: local only" ] && ok "local-only tags are not remote exposure" || no "local-only tags are not remote exposure (got: ${X:-nothing})"
G "$XR" push -q origin v-light
X="$(expose)"
[ "$X" = "EXPOSURE: remote" ] && ok "pushed lightweight tag is remote exposure" || no "pushed lightweight tag is remote exposure (got: ${X:-nothing})"
git -C "$XB" tag -d v-light >/dev/null
G "$XR" push -q origin v-leak
X="$(expose)"
[ "$X" = "EXPOSURE: remote" ] && ok "pushed annotated tag is remote exposure" || no "pushed annotated tag is remote exposure (got: ${X:-nothing})"
git -C "$XB" tag -d v-leak >/dev/null
G "$XR" remote set-url origin "$TMP/no-such-remote.git"
X="$(expose)"
[ "$X" = "EXPOSURE: unknown" ] && ok "unreachable remote is unknown, not local only" || no "unreachable remote is unknown, not local only (got: ${X:-nothing})"
G "$XR" remote set-url origin "$XB"
# Only a pull-request ref on the remote holds the commit.
G "$XR" push -q origin "$XSHA:refs/pull/1/head"
X="$(expose)"
[ "$X" = "EXPOSURE: remote" ] && ok "remote PR ref is remote exposure" || no "remote PR ref is remote exposure (got: ${X:-nothing})"
git -C "$XB" update-ref -d refs/pull/1/head
# Pushed with an upstream, then the remote branch was deleted and pruned.
G "$XR" checkout -q -b feat "$XSHA"
G "$XR" push -q -u origin feat
git -C "$XB" update-ref -d refs/heads/feat
G "$XR" fetch -q --prune origin
X="$(expose)"
[ "$X" = "EXPOSURE: remote" ] && ok "pushed branch whose remote ref was pruned is remote exposure" || no "pushed branch whose remote ref was pruned is remote exposure (got: ${X:-nothing})"
G "$XR" checkout -q --detach HEAD~1
G "$XR" branch -q -D feat

echo "recheck scope"
has   "recheck runs Phase 1 (rule 6)"      "(Phases 0-1, the finding's own phase, 12-14)"
has   "recheck section runs Phase 1"       "run Phases 0-1, then that finding's phase"

echo "standards"
has   "OWASP Top 10:2025"                  'OWASP Top 10:2025'
has   "2025 A10"                           '#### A10: Mishandling of Exceptional Conditions'
has   "2025 A03"                           '#### A03: Software Supply Chain Failures'
hasnt "no 2021 A10 SSRF"                   '#### A10: Server-Side Request Forgery'
has   "API Top 10:2023"                    'API Security Top 10:2023'
has   "ASVS 5.0.0"                         'ASVS 5.0.0'

echo "agentic and MCP"
has   "phase title"                        '### Phase 7: LLM, Agentic & MCP Security'
has   "tool results traced"                '**Tool results as instructions:**'
has   "memory poisoning"                   '**Memory poisoning:**'
has   "delegation"                         '**Uncontrolled delegation:**'
has   "token passthrough"                  '**No token passthrough:**'
has   "confused deputy"                    '**Confused deputy:**'
has   "no live MCP connection"             'Do not connect to a live MCP server'

echo "exclusions"
hasnt "own skills not trusted (FP rule)"   "vibestack's own skills are trusted"
hasnt "own skills not excluded"            'Skill files that are part of vibestack itself (trusted source)'
hasnt "UUID precedent narrowed"            "don't flag missing UUID validation."
hasnt "env var precedent narrowed"         '3. Environment variables and CLI flags are trusted input.'
hasnt "pull_request_target precedent"      '11. `pull_request_target` without PR ref checkout is safe.'
hasnt "removed-secret exclusion"           'removed in the same initial-setup PR'
has   "dev deps with CI credentials"       'publish credentials'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
