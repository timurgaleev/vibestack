**Release after merge.** One block decides everything: it reads the PR's state, and only
a merged PR whose merge commit is on the base branch gets a tag and a release. Substitute
`<base>` with the base branch. Set `PR_REF` to the PR/MR number when the current branch is
not the PR's branch (after a merge with `--delete-branch` the checkout has moved to the
base); leave it empty to use the current branch's PR.

The version and the release notes are read from the merge commit itself, not the working
tree, so a stale or switched checkout cannot tag the wrong version. A repo with no
`VERSION` file at the merge commit has nothing to tag and is skipped; that is decided
only once the merge commit is known, never from the checkout.

```bash
BASE="<base>"
PR_REF=""
PLATFORM=""
gh repo view --json url -q .url >/dev/null 2>&1 && PLATFORM="github"
[ -z "$PLATFORM" ] && glab repo view -F json >/dev/null 2>&1 && PLATFORM="gitlab"

# "<STATE> <merge-commit-sha>"; a squash merge still lands one commit on the base, and a
# GitLab fast-forward merge lands the MR head itself (no merge commit), so .sha is that commit.
case "$PLATFORM" in
  github) PR_STATE=$(gh pr view $PR_REF --json state,mergeCommit -q '.state + " " + (.mergeCommit.oid // "")' 2>/dev/null) ;;
  gitlab) PR_STATE=$(glab mr view $PR_REF -F json 2>/dev/null | jq -r '(.state | ascii_upcase) + " " + (.merge_commit_sha // .squash_commit_sha // .sha // "")' 2>/dev/null) ;;
  *)      PR_STATE="" ;;
esac
STATE=$(printf '%s' "$PR_STATE" | awk '{print $1}')
MERGE_SHA=$(printf '%s' "$PR_STATE" | awk '{print $2}')
[ -n "$STATE" ] || STATE="UNKNOWN"

# Unknown first: without the PR state or the merge commit nothing is decided yet.
if [ "$STATE" = "UNKNOWN" ] || { [ "$STATE" = "MERGED" ] && [ -z "$MERGE_SHA" ]; }; then
  echo "Release deferred: could not read the PR state or merge commit (platform: ${PLATFORM:-unknown}, state: $STATE). Not a final outcome — nothing was tagged; re-run this step once gh/glab can read the PR (check auth and network, or set PR_REF)."
  exit 0
fi
if [ "$STATE" != "MERGED" ]; then
  if [ -f VERSION ]; then
    echo "Release deferred: v$(tr -d '[:space:]' < VERSION) is tagged and released after the PR merges (PR state: $STATE)."
  else
    echo "Release deferred: the version at the merge commit is tagged and released after the PR merges (PR state: $STATE)."
  fi
  exit 0
fi

git fetch -q origin "$BASE" || { echo "BLOCKED: cannot fetch origin/$BASE — no tag, no release."; exit 1; }
git merge-base --is-ancestor "$MERGE_SHA" "origin/$BASE" 2>/dev/null \
  || { echo "BLOCKED: merge commit $MERGE_SHA is not on origin/$BASE — no tag, no release."; exit 1; }

if ! git cat-file -e "$MERGE_SHA:VERSION" 2>/dev/null; then
  echo "RELEASE: SKIPPED — no VERSION file at the merge commit, nothing to tag."
  exit 0
fi
NEW_VERSION=$(git show "$MERGE_SHA:VERSION" | tr -d '[:space:]')
case "$NEW_VERSION" in
  ''|*[!0-9A-Za-z.+-]*) echo "BLOCKED: VERSION at $MERGE_SHA is not a version ('$NEW_VERSION') — no tag, no release."; exit 1 ;;
esac
TAG_NAME="v$NEW_VERSION"

# A published tag is never moved: an existing remote or local tag must already be the merge commit.
_LS=$(git ls-remote --tags origin "refs/tags/$TAG_NAME" "refs/tags/$TAG_NAME^{}") \
  || { echo "BLOCKED: cannot read tags on origin — no tag, no release."; exit 1; }
_REMOTE_TAG=$(printf '%s\n' "$_LS" | awk -v r="refs/tags/$TAG_NAME^{}" '$2 == r {print $1}')
[ -n "$_REMOTE_TAG" ] || _REMOTE_TAG=$(printf '%s\n' "$_LS" | awk -v r="refs/tags/$TAG_NAME" '$2 == r {print $1}')
if [ -n "$_REMOTE_TAG" ] && [ "$_REMOTE_TAG" != "$MERGE_SHA" ]; then
  echo "BLOCKED: tag $TAG_NAME already exists on origin at $_REMOTE_TAG, not at $MERGE_SHA."
  echo "A published tag is never moved. Pick a new version, or resolve the stray tag by hand."
  exit 1
fi
if [ -z "$_REMOTE_TAG" ]; then
  if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; then
    [ "$(git rev-parse "$TAG_NAME^{commit}")" = "$MERGE_SHA" ] || {
      echo "BLOCKED: a local tag $TAG_NAME points elsewhere. Delete or rename it by hand; it is never moved."; exit 1; }
  else
    git tag -a "$TAG_NAME" "$MERGE_SHA" -m "$TAG_NAME — see CHANGELOG.md for details" \
      || { echo "BLOCKED: could not create tag $TAG_NAME — no release."; exit 1; }
  fi
  git push origin "refs/tags/$TAG_NAME" || { echo "BLOCKED: tag push failed — no release created."; exit 1; }
fi
echo "TAG: $TAG_NAME at $MERGE_SHA"

# Notes: the CHANGELOG section for this version, as it stands in the merge commit.
TMPNOTES=$(mktemp "${TMPDIR:-/tmp}/release-notes-XXXXXX")
git show "$MERGE_SHA:CHANGELOG.md" 2>/dev/null | awk -v v="$NEW_VERSION" '
  function is_head(l) { return l == "## " v || index(l, "## " v " ") == 1 || index(l, "## [" v "]") == 1 || l == "## v" v || index(l, "## v" v " ") == 1 }
  /^## / { if (on) exit; if (is_head($0)) on = 1 }
  on { print }
' > "$TMPNOTES"
[ -s "$TMPNOTES" ] || printf '## %s\n\nRelease notes pending — see CHANGELOG.md.\n' "$NEW_VERSION" > "$TMPNOTES"

case "$PLATFORM" in
  github)
    if gh release view "$TAG_NAME" >/dev/null 2>&1; then
      gh release edit "$TAG_NAME" --notes-file "$TMPNOTES" \
        && echo "Release $TAG_NAME updated" || echo "BLOCKED: release $TAG_NAME exists but its notes could not be updated."
    else
      gh release create "$TAG_NAME" --verify-tag --title "$TAG_NAME" --notes-file "$TMPNOTES" --latest \
        && echo "Release $TAG_NAME created" || echo "BLOCKED: tag $TAG_NAME is pushed but the release could not be created."
    fi
    ;;
  gitlab)
    if glab release view "$TAG_NAME" >/dev/null 2>&1; then
      glab release update "$TAG_NAME" --notes "$(cat "$TMPNOTES")" \
        && echo "Release $TAG_NAME updated" || echo "BLOCKED: release $TAG_NAME exists but its notes could not be updated."
    else
      glab release create "$TAG_NAME" --notes "$(cat "$TMPNOTES")" \
        && echo "Release $TAG_NAME created" || echo "BLOCKED: tag $TAG_NAME is pushed but the release could not be created."
    fi
    ;;
esac
rm -f "$TMPNOTES"
```

Report the outcome line as printed:

- `Release deferred: …` — the PR is not merged, or its state or merge commit could not be
  read. Nothing was tagged and nothing is final. Run this step again once it merges (or,
  for an unreadable state, once `gh`/`glab` can read the PR): `/land-and-deploy` runs it
  right after its merge, and re-running `/ship` on the merged branch goes straight to it.
- `RELEASE: SKIPPED …` — no `VERSION` file at the merge commit; there is no version to tag.
- `BLOCKED: …` — stop here and report the line verbatim with what the user must resolve.
  Never `git tag -f`, never `git push --force` a tag, never delete a published tag to
  make room.
- `TAG: …` plus `Release … created` / `updated` — report the tag, the merge commit and the
  release URL (`gh release view "$TAG_NAME" --json url -q .url`). A re-run finds the tag
  already on the merge commit and the release already present, and only refreshes the
  notes.
