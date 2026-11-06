#!/usr/bin/env bash
# Every inline python call in the pack's shell code must run isolated (-I).
#
# `python3 -c`, `python3 -` and `python3 -m` put the current directory first on
# sys.path, so a json.py in whatever repo the user is standing in runs on
# `import json`. The bins and hooks run from arbitrary working directories, so
# that is code execution from an untrusted checkout.
#
# Three parts:
#   1. the scanner flags exactly the call shapes it should (fixture),
#   2. the ratchet: no unisolated call under bin/, lib/*.sh, skills/*/bin/,
#   3. behaviour: bins run from a hostile cwd import nothing from it, and
#      vibe-config treats keys/values/paths as data, never as python source.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# Prints "<file>:<line>: <text>" for each python call that runs inline code,
# stdin or a module without -I. Comment lines (and shebangs) are skipped.
scan() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      n = split($0, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] !~ /(^|[^A-Za-z0-9_.\/-])python3?$/) continue
        iso = 0; code = 0
        for (j = i + 1; j <= n; j++) {
          t = w[j]
          if (t ~ /^-($|<)/) { code = 1; break }
          if (t !~ /^-[A-Za-z]/) break
          match(t, /^-[A-Za-z]+/)
          letters = substr(t, 2, RLENGTH - 1)
          if (letters ~ /I/) iso = 1
          if (letters ~ /[cm]/) { code = 1; break }
          if (RLENGTH != length(t)) break
        }
        if (code && !iso) { print FILENAME ":" FNR ": " $0; break }
      }
    }
  ' "$@"
}

echo "scanner"
cat > "$TMP/fixture.sh" <<'EOF'
python3 -c 'import json'
X=1 python3 - "$a" <<'PY'
out=$(printf x | python3 -Ec 'import sys')
python3 -m json.tool f
python -c 'pass'
python3 -u -<<EOF2
python3 -I -c 'import json'
python3 -Ic 'import json'
python3 -I - "$a" <<'PY'
exec python3 -I -m json.tool
command -v python3 >/dev/null
python3 --version
python3 "$script"
code_python|code_rust) ;;
# python3 -c 'commented out'
EOF
got="$(scan "$TMP/fixture.sh" | sed -E 's/^[^:]+:([0-9]+):.*/\1/' | tr '\n' ' ')"
[ "$got" = "1 2 3 4 5 6 " ] \
  && ok "scanner flags the six unisolated shapes and nothing else" \
  || no "scanner flagged lines '$got', expected '1 2 3 4 5 6 '"

echo "ratchet"
files=()
for f in "$ROOT"/bin/* "$ROOT"/lib/*.sh "$ROOT"/skills/*/bin/*; do
  [ -f "$f" ] && grep -Iq . "$f" && files+=("$f")
done
hits="$(cd "$ROOT" && scan "${files[@]#"$ROOT/"}")"
if [ -z "$hits" ]; then
  ok "no unisolated python call in ${#files[@]} files"
else
  no "unisolated python calls (add -I):"
  printf '%s\n' "$hits" | sed 's/^/         /'
fi

echo "hostile cwd"
EVIL="$TMP/evil-repo"; MARK="$TMP/imported-from-cwd"
mkdir -p "$EVIL"
printf 'open(%s, "w").close()\n' "'$MARK'" > "$EVIL/json.py"
export VIBESTACK_HOME="$TMP/state"

rm -f "$MARK"
(cd "$EVIL" && "$BIN/vibe-config" get telemetry >/dev/null 2>&1)
[ ! -e "$MARK" ] && ok "vibe-config get imports nothing from cwd" \
  || no "vibe-config get imported json.py from cwd"

rm -f "$MARK"
(cd "$EVIL" && "$BIN/vibe-config" set telemetry off >/dev/null 2>&1)
[ ! -e "$MARK" ] && ok "vibe-config set imports nothing from cwd" \
  || no "vibe-config set imported json.py from cwd"

rm -f "$MARK"
(cd "$EVIL" && "$BIN/vibe-timeline-log" '{"skill":"t","event":"e"}' >/dev/null 2>&1)
[ ! -e "$MARK" ] && ok "stdin-fed python (vibe-timeline-log) imports nothing from cwd" \
  || no "vibe-timeline-log imported json.py from cwd"

echo "vibe-config argv"
export VIBESTACK_HOME="$TMP/argv-state"
INJ="$TMP/injected"
rm -f "$INJ"
"$BIN/vibe-config" get "x') or open('$INJ', 'w').close() or d.get('x" >/dev/null 2>&1
[ ! -e "$INJ" ] && ok "a quote in the key is data, not source" \
  || no "vibe-config executed code spliced in through the key"

rm -f "$INJ"
"$BIN/vibe-config" set plain "x' + str(open('$INJ', 'w').close()) + '" >/dev/null 2>&1
[ ! -e "$INJ" ] && ok "a quote in the value is data, not source" \
  || no "vibe-config executed code spliced in through the value"

"$BIN/vibe-config" set "it's" "O'Brien" >/dev/null 2>&1
out="$("$BIN/vibe-config" get "it's" 2>/dev/null)"
[ "$out" = "O'Brien" ] && ok "quoted key and value round-trip" \
  || no "round-trip of a quoted key/value got '$out'"

out="$("$BIN/vibe-config" set telemetry true 2>/dev/null)"
[ "$out" = "Set telemetry=true" ] && ok "set reports the value as given" \
  || no "set printed '$out'"
out="$("$BIN/vibe-config" get telemetry 2>/dev/null)"
[ "$out" = "true" ] && ok "true is stored as a bool and read back lower-case" \
  || no "bool round-trip got '$out'"

(
  export VIBESTACK_HOME="$TMP/it's here"
  "$BIN/vibe-config" set mode solo >/dev/null 2>&1
  out="$("$BIN/vibe-config" get mode 2>/dev/null)"
  [ "$out" = "solo" ]
) && ok "a quote in the state path works" || no "a quote in the state path broke get/set"

echo
echo "python isolation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
