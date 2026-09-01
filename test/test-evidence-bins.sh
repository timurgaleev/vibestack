#!/usr/bin/env bash
# test-evidence-bins.sh — the five binaries behind the review-staleness,
# release, long-job and outside-voice gates.
#
# Each one exists so a gate can stop trusting prose. A gate is only as good as
# its negative: a check that cannot fail is decoration. So every tool here is
# asserted in both directions — it must pass when it should, and it must FAIL
# when it should, including on absent input.
set -uo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want $3, got $2)"; fi; }

# A throwaway repo, so the suite never depends on the state of this one.
REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
printf 'one\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m base

export VIBESTACK_HOME="$TMP/home"

echo "vibe-tree-hash"
H1=$(cd "$REPO" && "$BIN/vibe-tree-hash")
[ -n "$H1" ] && ok "prints a hash in a clean repo" || no "printed nothing"
printf 'two\n' >> "$REPO/a.txt"
H2=$(cd "$REPO" && "$BIN/vibe-tree-hash")
[ "$H1" != "$H2" ] && ok "an uncommitted edit changes the hash" || no "edit did not change the hash"
git -C "$REPO" checkout -q -- a.txt
H3=$(cd "$REPO" && "$BIN/vibe-tree-hash")
chk "reverting the edit restores the hash" "$H3" "$H1"
# Committing already-seen content must not read as a change: this is the case a
# commit counter gets wrong, and the whole reason the hash exists.
printf 'two\n' >> "$REPO/a.txt"
H4=$(cd "$REPO" && "$BIN/vibe-tree-hash")
git -C "$REPO" commit -q -am second
H5=$(cd "$REPO" && "$BIN/vibe-tree-hash")
chk "committing staged content leaves the hash unchanged" "$H5" "$H4"
# An untracked file is not content under review.
printf 'scratch\n' > "$REPO/untracked.log"
H6=$(cd "$REPO" && "$BIN/vibe-tree-hash")
chk "an untracked file does not move the hash" "$H6" "$H5"
rm -f "$REPO/untracked.log"
(cd "$TMP" && "$BIN/vibe-tree-hash" >/dev/null 2>&1); chk "exit 2 outside a work tree" "$?" "2"

echo "vibe-evidence"
E="$BIN/vibe-evidence"
(cd "$REPO" && "$E" check --label tests >/dev/null 2>&1); chk "an empty ledger fails the check" "$?" "1"
(cd "$REPO" && "$E" run --skill t --label tests -- true >/dev/null 2>&1); chk "run forwards exit 0" "$?" "0"
(cd "$REPO" && "$E" run --skill t --label broken -- false >/dev/null 2>&1); chk "run forwards a nonzero exit" "$?" "1"
(cd "$REPO" && "$E" check --label tests >/dev/null 2>&1); chk "a passing run reads FRESH" "$?" "0"
(cd "$REPO" && "$E" check --label broken >/dev/null 2>&1); chk "a failing run never satisfies the gate" "$?" "1"
printf 'edit\n' >> "$REPO/a.txt"
(cd "$REPO" && "$E" check --label tests >/dev/null 2>&1); chk "editing the tree invalidates the evidence" "$?" "1"
git -C "$REPO" checkout -q -- a.txt
(cd "$REPO" && "$E" check --label tests >/dev/null 2>&1); chk "reverting restores FRESH" "$?" "0"
(cd "$REPO" && "$E" check >/dev/null 2>&1); chk "check without --label is a usage error" "$?" "2"
LEDGER="$VIBESTACK_HOME/projects/repo/evidence.jsonl"
[ -f "$LEDGER" ] || LEDGER=$(find "$VIBESTACK_HOME" -name evidence.jsonl | head -1)
BEFORE=$(wc -l < "$LEDGER" | tr -d ' ')
(cd "$REPO" && "$E" run --skill t --label leak -- echo "AKIAIOSFODNN7EXAMPLE" >/dev/null 2>&1)
RC=$?; AFTER=$(wc -l < "$LEDGER" | tr -d ' ')
chk "a secret-bearing command is refused" "$RC" "2"
chk "and nothing is appended for it" "$AFTER" "$BEFORE"

echo "vibe-version-bump"
V="$BIN/vibe-version-bump"
PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf '1.0.0\n' > "$PROJ/VERSION"
printf '{\n  "name": "x",\n  "version": "1.0.0"\n}\n' > "$PROJ/package.json"
printf '{\n  "name": "x",\n  "version": "1.0.0",\n  "lockfileVersion": 3,\n  "packages": {\n    "": {\n      "name": "x",\n      "version": "1.0.0"\n    },\n    "node_modules/dep": {\n      "version": "9.9.9"\n    }\n  }\n}\n' > "$PROJ/package-lock.json"
"$V" 1.2.3 --root "$PROJ" >/dev/null 2>&1; chk "bump succeeds" "$?" "0"
chk "VERSION updated" "$(cat "$PROJ/VERSION")" "1.2.3"
chk "package.json updated" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PROJ/package.json")" "1.2.3"
chk "lockfile top-level updated" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PROJ/package-lock.json")" "1.2.3"
chk "lockfile self-entry updated" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["packages"][""]["version"])' "$PROJ/package-lock.json")" "1.2.3"
# A dependency's version is not the project's version.
chk "a dependency version is left alone" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["packages"]["node_modules/dep"]["version"])' "$PROJ/package-lock.json")" "9.9.9"
"$V" not-a-version --root "$PROJ" >/dev/null 2>&1; chk "a non-semver argument is rejected" "$?" "2"
# The atomicity claim: a malformed lockfile must abort the whole set, leaving
# VERSION where it was. Without this the bump half-lands and the build breaks
# after the release commit is pushed.
printf '{ this is not json' > "$PROJ/package-lock.json"
"$V" 2.0.0 --root "$PROJ" >/dev/null 2>&1; chk "a malformed lockfile aborts the bump" "$?" "1"
chk "and VERSION is untouched by the aborted bump" "$(cat "$PROJ/VERSION")" "1.2.3"
"$V" 1.2.3 --root "$TMP/nope" >/dev/null 2>&1; chk "a missing root is an error" "$?" "2"

echo "vibe-detach"
D="$BIN/vibe-detach"
ID=$("$D" start --label quick -- sh -c 'echo hello; exit 0')
[ -n "$ID" ] && ok "start prints a job id" || no "start printed no id"
for _ in $(seq 1 30); do
  S=$("$D" status "$ID" 2>/dev/null || true)
  case "$S" in exit:*) break ;; esac
  sleep 1
done
chk "a finished job reports its exit status" "$S" "exit:0"
"$D" status "$ID" >/dev/null 2>&1; chk "status exits 0 for a job that succeeded" "$?" "0"
"$D" log "$ID" 2>/dev/null | grep -q hello && ok "log replays the job's output" || no "log lost the output"
ID2=$("$D" start --label fails -- sh -c 'exit 3')
for _ in $(seq 1 30); do
  S2=$("$D" status "$ID2" 2>/dev/null || true)
  case "$S2" in exit:*) break ;; esac
  sleep 1
done
chk "a failing job reports its own code" "$S2" "exit:3"
"$D" status "$ID2" >/dev/null 2>&1; chk "status exits nonzero for a failed job" "$?" "1"
# An argument containing a space must survive as ONE argument. Re-parsing a
# command from a string is where a filename with a space becomes two files.
ID3=$("$D" start --label spaces -- sh -c 'printf "%s\n" "$0"' "one two three")
for _ in $(seq 1 30); do
  S3=$("$D" status "$ID3" 2>/dev/null || true)
  case "$S3" in exit:*) break ;; esac
  sleep 1
done
chk "an argument with spaces stays one argument" "$("$D" log "$ID3" | tr -d '\n')" "one two three"
# The whole point: the job has to outlive the shell that started it. Started
# from a subshell that exits at once, and polled from here afterwards.
ID4=$(bash -c "\"$D\" start --label survives -- sh -c 'sleep 3; echo alive'")
sleep 1
S4=$("$D" status "$ID4" 2>/dev/null || true)
chk "the job is still running after its launching shell exited" "$S4" "running"
for _ in $(seq 1 30); do
  S4=$("$D" status "$ID4" 2>/dev/null || true)
  case "$S4" in exit:*) break ;; esac
  sleep 1
done
chk "and it finishes on its own" "$S4" "exit:0"
"$D" log "$ID4" | grep -q alive && ok "its output survived too" || no "output lost"

"$D" status nosuchjob >/dev/null 2>&1; chk "an unknown job id is an error" "$?" "2"
"$D" status ../escape >/dev/null 2>&1; chk "a traversing job id is rejected" "$?" "2"

echo "vibe-codex-probe"
P="$BIN/vibe-codex-probe"
# Rung 1 and rung 3 only. Rung 4 is a real round trip and is never run here: a
# test suite that spends tokens is a test suite people switch off.
# The PATH still has to carry bash, env, date and mktemp -- the probe's own
# shebang needs them. Emptying PATH outright tests nothing but the shebang.
# /usr/bin:/bin has those and does not have codex, which npm installs to
# /usr/local/bin or a user prefix. Verified rather than assumed.
BARE="/usr/bin:/bin"
if PATH="$BARE" command -v codex >/dev/null 2>&1; then
  ok "SKIP missing-binary case (codex is installed inside $BARE)"
else
  OUT=$(PATH="$BARE" VIBESTACK_HOME="$TMP/h1" "$P" 2>&1); RC=$?
  chk "no binary on PATH reports missing" "$OUT" "CODEX: missing"
  chk "and exits nonzero" "$RC" "1"
fi
# A fake codex on PATH with no credentials anywhere must stop at rung 3 rather
# than attempt the round trip.
FAKE="$TMP/fakepath"; mkdir -p "$FAKE"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h2" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1); RC=$?
chk "credentials absent reports unauthenticated" "$OUT" "CODEX: unauthenticated"
chk "and exits nonzero" "$RC" "1"
# A cached verdict is replayed without re-probing, and a corrupt cache is
# ignored rather than trusted.
mkdir -p "$TMP/h3"; printf '%s usable\n' "$(date +%s)" > "$TMP/h3/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" VIBESTACK_HOME="$TMP/h3" "$P" 2>&1); RC=$?
chk "a fresh cache is replayed" "$OUT" "CODEX: usable"
chk "and a usable verdict exits 0" "$RC" "0"
mkdir -p "$TMP/h4"; printf 'garbage usable\n' > "$TMP/h4/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h4" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "a corrupt cache is ignored, not trusted" "$OUT" "CODEX: unauthenticated"
mkdir -p "$TMP/h5"; printf '%s usable\n' "$(( $(date +%s) - 99999 ))" > "$TMP/h5/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h5" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "an expired cache is re-probed" "$OUT" "CODEX: unauthenticated"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
