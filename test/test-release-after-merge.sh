#!/usr/bin/env bash
# test-release-after-merge.sh — the shared tag-and-release step that /ship
# (Step 19.5) and /land-and-deploy (§4a-release) run once a PR has merged.
#
# The bash block is pulled out of each rendered skill and executed in fixture
# repos with a bare remote and a stub `gh` (its `-q` filters run through jq):
#   - both skills render the same block from lib/snippets/release-after-merge.md;
#   - an unmerged PR defers: no tag, no release;
#   - a merged PR tags the merge commit (VERSION read from that commit), pushes
#     the tag without force, and runs `gh release create --verify-tag` with the
#     CHANGELOG section for that version as notes;
#   - a re-run updates the existing release instead of creating a second one;
#   - a tag that already exists elsewhere (remote or local) is refused and left
#     where it is;
#   - a repo with no VERSION file at the merge commit is skipped; an unreadable
#     PR state defers with retry guidance and is never reported as skipped;
#   - a merge commit that is not on the base branch is refused.
#
# Usage: test-release-after-merge.sh   (SHIP_SKILL / LAND_SKILL override the sources)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIP_SRC="${SHIP_SKILL:-$ROOT/skills/ship/SKILL.md}"
LAND_SRC="${LAND_SKILL:-$ROOT/skills/land-and-deploy/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# block FILE MARKER -> the first ```bash fence after the first line containing MARKER
block() {
  python3 -I - "$1" "$2" <<'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
marker = sys.argv[2]
start = next((i for i, l in enumerate(text) if marker in l), None)
if start is None:
    sys.exit(1)
out, on = [], False
for line in text[start:]:
    if not on and line.strip() == "```bash":
        on = True
        continue
    if on and line.strip() == "```":
        break
    if on:
        out.append(line)
if not out:
    sys.exit(1)
print("\n".join(out))
PY
}

echo "shared block"
MARK='**Release after merge.**'
for s in ship land; do
  src=$SHIP_SRC; [ "$s" = land ] && src=$LAND_SRC
  if "$ROOT/bin/vibe-render-skill" "$src" "$TMP/$s.md" >/dev/null 2>&1 \
     && block "$TMP/$s.md" "$MARK" > "$TMP/$s.sh"; then
    sed -i.bak 's/<base>/main/g' "$TMP/$s.sh"
    ok "$s renders the release-after-merge block"
  else
    no "$s has no release-after-merge block"; : > "$TMP/$s.sh"
  fi
done
if [ -s "$TMP/ship.sh" ] && cmp -s "$TMP/ship.sh" "$TMP/land.sh"; then
  ok "ship and land-and-deploy run the identical block"
else
  no "ship and land-and-deploy release blocks differ"
fi
LAND_ORDER=$(awk '/^### 4a-release:/{r=NR} /^### 4b:/{b=NR} END{print (r && b && r < b) ? "ok" : "bad"}' "$TMP/land.md")
[ "$LAND_ORDER" = ok ] && ok "land-and-deploy releases right after the merge, before deploy detection" \
  || no "land-and-deploy has no release step between the merge and §4b"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# Stub gh: a canned PR (pr.json, filtered with jq like gh -q), releases as files.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_DIR/log"
sub="$1 ${2:-}"; shift 2 2>/dev/null || shift $#
case "$sub" in
  "repo view") echo "https://github.com/o/r" ;;
  "pr view")
    q=""
    while [ $# -gt 0 ]; do case "$1" in -q) q="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$STUB_DIR/pr.json" ] || exit 1
    if [ -n "$q" ]; then jq -r "$q" "$STUB_DIR/pr.json"; else cat "$STUB_DIR/pr.json"; fi ;;
  "release view") [ -f "$STUB_DIR/release-$1" ] ;;
  "release create"|"release edit")
    tag="$1"; shift; verify=0; notes=""
    while [ $# -gt 0 ]; do case "$1" in --verify-tag) verify=1; shift ;; --notes-file) notes="$2"; shift 2 ;; *) shift ;; esac; done
    if [ "$sub" = "release create" ]; then
      [ -f "$STUB_DIR/release-$tag" ] && { echo "release exists" >&2; exit 1; }
      [ "$verify" = 1 ] && [ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ] && { echo "tag not found" >&2; exit 1; }
    else
      [ -f "$STUB_DIR/release-$tag" ] || exit 1
    fi
    touch "$STUB_DIR/release-$tag"
    [ -n "$notes" ] && cp "$notes" "$STUB_DIR/notes-$tag" ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/glab"
chmod +x "$TMP/bin/gh" "$TMP/bin/glab"
export PATH="$TMP/bin:$PATH"

# fixture NAME VERSION -> work repo $TMP/NAME (origin = $TMP/NAME.git); feature
# merged into main with a merge commit when VERSION is set, CHANGELOG has 2 sections.
fixture() {
  local d="$TMP/$1"
  git init -q --bare "$d.git"
  git init -q -b main "$d"
  mkdir -p "$d.stub"
  ( cd "$d" || exit 1
    echo app > app.txt
    [ -n "$2" ] && printf '1.1.0\n' > VERSION
    printf '# Changelog\n\n## 1.1.0 — 2026-01-01\n\n- old entry\n' > CHANGELOG.md
    git add -A && git commit -q -m init
    git remote add origin "$d.git"
    git push -q origin main
    git checkout -q -b feature
    [ -n "$2" ] && printf '%s\n' "$2" > VERSION
    printf '# Changelog\n\n## %s — 2026-02-02\n\n- new entry\n\n## 1.1.0 — 2026-01-01\n\n- old entry\n' "${2:-1.2.0}" > CHANGELOG.md
    git add -A && git commit -q -m feature
    git push -q origin feature
    git checkout -q main
    git merge -q --no-ff feature -m "Merge feature"
    git push -q origin main
    git checkout -q feature )
  printf '%s' "$d"
}
pr() { printf '{"state":"%s","mergeCommit":%s}\n' "$2" "$3" > "$1.stub/pr.json"; }
run() { ( cd "$1" && STUB_DIR="$1.stub" bash "$2" ) 2>&1; }
remote_tag() { git -C "$1" ls-remote --tags origin "refs/tags/$2^{}" "refs/tags/$2" | awk '{print $1}' | tail -1; }
creates() { grep -c '^gh release create' "$1.stub/log" 2>/dev/null || true; }

for s in land ship; do
  B="$TMP/$s.sh"
  [ -s "$B" ] || { no "$s: no block to run"; continue; }
  echo "$s: behaviour"

  d=$(fixture "$s-open" 1.2.0); pr "$d" OPEN null
  out=$(run "$d" "$B"); rc=$?
  case "$out" in *"Release deferred"*) ok "$s: unmerged PR defers" ;; *) no "$s: unmerged PR not deferred: $out" ;; esac
  [ "$rc" = 0 ] && ok "$s: deferral exits 0" || no "$s: deferral exit $rc"
  [ -z "$(remote_tag "$d" v1.2.0)$(git -C "$d" tag -l v1.2.0)" ] && ok "$s: unmerged PR gets no tag" || no "$s: unmerged PR was tagged"
  [ "$(creates "$d")" = 0 ] && ok "$s: unmerged PR gets no release" || no "$s: unmerged PR got a release"

  d=$(fixture "$s-merged" 1.2.0); MS=$(git -C "$d" rev-parse main)
  git -C "$d" checkout -q main~1   # stale checkout: VERSION here is 1.1.0
  pr "$d" MERGED "{\"oid\":\"$MS\"}"
  out=$(run "$d" "$B"); rc=$?
  [ "$rc" = 0 ] && ok "$s: merged PR exits 0" || no "$s: merged PR exit $rc: $out"
  [ "$(remote_tag "$d" v1.2.0)" = "$MS" ] && ok "$s: tag v1.2.0 is on the merge commit at origin" || no "$s: tag not on merge commit: $out"
  [ -z "$(remote_tag "$d" v1.1.0)" ] && ok "$s: version comes from the merge commit, not the checkout" || no "$s: tagged the checkout's version"
  grep -q '^gh release create v1.2.0 .*--verify-tag' "$d.stub/log" && ok "$s: gh release create --verify-tag" || no "$s: no verified release create: $(cat "$d.stub/log")"
  if grep -q 'new entry' "$d.stub/notes-v1.2.0" 2>/dev/null && ! grep -q 'old entry' "$d.stub/notes-v1.2.0"; then
    ok "$s: notes are the CHANGELOG section for v1.2.0"
  else
    no "$s: wrong release notes"
  fi
  out=$(run "$d" "$B"); rc=$?
  [ "$rc" = 0 ] && ok "$s: re-run exits 0" || no "$s: re-run exit $rc: $out"
  [ "$(creates "$d")" = 1 ] && grep -q '^gh release edit v1.2.0' "$d.stub/log" \
    && ok "$s: re-run updates the release instead of creating another" || no "$s: re-run did not update: $(cat "$d.stub/log")"
  [ "$(remote_tag "$d" v1.2.0)" = "$MS" ] && ok "$s: re-run leaves the tag in place" || no "$s: re-run moved the tag"

  d=$(fixture "$s-stray" 1.2.0); MS=$(git -C "$d" rev-parse main); OLD=$(git -C "$d" rev-parse main~1)
  git -C "$d" tag v1.2.0 "$OLD" && git -C "$d" push -q origin v1.2.0 && git -C "$d" tag -d v1.2.0 >/dev/null
  pr "$d" MERGED "{\"oid\":\"$MS\"}"
  out=$(run "$d" "$B"); rc=$?
  case "$out" in *BLOCKED*) ok "$s: remote tag elsewhere is refused" ;; *) no "$s: remote tag elsewhere not refused: $out" ;; esac
  [ "$rc" != 0 ] && ok "$s: refusal exits non-zero" || no "$s: refusal exit 0"
  [ "$(remote_tag "$d" v1.2.0)" = "$OLD" ] && ok "$s: the published tag is not moved" || no "$s: the published tag moved"
  [ "$(creates "$d")" = 0 ] && ok "$s: no release on a refused tag" || no "$s: release created on a refused tag"

  d=$(fixture "$s-local" 1.2.0); MS=$(git -C "$d" rev-parse main); OLD=$(git -C "$d" rev-parse main~1)
  git -C "$d" tag v1.2.0 "$OLD"
  pr "$d" MERGED "{\"oid\":\"$MS\"}"
  out=$(run "$d" "$B"); rc=$?
  case "$out" in *BLOCKED*) ok "$s: local tag elsewhere is refused" ;; *) no "$s: local tag elsewhere not refused: $out" ;; esac
  [ "$(git -C "$d" rev-parse 'v1.2.0^{commit}')" = "$OLD" ] && [ -z "$(remote_tag "$d" v1.2.0)" ] \
    && ok "$s: local tag untouched, nothing pushed" || no "$s: local tag moved or pushed"

  d=$(fixture "$s-nover" ""); MS=$(git -C "$d" rev-parse main)
  pr "$d" MERGED "{\"oid\":\"$MS\"}"
  out=$(run "$d" "$B"); rc=$?
  case "$out" in *SKIPPED*) ok "$s: no VERSION -> skipped" ;; *) no "$s: versionless repo not skipped: $out" ;; esac
  [ "$rc" = 0 ] && ok "$s: skip exits 0" || no "$s: skip exit $rc"
  [ -z "$(git -C "$d" ls-remote --tags origin)" ] && [ "$(creates "$d")" = 0 ] \
    && ok "$s: no VERSION -> no tag, no release" || no "$s: versionless repo got a tag or release"

  # A failed PR-state lookup decides nothing, even where the checkout has no VERSION.
  d=$(fixture "$s-unknown" ""); rm -f "$d.stub/pr.json"
  out=$(run "$d" "$B"); rc=$?
  case "$out" in
    *SKIPPED*) no "$s: unreadable PR state reported as SKIPPED: $out" ;;
    *"Release deferred: could not read the PR state"*"re-run"*) ok "$s: unreadable PR state defers with retry guidance, not SKIPPED" ;;
    *) no "$s: unreadable PR state not deferred: $out" ;;
  esac
  [ "$rc" = 0 ] && ok "$s: unreadable PR state exits 0" || no "$s: unreadable PR state exit $rc"
  [ -z "$(git -C "$d" ls-remote --tags origin)" ] && [ "$(creates "$d")" = 0 ] \
    && ok "$s: unreadable PR state -> no tag, no release" || no "$s: unreadable PR state got a tag or release"

  d=$(fixture "$s-open-nover" ""); pr "$d" OPEN null
  out=$(run "$d" "$B")
  case "$out" in
    *SKIPPED*) no "$s: open PR without a checkout VERSION reported as SKIPPED: $out" ;;
    *"Release deferred"*) ok "$s: open PR without a checkout VERSION defers (no-VERSION is decided at the merge commit)" ;;
    *) no "$s: open PR without a checkout VERSION not deferred: $out" ;;
  esac

  d=$(fixture "$s-offbase" 1.2.0); git -C "$d" commit -q --allow-empty -m unmerged; FS=$(git -C "$d" rev-parse feature)
  pr "$d" MERGED "{\"oid\":\"$FS\"}"
  out=$(run "$d" "$B"); rc=$?
  case "$out" in *BLOCKED*"not on origin/main"*) ok "$s: merge commit off the base is refused" ;; *) no "$s: off-base commit not refused: $out" ;; esac
  [ -z "$(git -C "$d" ls-remote --tags origin)" ] && ok "$s: off-base commit gets no tag" || no "$s: off-base commit was tagged"
done

echo "no force anywhere"
for s in ship land; do
  grep -Eq 'tag -f|tag -fa|push --force|push -f( |$)' "$TMP/$s.sh" && no "$s: release block forces a tag" || ok "$s: release block never forces"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
