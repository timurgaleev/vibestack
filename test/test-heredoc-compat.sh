#!/usr/bin/env bash
# Every pack script that feeds a heredoc between 512 B and 64 KiB runs at bash
# compat level 5.0.
#
# From 5.2 on, bash writes a heredoc that fits in a pipe into a pipe instead of
# a temp file, writing the whole body before the reader starts. macOS can hand
# out a 512-byte pipe under kernel memory pressure; a larger body then blocks
# the writer forever and the script hangs with no output. Compat level 5.0
# keeps the temp-file path. A body of 512 B or less always fits; past 64 KiB
# bash uses a temp file anyway. An unquoted heredoc that expands anything has
# a size known only at run time, so it counts as in the window.
#
# Three parts:
#   1. the scanner flags exactly the shapes it should (fixtures),
#   2. the ratchet: every script under bin/, skills/*/bin/ and lib/, and
#      install and uninstall, is clean,
#   3. behaviour: the guard line the bins carry really switches this bash from
#      a pipe to a file (only observable on bash 5.2+).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# Prints "<path>:<line>: <size> B heredoc <tag> without BASH_COMPAT=50 before it"
# (or "... here-string ...") for each offending heredoc or here-string in the
# given files; non-shell files are skipped.
SCAN='
import re, sys

LO, HI = 512, 64 * 1024
OPEN = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(?:([\x27\"])([^\x27\"]+)\2|(\\?)([A-Za-z_][A-Za-z0-9_]*))")
# (( ... )) and $(( ... )) hold arithmetic, where << is a shift.
ARITH = re.compile(r"\(\((?:[^()]|\([^()]*\))*\)\)")
GUARD = re.compile(r"^(\[ .*\] \|\| )?BASH_COMPAT=50[ \t]*(#.*)?$")
HSTR = re.compile(r"<<<[ \t]*")

def herestring(rest):
    """(bytes, expands) for the word after <<<, newline included."""
    if rest.startswith("\x27"):
        j = rest.find("\x27", 1)
        return len(rest[1:j if j > 0 else None].encode("utf-8")) + 1, False
    if rest.startswith("\""):
        j = 1
        while j < len(rest) and rest[j] != "\"":
            j += 2 if rest[j] == "\\" else 1
        word = rest[1:j]
    else:
        word = re.match(r"[^ \t;|&)]*", rest).group(0)
    return len(word.encode("utf-8")) + 1, bool(re.search(r"[$`]", word))

for path in sys.argv[1:]:
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        continue
    first = raw.split(b"\n", 1)[0]
    if not (first.startswith(b"#!") and re.search(rb"\b(ba)?sh\b", first)):
        continue
    lines = raw.decode("utf-8", "replace").split("\n")
    guarded, i = False, 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if GUARD.match(line):
            guarded = True
        if line.lstrip().startswith("#"):
            continue
        for m in HSTR.finditer(line):
            size, expands = herestring(line[m.end():])
            if not guarded and size <= HI and (size > LO or expands):
                print("%s:%d: %d B here-string without BASH_COMPAT=50 before it" % (path, i, size))
        for m in OPEN.finditer(ARITH.sub("", line)):
            dash = m.group(1)
            literal, tag = (True, m.group(3)) if m.group(2) else (bool(m.group(4)), m.group(5))
            start, body = i, []
            while i < len(lines):
                cur = lines[i].lstrip("\t") if dash else lines[i]
                i += 1
                if cur == tag:
                    break
                body.append(cur + "\n")
            text = "".join(body)
            size = len(text.encode("utf-8"))
            expands = not literal and re.search(r"[$`]", text)
            if not guarded and size <= HI and (size > LO or expands):
                print("%s:%d: %d B heredoc %s without BASH_COMPAT=50 before it" % (path, start, size, tag))
'
scan() { python3 -I -c "$SCAN" "$@"; }

body() { python3 -I -c 'import sys; print("x" * (int(sys.argv[1]) - 1))' "$1"; }
mk() { # mk <name> <guard-line-or-empty> <opener> <body-bytes> [after-guard]
  local f="$TMP/fx/$1"
  mkdir -p "$TMP/fx"
  {
    echo '#!/usr/bin/env bash'
    echo '# header'
    [ -n "$2" ] && echo "$2"
    echo "$3"
    body "$4"
    echo 'EOF'
  } > "$f"
}

GUARD_LINE='[ "${BASH_VERSINFO[0]}" -lt 5 ] || BASH_COMPAT=50'

echo "scanner"
mk big-unguarded "" "python3 - <<'EOF'" 4833
mk big-guarded "$GUARD_LINE" "python3 - <<'EOF'" 4833
mk plain-guard "BASH_COMPAT=50" "cat <<EOF" 2000
mk small "" "python3 - <<'EOF'" 300
mk at-floor "" "python3 - <<'EOF'" 512
mk over-ceiling "" "python3 - <<'EOF'" 70000
mk dash-quoted "" 'cat <<-"EOF"' 900
mk in-subst "" "_PY=\$(cat <<'EOF'" 18000
out="$(scan "$TMP"/fx/*)"
printf '%s\n' "$out" | grep -q 'big-unguarded:3: 4833 B heredoc EOF' \
  && ok "flags a 4833 B quoted heredoc with no guard" || no "4833 B heredoc not flagged" "$out"
printf '%s\n' "$out" | grep -q 'dash-quoted' && ok "flags a <<- heredoc with a quoted tag" || no "<<- heredoc not flagged" "$out"
printf '%s\n' "$out" | grep -q 'in-subst' && ok "flags a heredoc inside \$(...)" || no "heredoc in a command substitution not flagged" "$out"
printf '%s\n' "$out" | grep -qE 'big-guarded|plain-guard' \
  && no "a guarded script flagged" "$out" || ok "the version-checked and the plain guard both clear a script"
printf '%s\n' "$out" | grep -qE 'small|at-floor' \
  && no "a body that fits a 512-byte pipe flagged" "$out" || ok "bodies of 512 B and less are not flagged"
printf '%s\n' "$out" | grep -q 'over-ceiling' \
  && no "a body over 64 KiB flagged" "$out" || ok "a body over 64 KiB is not flagged (bash uses a file)"

f="$TMP/fx2/late-guard"; mkdir -p "$TMP/fx2"
{ echo '#!/bin/bash'; echo "cat <<'EOF'"; body 1000; echo 'EOF'; echo 'BASH_COMPAT=50'; } > "$f"
out="$(scan "$f")"
[ -n "$out" ] && ok "a guard after the heredoc does not count" || no "a guard placed after the heredoc cleared it"

f="$TMP/fx2/expands"
{ echo '#!/usr/bin/env bash'; echo 'cat > hook <<EOF'; echo 'run "$prepush_bin" "\$@"'; echo 'EOF'; } > "$f"
out="$(scan "$f")"
[ -n "$out" ] && ok "an unquoted heredoc that expands a variable is flagged at any size" \
  || no "small expanding heredoc not flagged"
f="$TMP/fx2/literal-small"
{ echo '#!/usr/bin/env bash'; echo "cat > hook <<'EOF'"; echo 'run "$prepush_bin"'; echo 'EOF'; } > "$f"
out="$(scan "$f")"
[ -z "$out" ] && ok "a small quoted heredoc is literal and not flagged" || no "small quoted heredoc flagged" "$out"

# A here-string takes the same pipe path: flagged when it expands anything
# (size known only at run time) or holds more than 512 B literally.
f="$TMP/fx2/herestring"
{ echo '#!/usr/bin/env bash'; printf 'grep x <<< "%s"\n' "$(body 2000)"; echo 'while read -r l; do :; done <<< "$out"';
  echo "grep x <<<'abc'"; echo 'grep x <<< plain'; echo 'y=$((1 << 20))'; } > "$f"
out="$(scan "$f")"
printf '%s\n' "$out" | grep -q 'herestring:2: .*here-string' && ok "a 2000 B literal here-string is flagged" || no "large here-string not flagged" "$out"
printf '%s\n' "$out" | grep -q 'herestring:3: .*here-string' && ok "a here-string that expands a variable is flagged" || no "expanding here-string not flagged" "$out"
printf '%s\n' "$out" | grep -qE 'herestring:(4|5|6):' && no "a small literal here-string or a shift flagged" "$out" \
  || ok "small literal here-strings and arithmetic shifts are not flagged"
f="$TMP/fx2/herestring-guarded"
{ echo '#!/usr/bin/env bash'; echo "$GUARD_LINE"; echo 'grep x <<< "$out"'; } > "$f"
out="$(scan "$f")"
[ -z "$out" ] && ok "the guard clears a here-string" || no "guarded here-string flagged" "$out"

# A quoted tag may hold any character but the quote; an arithmetic shift is
# not an opener even when an identifier follows it.
f="$TMP/fx2/oddtag"
{ echo '#!/usr/bin/env bash'; echo 'y=$((1<<NAME)); z=$(( x << SHIFT ))'; echo "python3 -I - <<'END-PY'"; body 2000; echo 'END-PY'; } > "$f"
out="$(scan "$f")"
printf '%s\n' "$out" | grep -q "oddtag:3: 2000 B heredoc END-PY" && ok "a quoted tag holding a dash is read to its terminator" || no "quoted non-identifier tag missed" "$out"
printf '%s\n' "$out" | grep -q 'oddtag:2:' && no "an arithmetic shift read as a heredoc" "$out" || ok "\$((1<<NAME)) is not a heredoc opener"

f="$TMP/fx2/notshell.py"
{ echo '#!/usr/bin/env python3'; echo "x = '''<<'EOF'"; body 2000; echo "EOF'''"; } > "$f"
out="$(scan "$f")"
[ -z "$out" ] && ok "a non-shell script is skipped" || no "python script scanned as shell" "$out"

echo "ratchet: bin/, skills/*/bin/, lib/*.sh, install, uninstall"
targets=()
for f in "$ROOT"/bin/* "$ROOT"/skills/*/bin/* "$ROOT"/lib/*.sh "$ROOT"/install "$ROOT"/uninstall; do
  [ -f "$f" ] && targets+=("$f")
done
scan_rc=0
out="$(scan "${targets[@]}")" || scan_rc=$?
if [ "$scan_rc" -ne 0 ] || [ "${#targets[@]}" -lt 20 ]; then
  no "the scanner did not run over the tree (exit $scan_rc, ${#targets[@]} files)" "$out"
else
  [ -z "$out" ] && ok "every in-window heredoc and here-string runs at compat 5.0 (${#targets[@]} files)" \
    || no "unguarded in-window heredocs or here-strings" "$(printf '%s\n' "$out" | sed "s|$ROOT/||")"
fi
# The bin that every skill preamble calls is the one the hang was found in.
grep -qE '^(\[ .*\] \|\| )?BASH_COMPAT=50' "$ROOT/bin/vibe-learnings-search" \
  && ok "vibe-learnings-search carries the guard" || no "vibe-learnings-search has no BASH_COMPAT=50 line"

echo "behaviour"
guard="$(grep -m1 -E '^(\[ .*\] \|\| )?BASH_COMPAT=50' "$ROOT/bin/vibe-learnings-search" || true)"
probe() { # probe <guard-line-or-empty> — prints FIFO or FILE for the heredoc's stdin
  { echo 'set -euo pipefail'; [ -n "$1" ] && echo "$1"
    echo "python3 -I -c 'import os, stat; print(\"FIFO\" if stat.S_ISFIFO(os.fstat(0).st_mode) else \"FILE\")' <<'EOF'"
    body 4833; echo 'EOF'; } > "$TMP/probe.sh"
  bash "$TMP/probe.sh" 2>&1
}
read -r major minor <<<"$(bash -c 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"')"
if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 2 ]; }; then
  [ "$(probe "")" = FIFO ] && ok "control: bash $major.$minor feeds an unguarded 4833 B heredoc through a pipe" \
    || no "control: expected a pipe without the guard on bash $major.$minor"
  [ -n "$guard" ] && [ "$(probe "$guard")" = FILE ] \
    && ok "with the bins' guard line the same heredoc is a temp file" \
    || no "the bins' guard line did not switch the heredoc to a file (guard: ${guard:-none})"
else
  got="$(probe "${guard:-BASH_COMPAT=50}")"
  [ "$got" = FILE ] || [ "$got" = FIFO ] \
    && ok "bash $major.$minor runs the guard line without complaint (pipe heredocs need 5.2+)" \
    || no "the guard line broke bash $major.$minor" "$got"
fi

echo "heredoc-compat: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
