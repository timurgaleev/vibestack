#!/usr/bin/env bash
# test-jira-adapter.sh — the opt-in Jira adapter in /spec and /ship stays opt-in.
#
# A ticket key in a branch name is a hint, not a mandate: nothing may comment on
# or move a Jira issue because a branch happens to be named after it. Ticket
# text is written by anyone with board access, so it reaches the model only
# through the untrusted envelope. A transition is chosen by the user from the
# workflow's own list, never inferred from a merge. These rules live in prose,
# so the rendered skill text is checked here; the branch-key detection block in
# /ship is run for real against throwaway repos.
#
# Usage: test-jira-adapter.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SNIP="$ROOT/lib/snippets/jira-adapter.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

for s in spec ship; do
  if ! "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$s/SKILL.md" "$TMP/$s.md" >/dev/null 2>&1; then
    echo "cannot render skills/$s/SKILL.md" >&2; exit 1
  fi
done

# The adapter section of a rendered skill: from its heading to the next `## `.
section() { awk '/^## Jira adapter \(opt-in\)$/ {on=1; print; next} on && /^## / {on=0} on' "$1"; }

echo "snippet"
if [ -f "$SNIP" ]; then
  ok "lib/snippets/jira-adapter.md exists"
  grep -q '{{include' "$SNIP" && no "snippet includes another snippet" || ok "snippet includes no other snippet"
  grep -q 'jira_get_issue' "$SNIP" && grep -q 'getJiraIssue' "$SNIP" \
    && ok "snippet maps both tool families (jira_get_issue, getJiraIssue)" \
    || no "snippet does not name both jira_get_issue and getJiraIssue"
  if grep -Eiq 'curl|rest/api|atlassian\.net' "$SNIP"; then
    no "snippet reaches Jira over HTTP: $(grep -Eio 'curl|rest/api|atlassian\.net' "$SNIP" | head -1)"
  else
    ok "snippet has no curl, rest/api or atlassian.net URL"
  fi
else
  no "lib/snippets/jira-adapter.md missing"
fi

for s in spec ship; do
  echo "/$s"
  R="$TMP/$s.md"; SEC="$TMP/$s.sec"
  section "$R" > "$SEC"
  n=$(grep -c '^## Jira adapter (opt-in)$' "$R")
  [ "$n" = "1" ] && ok "heading '## Jira adapter (opt-in)' appears once" || no "adapter heading appears $n times"
  [ -s "$SEC" ] || { no "adapter section empty"; continue; }

  grep -qi 'correlation' "$SEC" && grep -qi 'authorization' "$SEC" \
    && ok "branch key is correlation, not authorization" || no "correlation/authorization rule missing"

  grep -q 'vibe-untrusted" --source jira-issue --file' "$R" \
    && ok "issue text read through vibe-untrusted --source jira-issue --file" \
    || no "issue text not routed through vibe-untrusted --source jira-issue --file"

  grep -Eiq 'headless.*never|never.*headless' "$SEC" \
    && ok "headless session never writes to Jira" || no "headless no-write rule missing"

  # Every paragraph that mentions a transition, anywhere in the skill, names the
  # transition lookup and the user's approval.
  awk -v out="$TMP/$s.para" 'BEGIN{RS=""} tolower($0) ~ /transition/ {print > (out "." NR)}' "$R"
  bad=0; seen=0
  for p in "$TMP/$s.para".*; do
    [ -f "$p" ] || continue
    seen=$((seen+1))
    if ! grep -Eq 'get_transitions|listJiraIssueTransitions' "$p" || ! grep -Eq 'approv|AskUserQuestion' "$p"; then
      bad=$((bad+1)); printf '       unguarded: %s\n' "$(grep -i -m1 transition "$p" | cut -c1-120)"
    fi
  done
  [ "$seen" -gt 0 ] && [ "$bad" = "0" ] \
    && ok "every transition paragraph ($seen) names the lookup and the approval" \
    || no "$bad of $seen transition paragraphs lack get_transitions/listJiraIssueTransitions + approval"
done

echo "/spec acceptance criteria"
grep -q 'AC-001' "$TMP/spec.md" && ok "ACs numbered AC-001…" || no "AC-001 numbering missing"
grep -q 'TBD — needs validation via' "$TMP/spec.md" \
  && ok "unknowns written 'TBD — needs validation via <method>'" || no "TBD validation template missing"
grep -q -- '--jira <KEY>' "$TMP/spec.md" && ok "Flag Reference lists --jira <KEY>" || no "--jira flag row missing"

echo "/ship key detection"
grep -q 'JIRA_HINT:' "$TMP/ship.md" && ok "ship prints JIRA_HINT:" || no "JIRA_HINT: missing"
awk 'BEGIN{RS=""} /JIRA_KEY: <key>/ && /--jira/ {f=1} END{exit !f}' "$TMP/ship.md" \
  && ok "JIRA_KEY: comes from an explicit --jira flag" || no "JIRA_KEY: not tied to --jira"
# A bare --jira must not silently become JIRA_KEY: none: the user asked for
# Jira, so the key is asked for (the branch hint offered, never assumed).
awk 'BEGIN{RS=""} /bare `--jira`/ && /AskUserQuestion/ && /JIRA_HINT/ {f=1} END{exit !f}' "$TMP/ship.md" \
  && ok "bare --jira asks for the key, offering the branch hint" || no "bare --jira falls through to JIRA_KEY: none"

# The fenced bash block that prints JIRA_HINT, run against real branches.
awk '/^[[:space:]]*```bash$/ {buf=""; on=1; next} on && /^[[:space:]]*```$/ {on=0; if (buf ~ /JIRA_HINT:/) {printf "%s", buf; exit}} on {sub(/^   /, ""); buf = buf $0 "\n"}' \
  "$TMP/ship.md" > "$TMP/hint.sh"
if [ -s "$TMP/hint.sh" ]; then
  run_hint() {
    local repo="$TMP/repo-$2"
    git init -q -b "$1" "$repo" 2>/dev/null || { git init -q "$repo" && git -C "$repo" checkout -q -b "$1"; }
    (cd "$repo" && bash "$TMP/hint.sh" 2>&1)
  }
  out=$(run_hint "feat/PROJ-123-login" a)
  printf '%s' "$out" | grep -q '^JIRA_HINT: PROJ-123 (branch name — correlation only, not authorization)$' \
    && ok "branch feat/PROJ-123-login → JIRA_HINT: PROJ-123" || no "branch key not hinted: $out"
  printf '%s' "$out" | grep -q 'JIRA_KEY' && no "branch key produced JIRA_KEY: $out" || ok "branch key never sets JIRA_KEY"
  out=$(run_hint "fix/login-timeout" b)
  printf '%s' "$out" | grep -q '^JIRA_HINT: none$' && ok "branch without a key → JIRA_HINT: none" || no "keyless branch: $out"
else
  no "no bash block printing JIRA_HINT: in rendered /ship"
fi

echo
echo "jira adapter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
