#!/bin/bash
# config/copilot/ is generated from config/claude/: copilot-instructions.md from
# CLAUDE.md + rules/ by scripts/gen-codex-agents.py --target copilot, and
# agents/*.agent.md from agents/*.md by scripts/gen-copilot-agents.py. This
# suite fails when either drifts from its source, or when the output carries
# something Copilot CLI cannot act on.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$ROOT/scripts/gen-codex-agents.py"
GEN_AGENTS="$ROOT/scripts/gen-copilot-agents.py"
OUT="$ROOT/config/copilot/copilot-instructions.md"
SRC_AGENTS="$ROOT/config/claude/agents"
OUT_AGENTS="$ROOT/config/copilot/agents"
SETTINGS="$ROOT/config/copilot/settings.json"

RULE_NAME=$(sed -n 's/^RULE_NAME = r"\(.*\)"$/\1/p' "$GEN")
[[ -n "$RULE_NAME" ]] || { echo "  FAIL: could not read RULE_NAME from $GEN"; exit 1; }

# Unfenced text only: fenced examples are quoted on purpose.
unfenced() { awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f' "$1"; }

# G1: the committed copilot-instructions.md matches the generator's output.
if python3 "$GEN" --target copilot --check >/dev/null 2>&1; then
  _pass "G1: copilot/copilot-instructions.md is up to date"
else
  _fail "G1: copilot/copilot-instructions.md is stale or missing — run scripts/gen-codex-agents.py --target copilot"
fi

# G2: Copilot loads one personal instructions file; a rules/ link points at
# nothing it will ever read.
if [[ ! -f "$OUT" ]]; then
  _fail "G2: $OUT missing"
elif unfenced "$OUT" | grep -qE "rules/${RULE_NAME}\.md"; then
  _fail "G2: dangling rules/*.md reference outside a fenced block"
else
  _pass "G2: no dangling rules/*.md references"
fi

# G3: no Claude Code tool names and no Codex `$name` skill syntax. Copilot
# invokes skills as /name.
if [[ -f "$OUT" ]]; then
  leaked=""
  for term in EnterPlanMode ExitPlanMode "Skill tool" "Codex Usage"; do
    grep -q "$term" "$OUT" && leaked="$leaked [$term]"
  done
  unfenced "$OUT" | grep -qE '`\$[a-z][a-z0-9-]*`' && leaked="$leaked [\$name skill syntax]"
  grep -q '~/.agents/skills' "$OUT" && leaked="$leaked [~/.agents/skills]"
  if [[ -n "$leaked" ]]; then
    _fail "G3: copilot-instructions.md names things Copilot does not have:$leaked"
  else
    _pass "G3: no Claude-only tools, no \$name syntax, no codex skill root"
  fi
else
  _fail "G3: $OUT missing"
fi

# G3b: the authorship rule arrives intact — Copilot's own default adds a
# co-author trailer, so the instruction not to is load-bearing here.
if [[ -f "$OUT" ]] && grep -q 'Co-Authored-By' "$OUT" \
   && grep -q '## Authorship' "$OUT" && grep -q 'includeCoAuthoredBy' "$OUT"; then
  _pass "G3b: authorship rule (no AI co-author trailer) is in copilot-instructions.md"
else
  _fail "G3b: copilot-instructions.md lacks the authorship rule or the includeCoAuthoredBy note"
fi

# G3c: skills are routed as /name and resolved from the copilot skill root.
if [[ -f "$OUT" ]] && grep -q '## Copilot Usage' "$OUT" \
   && grep -q '~/.copilot/skills' "$OUT" && grep -q '`/review`' "$OUT"; then
  _pass "G3c: Copilot Usage section routes skills as /name from ~/.copilot/skills"
else
  _fail "G3c: Copilot Usage section missing or does not route skills"
fi

# G4: every Claude agent has a Copilot twin and nothing else is shipped.
want=$(cd "$SRC_AGENTS" && for f in *.md; do [[ "$f" == README.md ]] || echo "${f%.md}"; done | sort)
got=$( [[ -d "$OUT_AGENTS" ]] && cd "$OUT_AGENTS" && for f in *.agent.md; do [[ -e "$f" ]] && echo "${f%.agent.md}"; done | sort)
if [[ -n "$want" && "$want" == "$got" ]]; then
  _pass "G4: $(wc -l <<<"$want" | tr -d ' ') agents, one .agent.md each, no extras"
else
  _fail "G4: agent sets differ: $(diff <(echo "$want") <(echo "$got") | grep '^[<>]' | tr '\n' ' ')"
fi

# G5: each .agent.md is loadable as Copilot documents it.
g5=$(python3 - "$OUT_AGENTS" <<'PY'
import json, pathlib, sys
bad = []
d = pathlib.Path(sys.argv[1])
for p in sorted(d.glob("*.agent.md")) if d.is_dir() else []:
    text = p.read_text()
    if not text.startswith("---\n"):
        bad.append(f"{p.name}: no frontmatter"); continue
    head, _, body = text[4:].partition("\n---\n")
    keys = {}
    for line in head.splitlines():
        k, _, v = line.partition(":")
        keys[k.strip()] = v.strip()
    if not keys.get("description"):
        bad.append(f"{p.name}: no description")
    if "model" in keys:
        bad.append(f"{p.name}: carries a model key")
    if keys.get("name") != p.name[: -len(".agent.md")]:
        bad.append(f"{p.name}: name {keys.get('name')!r} != filename")
    for k in ("description", "tools"):
        if k in keys:
            try:
                json.loads(keys[k])
            except ValueError:
                bad.append(f"{p.name}: {k} is not a quoted scalar/flow list")
    if len(body) > 30000:
        bad.append(f"{p.name}: body {len(body)} chars > 30000")
print("\n".join(bad))
PY
)
if [[ -d "$OUT_AGENTS" && -z "$g5" ]]; then
  _pass "G5: every .agent.md has description, quoted values, no model, name == filename, body <= 30000"
else
  _fail "G5: ${g5:-config/copilot/agents missing}"
fi

# G6: the committed agents match the generator's output.
if python3 "$GEN_AGENTS" --check >/dev/null 2>&1; then
  _pass "G6: copilot/agents is up to date"
else
  _fail "G6: copilot/agents is stale or missing — run scripts/gen-copilot-agents.py"
fi

# G7: settings.json ships exactly one key, the one that keeps Copilot from
# adding a co-author trailer to commits. Anything else is unvetted policy.
if [[ -f "$SETTINGS" ]] && python3 -c '
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == {"includeCoAuthoredBy": False} else 1)
' "$SETTINGS" 2>/dev/null; then
  _pass "G7: settings.json is exactly {\"includeCoAuthoredBy\": false}"
else
  _fail "G7: config/copilot/settings.json missing or not exactly {\"includeCoAuthoredBy\": false}"
fi

# G8: codex output is untouched by the --target switch.
if python3 "$GEN" --check >/dev/null 2>&1; then
  _pass "G8: codex/AGENTS.md still matches the default target"
else
  _fail "G8: the default (codex) target drifted"
fi

echo "  ---"
echo "  passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
