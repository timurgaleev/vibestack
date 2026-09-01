#!/usr/bin/env bash
# test-brand-audit.sh — the brand audit has to bite, and has to not cry wolf.
#
# A check that never fires is indistinguishable from no check at all, and one
# that fires on ordinary English trains people to route around it. Both halves
# are asserted here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/bin/vibe-brand-audit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# flags NAME TEXT — the audit must reject this text
flags() {
  printf '%s\n' "$2" > "$TMP/t.md"
  if "$AUDIT" --text "$TMP/t.md" >/dev/null 2>&1; then
    no "$1 (was accepted)"
  else
    ok "$1"
  fi
}

# allows NAME TEXT — the audit must accept this text
allows() {
  printf '%s\n' "$2" > "$TMP/t.md"
  if "$AUDIT" --text "$TMP/t.md" >/dev/null 2>&1; then
    ok "$1"
  else
    no "$1 (was rejected)"
  fi
}

echo "rejects text that names another project as the source"
flags "a project name"              "See gstack for the original."
flags "a project name, capitalised" "GStack does it this way."
flags "an author handle"            "Taken from garrytan's version."
flags "a tool name"                 "The gbrain integration is removed."
flags "'ported from'"               "Ported from someone else's script."
flags "'copied from'"               "This was copied from another repo."
flags "'copied from the original'"  "The helper was copied from the original version."
flags "'vendored from upstream'"    "These files are vendored from upstream."
flags "'forked from'"               "Forked from an earlier project."
flags "'our fork'"                  "Our fork drops that feature."
flags "'upstream carries'"          "Adds the deny tier upstream carries."
flags "'upstream fixed'"            "The bug upstream fixed in 1.70."
flags "'the upstream repo'"         "See the upstream repo for context."
flags "'parity audit against'"      "A parity audit against v1.77 found this."
# `parity` as a PROCESS NOUN presupposes an external reference to be at parity
# with, even when no "against"/"with" follows. An earlier pattern required one
# of those words, and "upstream parity wave" shipped in a released commit
# subject while the audit reported clean.
flags "'upstream parity'"           "Ships the upstream parity work."
flags "bare 'parity wave'"          "feat: parity wave — stealth and pre-push guard."
flags "bare 'parity audit'"         "Closes the parity audit's remaining findings."
flags "bare 'parity polish'"        "fix: parity polish — hook analytics."
flags "bare 'parity sweep'"         "The parity sweep closed 239 findings."

echo "accepts ordinary engineering English"
# `upstream` is git vocabulary and appears constantly in legitimate prose.
# Banning the bare word would push people to phrase around the check instead.
allows "branch upstream"            "Force-push targets the branch's upstream."
allows "upstream in a pipeline"     "Something upstream broke before we got the payload."
allows "'imported from'"            "escapeHtml is imported from ./render."
# Copying a FILE is ordinary engineering English. Firing on it is how a check
# gets routed around instead of obeyed.
allows "copying a file"             "The index is now copied from the real one."
allows "copying a fixture"          "The fixture is copied from the tracked tree."
allows "an identifier ending gStack" "isBackTrackingStack is reset per rule."
allows "plain release prose"        "Adds a deny tier for recursive deletes of /."
# `parity` as a PROPERTY of our own things is ordinary engineering English and
# has to keep passing, or the check gets routed around instead of obeyed.
allows "'behavioral parity'"        "Behavioral parity is partial, gated on Day 0 Track B."
allows "'CLI/API parity gap'"       "Validation added to close a CLI/API parity gap."
allows "'hard-tier parity'"         "Hard-tier parity becomes possible with a hook config."
allows "'environment parity'"       "Environment parity. Tested in staging?"
allows "'Parity with' a sibling"    "Parity with the sibling load-html path below."

echo "scans commit messages"
# A merged commit message cannot be fixed without rewriting published history,
# so the range check is the one that has to run before a merge.
git init -q "$TMP/repo" 2>/dev/null
(
  cd "$TMP/repo"
  git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "chore: base"
  git -c user.email=t@example.com -c user.name=t commit -q --allow-empty \
    -m "fix: something" -m "Adds the deny tier upstream carries."
) >/dev/null 2>&1
if (cd "$TMP/repo" && "$AUDIT" --commits "HEAD~1..HEAD" >/dev/null 2>&1); then
  no "a commit body naming another project (was accepted)"
else
  ok "a commit body naming another project"
fi

echo "this repo is clean"
"$AUDIT" >/dev/null 2>&1 && ok "tracked files pass the audit" || no "tracked files fail the audit"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
