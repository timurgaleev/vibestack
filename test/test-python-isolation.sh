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
# stdin or a module without -I. Comment lines (and shebangs) are skipped; a
# backslash-continued call is read as one line and reported at its first line.
# The interpreter may be python, python3, python3.12, a path to one, or a
# $PY / $PYTHON variable; -W and -X take a separate argument; stdin counts
# whether it arrives through "-", a redirect, a heredoc or a pipe.
scan() {
  awk '
    function interp(t) {
      sub(/^.*[(`]/, "", t); gsub(/["\047]/, "", t)
      if (t ~ /^([A-Za-z0-9_.\/-]*\/)?python(3(\.[0-9]+)?)?$/) return 1
      return t ~ /^[$][{]?([A-Za-z0-9_]*_)?(PY|PYTHON|PYTHON3|py|python|python3)[}]?$/
    }
    function unisolated(s,   t, k, i, j, p, c, tok, prev, iso, res, skip) {
      k = split(s, t, /[[:space:]]+/)
      for (i = 1; i <= k; i++) {
        if (t[i] == "" || !interp(t[i])) continue
        prev = (i > 1) ? t[i - 1] : ""
        if (prev == "-v" || prev == "-V" || prev == "which" || prev == "type" || prev == "hash" || prev == "command") continue
        iso = 0; res = ""
        for (j = i + 1; j <= k + 1 && res == ""; j++) {
          tok = (j <= k) ? t[j] : ""
          if (tok == "" || tok ~ /^(\||\|\||&&|;|;;|&|\))$/) { res = (prev ~ /\|$/) ? "-" : "none"; break }
          if (tok ~ /^[0-9]*</) { res = "-"; break }
          if (tok ~ /^[0-9]*>/) { if (tok ~ /^[0-9]*>>?$/) j++; continue }
          if (tok == "-" || tok ~ /^-</) { res = "-"; break }
          if (tok !~ /^-/ || tok ~ /^--/) { res = "none"; break }
          skip = 0
          for (p = 2; p <= length(tok); p++) {
            c = substr(tok, p, 1)
            if (c == "I") iso = 1
            else if (c == "c" || c == "m") { res = "-" c; break }
            else if (c == "W" || c == "X") { if (p == length(tok)) skip = 1; break }
            else if (c == "V" || c == "h") { res = "none"; break }
          }
          if (skip) j++
        }
        if (res != "" && res != "none" && !iso) return 1
      }
      return 0
    }
    FNR == 1 { buf = "" }
    buf == "" && /^[[:space:]]*#/ { next }
    {
      if (buf == "") { at = FNR; first = $0 }
      buf = buf (buf == "" ? "" : " ") $0
      if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
      if (unisolated(buf)) print FILENAME ":" at ": " first
      buf = ""
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
python3 \
  -c 'import json'
python3 <<'PY'
/usr/bin/python3 -c 'import json'
"$PY" -c 'import json'
python3.12 -c 'import json'
python3 -X utf8 -c 'import json'
python3 -W ignore - <<'PY'
printf x | python3
python3 -X utf8 script.py
echo "python3 is needed"
printf x | python3 -I
PY=python3
EOF
got="$(scan "$TMP/fixture.sh" | sed -E 's/^[^:]+:([0-9]+):.*/\1/' | tr '\n' ' ')"
want="1 2 3 4 5 6 16 18 19 20 21 22 23 24 "
[ "$got" = "$want" ] \
  && ok "scanner flags every unisolated shape (continued lines, stdin, paths, versions, -X/-W) and nothing else" \
  || no "scanner flagged lines '$got', expected '$want'"

echo "ratchet"
files=()
for f in "$ROOT"/bin/* "$ROOT"/lib/*.sh "$ROOT"/skills/*/bin/* "$ROOT"/install "$ROOT"/uninstall; do
  [ -f "$f" ] && grep -Iq . "$f" && files+=("$f")
done
inst=0
for f in ${files[@]+"${files[@]}"}; do case "$f" in "$ROOT/install"|"$ROOT/uninstall") inst=$((inst + 1)) ;; esac; done
[ "${#files[@]}" -gt 20 ] && [ "$inst" -eq 2 ] \
  && ok "the ratchet scans ${#files[@]} files, install and uninstall included" \
  || no "the ratchet file list is short (${#files[@]} files, $inst of install/uninstall)"
scan_rc=0
hits="$(cd "$ROOT" && scan ${files[@]+"${files[@]#"$ROOT/"}"})" || scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
  no "the scanner itself failed (awk exit $scan_rc) — nothing was checked"
elif [ -z "$hits" ]; then
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
