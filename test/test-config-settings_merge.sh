#!/bin/bash
# Tests the claude/settings.json merge that install.sh performs.
#
# The merge program is a python heredoc inside install.sh rather than a function
# in lib/sync.sh, so this suite extracts it and runs the shipped bytes. Copying
# the logic here instead would test a copy that can silently drift from the one
# users actually run.
#
# What matters: the repo is authoritative for the keys it ships, and everything
# the machine added on its own survives. A regression either way is invisible
# until someone loses their own plugins or a repo change never arrives.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"

INSTALL="$HERE/../lib/config-install.sh"
SRC="$HERE/../config/claude/settings.json"
SB="$(make_sandbox)"
MERGE="$SB/merge.py"

# Extract the merge program: everything between the `merged=$(python3 ...` line
# and its PYEOF terminator.
START=$(grep -n 'merged=\$(python3' "$INSTALL" | head -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^PYEOF$/{print NR; exit}' "$INSTALL")
if [[ -z "$START" || -z "$END" ]]; then
  _fail "S0: could not locate the settings merge block in install.sh"
  echo "----"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
sed -n "$((START+1)),$((END-1))p" "$INSTALL" > "$MERGE"
[[ -s "$MERGE" ]] && _pass "S0: merge program extracted from install.sh" \
                  || _fail "S0: extracted merge program is empty"

# A destination that looks like a real machine: its own marketplace, its own
# plugin, its own permission, its own theme, and a key the repo never ships.
cat > "$SB/dst.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "somebody-else": { "source": { "source": "github", "repo": "someone/their-pack" } }
  },
  "enabledPlugins": { "their-plugin@somebody-else": true },
  "permissions": {
    "allow": ["Bash(their-own-tool:*)"],
    "deny": ["Bash(their-own-danger:*)"],
    "defaultMode": "acceptEdits"
  },
  "theme": "dark",
  "model": "some-local-model"
}
JSON

python3 "$MERGE" "$SRC" "$SB/dst.json" > "$SB/out.json" 2>"$SB/err.txt"
if [[ $? -ne 0 || ! -s "$SB/out.json" ]]; then
  _fail "S1: merge failed — $(head -1 "$SB/err.txt")"
  echo "----"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
_pass "S1: merge ran and produced output"

check() { # check <jq-ish python expr> <name>
  if python3 -c "
import json,sys
d=json.load(open('$SB/out.json'))
sys.exit(0 if ($1) else 1)
" 2>/dev/null; then _pass "$2"; else _fail "$2"; fi
}

# Destination-owned state survives.
check "'somebody-else' in d['extraKnownMarketplaces']"            "S2: a machine's own marketplace survives"
check "'their-plugin@somebody-else' in d['enabledPlugins']"        "S3: a machine's own plugin survives"
check "'Bash(their-own-tool:*)' in d['permissions']['allow']"      "S4: a machine's own allow entry survives"
check "'Bash(their-own-danger:*)' in d['permissions']['deny']"     "S5: a machine's own deny entry survives"
check "d.get('model') == 'some-local-model'"                       "S6: a key the repo does not ship survives"

# Repo-shipped state arrives.
check "'caveman' in d['extraKnownMarketplaces'] and 'ponytail' in d['extraKnownMarketplaces']" \
                                                                   "S7: repo marketplaces are added"
check "d['enabledPlugins'].get('caveman@caveman') is True"         "S8: repo plugin arrives enabled"
check "d.get('tui') == 'fullscreen'"                               "S9: repo scalar arrives"
check "d.get('theme') == 'auto'"                                   "S10: repo wins on a scalar the machine also set"

# Guard the thing that makes shipping plugin state safe in the first place:
# every plugin the repo ships must still be there alongside the local one.
check "all(k in d['enabledPlugins'] for k in json.load(open('$SRC'))['enabledPlugins'])" \
                                                                   "S11: no repo plugin is dropped by the merge"

# deliberation is declared here but installed only with `install.sh -D`, so the
# declaration must arrive intact — plugin and marketplace together, or the
# plugin resolves to a marketplace the machine has never heard of.
check "d['enabledPlugins'].get('deliberation@antonbabenko') is True" \
                                                                   "S12: deliberation plugin arrives enabled"
check "d['extraKnownMarketplaces'].get('antonbabenko', {}).get('source', {}).get('repo') == 'antonbabenko/agent-plugins'" \
                                                                   "S13: deliberation marketplace arrives with its source"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
