#!/bin/bash
# Guards the deliberation integration in install.sh.
#
# The plugin is opt-in and the installer deliberately stops after installing it:
# the plugin's own /deliberation:setup owns ~/.claude/rules/deliberation/ (~12k
# tokens loaded every session) and ~/.config/deliberation/config.json. Three
# regressions this locks down:
#  - the flag must stay off by default, or every sync installs a third-party
#    plugin nobody asked for;
#  - the installer must never run that setup script, write the provider config,
#    or enable a paid provider;
#  - a missing `claude` CLI must warn and skip, not abort the whole sync.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config-helpers.sh"
INSTALL="$HERE/../lib/config-install.sh"
SETTINGS="$HERE/../config/claude/settings.json"

# D1: -D flag is parsed and enables the install.
test_flag_parsed() {
  if grep -q 'D) DELIBERATION=true' "$INSTALL"; then
    _pass "D1: -D flag sets DELIBERATION=true"
  else
    _fail "D1: -D flag does not enable deliberation"
  fi
}

# D2: off by default (opt-in, like Caveman and Ponytail).
test_off_by_default() {
  if grep -q 'DELIBERATION=${DELIBERATION:-false}' "$INSTALL"; then
    _pass "D2: deliberation is off by default"
  else
    _fail "D2: deliberation is not off by default"
  fi
}

# D3: installs through the claude plugin CLI, marketplace first.
test_install_commands() {
  local market_line install_line
  market_line=$(grep -n 'claude plugin marketplace add "$DELIBERATION_REPO"' "$INSTALL" | head -1 | cut -d: -f1)
  install_line=$(grep -n 'claude plugin install "$DELIBERATION_PLUGIN"' "$INSTALL" | head -1 | cut -d: -f1)
  if [[ -n "$market_line" && -n "$install_line" && "$install_line" -gt "$market_line" ]]; then
    _pass "D3: marketplace add ($market_line) precedes plugin install ($install_line)"
  else
    _fail "D3: plugin install must follow the marketplace add (add=$market_line install=$install_line)"
  fi
}

# D4: a missing claude CLI warns and skips instead of aborting the sync.
test_missing_cli_skips() {
  if grep -q 'claude CLI not found — skipping deliberation' "$INSTALL"; then
    _pass "D4: missing claude CLI warns and skips"
  else
    _fail "D4: no warn-and-skip path for a missing claude CLI"
  fi
}

# D5: preview mode prints the commands instead of running them.
test_preview_mode() {
  if grep -q 'Preview mode: would install deliberation plugin' "$INSTALL"; then
    _pass "D5: preview mode prints the plugin commands"
  else
    _fail "D5: preview mode has no deliberation branch"
  fi
}

# D6: the installer never runs the plugin's setup, writes its config, or turns
# on a provider. Those belong to /deliberation:setup and to the user.
test_no_setup_side_effects() {
  local hits
  hits=$(grep -nE 'deliberation:setup"|setup\.sh|\.config/deliberation|openrouter|XAI_API_KEY=|OPENROUTER_API_KEY=' "$INSTALL" \
    | grep -v '^\s*#' | grep -vE 'msg_info|msg_warn|^[0-9]+:#' || true)
  if [[ -z "$hits" ]]; then
    _pass "D6: installer runs no setup and writes no provider config"
  else
    _fail "D6: installer touches deliberation setup/config: $hits"
  fi
}

# D7: the plugin and its marketplace are declared in the shipped settings, in
# the same shape as caveman/ponytail (declaring is not installing).
test_settings_declaration() {
  python3 - "$SETTINGS" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["enabledPlugins"].get("deliberation@antonbabenko") is True, "plugin not enabled"
m = s["extraKnownMarketplaces"].get("antonbabenko")
assert m == {"source": {"source": "github", "repo": "antonbabenko/agent-plugins"}}, m
PYEOF
  if [[ $? -eq 0 ]]; then
    _pass "D7: settings.json declares the plugin and its marketplace"
  else
    _fail "D7: settings.json declaration is missing or malformed"
  fi
}

test_flag_parsed
test_off_by_default
test_install_commands
test_missing_cli_skips
test_preview_mode
test_no_setup_side_effects
test_settings_declaration
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
