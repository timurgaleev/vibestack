#!/usr/bin/env bash
# pr-thread-reply.sh <thread_id> <body> [--resolve]
#
# Reply to one review thread on the current PR; with --resolve, also mark
# the thread resolved. Prints the URL of the new comment.
#
# The reply and the resolve are two separate API mutations, so the pair can land
# half-way: the reply posts and the resolve fails. That case exits 1 with the
# comment URL still on stdout. Re-running the identical command is the retry —
# the script reads the thread's existing comments first and, when one of them
# already carries exactly this body, reuses that comment instead of posting a
# second copy, then retries only the resolve.
#
# A thread id is a global node id, so it names a thread on any PR in any repo.
# Before mutating anything the script resolves the current branch's PR and
# checks that the thread belongs to it — a stale id left over from an earlier
# round would otherwise post a reply on a different PR without a word.
#
# Exit 0 on success, 1 on bad arguments or API failure.
# Exit 2 when the branch has no PR, or when gh cannot see the repo.
set -euo pipefail

usage() {
  echo "usage: pr-thread-reply.sh <thread_id> <body> [--resolve]" >&2
  exit 1
}

[ $# -ge 2 ] || usage
THREAD_ID="$1"
BODY="$2"
RESOLVE=0
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --resolve) RESOLVE=1 ;;
    *) usage ;;
  esac
  shift
done

[ -n "$THREAD_ID" ] || usage
[ -n "$BODY" ] || { echo "pr-thread-reply: empty body" >&2; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  echo "pr-thread-reply: gh CLI not found — install it and run 'gh auth login'" >&2
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
  echo "pr-thread-reply: not inside a GitHub repository gh can see" >&2
  exit 2
}

BRANCH=$(git branch --show-current 2>/dev/null || true)
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null) || {
  echo "pr-thread-reply: no pull request found for branch '${BRANCH:-?}' — open one first (/ship)" >&2
  exit 2
}

THREAD_QUERY='query($threadId:ID!) {
  node(id:$threadId) {
    ... on PullRequestReviewThread {
      isResolved
      pullRequest { number repository { nameWithOwner } }
      comments(last:100) { nodes { body url } }
    }
  }
}'

# One request answers all three questions: which PR owns the thread, whether it
# is already resolved, and whether this exact reply is already on it. Comment
# bodies are base64-encoded so a body with tabs or newlines still occupies one
# line, and the base64 alphabet cannot collide with the "#" markers.
THREAD_FILTER='.data.node as $t
  | if $t == null or $t.pullRequest == null then "#missing:"
    else
      ("#pr:" + $t.pullRequest.repository.nameWithOwner + "#" + ($t.pullRequest.number | tostring)),
      ("#resolved:" + ($t.isResolved | tostring)),
      ($t.comments.nodes[] | (.body | @base64) + "\t" + .url)
    end'

THREAD_INFO=$(gh api graphql \
  -f query="$THREAD_QUERY" \
  -f threadId="$THREAD_ID" \
  --jq "$THREAD_FILTER" 2>/dev/null) || {
  echo "pr-thread-reply: could not read thread '$THREAD_ID'" >&2
  exit 1
}

BODY_B64=$(printf '%s' "$BODY" | base64 | tr -d '\n')

THREAD_PR=""
ALREADY_RESOLVED=""
EXISTING_URL=""
while IFS= read -r LINE; do
  case "$LINE" in
    '') ;;
    '#missing:') ;;
    '#pr:'*) THREAD_PR="${LINE#\#pr:}" ;;
    '#resolved:'*) ALREADY_RESOLVED="${LINE#\#resolved:}" ;;
    "$BODY_B64"$'\t'*)
      [ -n "$EXISTING_URL" ] || EXISTING_URL="${LINE#*$'\t'}"
      ;;
  esac
done <<< "$THREAD_INFO"

if [ -z "$THREAD_PR" ]; then
  echo "pr-thread-reply: '$THREAD_ID' is not a review thread this token can read" >&2
  exit 1
fi
if [ "$THREAD_PR" != "$REPO#$PR_NUMBER" ]; then
  echo "pr-thread-reply: thread belongs to $THREAD_PR, but this branch's PR is $REPO#$PR_NUMBER" >&2
  echo "pr-thread-reply: re-run pr-threads.sh to get ids for the current PR" >&2
  exit 1
fi

REPLY_MUTATION='mutation($threadId:ID!, $body:String!) {
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}) {
    comment { url }
  }
}'

if [ -n "$EXISTING_URL" ]; then
  echo "pr-thread-reply: this reply is already on the thread — reusing it instead of posting a duplicate" >&2
  URL="$EXISTING_URL"
else
  # -f passes strings verbatim; -F would try to interpret @file and numbers.
  URL=$(gh api graphql \
    -f query="$REPLY_MUTATION" \
    -f threadId="$THREAD_ID" \
    -f body="$BODY" \
    --jq '.data.addPullRequestReviewThreadReply.comment.url')
fi

if [ "$RESOLVE" -eq 1 ] && [ "$ALREADY_RESOLVED" != "true" ]; then
  RESOLVE_MUTATION='mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { isResolved }
    }
  }'
  RESOLVED=$(gh api graphql \
    -f query="$RESOLVE_MUTATION" \
    -f threadId="$THREAD_ID" \
    --jq '.data.resolveReviewThread.thread.isResolved') || RESOLVED=""
  if [ "$RESOLVED" != "true" ]; then
    echo "pr-thread-reply: reply posted but thread did not resolve — re-run the same command to retry the resolve; the reply will not be posted twice" >&2
    echo "$URL"
    exit 1
  fi
fi

echo "$URL"
