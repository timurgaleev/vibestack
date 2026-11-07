#!/usr/bin/env bash
# test-base-branch-detect.sh — the shared base-branch and confidence snippets.
#
# lib/snippets/base-branch-detect.md holds the git-native base detection the
# diff-reading skills fall back to without gh/glab. Its bash block is extracted
# and run for real in throwaway repos with a local bare origin, behind a PATH
# git shim that logs every git call:
#   - a normal feature branch, the base branch itself, a fresh branch at the
#     base tip and a fresh branch that lags the base all resolve, exit 0;
#   - a cached origin/HEAD naming the checked-out branch, or pointing at HEAD's
#     own commit, is discarded and the remote's real HEAD is asked instead;
#   - a default branch other than main (develop) resolves to itself on that
#     branch, and with the remote offline the cache still wins over "main";
#   - a branch whose commits the base already contains (merged) prints
#     BASE_CONTAINS_HEAD and exits non-zero instead of reading as an empty diff.
#
# lib/snippets/confidence-calibration.md is prose; its content is asserted:
# unverified findings go to exactly 4 (appendix) or 5 (main report with the
# caveat), the 1-2 row admits only a release-blocking catastrophe labelled
# CRITICAL and speculative, and P0-P3 is the severity scale.
#
# Usage: test-base-branch-detect.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SNIP="$ROOT/lib/snippets/base-branch-detect.md"
CONF="$ROOT/lib/snippets/confidence-calibration.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

REAL_GIT="$(command -v git)" || { echo "git not found" >&2; exit 2; }
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME" "$TMP/shim"
cat > "$TMP/shim/git" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_SHIM_LOG"
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$TMP/shim/git"
export REAL_GIT

# setup <name> [default] — $TMP/<name>/{origin.git,seed,work}; origin's HEAD is
# <default> (main) and work is a fresh clone, so its origin/HEAD names it.
setup() {
  local d="$TMP/$1" b="${2:-main}"; mkdir -p "$d"
  git init -q --bare -b "$b" "$d/origin.git"
  git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
  git -C "$d/seed" commit -q --allow-empty -m init
  git -C "$d/seed" push -q origin "$b"
  git clone -q "$d/origin.git" "$d/work"
}
commit() { git -C "$1" commit -q --allow-empty -m "${2:-work}"; }

# run_block <work-dir> — runs the snippet block there; sets OUT, RC, LOG.
run_block() {
  LOG="$TMP/git.log"; : > "$LOG"
  OUT="$(cd "$1" && GIT_SHIM_LOG="$LOG" PATH="$TMP/shim:$PATH" bash "$TMP/block.sh" 2>&1)"; RC=$?
}
base_line() { printf '%s\n' "$OUT" | sed -n 's/^BASE_BRANCH: //p'; }

expect_base() { # expect_base <label> <branch>
  local got; got="$(base_line)"
  if [ "$RC" = 0 ] && [ "$got" = "$2" ] && ! printf '%s' "$OUT" | grep -q BASE_CONTAINS_HEAD; then
    ok "$1 → BASE_BRANCH: $2, exit 0"
  else
    no "$1 → expected BASE_BRANCH: $2 and exit 0, got exit $RC: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
}

echo "base-branch-detect snippet"
if [ ! -f "$SNIP" ]; then
  no "lib/snippets/base-branch-detect.md missing"
else
  ok "lib/snippets/base-branch-detect.md exists"
  grep -q '{{include' "$SNIP" && no "snippet includes another snippet" || ok "snippet includes no other snippet"
  awk '/^```bash$/ {on=1; next} on && /^```$/ {exit} on' "$SNIP" > "$TMP/block.sh"
  if [ ! -s "$TMP/block.sh" ]; then
    no "snippet has no bash block"
  else
    ok "bash block extracted ($(wc -l < "$TMP/block.sh" | tr -d ' ') lines)"
    grep -Eq 'git (fetch|pull|push)' "$TMP/block.sh" \
      && no "block touches the network beyond ls-remote" || ok "block never fetches, pulls or pushes"

    setup green; W="$TMP/green/work"
    git -C "$W" switch -q -c feat; commit "$W"
    run_block "$W"; expect_base "feature branch with a commit" main

    git -C "$W" switch -q main; run_block "$W"
    expect_base "on the base branch itself" main

    git -C "$W" switch -q -c fresh main
    run_block "$W"; expect_base "fresh branch at the base tip" main

    setup stale; W="$TMP/stale/work"
    git -C "$W" switch -q -c stale
    commit "$TMP/stale/seed" "base moves on"; git -C "$TMP/stale/seed" push -q origin main
    git -C "$W" fetch -q origin
    run_block "$W"; expect_base "fresh branch the base has moved past" main

    # The remote's default is develop; the local cache was pointed at the
    # checked-out branch, as `git remote set-head origin feat` leaves it.
    setup selfref; W="$TMP/selfref/work"
    git -C "$TMP/selfref/seed" push -q origin main:develop
    git -C "$TMP/selfref/origin.git" symbolic-ref HEAD refs/heads/develop
    git -C "$W" switch -q -c feat; commit "$W"
    git -C "$W" push -q origin feat 2>/dev/null
    git -C "$W" fetch -q origin
    git -C "$W" remote set-head origin feat >/dev/null
    run_block "$W"; expect_base "origin/HEAD names the current branch" develop
    grep -q '^ls-remote --symref origin HEAD$' "$LOG" \
      && ok "remote HEAD asked with ls-remote --symref" || no "ls-remote --symref origin HEAD never ran"

    # origin/HEAD names another branch whose tip is HEAD's own commit.
    setup samesha; W="$TMP/samesha/work"
    git -C "$TMP/samesha/seed" push -q origin main:develop
    git -C "$TMP/samesha/origin.git" symbolic-ref HEAD refs/heads/develop
    git -C "$W" switch -q -c feat; commit "$W"
    git -C "$W" push -q origin HEAD:release 2>/dev/null
    git -C "$W" fetch -q origin
    git -C "$W" remote set-head origin release >/dev/null
    run_block "$W"; expect_base "origin/HEAD points at HEAD's own commit" develop

    # The remote's default is develop and there is no main or master at all.
    # On develop the cache names the current branch and the remote's answer
    # names it too; that answer is the base, not a reason to guess "main".
    setup devonly develop; W="$TMP/devonly/work"
    run_block "$W"; expect_base "on a develop default branch, no main or master" develop
    commit "$W" "local work on develop"
    run_block "$W"; expect_base "develop default with a local commit ahead" develop

    # Offline: the remote cannot be asked, so the cache is all there is.
    git -C "$W" switch -q -c fresh origin/develop
    git -C "$W" remote set-url origin "$TMP/devonly/gone.git"
    run_block "$W"; expect_base "remote offline, fresh branch at develop's tip" develop
    git -C "$W" switch -q develop
    run_block "$W"; expect_base "remote offline, on develop itself" develop

    # Offline with both develop (the default) and main on the remote.
    setup flow develop; W="$TMP/flow/work"
    git -C "$TMP/flow/seed" push -q origin develop:main
    git -C "$W" fetch -q origin
    git -C "$W" switch -q -c fresh origin/develop
    git -C "$W" remote set-url origin "$TMP/flow/gone.git"
    run_block "$W"; expect_base "remote offline, develop default beside a main branch" develop

    # origin/HEAD naming a pruned ref is not a base: the remote is asked.
    setup pruned; W="$TMP/pruned/work"
    git -C "$W" switch -q -c feat; commit "$W"
    git -C "$W" update-ref refs/remotes/origin/develop HEAD
    git -C "$W" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
    git -C "$W" update-ref -d refs/remotes/origin/develop
    run_block "$W"; expect_base "cached origin/HEAD naming a pruned ref" main

    # An ssh remote is asked in batch mode with a bounded connect, never a prompt.
    setup sshremote; W="$TMP/sshremote/work"
    git -C "$W" switch -q -c feat; commit "$W"
    git -C "$W" symbolic-ref -d refs/remotes/origin/HEAD
    git -C "$W" remote set-url origin "ssh://git@example.invalid/x.git"
    mkdir -p "$TMP/fakessh"; SSH_LOG="$TMP/ssh.log"; : > "$SSH_LOG"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 255\n' "$SSH_LOG" > "$TMP/fakessh/ssh"; chmod +x "$TMP/fakessh/ssh"
    OUT="$(cd "$W" && GIT_SHIM_LOG="$TMP/git.log" PATH="$TMP/fakessh:$TMP/shim:$PATH" bash "$TMP/block.sh" 2>&1)"; RC=$?
    if grep -q -- '-o BatchMode=yes' "$SSH_LOG" && grep -q -- '-o ConnectTimeout=5' "$SSH_LOG"; then
      ok "ssh remote is asked with BatchMode=yes and ConnectTimeout=5"
    else
      no "ssh remote asked without batch mode or a connect bound: $(tr '\n' '|' < "$SSH_LOG")"
    fi
    expect_base "ssh remote that cannot answer falls back offline" main

    # The branch was merged; every commit on it is already in main.
    setup merged; W="$TMP/merged/work"; S="$TMP/merged/seed"
    git -C "$W" switch -q -c feat; commit "$W" "feature"
    git -C "$W" push -q origin feat 2>/dev/null
    git -C "$S" fetch -q origin feat
    git -C "$S" merge -q --no-ff -m "merge feat" FETCH_HEAD
    git -C "$S" push -q origin main
    git -C "$W" fetch -q origin
    run_block "$W"
    if [ "$RC" != 0 ] && printf '%s\n' "$OUT" | grep -q '^BASE_CONTAINS_HEAD' && [ -z "$(base_line)" ]; then
      ok "merged branch → BASE_CONTAINS_HEAD, non-zero exit, no BASE_BRANCH line"
    else
      no "merged branch → expected BASE_CONTAINS_HEAD and a non-zero exit, got exit $RC: $(printf '%s' "$OUT" | tr '\n' '|')"
    fi
  fi
fi

echo "confidence-calibration snippet"
if [ ! -f "$CONF" ]; then
  no "lib/snippets/confidence-calibration.md missing"
else
  ok "lib/snippets/confidence-calibration.md exists"
  grep -q '{{include' "$CONF" && no "snippet includes another snippet" || ok "snippet includes no other snippet"
  grep -Eq '^ *- \*\*4\*\* .*appendix' "$CONF" \
    && ok "forced row 4: appendix only" || no "no forced row '- **4** … appendix'"
  grep -Eq '^ *- \*\*5\*\* .*main report.*Medium confidence' "$CONF" \
    && ok "forced row 5: main report with the medium-confidence caveat" \
    || no "no forced row '- **5** … main report … Medium confidence'"
  grep -Eq '^\| *1-2 *\|.*release-blocking.*CRITICAL.*speculative' "$CONF" \
    && ok "1-2 row: only a release-blocking catastrophe, CRITICAL + speculative" \
    || no "1-2 row does not limit itself to a release-blocking catastrophe labelled CRITICAL and speculative"
  grep -q '4-5 (suppressed' "$CONF" && no "contradictory '4-5 (suppressed' rule still present" \
    || ok "no '4-5 (suppressed' rule"
  missing=""
  for p in P0 P1 P2 P3; do grep -Eq "^\| *\*\*$p\*\* *\|" "$CONF" || missing="$missing $p"; done
  [ -z "$missing" ] && ok "severity scale defines P0-P3" || no "severity scale lacks:$missing"
  grep -Fq '`[P1] (confidence: 9/10)' "$CONF" \
    && ok "example uses [P1] (confidence: 9/10)" || no "no \`[P1] (confidence: 9/10) example"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
