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
# A file that is `git add`-ed but never committed lives in the index, not in
# HEAD. Seeding the scratch index from HEAD dropped it, and `add -u` only
# refreshes paths already present -- so editing it moved nothing (a gate would
# pass on stale evidence) and committing it moved the hash though no byte on
# disk had changed.
printf 'v1\n' > "$REPO/staged-new.txt"
git -C "$REPO" add staged-new.txt
SN1=$(cd "$REPO" && "$BIN/vibe-tree-hash")
printf 'v2-changed\n' > "$REPO/staged-new.txt"
SN2=$(cd "$REPO" && "$BIN/vibe-tree-hash")
[ "$SN1" != "$SN2" ] && ok "editing a staged-but-uncommitted file moves the hash" \
                     || no "editing a staged-but-uncommitted file left the hash unmoved"
git -C "$REPO" add staged-new.txt
git -C "$REPO" commit -q -m staged-new
SN3=$(cd "$REPO" && "$BIN/vibe-tree-hash")
chk "committing it leaves the hash alone" "$SN3" "$SN2"

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
# The AWS documentation key (AKIA...EXAMPLE) is a placeholder to every sink; a live shape is not.
(cd "$REPO" && "$E" run --skill t --label leak -- echo "AKIA""QWERTYUIOPASDFGH" >/dev/null 2>&1)
RC=$?; AFTER=$(wc -l < "$LEDGER" | tr -d ' ')
chk "a secret-bearing command is refused" "$RC" "2"
chk "and nothing is appended for it" "$AFTER" "$BEFORE"
# The most recent record decides. Taking any historical pass meant a label that
# passed and then failed at the same tree still reported FRESH -- the newer
# truth losing to the older one is the one direction a gate may never fail.
(cd "$REPO" && "$E" run --skill t --label super -- true  >/dev/null 2>&1)
(cd "$REPO" && "$E" check --label super >/dev/null 2>&1); chk "a fresh pass reads FRESH" "$?" "0"
(cd "$REPO" && "$E" run --skill t --label super -- false >/dev/null 2>&1)
(cd "$REPO" && "$E" check --label super >/dev/null 2>&1); chk "a newer failure supersedes the older pass" "$?" "1"
# Corruption must fail closed: silently skipping an unreadable record lets a
# stale pass outlive the failure that was meant to replace it.
(cd "$REPO" && "$E" run --skill t --label torn -- true >/dev/null 2>&1)
printf '{"not json\n' >> "$LEDGER"
(cd "$REPO" && "$E" check --label torn >/dev/null 2>&1); chk "an unreadable ledger line fails closed" "$?" "1"
# Trim the torn line back off so later cases still have a usable ledger.
python3 - "$LEDGER" <<'PYTRIM'
import sys
p = sys.argv[1]
keep = [l for l in open(p) if l.strip().startswith("{") and l.rstrip().endswith("}")]
open(p, "w").writelines(keep)
PYTRIM
# The slug alone is not an identity -- two projects can share one, and their
# ledgers then share a file.
LAST_REPO=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read().strip().split(chr(10))[-1]).get("repo",""))' "$LEDGER")
[ -n "$LAST_REPO" ] && ok "a record carries the repo it was taken in" || no "record has no repo field"

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
# json.dumps escapes non-ASCII by default, which rewrites an em dash in a
# description into \u2014 -- a diff nobody asked for, in a file the bump is
# only supposed to touch one field of.
printf '{\n  "name": "x",\n  "version": "1.2.3",\n  "description": "a \xe2\x80\x94 dash"\n}\n' > "$PROJ/package.json"
"$V" 1.2.4 --root "$PROJ" >/dev/null 2>&1
grep -q 'u2014' "$PROJ/package.json" && no "the bump escaped a non-ASCII character" \
                                     || ok "non-ASCII in an untouched field survives the bump"
chk "and the version still moved" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$PROJ/package.json")" "1.2.4"
# Put the whole fixture back -- VERSION moved too, and the abort case below
# asserts against it.
printf '1.2.3\n' > "$PROJ/VERSION"
printf '{\n  "name": "x",\n  "version": "1.2.3"\n}\n' > "$PROJ/package.json"

"$V" not-a-version --root "$PROJ" >/dev/null 2>&1; chk "a non-semver argument is rejected" "$?" "2"
# Some projects version MAJOR.MINOR.PATCH.MICRO, and /ship accepts that shape.
# The bump refusing it leaves the caller hand-writing files again.
FOUR="$TMP/four"; mkdir -p "$FOUR"
printf '1.2.3.3\n' > "$FOUR/VERSION"
printf '{\n  "name": "q",\n  "version": "1.2.3.3"\n}\n' > "$FOUR/package.json"
"$V" 1.2.3.4 --root "$FOUR" >/dev/null 2>&1; chk "a four-part version is accepted" "$?" "0"
chk "and lands in VERSION" "$(cat "$FOUR/VERSION")" "1.2.3.4"
chk "and in package.json" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$FOUR/package.json")" "1.2.3.4"
"$V" 1.2.3.4.5 --root "$FOUR" >/dev/null 2>&1; chk "a five-part version is still rejected" "$?" "2"
"$V" 1.2.3. --root "$FOUR" >/dev/null 2>&1; chk "a trailing dot is still rejected" "$?" "2"
chk "and the rejected bumps left VERSION alone" "$(cat "$FOUR/VERSION")" "1.2.3.4"
# The atomicity claim: a malformed lockfile must abort the whole set, leaving
# VERSION where it was. Without this the bump half-lands and the build breaks
# after the release commit is pushed.
printf '{ this is not json' > "$PROJ/package-lock.json"
"$V" 2.0.0 --root "$PROJ" >/dev/null 2>&1; chk "a malformed lockfile aborts the bump" "$?" "1"
chk "and VERSION is untouched by the aborted bump" "$(cat "$PROJ/VERSION")" "1.2.3"
# os.replace on a symlink replaces the LINK with a regular file and leaves the
# real target stale. The link has to survive and its target has to change.
LINKED="$TMP/linked"; mkdir -p "$LINKED/real"
printf '1.0.0\n' > "$LINKED/real/VERSION"
ln -s real/VERSION "$LINKED/VERSION"
printf '{\n  "name": "y",\n  "version": "1.0.0"\n}\n' > "$LINKED/real/package.json"
ln -s real/package.json "$LINKED/package.json"
chmod 0640 "$LINKED/real/package.json"
"$V" 3.1.0 --root "$LINKED" >/dev/null 2>&1
[ -L "$LINKED/VERSION" ] && ok "a symlinked VERSION is still a symlink after the bump" || no "the symlink was replaced by a regular file"
chk "and its target carries the new version" "$(cat "$LINKED/real/VERSION")" "3.1.0"
chk "a symlinked package.json updates its target too" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$LINKED/real/package.json")" "3.1.0"
# Rewriting bytes through a temp file would hand the result the caller's umask.
chk "the file keeps its own mode" "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$LINKED/real/package.json")" "0o640"

# The rollback claim: if a rename fails PARTWAY, the ones already done are
# undone. Staging cannot be made to fail here -- that path aborts before any
# rename and is covered above -- so the failure is injected into os.replace
# itself, via a sitecustomize the interpreter imports at startup. That runs the
# real rollback code rather than a stand-in for it.
INJ="$TMP/inject"; mkdir -p "$INJ"
cat > "$INJ/sitecustomize.py" <<'PYINJ'
import os
_real = os.replace
_calls = {"n": 0}


def _replace(src, dst, **kw):
    _calls["n"] += 1
    # Let the first file land, then fail. That is the state the rollback
    # exists for: some renamed, some not.
    if _calls["n"] >= 2:
        raise OSError(28, "No space left on device (injected)")
    return _real(src, dst, **kw)


os.replace = _replace
PYINJ
ROLL="$TMP/rollback"; mkdir -p "$ROLL"
printf '5.0.0\n' > "$ROLL/VERSION"
printf '{\n  "name": "z",\n  "version": "5.0.0"\n}\n' > "$ROLL/package.json"
printf '{\n  "name": "z",\n  "version": "5.0.0",\n  "lockfileVersion": 3,\n  "packages": {\n    "": {\n      "version": "5.0.0"\n    }\n  }\n}\n' > "$ROLL/package-lock.json"
ROLLOUT=$(PYTHONPATH="$INJ" "$V" 6.0.0 --root "$ROLL" 2>/dev/null)
RC=$?
chk "a rename failing partway exits nonzero" "$RC" "1"
# The report used to be printed before the writes, so a run that rolled back
# still announced every file as bumped -- telling the reader the opposite of
# what happened.
printf '%s' "$ROLLOUT" | grep -q '^bumped' && no "a rolled-back run still claimed it bumped files" \
                                           || ok "a rolled-back run claims nothing was bumped"
chk "the file that had already been renamed is restored" "$(cat "$ROLL/VERSION")" "5.0.0"
chk "the file that never landed is untouched" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROLL/package.json")" "5.0.0"
chk "and so is the lockfile" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROLL/package-lock.json")" "5.0.0"
[ -z "$(ls "$ROLL"/*.vibe-bump.*.tmp 2>/dev/null)" ] && ok "no staging temp files are left behind" \
                                                    || no "staging temp files survived the rollback"
# The same fixture must still bump cleanly once nothing is injected -- a
# rollback that leaves the tree unusable would pass every check above.
CLEANOUT=$("$V" 6.0.0 --root "$ROLL" 2>/dev/null)
chk "the same tree still bumps cleanly afterwards" "$(cat "$ROLL/VERSION")" "6.0.0"
# Reports name the file the caller asked about. relpath against an unresolved
# root turned a realpath'd target into a run of "../.." on macOS, where /var is
# itself a symlink.
printf '%s' "$CLEANOUT" | grep -q '\.\./' && no "the report leaked a traversal path" \
                                            || ok "the report names files plainly"
printf '%s' "$CLEANOUT" | grep -q '^bumped VERSION -> 6.0.0$' && ok "and says exactly what landed" \
                                                              || no "report line not in the expected shape"

"$V" 1.2.3 --root "$TMP/nope" >/dev/null 2>&1; chk "a missing root is an error" "$?" "2"

echo "vibe-next-version"
# The pick is only as good as the queue it saw. Every case asserts `complete`:
# a claim the bin could not read is a slot it may hand out twice, and a caller
# that cannot tell that from a clean read reports "no drift" on a collision.
NV="$BIN/vibe-next-version"
NQ="$TMP/nq"; mkdir -p "$NQ/bin" "$NQ/heads"
cat > "$NQ/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "${NQ_GH_DOWN:-0}" = 1 ] && exit 1
case "$1 $2" in
  "pr list") cat "$NQ_DIR/prs.json" ;;
  "pr view") case "$*" in *number*) echo "${NQ_PRN:-}" ;; *) echo main ;; esac ;;
  "repo view") [ "${NQ_OWNER_DOWN:-0}" = 1 ] && exit 1; echo me ;;
  "api "*)
    ref="${2##*ref=}"; f="$NQ_DIR/heads/$ref"
    [ -f "$f" ] || f="$NQ_DIR/heads/default"
    [ -f "$f" ] || exit 1
    base64 < "$f" | tr -d '\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$NQ/bin/glab" <<'SH'
#!/usr/bin/env bash
[ "${NQ_GL:-0}" = 1 ] || exit 1
case "$1 $2" in
  "mr list") cat "$NQ_DIR/mrs.json" ;;
  "api "*)
    ref="${2##*ref=}"; f="$NQ_DIR/heads/$ref"
    [ -f "$f" ] || f="$NQ_DIR/heads/default"
    [ -f "$f" ] || exit 1
    printf '{"content":"%s"}' "$(base64 < "$f" | tr -d '\n')" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$NQ/bin/gh" "$NQ/bin/glab"
nq_pr() { # nq_pr NUMBER BRANCH OWNER
  printf '{"number":%s,"headRefName":"%s","headRepositoryOwner":{"login":"%s"},"url":"https://x/pr/%s"}' "$1" "$2" "$3" "$1"
}
nv() { PATH="$NQ/bin:$PATH" NQ_DIR="$NQ" "$NV" "$@"; }
jf() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

printf '[%s,%s]\n' "$(nq_pr 21 feat/a me)" "$(nq_pr 22 feat/b me)" > "$NQ/prs.json"
printf '1.20.1\n' > "$NQ/heads/feat%2Fa"
printf '1.20.2\n' > "$NQ/heads/feat%2Fb"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "a readable queue is complete" "$(jf 'd.get("complete")' <<<"$OUT")" "True"
chk "and the pick steps past both claims" "$(jf 'd["version"]' <<<"$OUT")" "1.20.3"

rm "$NQ/heads/feat%2Fb"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "an unreadable head VERSION makes the queue incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
chk "and the unread PR is named in a warning" "$(jf 'any("#22" in w for w in d["warnings"])' <<<"$OUT")" "True"

printf 'not-a-version\n' > "$NQ/heads/feat%2Fb"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "a malformed head VERSION makes the queue incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
# A claim is outside input: a 5000-digit component must read as malformed, not
# crash the bin, which callers read as "offline" and skip the queue check.
python3 -c 'print("1.2." + "9" * 5000)' > "$NQ/heads/feat%2Fb"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "an oversized VERSION component is a malformed claim, not a crash" "$(jf 'd["offline"], d.get("complete")' <<<"$OUT")" "(False, False)"
chk "and its warning quotes a bounded prefix" "$(jf 'max(len(w) for w in d["warnings"]) < 200' <<<"$OUT")" "True"

# A fork PR's head is not readable through our repo, so its VERSION is never
# seen -- but it still takes a slot when it merges.
printf '1.20.2\n' > "$NQ/heads/feat%2Fb"
printf '[%s,%s]\n' "$(nq_pr 21 feat/a me)" "$(nq_pr 23 feat/c someone)" > "$NQ/prs.json"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "a fork PR left unread makes the queue incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
chk "and the fork PR is named in a warning" "$(jf 'any("#23" in w for w in d["warnings"])' <<<"$OUT")" "True"
printf '[%s]\n' "$(nq_pr 21 feat/a me)" > "$NQ/prs.json"
OUT=$(NQ_OWNER_DOWN=1 nv --base main --bump patch --current-version 1.20.0)
chk "an unresolved repo owner makes the queue incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"

# gh caps the list at --limit. A full page means there may be more PRs behind
# it, so the queue is not known to be whole even when every row read cleanly.
printf '1.20.0\n' > "$NQ/heads/default"
nq_rows() { # nq_rows COUNT KEY -> same-repo rows whose heads carry the base VERSION
  python3 -c '
import json, sys
n, key = int(sys.argv[1]), sys.argv[2]
if key == "number":
    rows = [{"number": i, "headRefName": "f/%d" % i,
             "headRepositoryOwner": {"login": "me"}, "url": ""} for i in range(1, n + 1)]
else:
    rows = [{"iid": i, "source_branch": "f/%d" % i, "source_project_id": 1,
             "target_project_id": 1, "web_url": ""} for i in range(1, n + 1)]
print(json.dumps(rows))' "$1" "$2"
}
nq_rows 200 number > "$NQ/prs.json"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "a list that hit the limit is incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
nq_rows 199 number > "$NQ/prs.json"
OUT=$(nv --base main --bump patch --current-version 1.20.0)
chk "one row short of the limit is complete" "$(jf 'd.get("complete")' <<<"$OUT")" "True"

# GitLab serves at most 100 rows a page whatever is asked for, so a page of
# 100 is the full-page signal there.
NQGL() { NQ_GL=1 NQ_GH_DOWN=1 nv "$@"; }
nq_rows 2 iid > "$NQ/mrs.json"
OUT=$(NQGL --base main --bump patch --current-version 1.20.0)
chk "a readable GitLab queue is complete" "$(jf 'd["host"], d.get("complete")' <<<"$OUT")" "('gitlab', True)"
nq_rows 100 iid > "$NQ/mrs.json"
OUT=$(NQGL --base main --bump patch --current-version 1.20.0)
chk "a full GitLab page is incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
rm "$NQ/heads/default"
# Value: protects=GitLab's per-MR read failure clearing complete, a path separate from GitHub's; fails_when=the gitlab loop warns but keeps complete=True; why_new=the GitLab rows above read every head; seam=none
nq_rows 2 iid > "$NQ/mrs.json"
printf '1.20.1\n' > "$NQ/heads/f%2F1"
OUT=$(NQGL --base main --bump patch --current-version 1.20.0)
chk "an unreadable MR head VERSION makes the GitLab queue incomplete" \
  "$(jf 'd["host"], d.get("complete"), any("!2" in w for w in d["warnings"])' <<<"$OUT")" "('gitlab', False, True)"
rm "$NQ/heads/f%2F1"
# The files API resolves a branch name in the target project, so a fork MR on
# "release" would report our own release branch's VERSION as its claim.
printf '[{"iid":5,"source_branch":"release","source_project_id":2,"target_project_id":1,"web_url":""}]\n' > "$NQ/mrs.json"
printf '1.20.9\n' > "$NQ/heads/release"
OUT=$(NQGL --base main --bump patch --current-version 1.20.0)
chk "a GitLab fork MR is not read through our branch of the same name" \
  "$(jf 'd.get("complete"), [c["version"] for c in d["claimed"]], any("!5" in w for w in d["warnings"])' <<<"$OUT")" "(False, [], True)"
rm "$NQ/heads/release"

# Four-part versions: the bin used to call these offline and fall back to a
# bump that ignored the queue entirely.
printf '[%s]\n' "$(nq_pr 31 feat/m me)" > "$NQ/prs.json"
printf '1.2.3.5\n' > "$NQ/heads/feat%2Fm"
OUT=$(nv --base main --bump micro --current-version 1.2.3.4)
chk "a four-part base is not offline" "$(jf 'd["offline"]' <<<"$OUT")" "False"
chk "a micro bump steps past a four-part claim" "$(jf 'd["version"]' <<<"$OUT")" "1.2.3.6"
chk "and the four-part queue is complete" "$(jf 'd.get("complete")' <<<"$OUT")" "True"
chk "a patch bump of a four-part version zeroes MICRO" \
  "$(jf 'd["version"]' <<<"$(nv --base main --bump patch --current-version 1.2.3.4)")" "1.2.4.0"
chk "a major bump keeps four parts" \
  "$(jf 'd["version"]' <<<"$(nv --base main --bump major --current-version 1.2.3.4)")" "2.0.0.0"
chk "micro on a three-part version is still a patch bump" \
  "$(jf 'd["version"]' <<<"$(nv --base main --bump micro --current-version 1.2.3)")" "1.2.4"
# A three-part claim against a four-part base compares by value: 1.2.4 is
# ahead of 1.2.3.4 and is the slot a patch bump would take.
printf '1.2.4\n' > "$NQ/heads/feat%2Fm"
chk "a three-part claim collides with the four-part pick it equals" \
  "$(jf 'd["version"]' <<<"$(nv --base main --bump patch --current-version 1.2.3.4)")" "1.2.5.0"

# No PR host: the remote's branch heads are the next best queue. A head whose
# commit was never fetched cannot be read, so the result says so.
GO="$TMP/gitq"; mkdir -p "$GO"
# Fixture git ignores the machine's global config: a global signing key or
# hooks path would otherwise make these commits fail or prompt.
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
g init -q --bare -b main "$GO/origin.git"
g init -q -b main "$GO/seed"
g -C "$GO/seed" config user.email t@example.com
g -C "$GO/seed" config user.name t
printf '1.20.0\n' > "$GO/seed/VERSION"
g -C "$GO/seed" add VERSION && g -C "$GO/seed" commit -q -m base
g -C "$GO/seed" remote add origin "$GO/origin.git"
g -C "$GO/seed" push -q origin main
g -C "$GO/seed" checkout -q -b feat/a
printf '1.20.1\n' > "$GO/seed/VERSION"; g -C "$GO/seed" commit -q -am a
g -C "$GO/seed" push -q origin feat/a
g -C "$GO/seed" checkout -q -b docs/x main
printf 'x\n' > "$GO/seed/x.txt"; g -C "$GO/seed" add x.txt; g -C "$GO/seed" commit -q -m x
g -C "$GO/seed" push -q origin docs/x
g clone -q "$GO/origin.git" "$GO/work"
g -C "$GO/seed" checkout -q -b feat/b main
printf '1.20.2\n' > "$GO/seed/VERSION"; g -C "$GO/seed" commit -q -am b
g -C "$GO/seed" push -q origin feat/b
OUT=$(cd "$GO/work" && NQ_GH_DOWN=1 nv --base main --bump patch --current-version 1.20.0)
chk "with no PR host the remote branches are read" "$(jf 'd["host"]' <<<"$OUT")" "git"
chk "a fetched branch's VERSION is a claim" "$(jf '[c["branch"] for c in d["claimed"]]' <<<"$OUT")" "['feat/a']"
chk "and the pick steps past it" "$(jf 'd["version"]' <<<"$OUT")" "1.20.2"
chk "an unfetched head leaves the git queue incomplete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
chk "and is named in a warning" "$(jf 'any("feat/b" in w for w in d["warnings"])' <<<"$OUT")" "True"
chk "it is still reported offline -- branch heads are not the PR queue" "$(jf 'd["offline"]' <<<"$OUT")" "True"
g -C "$GO/work" fetch -q origin
OUT=$(cd "$GO/work" && NQ_GH_DOWN=1 nv --base main --bump patch --current-version 1.20.0)
chk "once fetched, that head is a claim too" "$(jf 'd["version"]' <<<"$OUT")" "1.20.3"
chk "a branch-head queue is never called complete" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
# Without a PR number there is nothing for --exclude-pr to match; a re-ship
# names its own branch so its pushed head is not read as somebody's claim.
OUT=$(cd "$GO/work" && NQ_GH_DOWN=1 nv --base main --bump patch --current-version 1.20.0 --exclude-branch feat/b)
chk "--exclude-branch drops that branch's head" "$(jf '[c["branch"] for c in d["claimed"]]' <<<"$OUT")" "['feat/a']"
chk "and the pick is the slot it held" "$(jf 'd["version"]' <<<"$OUT")" "1.20.2"
# A head whose VERSION is not text is a malformed claim, not a missing one.
g -C "$GO/seed" checkout -q -b feat/bin main
printf '\377\376\n' > "$GO/seed/VERSION"; g -C "$GO/seed" commit -q -am bin
g -C "$GO/seed" push -q origin feat/bin
g -C "$GO/work" fetch -q origin
OUT=$(cd "$GO/work" && NQ_GH_DOWN=1 nv --base main --bump patch --current-version 1.20.0)
chk "a head VERSION that is not UTF-8 is named in a warning" "$(jf 'any("feat/bin" in w for w in d["warnings"])' <<<"$OUT")" "True"
mkdir -p "$GO/lone"; g init -q "$GO/lone"
OUT=$(cd "$GO/lone" && NQ_GH_DOWN=1 nv --base main --bump patch --current-version 1.20.0)
chk "no remote at all falls back to the local bump" "$(jf 'd["version"]' <<<"$OUT")" "1.20.1"
chk "and that is not a complete queue either" "$(jf 'd.get("complete")' <<<"$OUT")" "False"
chk "nor a git queue" "$(jf 'd["host"]' <<<"$OUT")" "unknown"

# The callers derive the bump level from base vs branch and compare the pick
# with the branch's own VERSION. A level that is coarser than the release the
# PR makes answers a later slot, and the comparison calls a free PR stale --
# in /land-and-deploy that is a STOP on every micro release.
nq_block() { # nq_block SKILL HEADING -> the first bash fence after HEADING
  python3 -I - "$ROOT/skills/$1/SKILL.md" "$2" <<'BLK'
import sys
text = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(text) if l.startswith(sys.argv[2]))
out, on = [], False
for l in text[start:]:
    if not on and l.strip() == "```bash":
        on = True
    elif on and l.strip() == "```":
        break
    elif on:
        out.append(l)
print("\n".join(out))
BLK
}
CV="$TMP/callers"; mkdir -p "$CV/home/bin"
ln -s "$NV" "$CV/home/bin/vibe-next-version"
g init -q --bare -b main "$CV/origin.git"
g clone -q "$CV/origin.git" "$CV/w"
g -C "$CV/w" config user.email t@example.com; g -C "$CV/w" config user.name t
printf '1.2.3.4\n' > "$CV/w/VERSION"; g -C "$CV/w" add VERSION; g -C "$CV/w" commit -q -m base
g -C "$CV/w" push -q origin main
CV_BASE=$(g -C "$CV/w" rev-parse HEAD)
g -C "$CV/w" checkout -q -b feat/m
printf '1.2.3.5\n' > "$CV/w/VERSION"; g -C "$CV/w" commit -q -am micro
CV_HEAD=$(g -C "$CV/w" rev-parse HEAD)
printf '1.2.3.5\n' > "$NQ/heads/feat%2Fm"
printf '1.2.3.5\n' > "$NQ/heads/feat%2Fn"
nq_block land-and-deploy '## Step 3.4: VERSION drift' \
  | sed -e "s/<PR_NUMBER>/7/; s/<PR_HEAD>/$CV_HEAD/; s/<BASE_BRANCH>/main/; s/<BASE_SHA>/$CV_BASE/" > "$CV/land.sh"
echo 'echo "$BRANCH_VERSION $NEXT_SLOT $OFFLINE"' >> "$CV/land.sh"
nq_block review '## Step 3.4: Workspace-aware queue status' > "$CV/review.sh"
echo 'echo "$BRANCH_VERSION $NEXT_SLOT $OFFLINE"' >> "$CV/review.sh"
cv() { (cd "$CV/w" && PATH="$NQ/bin:$PATH" NQ_DIR="$NQ" VIBESTACK_HOME="$CV/home" bash "$1" 2>&1); }

printf '[%s]\n' "$(nq_pr 7 feat/m me)" > "$NQ/prs.json"
chk "land-and-deploy: a micro release alone in the queue is its own next slot" "$(cv "$CV/land.sh")" "1.2.3.5 1.2.3.5 false"
printf '[%s,%s]\n' "$(nq_pr 7 feat/m me)" "$(nq_pr 8 feat/n me)" > "$NQ/prs.json"
chk "land-and-deploy: another PR on the same micro slot is still drift" "$(cv "$CV/land.sh")" "1.2.3.5 1.2.3.6 false"
# A queue the bin could not fully read must not reach the drift comparison as
# if it were whole: an unread fork PR may hold the very slot being landed.
cp "$CV/land.sh" "$CV/land-c.sh"; echo 'echo "$COMPLETE"' >> "$CV/land-c.sh"
printf '[%s,%s]\n' "$(nq_pr 7 feat/m me)" "$(nq_pr 8 feat/z someone)" > "$NQ/prs.json"
chk "land-and-deploy: an unread fork PR marks the queue incomplete" "$(cv "$CV/land-c.sh" | tail -1)" "false"
printf '[]\n' > "$NQ/prs.json"
chk "review: a micro release with an empty queue reads as a free slot" "$(cv "$CV/review.sh")" "1.2.3.5 1.2.3.5 false"
# /review runs on an open PR, which is in the queue it reads; its own claim is
# not a sibling's.
printf '[%s]\n' "$(nq_pr 7 feat/m me)" > "$NQ/prs.json"
export NQ_PRN=7
chk "review: the PR's own claim does not read as the queue moving" "$(cv "$CV/review.sh")" "1.2.3.5 1.2.3.5 false"
unset NQ_PRN
rm "$NQ/heads/feat%2Fm" "$NQ/heads/feat%2Fn"

# Value: protects=land-and-deploy querying at patch for a four-part release that moved PATCH; fails_when=micro is chosen for every four-part version, so a sibling on 1.2.4.0 is missed (query answers 1.2.3.5); why_new=the micro rows above keep PATCH unchanged; seam=none
g -C "$CV/w" checkout -q -b feat/p "$CV_BASE"
printf '1.2.4.0\n' > "$CV/w/VERSION"; g -C "$CV/w" commit -q -am patch
nq_block land-and-deploy '## Step 3.4: VERSION drift' \
  | sed -e "s/<PR_NUMBER>/7/; s/<PR_HEAD>/$(g -C "$CV/w" rev-parse HEAD)/; s/<BASE_BRANCH>/main/; s/<BASE_SHA>/$CV_BASE/" > "$CV/land-p.sh"
echo 'echo "$BRANCH_VERSION $NEXT_SLOT $OFFLINE"' >> "$CV/land-p.sh"
printf '1.2.4.0\n' > "$NQ/heads/feat%2Fq"
printf '[%s,%s]\n' "$(nq_pr 7 feat/p me)" "$(nq_pr 8 feat/q me)" > "$NQ/prs.json"
chk "land-and-deploy: a four-part PATCH release sees a sibling on its slot" "$(cv "$CV/land-p.sh")" "1.2.4.0 1.2.5.0 false"
rm "$NQ/heads/feat%2Fq"

# Value: protects=review deriving minor (it used to hard-code patch); fails_when=review's level derivation drops or mis-orders the minor arm, so a sibling on 1.34.0 reads "Slot free"; why_new=the review row above is micro-only and passes without the minor arm; seam=none
g init -q --bare -b main "$CV/r.git"
g clone -q "$CV/r.git" "$CV/r"
g -C "$CV/r" config user.email t@example.com; g -C "$CV/r" config user.name t
printf '1.33.2\n' > "$CV/r/VERSION"; g -C "$CV/r" add VERSION; g -C "$CV/r" commit -q -m base
g -C "$CV/r" push -q origin main
g -C "$CV/r" checkout -q -b feat/r
printf '1.34.0\n' > "$CV/r/VERSION"; g -C "$CV/r" commit -q -am minor
printf '1.34.0\n' > "$NQ/heads/feat%2Fs"
printf '[%s]\n' "$(nq_pr 9 feat/s me)" > "$NQ/prs.json"
chk "review: a minor release sees a sibling claiming the same minor slot" \
  "$(cd "$CV/r" && PATH="$NQ/bin:$PATH" NQ_DIR="$NQ" VIBESTACK_HOME="$CV/home" bash "$CV/review.sh" 2>&1)" "1.34.0 1.35.0 false"
rm "$NQ/heads/feat%2Fs"

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

# printf %q leaves an assignment-shaped first word (X=Y) unquoted, and bash
# reads it as a variable assignment followed by the rest of the line: the
# intended program never runs, yet the job would report exit 0.
ID5=$("$D" start --label assign -- "X=Y" /usr/bin/true)
for _ in $(seq 1 20); do
  S5=$("$D" status "$ID5" 2>/dev/null || true)
  case "$S5" in exit:*|died) break ;; esac
  sleep 1
done
[ "$S5" = "exit:0" ] && no "an assignment-shaped command name reported success" \
                     || ok "an assignment-shaped command name is not reported as success"

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
# A cache line written before the credential key existed answers a question
# this probe can no longer confirm it was asked, so it is ignored rather than
# replayed.
mkdir -p "$TMP/h3"; printf '%s usable\n' "$(date +%s)" > "$TMP/h3/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h3" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "an unkeyed legacy cache is ignored" "$OUT" "CODEX: unauthenticated"

# Replay is asserted against a cache the probe wrote itself: prime it with a
# codex that answers, then swap in one that would fail. Still usable means the
# verdict came from the cache and no second round trip happened.
printf '#!/bin/sh\necho OK\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h3b" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1); RC=$?
chk "the first probe writes a usable verdict" "$OUT" "CODEX: usable"
chk "and exits 0" "$RC" "0"
printf '#!/bin/sh\nexit 9\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h3b" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "the second probe replays the cache instead of re-probing" "$OUT" "CODEX: usable"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h3b" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" --refresh 2>&1)
chk "--refresh bypasses the cache and sees the truth" "$OUT" "CODEX: error"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
mkdir -p "$TMP/h4"; printf 'garbage usable\n' > "$TMP/h4/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h4" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "a corrupt cache is ignored, not trusted" "$OUT" "CODEX: unauthenticated"
mkdir -p "$TMP/h5"; printf '%s usable\n' "$(( $(date +%s) - 99999 ))" > "$TMP/h5/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h5" \
      env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "an expired cache is re-probed" "$OUT" "CODEX: unauthenticated"


# Exit 0 is not an answer. A wrapper that exits without contacting anything
# would otherwise be reported as usable.
printf '#!/bin/sh\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h6" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "exit 0 with no reply is not usable" "$OUT" "CODEX: error"
printf '#!/bin/sh\necho OK\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h7" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a real reply is usable" "$OUT" "CODEX: usable"
# That verdict was about one set of credentials. Removing them must not leave
# the cached answer standing.
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$TMP/nocodexhome" VIBESTACK_HOME="$TMP/h7" \
      VIBE_CODEX_PROBE_TIMEOUT=5 env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "a cached verdict does not cross credential contexts" "$OUT" "CODEX: unauthenticated"

# Credentials present but refused: the round trip itself has to name it.
printf '#!/bin/sh\necho "Error: Not logged in. Run codex login." >&2\nexit 1\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h8" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a logged-out round trip reports unauthenticated" "$OUT" "CODEX: unauthenticated"

# A usage limit is its own verdict, relays Codex's reset line, and is cached --
# but only briefly, because it lifts on its own.
printf '#!/bin/sh\necho "ERROR: You have hit your usage limit. Try again at 4:05 PM." >&2\nexit 1\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h9" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1); RC=$?
chk "a usage-limit refusal reports quota_exhausted" "$(printf '%s\n' "$OUT" | head -1)" "CODEX: quota_exhausted"
chk "and exits nonzero" "$RC" "1"
printf '%s\n' "$OUT" | grep -q '^DETAIL: .*Try again at 4:05 PM' \
  && ok "Codex's reset line is relayed" || no "the reset line was dropped"
printf '#!/bin/sh\necho OK\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h9" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a fresh quota verdict is replayed, not re-paid" "$(printf '%s\n' "$OUT" | head -1)" "CODEX: quota_exhausted"
printf '%s\n' "$OUT" | grep -q '^DETAIL: .*Try again at 4:05 PM' \
  && ok "the replay still names the reset time" || no "the replay lost the reset line"
# Older than the quota window but well inside the default hour: re-probed.
read -r _qts _qv _qk < "$TMP/h9/codex-probe.txt"
printf '%s %s %s\n' "$(( $(date +%s) - 1000 ))" "$_qv" "$_qk" > "$TMP/h9/codex-probe.txt"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h9" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a quota verdict expires after 15 minutes, not an hour" "$OUT" "CODEX: usable"

# A 429 body that names insufficient_quota is the quota, not a rate limit.
printf '#!/bin/sh\necho "ERROR: 429 Too Many Requests: insufficient_quota" >&2\nexit 1\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h10" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "insufficient_quota wins over the 429" "$(printf '%s\n' "$OUT" | head -1)" "CODEX: quota_exhausted"

# A plain rate limit is transient: named, never cached.
printf '#!/bin/sh\necho "ERROR: stream error: 429 Too Many Requests (rate limit reached)" >&2\nexit 1\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h11" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a plain 429 reports rate_limited" "$(printf '%s\n' "$OUT" | head -1)" "CODEX: rate_limited"
[ -f "$TMP/h11/codex-probe.txt" ] && no "a rate-limited verdict was cached" \
                                 || ok "a rate-limited verdict is not cached"
printf '#!/bin/sh\necho OK\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h11" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "the next probe after a rate limit sees the truth" "$OUT" "CODEX: usable"

# codex echoes the prompt into the captured stream, and the prompt contains the
# word. The echo alone, exit 0, is not a reply.
printf '#!/bin/sh\necho user\necho "Reply with the single word OK."\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h12" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "the prompt echo alone is not a reply" "$OUT" "CODEX: error"

# A timeout or an unclassified failure is cached briefly, not for the hour: one
# network blip must not switch Codex off for every skill until it expires.
read -r _ets _ev _ek < "$TMP/h12/codex-probe.txt"
chk "an error verdict is cached" "$_ev" "error"
printf '#!/bin/sh\necho OK\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h12" \
      VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
chk "a fresh error verdict is replayed" "$OUT" "CODEX: error"
for _v in error unresponsive; do
  printf '%s %s %s\n' "$(( $(date +%s) - 1000 ))" "$_v" "$_ek" > "$TMP/h12/codex-probe.txt"
  OUT=$(PATH="$FAKE:$PATH" CODEX_API_KEY=x VIBESTACK_HOME="$TMP/h12" \
        VIBE_CODEX_PROBE_TIMEOUT=5 "$P" 2>&1)
  chk "an $_v verdict expires after 15 minutes, not an hour" "$OUT" "CODEX: usable"
done

# `codex login` writes auth.json. A cached `unauthenticated` recorded before
# the login must not outlive it -- the preflight tells the user to log in, and
# the very next run has to see that they did.
CH="$TMP/loginhome"; mkdir -p "$CH"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$CH" VIBESTACK_HOME="$TMP/h13" \
      VIBE_CODEX_PROBE_TIMEOUT=5 env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "before login: unauthenticated" "$OUT" "CODEX: unauthenticated"
printf '{}\n' > "$CH/auth.json"
OUT=$(PATH="$FAKE:$PATH" CODEX_HOME="$CH" VIBESTACK_HOME="$TMP/h13" \
      VIBE_CODEX_PROBE_TIMEOUT=5 env -u CODEX_API_KEY -u OPENAI_API_KEY "$P" 2>&1)
chk "after login the cached unauthenticated is not replayed" "$OUT" "CODEX: usable"

# The preflight every outside-voice skill shares has to ask the probe. A
# `codex --version` check passes while logged out, which is the whole bug.
PRE="$ROOT/lib/snippets/outside-voice-preflight.md"
grep -q 'vibe-codex-probe' "$PRE" && ok "the outside-voice preflight runs the probe" \
                                  || no "the outside-voice preflight does not run the probe"
grep -v '^[[:space:]]*#' "$PRE" | grep -q 'codex --version' \
  && no "the preflight still treats codex --version as auth" \
  || ok "the preflight no longer trusts codex --version"

# The verdict-to-mode mapping is what makes the preflight fail closed: anything
# the probe cannot vouch for -- including no probe at all -- must route to the
# Claude subagent, never to the Codex pass. Run the snippet's own bash block
# against a stub probe that prints each verdict.
echo "outside-voice preflight"
PF="$TMP/preflight.sh"
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$PRE" > "$PF"
[ -s "$PF" ] && ok "the preflight block extracts" || no "no bash block in the preflight snippet"
PFH="$TMP/pfhome"; mkdir -p "$PFH/.vibestack/bin"
printf '#!/bin/sh\nprintf "CODEX: %%s\\n" "$STUB_VERDICT"\n[ "$STUB_VERDICT" = usable ]\n' \
  > "$PFH/.vibestack/bin/vibe-codex-probe"
chmod +x "$PFH/.vibestack/bin/vibe-codex-probe"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/codex"; chmod +x "$FAKE/codex"
pf() { # pf VERDICT -> the preflight's full output
  HOME="$PFH" VIBESTACK_HOME="$PFH/.vibestack" PATH="$FAKE:/usr/bin:/bin" STUB_VERDICT="$1" \
    env -u CODEX_THREAD_ID -u CODEX_SANDBOX -u VIBE_FORCE_CODEX_REVIEW bash "$PF" 2>&1
}
pfmode() { pf "$1" | sed -n 's/^CODEX_MODE: //p'; }
chk "usable runs the Codex pass" "$(pfmode usable)" "ready"
chk "rate_limited still runs it" "$(pfmode rate_limited)" "ready"
printf '%s\n' "$(pf rate_limited)" | grep -q '^CODEX_NOTE: rate_limited' \
  && ok "and says it is rate limited" || no "rate_limited ran without a CODEX_NOTE"
chk "unauthenticated -> not_authed" "$(pfmode unauthenticated)" "not_authed"
chk "missing -> not_installed" "$(pfmode missing)" "not_installed"
chk "quota_exhausted keeps its own mode" "$(pfmode quota_exhausted)" "quota_exhausted"
chk "error -> unavailable" "$(pfmode error)" "unavailable"
chk "unresponsive -> unavailable" "$(pfmode unresponsive)" "unavailable"
chk "an unknown verdict -> unavailable" "$(pfmode something_new)" "unavailable"
printf '%s\n' "$(pf quota_exhausted)" | grep -q '^CODEX: quota_exhausted' \
  && ok "the probe's verdict line is relayed" || no "the probe's output was swallowed"
mv "$PFH/.vibestack/bin/vibe-codex-probe" "$PFH/.vibestack/bin/probe.off"
chk "a missing probe -> unavailable, never ready" "$(pfmode usable)" "unavailable"
mv "$PFH/.vibestack/bin/probe.off" "$PFH/.vibestack/bin/vibe-codex-probe"
printf '#!/bin/sh\necho disabled\n' > "$PFH/.vibestack/bin/vibe-config"; chmod +x "$PFH/.vibestack/bin/vibe-config"
chk "codex_reviews disabled wins over a usable probe" "$(pfmode usable)" "disabled"
rm -f "$PFH/.vibestack/bin/vibe-config"
chk "a Codex host is under_codex, not a nested pass" \
  "$(HOME="$PFH" VIBESTACK_HOME="$PFH/.vibestack" PATH="$FAKE:/usr/bin:/bin" STUB_VERDICT=usable CODEX_THREAD_ID=t \
     env -u VIBE_FORCE_CODEX_REVIEW bash "$PF" 2>&1 | sed -n 's/^CODEX_MODE: //p')" "under_codex"
if PATH="/usr/bin:/bin" command -v codex >/dev/null 2>&1; then
  ok "SKIP no-binary preflight case (codex is installed inside /usr/bin:/bin)"
else
  chk "no codex binary -> not_installed without asking the probe" \
    "$(HOME="$PFH" VIBESTACK_HOME="$PFH/.vibestack" PATH="/usr/bin:/bin" STUB_VERDICT=usable \
       env -u CODEX_THREAD_ID -u CODEX_SANDBOX bash "$PF" 2>&1 | sed -n 's/^CODEX_MODE: //p')" "not_installed"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
