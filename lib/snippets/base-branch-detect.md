**Git-native fallback (if unknown platform, or CLI commands fail):**

```bash
_BD_CUR="$(git branch --show-current 2>/dev/null)"
_BD_HEAD="$(git rev-parse -q --verify HEAD 2>/dev/null)"
_BD_BASE=""
# origin/HEAD is a local cache: a fork clone or `git remote set-head` run on a
# feature branch can leave it naming the branch you are on. When it names the
# current branch or points at HEAD itself, ask the remote; the cache is used
# again only if the remote cannot answer.
_BD_CACHED="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
_BD_CACHED="${_BD_CACHED#origin/}"
if [ -n "$_BD_CACHED" ] && [ "$_BD_CACHED" != "$_BD_CUR" ] \
   && [ "$(git rev-parse -q --verify "refs/remotes/origin/$_BD_CACHED" 2>/dev/null)" != "$_BD_HEAD" ]; then
  _BD_BASE="$_BD_CACHED"
fi
if [ -z "$_BD_BASE" ]; then
  _BD_BASE="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref origin HEAD 2>/dev/null \
    | awk '$(1) == "ref:" { sub("^refs/heads/", "", $(2)); print $(2); exit }')"
fi
if [ -z "$_BD_BASE" ]; then
  if [ -n "$_BD_CACHED" ] && git rev-parse -q --verify "refs/remotes/origin/$_BD_CACHED" >/dev/null; then _BD_BASE="$_BD_CACHED"
  elif git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then _BD_BASE=main
  elif git rev-parse -q --verify refs/remotes/origin/master >/dev/null; then _BD_BASE=master
  else _BD_BASE=main
  fi
fi
# A merged branch reaches the base through a merge's second parent. A branch
# that only lags the base sits on the base's own first-parent line and has no
# commits of its own, so that is not a stop.
_BD_TIP="$(git rev-parse -q --verify "refs/remotes/origin/$_BD_BASE" 2>/dev/null)"
if [ -n "$_BD_CUR" ] && [ "$_BD_CUR" != "$_BD_BASE" ] && [ -n "$_BD_TIP" ] \
   && [ "$_BD_TIP" != "$_BD_HEAD" ] && git merge-base --is-ancestor "$_BD_HEAD" "$_BD_TIP" 2>/dev/null; then
  _BD_LAST="$(git rev-list --first-parent "$_BD_TIP" "^$_BD_HEAD" | tail -n 1)"
  if [ "$(git rev-parse -q --verify "$_BD_LAST^1" 2>/dev/null)" != "$_BD_HEAD" ]; then
    echo "BASE_CONTAINS_HEAD: origin/$_BD_BASE already contains every commit on $_BD_CUR ($_BD_HEAD)"
    exit 1
  fi
fi
echo "BASE_BRANCH: $_BD_BASE"
```

Use the name on the `BASE_BRANCH:` line as the base branch.

If the block prints `BASE_CONTAINS_HEAD` instead, stop. The base already holds
every commit on this branch — it was merged, or the base is not the branch this
work targets. Tell the user and ask which base to compare against; never report
it as "nothing to review" or an empty diff.
