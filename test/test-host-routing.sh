#!/usr/bin/env bash
# test-host-routing.sh — routing that depends on which agent host is running.
#
# The /vibe router has to find its index and pick a second-opinion skill on
# every host, the shared outside-voice preflight has to choose Claude Code when
# the session itself is Codex, and the memrain rule has to send code questions
# to the code graph without treating an empty graph as an answer. Each check
# executes the shipped bash where there is any, so reverting the text fails it.
set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
chk() { # chk NAME ACTUAL EXPECTED
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi
}
has() { # has NAME FILE FIXED-STRING
  if grep -qF -- "$3" "$2"; then ok "$1"; else no "$1"; fi
}

ROUTER="$ROOT/skills/vibe/SKILL.md"
PRE="$ROOT/lib/snippets/outside-voice-preflight.md"

# nth_bash FILE N -> the Nth ```bash block of FILE (1-based)
nth_bash() {
  awk -v want="$2" '/^```bash$/{n++; f=(n==want); next} /^```$/{f=0} f' "$1"
}
# bash_with FILE PATTERN -> the first ```bash block containing PATTERN
bash_with() {
  local i=1 blk
  while :; do
    blk=$(nth_bash "$1" "$i")
    [ -n "$blk" ] || return 1
    if printf '%s\n' "$blk" | grep -qF -- "$2"; then printf '%s\n' "$blk"; return 0; fi
    i=$((i + 1))
  done
}

echo "router: index lookup"
IDX="$TMP/index.sh"
bash_with "$ROUTER" "skills-index.md" > "$IDX" || no "no index-lookup block in the router"
for host in agents cursor kiro; do
  H="$TMP/home-$host"; mkdir -p "$H/.$host/skills/vibe" "$TMP/cwd-$host"
  printf 'INDEX-%s\n' "$host" > "$H/.$host/skills/vibe/skills-index.md"
  out=$(cd "$TMP/cwd-$host" && HOME="$H" env -u CLAUDE_SKILL_DIR bash "$IDX" 2>/dev/null | head -1)
  chk "index found under ~/.$host/skills with CLAUDE_SKILL_DIR unset" "$out" "INDEX-$host"
done
H="$TMP/home-dir"; mkdir -p "$H/sd"; printf 'INDEX-dir\n' > "$H/sd/skills-index.md"
out=$(cd "$TMP" && HOME="$TMP/nowhere" CLAUDE_SKILL_DIR="$H/sd" bash "$IDX" 2>/dev/null | head -1)
chk "CLAUDE_SKILL_DIR still wins when set" "$out" "INDEX-dir"

echo "router: second-opinion host rule"
HOSTB="$TMP/host.sh"
bash_with "$ROUTER" 'HOST: codex' > "$HOSTB" || no "no host-detection block in the router"
host() { env -u CODEX_THREAD_ID -u CODEX_SANDBOX -u CLAUDECODE "$@" bash "$HOSTB"; }
chk "Codex session -> HOST: codex" "$(host CODEX_THREAD_ID=t)" "HOST: codex"
chk "Codex sandbox -> HOST: codex" "$(host CODEX_SANDBOX=seatbelt)" "HOST: codex"
chk "Claude Code session -> HOST: claude" "$(host CLAUDECODE=1)" "HOST: claude"
chk "neither -> HOST: other" "$(host)" "HOST: other"
has "HOST: codex routes to claude" "$ROUTER" '`HOST: codex` → `claude`'
has "HOST: claude routes to codex" "$ROUTER" '`HOST: claude` → `codex`'

echo "router: invoke, don't list"
has "the router tells the agent to invoke the skill" "$ROUTER" "Invoke it, don't describe it."
has "Codex hand-off uses \$name" "$ROUTER" 'Use $<name>'
has "answer-directly criteria are present" "$ROUTER" "Answer directly instead"
grep -qE '^  - Skill$' "$ROUTER" && ok "Skill is an allowed tool" || no "Skill missing from allowed-tools"

echo "outside-voice preflight under a Codex host"
PF="$TMP/preflight.sh"
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$PRE" > "$PF"
FAKE="$TMP/fake"; mkdir -p "$FAKE" "$TMP/pfhome"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/claude"; chmod +x "$FAKE/claude"
pfvoice() { # pfvoice PATH [VAR=VAL...] -> the OUTSIDE_VOICE value
  local p="$1"; shift
  HOME="$TMP/pfhome" PATH="$p" env -u CODEX_THREAD_ID -u CODEX_SANDBOX \
    -u VIBE_FORCE_CODEX_REVIEW -u OUTSIDE_VOICE "$@" bash "$PF" 2>&1 \
    | sed -n 's/^OUTSIDE_VOICE: //p'
}
chk "under Codex with claude installed -> claude_cli" \
    "$(pfvoice "$FAKE:/usr/bin:/bin" CODEX_THREAD_ID=t)" "claude_cli"
# A PATH holding only what the preflight runs, so a claude installed in
# /usr/bin on some image can never turn the negative case into a skip.
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for _t in env bash sed; do ln -s "$(command -v "$_t")" "$MINBIN/$_t"; done
chk "under Codex without claude -> same_model_subagent" \
    "$(pfvoice "$MINBIN" CODEX_THREAD_ID=t)" "same_model_subagent"
chk "not under Codex -> no OUTSIDE_VOICE line" \
    "$(pfvoice "$FAKE:/usr/bin:/bin")" ""
chk "a stray OUTSIDE_VOICE in the environment is not echoed" \
    "$(pfvoice "$FAKE:/usr/bin:/bin" OUTSIDE_VOICE=claude_cli)" ""
has "the claude_cli branch runs claude -p tool-less" "$PRE" \
    'claude -p --output-format json --disable-slash-commands --tools ""'
has "the same-model fallback is labelled as such" "$PRE" \
    'OUTSIDE VOICE (same-model subagent — not cross-model)'
grep -q 'genuinely different model' "$PRE" \
  && no "the preflight still sells a Codex subagent as a different model" \
  || ok "the preflight no longer calls the Codex subagent a different model"

echo "memrain rule: code questions"
for f in config/claude/rules/memrain.md config/cursor/rules/memrain.mdc config/codex/AGENTS.md; do
  for tool in code_def code_callers code_refs code_callees code_blast code_flow; do
    grep -qF "$tool" "$ROOT/$f" || no "$f does not route to $tool"
  done
  has "$f: zero hits means unknown" "$ROOT/$f" "Zero hits means unknown, not absent."
  has "$f: only readiness ready proves absence" "$ROOT/$f" '`readiness.state` is `ready`'
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
