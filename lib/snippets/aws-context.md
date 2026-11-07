Establish which AWS identity and region every finding below is about. Run this
block once, before any other AWS call:

```bash
# An identity the CLI did not confirm is not a scope: every field falls back to N-A.
_AWS_PROFILE="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}"
_AWS_ACCOUNT=""; _AWS_ARN=""; _AWS_RC=127; _AWS_ERR="aws CLI not found on PATH"
if command -v aws >/dev/null 2>&1; then
  # No pager, no prompt and bounded timeouts: an MFA or SSO prompt reads EOF and
  # fails, and an unreachable endpoint gives up instead of hanging the call.
  _AWS_OUT="$(AWS_PAGER= AWS_CLI_AUTO_PROMPT=off aws sts get-caller-identity \
    --cli-connect-timeout 5 --cli-read-timeout 15 \
    --query '[Account,Arn]' --output text </dev/null 2>&1)"
  _AWS_RC=$?
  _AWS_ID="$(printf '%s\n' "$_AWS_OUT" | awk 'length($(1)) == 12 && $(1) ~ /^[0-9]+$/ && $(2) ~ /^arn:aws/ { print $(1), $(2); exit }')"
  _AWS_ACCOUNT="$(printf '%s\n' "$_AWS_ID" | awk '{ print $(1) }')"
  _AWS_ARN="$(printf '%s\n' "$_AWS_ID" | awk '{ print $(2) }')"
  _AWS_ERR="$(printf '%s\n' "$_AWS_OUT" | awk 'NF { print; exit }')"
fi

if [ "$_AWS_RC" -ne 0 ] || [ -z "$_AWS_ACCOUNT" ]; then
  echo "AWS_CONTEXT: unavailable (profile $_AWS_PROFILE, exit $_AWS_RC): $_AWS_ERR"
  for _k in PROFILE REGION ACCOUNT PRINCIPAL; do echo "$_k: N-A"; done
else
  # First well-formed value wins; a malformed one is skipped, never repaired.
  _AWS_REGION="N-A"
  for _r in "${AWS_REGION:-}" "${AWS_DEFAULT_REGION:-}" \
      "$(aws configure list 2>/dev/null | awk '$(1) == "region" { print $(2); exit }')" \
      "$(aws configure get region 2>/dev/null)"; do
    if printf '%s\n' "$_r" | awk 'NR == 1 && /^[a-z][a-z](-[a-z]+)+-[0-9]+$/ { ok = 1 } END { exit !(ok && NR == 1) }'; then
      _AWS_REGION="$_r"; break
    fi
  done
  case "$_AWS_ARN" in
    *:assumed-role/AWSReservedSSO_*) _AWS_PRINCIPAL=sso-permission-set ;;
    *:assumed-role/*)                _AWS_PRINCIPAL=assumed-role ;;
    *:user/*)                        _AWS_PRINCIPAL=iam-user ;;
    *:root)                          _AWS_PRINCIPAL=root ;;
    *)                               _AWS_PRINCIPAL=N-A ;;
  esac
  echo "AWS_CONTEXT: ok"
  echo "PROFILE: $_AWS_PROFILE"
  echo "REGION: $_AWS_REGION"
  echo "ACCOUNT: $_AWS_ACCOUNT"
  echo "PRINCIPAL: $_AWS_PRINCIPAL"
fi
```

Put the four printed lines at the top of the report. Every Bash call starts a
fresh shell, so a later block that needs one of them restates it from the
printed line — `ACCOUNT='<ACCOUNT>'`, `REGION='<REGION>'` — and passes the
region explicitly with `--region "$REGION"`.

- **`AWS_CONTEXT: unavailable`**, or no `AWS_CONTEXT:` line at all (the call
  was killed or timed out) — the identity call failed or printed no identity. Do not run the AWS checks; mark each of them `N-A (AWS identity not
  established)`, show the printed error line, and name the fix for the profile
  shown: `aws sso login --profile <name>` for an SSO profile, `aws configure
  --profile <name>` otherwise. Never read `~/.aws/credentials` to work around it.
- **`REGION: N-A`** — nothing names a region. If the user named one in the
  request, use it; otherwise ask (AskUserQuestion) which region to check. Never
  assume one: a check against the wrong region reports an empty account as clean.
- **`PRINCIPAL:`** — `sso-permission-set` and `assumed-role` findings about
  permissions describe the role, not a person; `root` is itself a finding for
  any skill that reviews access.

**Verify against the docs tool when there is one.** If a tool whose name
matches `mcp__*aws-documentation*` is available in this session, check every
quota, price, regional-availability or API-field claim that sets or changes a
finding's severity against it before the finding is written, and cite the page
URL beside the claim. Without that tool, mark such a claim
`authoring-time knowledge` so the reader knows it was not checked against
current docs.
