#!/usr/bin/env bash
# test-spec-execute.sh — /spec's executor hand-off and the blocks around it.
#
# `/spec --execute` starts an unattended `claude -p` in a fresh worktree. What
# that child may do is decided entirely by the brief it reads and the flags on
# the spawn line, so both are pinned here: the brief forbids commits, pushes and
# PRs, marks the child as spawned, and points at a progress file; the spawn line
# carries a budget, a turn cap and explicit tool grants (a headless child with
# no grant cannot edit at all). The spawn, gate and dedupe blocks are extracted
# from the rendered skill and run for real against throwaway repos, with a fake
# `claude` and `gh` on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { grep -Fq -- "$1" "$2"; }

R="$TMP/spec.md"
"$ROOT/bin/vibe-render-skill" "$ROOT/skills/spec/SKILL.md" "$R" >/dev/null 2>&1 \
  || { echo "cannot render skills/spec/SKILL.md" >&2; exit 1; }

# First fenced block of language $2 in $1 whose body contains $3, unindented.
block() {
  awk -v lang="$2" -v needle="$3" '
    $0 ~ "^[[:space:]]*```" lang "$" {buf=""; on=1; next}
    on && /^[[:space:]]*```$/ {on=0; if (index(buf, needle)) {printf "%s", buf; exit}; next}
    on {sub(/^   /, ""); buf = buf $0 "\n"}' "$1"
}
# The text of one `## <name>` section of the Standard issue template.
template_section() {
  awk -v h="## $2" '$0 == h {on=1; next} on && /^## / {exit} on' "$1"
}

git_repo() {
  git init -q "$1" 2>/dev/null
  git -C "$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
}

echo "test value bar and implementer rules (rendered)"
for snip in test-value-bar implementer-dispatch-rules; do
  if python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().strip() in open(sys.argv[2]).read() else 1)' \
       "$ROOT/lib/snippets/$snip.md" "$R"; then
    ok "$snip.md renders verbatim"
  else
    no "$snip.md is not rendered verbatim into /spec"
  fi
done
template_section "$R" "Testing Plan" > "$TMP/testing-plan"
has 'Value: protects=' "$TMP/testing-plan" \
  && ok "Testing Plan rows carry a value card" || no "Testing Plan has no Value: card"
grep -q '^| Test seams' "$TMP/testing-plan" \
  && ok "Testing Plan has a Test seams row" || no "Testing Plan has no Test seams row"
template_section "$R" "Rules for the implementing agent" | grep -q . \
  && ok "Standard template carries the implementing-agent rules" \
  || no "Standard template has no '## Rules for the implementing agent' section"

echo "executor brief"
block "$R" text 'VIBE_SPAWNED' > "$TMP/brief"
if [ -s "$TMP/brief" ]; then
  first=$(grep -m1 . "$TMP/brief")
  printf '%s' "$first" | grep -Fq 'export VIBE_SPAWNED=1' \
    && ok "brief opens with the export VIBE_SPAWNED=1 line" || no "brief's first line is not the marker: $first"
  for needle in 'Never `git commit`' 'never push' 'never open a pull request' \
                '.vibestack-progress.md' 'Ruling: <what> — <why> — <cost if wrong>' \
                'baseline' 'pre-existing failures by name' 'red' 'criteria met'; do
    has "$needle" "$TMP/brief" && ok "brief: $needle" || no "brief lacks: $needle"
  done
  if grep -Eiq 'commit (each|per|after)|git add' "$TMP/brief"; then
    no "brief still asks for commits"
  else
    ok "brief never asks for a commit"
  fi
else
  no "no executor brief block (a text fence naming VIBE_SPAWNED) in rendered /spec"
fi

echo "spawn line"
block "$R" bash 'claude -p' > "$TMP/spawn.sh"
if [ -s "$TMP/spawn.sh" ]; then
  line=$(grep 'claude -p' "$TMP/spawn.sh")
  for needle in 'VIBE_SPAWNED=1 claude -p' '--allowedTools Edit,Write,Read,Bash,Grep,Glob' \
                '--max-budget-usd "${VIBE_SPEC_EXECUTE_USD:-5}"' '--max-turns "${VIBE_SPEC_EXECUTE_TURNS:-200}"' \
                'cat "$BRIEF_PATH" "$ARCHIVE_PATH" |' '> "$LOG_PATH" 2>&1' \
                "--strict-mcp-config --mcp-config '{\"mcpServers\":{}}'" \
                "--disallowedTools 'mcp__*' 'Bash(git commit:*)' 'Bash(git push:*)' 'Bash(gh pr:*)'"; do
    printf '%s' "$line" | grep -Fq -- "$needle" && ok "spawn line: $needle" || no "spawn line lacks: $needle"
  done
  has 'SPAWN_LOG:' "$TMP/spawn.sh" && ok "spawn block prints the log path" || no "spawn block does not print SPAWN_LOG:"
else
  no "no bash block running claude -p in rendered /spec"
fi

# The spawn block for real: a worktree reached through a symlinked parent (the
# shape of macOS /tmp), a fake claude that records what it was handed.
if [ -s "$TMP/spawn.sh" ]; then
  REPO="$TMP/repo"; git_repo "$REPO"
  mkdir -p "$TMP/real" "$TMP/arch" "$TMP/fakebin" "$TMP/rec"
  ln -s "$TMP/real" "$TMP/link"
  git -C "$REPO" worktree add -q "$TMP/link/wt" -b spec/t-1 2>/dev/null
  printf 'export VIBE_SPAWNED=1\nBRIEF\n' > "$TMP/arch/s.brief.txt"
  printf -- '---\nspec_issue_number: 7\n---\nARCHIVE\n' > "$TMP/arch/s.md"
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
printf '%s' "${VIBE_SPAWNED:-}" > "$REC/env"
pwd -P > "$REC/cwd"
cat > "$REC/stdin"
echo "child ran"
touch "$REC/done"
EOF
  chmod +x "$TMP/fakebin/claude"
  # The spawn block re-checks the session kind itself, so it needs the helper.
  SK="$TMP/sk"; mkdir -p "$SK/bin"; ln -s "$ROOT/bin/vibe-session-kind" "$SK/bin/vibe-session-kind"
  spawn_env() { env -u CI -u VIBESTACK_HEADLESS -u VIBE_SPAWNED -u OPENCLAW_SESSION \
    -u VIBE_SPEC_EXECUTE_USD -u VIBE_SPEC_EXECUTE_TURNS VIBESTACK_HOME="$SK" REC="$TMP/rec" PATH="$TMP/fakebin:$PATH" "$@"; }
  sed -e "s|<ARCHIVE_PATH>|$TMP/arch/s.md|" -e "s|<SPAWN_PATH>|$TMP/link/wt|" \
      -e "s|<SPAWN_BRANCH>|spec/t-1|" "$TMP/spawn.sh" > "$TMP/spawn-run.sh"
  out=$(cd "$REPO" && spawn_env bash "$TMP/spawn-run.sh" 2>&1)
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/rec/done" ] && break; sleep 0.5; done
  if [ -f "$TMP/rec/done" ]; then
    ok "symlinked worktree path spawns (toplevel compared physically)"
    [ "$(cat "$TMP/rec/env")" = 1 ] && ok "child runs with VIBE_SPAWNED=1" || no "child env VIBE_SPAWNED=$(cat "$TMP/rec/env")"
    [ "$(cat "$TMP/rec/cwd")" = "$(cd "$TMP/real/wt" && pwd -P)" ] \
      && ok "child runs in the worktree" || no "child cwd: $(cat "$TMP/rec/cwd")"
    printf 'export VIBE_SPAWNED=1\nBRIEF\n---\nspec_issue_number: 7\n---\nARCHIVE\n' > "$TMP/want-stdin"
    cmp -s "$TMP/want-stdin" "$TMP/rec/stdin" && ok "stdin is the brief, then the archive" || no "stdin differs from brief+archive"
    grep -qx -- '--max-budget-usd' "$TMP/rec/argv" && grep -qx '5' "$TMP/rec/argv" \
      && ok "default budget 5 reaches the child" || no "budget flag missing from argv"
    grep -qx '200' "$TMP/rec/argv" && ok "default turn cap 200 reaches the child" || no "turn cap missing from argv"
    log=$(printf '%s\n' "$out" | sed -n 's/^SPAWN_LOG: //p')
    [ "$log" = "$TMP/arch/s.execute.log" ] && grep -q 'child ran' "$log" \
      && ok "child output lands in the printed log beside the archive" || no "log path/content wrong: '$log'"
    excl=$(git -C "$REPO" rev-parse --git-common-dir)/info/exclude
    case "$excl" in /*) ;; *) excl="$REPO/$excl" ;; esac
    grep -qxF '.vibestack-progress.md' "$excl" 2>/dev/null \
      && ok "progress file is excluded from git" || no "progress file not in info/exclude"
  else
    no "spawn through a symlinked worktree path did not start the child: $(printf '%s' "$out" | tail -1)"
  fi

  # The spawn block refuses on its own when the session is not interactive or
  # the helper is missing: the gate runs in another shell and binds nothing.
  rm -f "$TMP/rec/done"
  out=$(cd "$REPO" && spawn_env VIBE_SPAWNED=1 bash "$TMP/spawn-run.sh" 2>&1)
  sleep 1
  if [ ! -f "$TMP/rec/done" ] && printf '%s' "$out" | grep -q '^NOT_SPAWNED:.*interactive'; then
    ok "spawned session → spawn block refuses"
  else
    no "spawn block started a child from a spawned session: $out"
  fi
  rm -f "$TMP/rec/done"
  out=$(cd "$REPO" && spawn_env VIBESTACK_HOME="$TMP/no-helper" bash "$TMP/spawn-run.sh" 2>&1)
  sleep 1
  if [ ! -f "$TMP/rec/done" ] && printf '%s' "$out" | grep -q '^NOT_SPAWNED:'; then
    ok "missing vibe-session-kind → spawn block refuses"
  else
    no "spawn block started a child without vibe-session-kind: $out"
  fi

  # A missing brief never spawns: the child would get the bare spec and no rules.
  rm -f "$TMP/rec/done" "$TMP/arch/s.brief.txt"
  out=$(cd "$REPO" && spawn_env bash "$TMP/spawn-run.sh" 2>&1)
  sleep 1
  if [ ! -f "$TMP/rec/done" ] && printf '%s' "$out" | grep -q '^NOT_SPAWNED:.*brief'; then
    ok "no brief → NOT_SPAWNED"
  else
    no "spawned without a brief: $out"
  fi
fi

echo "spawn gate"
block "$R" bash 'SPAWN_GATE:' > "$TMP/gate.sh"
if [ -s "$TMP/gate.sh" ]; then
  VH="$TMP/vh"; mkdir -p "$VH/bin"; ln -s "$ROOT/bin/vibe-session-kind" "$VH/bin/vibe-session-kind"
  run_gate() { # repo, extra env...
    local repo="$1"; shift
    (cd "$repo" && env -u CI -u VIBESTACK_HEADLESS -u VIBE_SPAWNED -u OPENCLAW_SESSION \
       VIBESTACK_HOME="$VH" "$@" bash "$TMP/gate.sh" 2>&1)
  }
  G1="$TMP/g-trusted"; git_repo "$G1"; printf '# x\n' > "$G1/CLAUDE.md"
  G2="$TMP/g-bare"; git_repo "$G2"
  G3="$TMP/g-dotclaude"; git_repo "$G3"; mkdir -p "$G3/.claude"
  run_gate "$G1" | grep -qx 'SPAWN_GATE: ok' && ok "CLAUDE.md + interactive → ok" || no "trusted interactive repo refused"
  run_gate "$G3" | grep -qx 'SPAWN_GATE: ok' && ok ".claude/ + interactive → ok" || no ".claude/ repo refused"
  out=$(run_gate "$G2"); printf '%s' "$out" | grep -q '^NOT_SPAWNED:.*untrusted' \
    && ok "no CLAUDE.md or .claude/ → NOT_SPAWNED (untrusted)" || no "untrusted repo: $out"
  out=$(run_gate "$G1" VIBE_SPAWNED=1); printf '%s' "$out" | grep -q '^NOT_SPAWNED:.*spawned' \
    && ok "spawned session → NOT_SPAWNED" || no "spawned session: $out"
  out=$(run_gate "$G1" CI=1); printf '%s' "$out" | grep -q '^NOT_SPAWNED:.*headless' \
    && ok "headless session → NOT_SPAWNED" || no "headless session: $out"
  # Without the helper the kind is unknown, and unknown refuses: a guessed
  # "interactive" would let a spawned session start another child.
  rm "$VH/bin/vibe-session-kind"
  out=$(run_gate "$G1"); printf '%s' "$out" | grep -q '^NOT_SPAWNED:' \
    && ok "missing vibe-session-kind → NOT_SPAWNED (fails closed)" || no "gate passes without vibe-session-kind: $out"
else
  no "no bash block printing SPAWN_GATE: in rendered /spec"
fi

echo "dedupe paths"
if grep -q '/tmp/vibestack-spec-dedupe' "$R"; then
  no "prose still names /tmp/vibestack-spec-dedupe.* instead of the printed paths"
else
  ok "prose names no fixed dedupe path"
fi
block "$R" bash 'gh issue list --search' > "$TMP/dedupe.sh"
if [ -s "$TMP/dedupe.sh" ]; then
  D="$TMP/d-repo"; git_repo "$D"; mkdir -p "$TMP/ghbin"
  printf '#!/bin/sh\necho "HTTP 403: API rate limit exceeded" >&2\nexit 1\n' > "$TMP/ghbin/gh"; chmod +x "$TMP/ghbin/gh"
  out=$(cd "$D" && TMPDIR="$TMP" VIBESTACK_HOME="$TMP/vh-empty" PATH="$TMP/ghbin:$PATH" bash "$TMP/dedupe.sh" 2>&1)
  derr=$(printf '%s\n' "$out" | sed -n 's/^DEDUPE_ERR: //p')
  dout=$(printf '%s\n' "$out" | sed -n 's/^DEDUPE_OUT: //p')
  [ -n "$derr" ] && grep -q 'rate limit' "$derr" 2>/dev/null \
    && ok "DEDUPE_ERR: names the file holding gh's stderr" || no "DEDUPE_ERR missing or empty: $out"
  [ -n "$dout" ] && [ -f "$dout" ] && ok "DEDUPE_OUT: names the output file" || no "DEDUPE_OUT missing: $out"
  block "$R" bash "rm -f \"\$DEDUPE_OUT\" \"\$DEDUPE_ERR\"" > "$TMP/dedupe-rm.sh"
  if [ -s "$TMP/dedupe-rm.sh" ] && [ -n "$derr" ] && [ -n "$dout" ]; then
    sed -e "s|<DEDUPE_OUT>|$dout|" -e "s|<DEDUPE_ERR>|$derr|" "$TMP/dedupe-rm.sh" | bash
    [ ! -e "$derr" ] && [ ! -e "$dout" ] && ok "cleanup block removes both dedupe files" || no "dedupe files survive cleanup"
  else
    no "no cleanup block removing DEDUPE_OUT and DEDUPE_ERR"
  fi
else
  no "no dedupe block in rendered /spec"
fi

echo
echo "spec execute: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
