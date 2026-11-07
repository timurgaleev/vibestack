#!/usr/bin/env bash
# test-aws-skills-contract.sh — the AWS review skills scope every finding to an
# account and region the CLI confirmed, and a failed call never reads as clean.
#
# The skills are rendered, and the blocks that make live calls are run against a
# PATH `aws` shim (no real AWS call is ever made):
#   - bedrock-guardrails: no hard-coded region anywhere; Step 1 prints
#     CALL_SITE_REGIONS; the enforced-guardrail (G2) and VPC-endpoint (D5) probes
#     take their regions from that line (D5 falls back to `aws configure get
#     region`) and print `N-A (region not established)` instead of guessing one;
#     the AgentCore controls and the /mcp-review pointer are present;
#   - the shared aws-context block is rendered verbatim into every AWS skill, and
#     no includer keeps its own inline identity call;
#   - aws-cost: the idle probes (unattached Elastic IPs, log groups without
#     retention, instances stopped 30+ days) print N-A on a failed call; the
#     onset lookup refuses dates outside CloudTrail's 90-day history and reports
#     a denied lookup as N-A; estimate mode lists what a Terraform plan creates
#     or changes; none of the new sections carries a hard-coded price;
#   - kb-review names the corpus write path as a trust boundary; ai-cost-guard
#     covers app-managed caches and the other providers' cache counters.
#
# Usage: test-aws-skills-contract.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

render() {
  "$ROOT/bin/vibe-render-skill" "$ROOT/skills/$1/SKILL.md" "$TMP/$1.md" >/dev/null 2>&1 \
    || no "$1 does not render"
}
for s in bedrock-guardrails aws-cost connect-review kb-review ai-cost-guard cso mcp-review; do render "$s"; done

# block <file> <marker> — the first fenced bash block containing a fixed string.
block() {
  awk -v m="$2" '/^```bash$/ {on=1; buf=""; next}
    on && /^```$/ {on=0; if (index(buf, m)) {printf "%s", buf; exit}; next}
    on {buf = buf $0 "\n"}' "$1"
}

# A PATH of the tools a skill block may use plus the shim; the host's aws is never on it.
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for t in awk sed head tail tr cat grep cut printf env mktemp rm wc sort date python3 dirname; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$TOOLS/$t"
done
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/aws" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SHIM_LOG"
case " ${SHIM_FAIL:-} " in *" ${2} "*) echo "An error occurred (AccessDenied) when calling ${2}" >&2; exit 254 ;; esac
case "${1} ${2}" in
  "configure get") [ -n "${SHIM_REGION:-}" ] || exit 1; printf '%s\n' "$SHIM_REGION" ;;
  "ec2 describe-addresses") printf '%s\n' "${SHIM_EIPS:-}" ;;
  "logs describe-log-groups") printf '%s\n' "${SHIM_LOGS:-}" ;;
  "ec2 describe-instances") printf '%s\n' "${SHIM_STOPPED:-}" ;;
  "cloudtrail lookup-events") printf '%s\n' "${SHIM_EVENTS:-}" ;;
  *) printf '[]\n' ;;
esac
SH
chmod +x "$SHIM/aws"

# runblock <shell> <script> [VAR=value ...] — clean env, shim first on PATH.
runblock() {
  local sh="$1" script="$2"; shift 2
  : > "$TMP/shim.log"
  # An empty working dir: the blocks' repo greps then scan nothing instead of this checkout.
  mkdir -p "$TMP/work"
  (cd "$TMP/work" && env -i HOME="$TMP" TMPDIR="$TMP" PATH="$SHIM:$TOOLS" SHIM_LOG="$TMP/shim.log" "$@" \
    "$sh" "$script" 2>&1)
}
SHELLS="bash"; command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"
REGION_RE='(us|eu|ap|sa|ca|me|af|il|mx)(-gov)?-(north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9]+'

echo "bedrock-guardrails: regions come from the account and the call sites"
BG="$TMP/bedrock-guardrails.md"
grep -q 'eu-central-1' "$BG" && no "rendered bedrock-guardrails still names eu-central-1: $(grep -n 'eu-central-1' "$BG" | head -3 | tr '\n' ' ')" \
  || ok "no eu-central-1 anywhere in the rendered skill"
awk '/^```bash$/ {on=1; next} on && /^```$/ {on=0} on' "$BG" > "$TMP/bg-blocks.sh"
lit="$(grep -Eo "$REGION_RE" "$TMP/bg-blocks.sh" | sort -u | tr '\n' ' ')"
[ -z "$lit" ] && ok "no literal region inside any bash block" || no "literal region(s) in bash blocks: $lit"
block "$BG" 'echo "CALL_SITE_REGIONS:' > "$TMP/bg-csr.sh"
[ -s "$TMP/bg-csr.sh" ] && ok "Step 1 prints a CALL_SITE_REGIONS: line" || no "no block prints CALL_SITE_REGIONS:"

block "$BG" "bg-probe.sh\" <<'PROBE'" > "$TMP/bg-helper.sh"
block "$BG" 'G2-enforced' > "$TMP/bg-g2.sh"
block "$BG" 'D5-vpce' > "$TMP/bg-d5.sh"
grep -q "CALL_SITE_REGIONS='<CALL_SITE_REGIONS>'" "$TMP/bg-g2.sh" \
  && ok "G2 restates CALL_SITE_REGIONS from the printed line" || no "G2 does not restate CALL_SITE_REGIONS from a placeholder"
grep -q "CALL_SITE_REGIONS='<CALL_SITE_REGIONS>'" "$TMP/bg-d5.sh" \
  && ok "D5 restates CALL_SITE_REGIONS from the printed line" || no "D5 does not restate CALL_SITE_REGIONS from a placeholder"

# with_regions <block> <value> — the block with the placeholder filled, after the helper.
with_regions() {
  { cat "$TMP/bg-helper.sh"; sed "s#'<CALL_SITE_REGIONS>'#'$2'#" "$1"; } > "$TMP/filled.sh"
}
for SH in $SHELLS; do
  SHP="$(command -v "$SH")"
  with_regions "$TMP/bg-g2.sh" ''
  out="$(runblock "$SHP" "$TMP/filled.sh")"
  if printf '%s\n' "$out" | grep -q 'G2-enforced: N-A (region not established)' \
     && ! grep -q 'list-enforced-guardrails-configuration' "$TMP/shim.log"; then
    ok "$SH: G2 with no call-site region -> N-A (region not established), no call"
  else
    no "$SH: G2 with no region guessed one: $(grep enforced "$TMP/shim.log" | head -2) :: $(printf '%s' "$out" | grep G2 | head -2)"
  fi
  with_regions "$TMP/bg-g2.sh" 'eu-west-1 us-east-2'
  out="$(runblock "$SHP" "$TMP/filled.sh")"
  if grep -q 'list-enforced-guardrails-configuration --region eu-west-1' "$TMP/shim.log" \
     && grep -q 'list-enforced-guardrails-configuration --region us-east-2' "$TMP/shim.log"; then
    ok "$SH: G2 probes each call-site region"
  else
    no "$SH: G2 did not probe both regions: $(grep enforced "$TMP/shim.log" | tr '\n' ' ')"
  fi

  with_regions "$TMP/bg-d5.sh" ''
  out="$(runblock "$SHP" "$TMP/filled.sh")"
  if printf '%s\n' "$out" | grep -q 'D5-vpce: N-A (region not established)' \
     && ! grep -q 'describe-vpc-endpoints' "$TMP/shim.log"; then
    ok "$SH: D5 with no call-site region and no configured region -> N-A, no call"
  else
    no "$SH: D5 guessed a region: $(grep vpc "$TMP/shim.log" | head -2) :: $(printf '%s' "$out" | grep D5 | head -2)"
  fi
  out="$(runblock "$SHP" "$TMP/filled.sh" SHIM_REGION=ap-south-1)"
  grep -q 'com.amazonaws.ap-south-1.bedrock-runtime' "$TMP/shim.log" \
    && ok "$SH: D5 falls back to 'aws configure get region'" || no "$SH: D5 ignored the configured region: $(grep vpc "$TMP/shim.log")"
  with_regions "$TMP/bg-d5.sh" 'eu-west-1'
  out="$(runblock "$SHP" "$TMP/filled.sh" SHIM_REGION=ap-south-1)"
  if grep -q 'com.amazonaws.eu-west-1.bedrock-runtime' "$TMP/shim.log" && ! grep -q 'ap-south-1.bedrock' "$TMP/shim.log"; then
    ok "$SH: D5 prefers the call-site region over the CLI default"
  else
    no "$SH: D5 region order wrong: $(grep vpc "$TMP/shim.log" | tr '\n' ' ')"
  fi
done

echo "bedrock-guardrails: AgentCore"
block "$BG" 'aws_bedrock|bedrock:' | grep -q 'agentcore\|AgentCore' \
  && ok "Step 1 infrastructure grep covers AgentCore resources" || no "Step 1 grep misses AgentCore"
grep -q 'authorizerType' "$BG" && grep -qE 'NONE.{0,200}HIGH|HIGH.{0,200}NONE' "$BG" \
  && ok "gateway with inbound authorizer NONE is HIGH" || no "no HIGH for an unauthenticated gateway"
grep -q 'aws:SourceVpce' "$BG" && grep -q 'get-resource-policy' "$BG" \
  && ok "resource policy read and checked for Principal * without a VPC condition" || no "AgentCore resource-policy check missing"
grep -qiE 'OAuth.{0,250}expected|expected.{0,250}OAuth' "$BG" \
  && ok "Principal * on an OAuth resource is called out as expected" || no "OAuth Principal * note missing"
grep -qiE 'credential provider' "$BG" && grep -qE 'environment.{0,200}MEDIUM|MEDIUM.{0,200}environment' "$BG" \
  && ok "gateway target credentials outside Identity providers are MEDIUM" || no "target-credential check missing"
grep -q 'bedrock-guardrails' "$TMP/mcp-review.md" && grep -qi 'agentcore' "$TMP/mcp-review.md" \
  && ok "/mcp-review points AgentCore-hosted servers at /bedrock-guardrails" || no "mcp-review pointer missing"

echo "aws-context is rendered into every AWS skill"
block "$ROOT/lib/snippets/aws-context.md" 'get-caller-identity' > "$TMP/ctx.sh"
for s in bedrock-guardrails aws-cost connect-review kb-review ai-cost-guard cso; do
  if python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1]).read() in open(sys.argv[2]).read() else 1)' "$TMP/ctx.sh" "$TMP/$s.md"; then
    ok "$s renders the aws-context block verbatim"
  else
    no "$s does not include lib/snippets/aws-context.md"
  fi
done
for s in bedrock-guardrails aws-cost connect-review kb-review ai-cost-guard; do
  hits="$(grep -nE '^[[:space:]]*aws sts get-caller-identity|\$\(aws sts get-caller-identity|aws sts get-caller-identity --output text 2>/dev/null' "$TMP/$s.md" | head -3 | tr '\n' ' ')"
  [ -z "$hits" ] && ok "$s keeps no inline identity call of its own" || no "$s still has an inline identity call: $hits"
done

echo "aws-cost: idle probes"
AC="$TMP/aws-cost.md"
block "$AC" 'describe-addresses' > "$TMP/ac-idle.sh"
if [ ! -s "$TMP/ac-idle.sh" ]; then
  no "no idle-probe block with describe-addresses"
else
  grep -q 'AssociationId' "$TMP/ac-idle.sh" && grep -q 'retentionInDays' "$TMP/ac-idle.sh" && grep -q 'storedBytes' "$TMP/ac-idle.sh" \
    && ok "probes select unassociated addresses and log groups without retention, with storedBytes" || no "probe queries incomplete"
  sed "s#'<region[^']*>'#'eu-west-1'#" "$TMP/ac-idle.sh" > "$TMP/idle.sh"
  OLD="i-0old$(printf '\t')User initiated (2020-01-02 10:00:00 GMT)"
  NEW_DAY="$(python3 -I -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=5))')"
  NEW="i-0new$(printf '\t')User initiated (${NEW_DAY} 10:00:00 GMT)"
  out="$(runblock "$(command -v bash)" "$TMP/idle.sh" SHIM_EIPS="203.0.113.7$(printf '\t')eipalloc-1" \
         SHIM_LOGS="/aws/lambda/x$(printf '\t')1048576" SHIM_STOPPED="$OLD
$NEW")"
  printf '%s\n' "$out" | grep -q 'IDLE_EIPS: 1' && ok "unassociated address counted" || no "address count wrong: $out"
  printf '%s\n' "$out" | grep -q 'i-0old' && ok "instance stopped since 2020 reported" || no "long-stopped instance missing: $out"
  printf '%s\n' "$out" | grep -q 'i-0new' && no "instance stopped 5 days ago reported as idle: $out" || ok "instance stopped 5 days ago is not a candidate"
  grep -q -- '--region eu-west-1' "$TMP/shim.log" && ok "probes run in the named region" || no "probes not region-scoped: $(head -2 "$TMP/shim.log")"
  out="$(runblock "$(command -v bash)" "$TMP/idle.sh" SHIM_FAIL="describe-addresses describe-log-groups describe-instances")"
  n="$(printf '%s\n' "$out" | grep -c 'N-A')"
  [ "$n" -ge 3 ] && ok "each failed probe prints N-A ($n), never an empty clean list" || no "failed probes not N-A: $out"
fi

echo "aws-cost: onset events from CloudTrail"
block "$AC" 'lookup-events' > "$TMP/ac-onset.sh"
if [ ! -s "$TMP/ac-onset.sh" ]; then
  no "no onset block with cloudtrail lookup-events"
else
  onset() {
    sed -e "s#'<onset[^']*>'#'$1'#" -e "s#'<region[^']*>'#'eu-west-1'#" -e "s#'<event source[^']*>'#'ec2.amazonaws.com'#" \
      "$TMP/ac-onset.sh" > "$TMP/onset.sh"
    shift
    runblock "$(command -v bash)" "$TMP/onset.sh" "$@"
  }
  OLD_DAY="$(python3 -I -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=200))')"
  RECENT="$(python3 -I -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=10))')"
  out="$(onset "$OLD_DAY")"
  if printf '%s\n' "$out" | grep -q 'outside the 90-day history' && ! grep -q lookup-events "$TMP/shim.log"; then
    ok "onset 200 days back -> outside the 90-day history, no lookup"
  else
    no "old onset looked up or misreported: $out"
  fi
  out="$(onset "$RECENT" SHIM_FAIL=lookup-events)"
  printf '%s\n' "$out" | grep -q 'N-A' && ok "denied lookup -> N-A" || no "denied lookup not N-A: $out"
  out="$(onset "$RECENT" SHIM_EVENTS="2026-10-28T09:00:00Z$(printf '\t')RunInstances$(printf '\t')ci-deployer$(printf '\t')i-0abc")"
  grep -q 'lookup-events --region eu-west-1' "$TMP/shim.log" && grep -q 'EventSource,AttributeValue=ec2.amazonaws.com' "$TMP/shim.log" \
    && ok "lookup runs in the moved region, filtered to the service's event source" || no "lookup scope wrong: $(cat "$TMP/shim.log")"
  grep -q "starts_with(EventName, 'Create')" "$TMP/ac-onset.sh" && grep -q "'Run'" "$TMP/ac-onset.sh" && grep -q "'Put'" "$TMP/ac-onset.sh" \
    && ok "events filtered to Create*, Run*, Put*" || no "event-name filter missing"
  printf '%s\n' "$out" | grep -q 'ci-deployer' && ok "event, resource and principal reported" || no "events not printed: $out"
fi

echo "aws-cost: estimate mode"
block "$AC" 'resource_changes' > "$TMP/ac-est.sh"
if [ ! -s "$TMP/ac-est.sh" ]; then
  no "no estimate block reading a Terraform plan's resource_changes"
else
  cat > "$TMP/plan.json" <<'JSON'
{"resource_changes":[
 {"address":"aws_nat_gateway.main","type":"aws_nat_gateway","change":{"actions":["create"]}},
 {"address":"aws_db_instance.db","type":"aws_db_instance","change":{"actions":["update"]}},
 {"address":"aws_instance.web","type":"aws_instance","change":{"actions":["delete","create"]}},
 {"address":"aws_s3_bucket.logs","type":"aws_s3_bucket","change":{"actions":["no-op"]}},
 {"address":"aws_eip.old","type":"aws_eip","change":{"actions":["delete"]}}]}
JSON
  sed "s#'<path to the terraform[^']*>'#'$TMP/plan.json'#" "$TMP/ac-est.sh" > "$TMP/est.sh"
  out="$(runblock "$(command -v bash)" "$TMP/est.sh")"
  if printf '%s\n' "$out" | grep -q 'aws_nat_gateway.main' && printf '%s\n' "$out" | grep -q 'aws_db_instance.db' \
     && printf '%s\n' "$out" | grep -q 'aws_instance.web' && ! printf '%s\n' "$out" | grep -qE 'aws_s3_bucket.logs|aws_eip.old'; then
    ok "creates, updates and replacements listed; no-ops and deletes left out"
  else
    no "plan resources wrong: $out"
  fi
fi
EST="$(awk '/^## .*[Ee]stimate/ {on=1; print; next} on && /^## / {exit} on' "$AC")"
[ -n "$EST" ] && ok "estimate mode has its own section" || no "no estimate section"
printf '%s\n' "$EST" | grep -q 'get-products' && printf '%s\n' "$EST" | grep -q 'regionCode' && printf '%s\n' "$EST" | grep -q 'bcm-pricing-calc' \
  && ok "estimate prices through filtered get-products or bcm-pricing-calc" || no "estimate pricing path missing"
printf '%s\n' "$EST" | grep -qE 'N-A.{0,80}(never|not) (a )?zero|never zero' && ok "unpriced rows are N-A, never zero" || no "unpriced-row rule missing"

echo "aws-cost: no hard-coded prices in the new sections"
NEWTEXT="$(cat "$TMP/ac-idle.sh" "$TMP/ac-onset.sh" 2>/dev/null; printf '%s\n' "$EST")"
prices="$(printf '%s\n' "$NEWTEXT" | grep -oE '(USD|\$) ?[0-9]+(\.[0-9]+)?' | sort -u | tr '\n' ' ')"
[ -z "$prices" ] && ok "no literal price in the idle probes, onset lookup or estimate mode" || no "hard-coded price(s): $prices"
grep -q 'PublicIPv4:IdleAddress' "$AC" && ok "address cost read from the account's PublicIPv4 idle usage-type row" || no "PublicIPv4 usage-type pricing missing"

echo "kb-review: the corpus write path"
KB="$TMP/kb-review.md"
grep -q 's3:PutObject' "$KB" && grep -q 'get-bucket-policy' "$KB" \
  && ok "writers found from the bucket policy and IAM grants" || no "write-path principals not enumerated"
grep -qiE 'upload' "$KB" && grep -qE 'other tenants.{0,200}HIGH|HIGH.{0,200}other tenants' "$KB" \
  && ok "untrusted uploads retrievable by other tenants are HIGH" || no "cross-tenant untrusted-content HIGH missing"
grep -qi 'trust boundary' "$KB" && grep -q '/bedrock-guardrails' "$KB" \
  && ok "write path chained with the prompt-framing check" || no "write path not chained with framing"

echo "ai-cost-guard: caches"
AG="$TMP/ai-cost-guard.md"
grep -qiE 'app-managed|application-managed' "$AG" && grep -qE 'tenant.{0,200}MEDIUM|MEDIUM.{0,200}tenant' "$AG" && grep -qi 'permission change' "$AG" \
  && ok "app-managed caches keyed to tenant, invalidated on permission change, cross-tenant MEDIUM" || no "app-managed cache rule missing"
grep -q 'cached_tokens' "$AG" && grep -q 'cachedContentTokenCount' "$AG" \
  && ok "OpenAI and Gemini cache counters named" || no "OpenAI/Gemini cache counters missing"
grep -qiE 'storage' "$AG" && grep -qiE 'explicit (context )?cach' "$AG" \
  && ok "Gemini explicit-cache storage charge named" || no "explicit-cache storage charge missing"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
