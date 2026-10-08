#!/usr/bin/env bash
# test-dispatch-flags.sh — every synchronous subagent dispatch in a rendered
# skill states `run_in_background: false`.
#
# A step that dispatches a subagent and then reads its result breaks silently
# when the subagent runs in the background: control comes back before the
# result exists, and the step reads the missing result as an empty one. The
# default for that flag has changed under us before, so no dispatch may rely on
# it. lib/snippets/foreground-dispatch.md is the shared wording; a snippet
# cannot include another snippet, so snippets state the flag inline.
#
# A dispatch is a paragraph (blank-line separated, outside code fences) that
# names the `Agent tool` together with a dispatch verb, or that dispatches,
# launches or spawns a sub-agent in one sentence without naming the tool. The flag must appear in
# that paragraph or the one right after it, which is where the include lands.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$ROOT/bin/vibe-render-skill"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Skills whose dispatch sites are still being brought in line. The list may
# only shrink: a listed skill that is already clean fails the run, so the entry
# cannot linger after the fix lands.
PENDING="autoplan cso design-consultation design-review improve-arch office-hours plan-ceo-review plan-design-review plan-devex-review"

# scan FILE... -> prints `file:line` for each dispatch paragraph without the flag
scan() {
  python3 - "$@" <<'PY'
import re, sys
verb = re.compile(r"(?:[Dd]ispatch|[Ll]aunch|[Uu]se the Agent tool|[Uu]sing the Agent tool|via (?:the )?Agent tool)")
# Dispatch wording that never names the tool: "dispatch the candidates to
# sub-agents in parallel", "spawn a subagent".
sub = re.compile(r"(?i)\b(?:dispatch\w*|launch\w*|spawn\w*)\b[^.]*?\bsub-?agents?\b|\bsub-?agents?\b[^.]*?\b(?:dispatch\w*|launch\w*|spawn\w*)\b")
for path in sys.argv[1:]:
    paras, cur, start, fence = [], [], 0, False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            if cur: paras.append((start, " ".join(cur))); cur = []
            continue
        if fence:
            continue
        if line.strip() == "":
            if cur: paras.append((start, " ".join(cur))); cur = []
            continue
        if not cur: start = n
        cur.append(line.strip())
    if cur: paras.append((start, " ".join(cur)))
    for i, (n, text) in enumerate(paras):
        text = re.sub(r"\s+", " ", text)
        if not (("Agent tool" in text and verb.search(text)) or sub.search(text)):
            continue
        window = text + " " + (paras[i + 1][1] if i + 1 < len(paras) else "")
        if "run_in_background: false" not in window:
            print(f"{path}:{n}")
PY
}

echo "scanner"
FIX="$TMP/fixture.md"
printf 'Dispatch via the Agent tool. Fresh context.\n\nNext.\n' > "$FIX"
[ -n "$(scan "$FIX")" ] && ok "an unflagged dispatch is caught" || no "an unflagged dispatch passed"
printf 'Use the Agent\ntool with a prompt.\n\nPass `run_in_background: false` on it.\n' > "$FIX"
[ -z "$(scan "$FIX")" ] && ok "a flag in the next paragraph satisfies it, across a wrapped line" \
                         || no "a flagged dispatch was caught"
printf 'Dispatch via the Agent tool.\n\nOther text.\n\nPass `run_in_background: false`.\n' > "$FIX"
[ -n "$(scan "$FIX")" ] && ok "a flag two paragraphs away does not count" || no "a distant flag was accepted"
printf '```\nDispatch via the Agent tool.\n```\n' > "$FIX"
[ -z "$(scan "$FIX")" ] && ok "a fenced example is not a dispatch" || no "a fenced example was caught"
printf 'Then dispatch the candidates to multiple sub-agents in parallel.\n' > "$FIX"
[ -n "$(scan "$FIX")" ] && ok "a sub-agent dispatch that never names the tool is caught" \
                         || no "a sub-agent dispatch without the tool name passed"
printf 'Spawn a subagent for the review.\n\nPass `run_in_background: false`.\n' > "$FIX"
[ -z "$(scan "$FIX")" ] && ok "a flagged subagent spawn passes" || no "a flagged subagent spawn was caught"
printf 'If the Agent tool is unavailable, self-verify.\n' > "$FIX"
[ -z "$(scan "$FIX")" ] && ok "a mention without a dispatch verb is not a dispatch" || no "a bare mention was caught"

# Snippets are checked on their own too: one included only by pending skills
# would otherwise regress without turning anything red.
echo "snippets"
for snip in "$ROOT"/lib/snippets/*.md; do
  hits=$(scan "$snip" | sed "s|$ROOT/||")
  [ -z "$hits" ] && ok "$(basename "$snip")" \
                 || no "dispatch without run_in_background: false at $(printf '%s' "$hits" | tr '\n' ' ')"
done

echo "rendered skills"
mkdir -p "$TMP/out"
for src in "$ROOT"/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$src")")
  mkdir -p "$TMP/out/$name"
  "$RENDER" "$src" "$TMP/out/$name/SKILL.md" >/dev/null 2>&1 \
    || { no "$name renders"; continue; }
  # Sub-docs ship next to SKILL.md and are read at runtime, unrendered.
  for doc in "$(dirname "$src")"/*.md; do
    [ "$(basename "$doc")" = SKILL.md ] && continue
    cp "$doc" "$TMP/out/$name/"
  done
done

for dir in "$TMP"/out/*/; do
  name=$(basename "$dir")
  hits=$(scan "$dir"*.md | sed "s|$TMP/out/||")
  case " $PENDING " in
    *" $name "*)
      if [ -n "$hits" ]; then
        printf '  todo %s (%s unflagged dispatch site(s), pending)\n' "$name" "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
      else
        no "$name is clean — drop it from PENDING"
      fi
      ;;
    *)
      if [ -n "$hits" ]; then
        no "$name: dispatch without run_in_background: false at $(printf '%s' "$hits" | tr '\n' ' ')"
      else
        ok "$name"
      fi
      ;;
  esac
done

# /ship and /review grade Codex output with the same gate; a drift between the
# copies means one of them passes output the other fails.
gate() { sed -n '/^# Codex gate: fail closed/,/^echo "GATE:/p' "$1"; }
if [ -n "$(gate "$ROOT/skills/review/SKILL.md")" ] &&
   [ "$(gate "$ROOT/skills/review/SKILL.md")" = "$(gate "$ROOT/skills/ship/SKILL.md")" ]; then
  ok "codex gate identical in review and ship"
else
  no "codex gate block differs between review and ship (or is missing)"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
