#!/usr/bin/env bash
# test-aws-context.sh — the shared AWS context block reports what the CLI says, or N-A.
#
# Every AWS skill states which account, principal and region its findings are
# about. A block that falls back to a hard-coded region, or prints an account
# after the identity call failed, puts a confident wrong scope on every finding
# that follows. So the block from lib/snippets/aws-context.md is run for real,
# against a PATH `aws` shim, with a PATH that holds nothing else of the host's:
#   - green: PROFILE / REGION / ACCOUNT / PRINCIPAL printed from the shim;
#   - region order: AWS_REGION > AWS_DEFAULT_REGION > `aws configure list` >
#     `aws configure get region` > N-A (the model asks), never a default;
#   - principal kind from the ARN: iam-user, sso-permission-set, assumed-role;
#   - failure (CLI exits non-zero, CLI missing, unparseable output): every field
#     N-A, the exit status and the CLI's error line printed, not discarded;
#   - the snippet text names no literal region and carries the docs-tool rule.
#
# Usage: test-aws-context.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SNIP="$ROOT/lib/snippets/aws-context.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

if [ ! -f "$SNIP" ]; then
  no "lib/snippets/aws-context.md missing"
  echo; echo "passed: $pass  failed: $fail"; exit 1
fi

# The first fenced bash block of the snippet is the one skills run.
awk '/^```bash$/ && !done {on=1; next} on && /^```$/ {on=0; done=1} on' "$SNIP" > "$TMP/block.sh"
[ -s "$TMP/block.sh" ] && ok "snippet has a bash block" || no "snippet has no bash block"

# A PATH of only the tools a shell block may lean on, so the host's real aws
# (and its ~/.aws) can never answer.
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for t in awk sed head tail tr cat grep cut printf env mktemp rm; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$TOOLS/$t"
done

SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/aws" <<'SH'
#!/bin/sh
# Answers from SHIM_* env vars; anything unexpected is an error, like a real CLI.
case "$*" in
  "sts get-caller-identity"*)
    if [ "${SHIM_STS_RC:-0}" != 0 ]; then
      [ -n "${SHIM_STS_OUT:-}" ] && printf '%s\n' "$SHIM_STS_OUT"
      printf '%s\n' "${SHIM_STS_ERR:-An error occurred (ExpiredToken)}" >&2
      exit "$SHIM_STS_RC"
    fi
    printf '%s\n' "${SHIM_STS_OUT:-}"
    ;;
  "configure list"*)
    printf '      Name                    Value             Type    Location\n'
    printf '      ----                    -----             ----    --------\n'
    printf '   profile                <not set>             None    None\n'
    printf '    region %24s      config-file    ~/.aws/config\n' "${SHIM_LIST_REGION:-<not set>}"
    ;;
  "configure get region"*)
    [ -n "${SHIM_GET_REGION:-}" ] || exit 1
    printf '%s\n' "$SHIM_GET_REGION"
    ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$SHIM/aws"

SSO_ARN='arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0a1b2c3d4e5f/alice'
ROLE_ARN='arn:aws:sts::123456789012:assumed-role/deploy-role/ci-session'
USER_ARN='arn:aws:iam::123456789012:user/bob'
TAB="$(printf '\t')"

# run <shell> <with-aws:yes|no> [VAR=value ...] — runs the block in a clean env.
run() {
  local sh="$1" withaws="$2"; shift 2
  local path="$TOOLS"
  [ "$withaws" = yes ] && path="$SHIM:$TOOLS"
  local home; home="$(mktemp -d "$TMP/home.XXXXXX")"
  env -i HOME="$home" VIBESTACK_HOME="$home/.vibestack" PATH="$path" "$@" \
    "$sh" "$TMP/block.sh" 2>"$TMP/stderr"
}

field() { printf '%s\n' "$1" | awk -v k="$2:" '$1 == k { sub(/^[^:]*:[ ]*/, ""); print; exit }'; }

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

for SH in $SHELLS; do
  SHP="$(command -v "$SH")"
  echo "$SH: green path"
  out="$(run "$SHP" yes SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_LIST_REGION=eu-west-1)"
  [ "$(field "$out" PROFILE)" = default ] && ok "PROFILE: default when no profile is set" || no "PROFILE wrong: $out"
  [ "$(field "$out" REGION)" = eu-west-1 ] && ok "REGION from 'aws configure list'" || no "REGION wrong: $out"
  [ "$(field "$out" ACCOUNT)" = 123456789012 ] && ok "ACCOUNT from sts" || no "ACCOUNT wrong: $out"
  [ "$(field "$out" PRINCIPAL)" = sso-permission-set ] && ok "AWSReservedSSO_ role -> sso-permission-set" || no "PRINCIPAL wrong: $out"

  out="$(run "$SHP" yes AWS_PROFILE=prod-ro SHIM_STS_OUT="123456789012${TAB}${ROLE_ARN}" SHIM_LIST_REGION=eu-west-1)"
  [ "$(field "$out" PROFILE)" = prod-ro ] && ok "PROFILE follows AWS_PROFILE" || no "PROFILE ignores AWS_PROFILE: $out"
  [ "$(field "$out" PRINCIPAL)" = assumed-role ] && ok "plain assumed role -> assumed-role" || no "PRINCIPAL wrong for role: $out"

  out="$(run "$SHP" yes SHIM_STS_OUT="123456789012${TAB}${USER_ARN}" SHIM_LIST_REGION=eu-west-1)"
  [ "$(field "$out" PRINCIPAL)" = iam-user ] && ok "iam user ARN -> iam-user" || no "PRINCIPAL wrong for user: $out"

  echo "$SH: region order"
  out="$(run "$SHP" yes AWS_REGION=ap-south-1 AWS_DEFAULT_REGION=sa-east-1 SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_LIST_REGION=eu-west-1 SHIM_GET_REGION=us-west-2)"
  [ "$(field "$out" REGION)" = ap-south-1 ] && ok "AWS_REGION wins" || no "AWS_REGION not first: $out"
  out="$(run "$SHP" yes AWS_DEFAULT_REGION=sa-east-1 SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_LIST_REGION=eu-west-1)"
  [ "$(field "$out" REGION)" = sa-east-1 ] && ok "AWS_DEFAULT_REGION before the config file" || no "AWS_DEFAULT_REGION skipped: $out"
  out="$(run "$SHP" yes SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_GET_REGION=us-west-2)"
  [ "$(field "$out" REGION)" = us-west-2 ] && ok "'aws configure get region' when the list shows none" || no "configure get region unused: $out"
  out="$(run "$SHP" yes SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}")"
  [ "$(field "$out" REGION)" = N-A ] && ok "no region anywhere -> REGION: N-A, not a default" || no "REGION invented: $out"
  [ "$(field "$out" ACCOUNT)" = 123456789012 ] && ok "a missing region leaves the identity intact" || no "ACCOUNT lost with region: $out"
  out="$(run "$SHP" yes AWS_REGION='eu-west-1; rm -rf x' SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_LIST_REGION=eu-central-1)"
  [ "$(field "$out" REGION)" = eu-central-1 ] && ok "a malformed AWS_REGION is skipped" || no "malformed region accepted: $out"

  echo "$SH: failure -> N-A"
  out="$(run "$SHP" yes SHIM_STS_RC=255 SHIM_STS_ERR='An error occurred (ExpiredToken) when calling the GetCallerIdentity operation' SHIM_LIST_REGION=eu-west-1)"
  bad=""
  for f in PROFILE REGION ACCOUNT PRINCIPAL; do [ "$(field "$out" "$f")" = N-A ] || bad="$bad $f"; done
  [ -z "$bad" ] && ok "sts exit 255 -> every field N-A" || no "fields not N-A on failure:$bad :: $out"
  printf '%s\n' "$out" | grep -q 'exit 255' && ok "exit status is printed" || no "exit status not printed: $out"
  printf '%s\n' "$out" | grep -q 'ExpiredToken' && ok "the CLI's error line is printed, not discarded" || no "error text lost: $out"

  out="$(run "$SHP" yes SHIM_STS_RC=1 SHIM_STS_OUT="123456789012${TAB}${SSO_ARN}" SHIM_LIST_REGION=eu-west-1)"
  bad=""
  for f in PROFILE REGION ACCOUNT PRINCIPAL; do [ "$(field "$out" "$f")" = N-A ] || bad="$bad $f"; done
  [ -z "$bad" ] && ok "non-zero exit with an identity on stdout -> every field N-A" || no "exit status ignored:$bad :: $out"

  out="$(run "$SHP" no AWS_PROFILE=prod-ro AWS_REGION=eu-west-1)"
  bad=""
  for f in PROFILE REGION ACCOUNT PRINCIPAL; do [ "$(field "$out" "$f")" = N-A ] || bad="$bad $f"; done
  [ -z "$bad" ] && ok "no aws CLI -> every field N-A" || no "fields not N-A without CLI:$bad :: $out"

  out="$(run "$SHP" yes SHIM_STS_OUT="not an identity" SHIM_LIST_REGION=eu-west-1)"
  bad=""
  for f in PROFILE REGION ACCOUNT PRINCIPAL; do [ "$(field "$out" "$f")" = N-A ] || bad="$bad $f"; done
  [ -z "$bad" ] && ok "exit 0 with unparseable output -> every field N-A" || no "garbage output trusted:$bad :: $out"
done

echo "snippet text"
grep -q '{{include' "$SNIP" && no "snippet includes another snippet" || ok "snippet includes no other snippet"
regions="$(grep -Eo '(us|eu|ap|sa|ca|me|af|il|mx)(-gov)?-(north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9]+' "$SNIP" | sort -u | tr '\n' ' ')"
[ -z "$regions" ] && ok "no literal region in the snippet" || no "literal region(s) in the snippet: $regions"
grep -q 'aws-documentation' "$SNIP" && grep -q 'authoring-time knowledge' "$SNIP" \
  && ok "docs-tool rule: verify against aws-documentation or mark authoring-time knowledge" \
  || no "docs-tool verification rule missing"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
