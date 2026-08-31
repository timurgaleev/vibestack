#!/usr/bin/env bash
# hook-extract.sh — SHARED JSON helpers for vibestack PreToolUse hooks.
# Sourced (never executed) by careful/bin/check-careful.sh and
# freeze/bin/check-freeze.sh via a path relative to each hook script.
#
# ONE copy on purpose. Both hooks previously carried their own extractor, and
# the same escaped-quote truncation bug lived in each. Any future parsing fix
# lands here and reaches both hooks by construction.

# vibe_hook_extract_field PAYLOAD FIELD
#   Prints tool_input.FIELD when PAYLOAD is valid JSON and the field is a
#   string ("" when absent or non-string). Returns 1 when no parser is
#   available or the payload is not parseable JSON — the CALLER decides the
#   polarity for that case (careful asks, freeze denies).
#
#   python3 is tried first because it ships with macOS and most Linux distros
#   and is reliably on PATH in a hook environment; node is the fallback.
vibe_hook_extract_field() {
  _vhef_payload="$1"
  _vhef_field="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_vhef_payload" | python3 -c 'import sys,json
field = sys.argv[1]
d = json.loads(sys.stdin.read())
c = d.get("tool_input", {}).get(field, "")
sys.stdout.write(c if isinstance(c, str) else "")' "$_vhef_field" 2>/dev/null && return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$_vhef_payload" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const c=(j&&j.tool_input&&j.tool_input[process.argv[1]])||"";process.stdout.write(typeof c==="string"?c:"")}catch(e){process.exit(3)}})' "$_vhef_field" 2>/dev/null && return 0
  fi
  return 1
}

# vibe_hook_json_string TEXT
#   Prints TEXT as a JSON string literal (surrounding quotes included),
#   encoding quotes, backslashes, control characters and newlines. Never build
#   hook JSON with printf/sed interpolation: a path containing a quote or a
#   newline produces malformed JSON, and Claude Code silently ignores the
#   whole decision — a deny that no-ops exactly when it matters.
vibe_hook_json_string() {
  _vhjs_text="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$_vhjs_text" | python3 -c 'import sys,json; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null && return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$_vhjs_text" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))' 2>/dev/null && return 0
  fi
  # Last-resort fallback (no parser on PATH): strip to a safe charset so the
  # envelope stays valid JSON even if the message loses characters.
  printf '"%s"' "$(printf '%s' "$_vhjs_text" | tr -cd 'a-zA-Z0-9 ._/:@=+-' )"
}

# vibe_hook_decision DECISION REASON
#   Emits the full PreToolUse hookSpecificOutput envelope with REASON safely
#   JSON-encoded. DECISION is "ask" or "deny". The decision MUST be nested
#   under hookSpecificOutput — Claude Code ignores a top-level
#   permissionDecision, which silently no-ops the block.
vibe_hook_decision() {
  _vhd_decision="$1"
  _vhd_reason="$2"
  _vhd_encoded=$(vibe_hook_json_string "$_vhd_reason")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$_vhd_decision" "$_vhd_encoded"
}
