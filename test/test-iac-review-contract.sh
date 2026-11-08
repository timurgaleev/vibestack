#!/usr/bin/env bash
# test-iac-review-contract.sh — /iac-review ranks what a Terraform plan will
# break, and a plan it could not read never reads as a clean one.
#
# The skill is rendered, and its fixed blocks are run against fixtures (no
# terraform, cdk, aws or kubectl call is ever made):
#   - the plan ranker: a stateful replace is CRITICAL; destroys, replacements,
#     count-index churn and unmarked secret outputs are HIGH; sensitive values in
#     state and unpinned providers/modules are MEDIUM; no-ops, reads, local
#     modules and pinned sources are not findings; a clean plan prints RANKED: 0;
#     a missing, malformed, errored or non-plan file prints PLAN: N-A and no
#     RANKED line;
#   - the repo scan: an s3 backend without encryption or locking, no backend at
#     all, a partial backend config and a missing lock file are each reported;
#     .terraform/ is never scanned;
#   - the scanner probe names every static scanner as present or absent;
#   - the frontmatter is read-only and within the description budget, the shared
#     aws-context block is included, plan generation stays read-only, live EKS
#     calls are read-only and gated, and the EKS section, the /aws-cost and /cso
#     links and the N-A rule are present.
#
# Usage: test-iac-review-contract.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SRC="$ROOT/skills/iac-review/SKILL.md"
IR="$TMP/iac-review.md"
if [ -f "$SRC" ] && "$ROOT/bin/vibe-render-skill" "$SRC" "$IR" >/dev/null 2>&1; then
  ok "iac-review renders"
else
  no "skills/iac-review/SKILL.md is missing or does not render"
  echo; echo "$pass passed, $fail failed"; exit 1
fi

# block <file> <marker> — the first fenced bash block containing a fixed string.
block() {
  awk -v m="$2" '/^```bash$/ {on=1; buf=""; next}
    on && /^```$/ {on=0; if (index(buf, m)) {printf "%s", buf; exit}; next}
    on {buf = buf $0 "\n"}' "$1"
}
awk '/^```bash$/ {on=1; next} on && /^```$/ {on=0} on' "$IR" > "$TMP/all-blocks.sh"

# A PATH of the tools a block may use; no terraform, aws, kubectl or scanner on it.
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for t in awk sed head tail tr cat grep cut printf env mktemp rm wc sort date python3 dirname ls; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$TOOLS/$t"
done
runblock() { # runblock <shell> <script> [extra PATH dir]
  local sh="$1" script="$2" extra="${3:-}"
  mkdir -p "$TMP/work"
  (cd "$TMP/work" && env -i HOME="$TMP" TMPDIR="$TMP" PATH="${extra:+$extra:}$TOOLS" "$sh" "$script" 2>&1)
}
SHELLS="bash"; command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

echo "frontmatter"
fm="$(awk 'NR==1 && /^---$/ {on=1; next} on && /^---$/ {exit} on' "$SRC")"
printf '%s\n' "$fm" | grep -qx 'name: iac-review' && ok "name matches the directory" || no "name: is not iac-review"
desc="$(printf '%s\n' "$fm" | awk '/^description:/ {d=1; sub(/^description:[ |>]*/, ""); if (length($0)) print; next}
  d && /^  / {sub(/^  /, ""); print; next} d {exit}' | tr -d '\n')"
[ -n "$desc" ] && [ "${#desc}" -le 120 ] && ok "description is ${#desc} chars (<= 120)" \
  || no "description is ${#desc} chars (want 1..120): $desc"
tools="$(printf '%s\n' "$fm" | awk '/^allowed-tools:/ {on=1; next} on && /^  - / {sub(/^  - /, ""); print; next} on {exit}')"
printf '%s\n' "$tools" | grep -qxE 'Edit|Write|NotebookEdit' && no "a read-only review lists a write tool: $(printf '%s' "$tools" | tr '\n' ' ')" \
  || ok "allowed-tools holds no write tool"
printf '%s\n' "$tools" | grep -qx 'AskUserQuestion' && ok "AskUserQuestion is allowed (gates the live calls)" \
  || no "AskUserQuestion missing from allowed-tools"
printf '%s\n' "$fm" | grep -q '^hooks:' && no "frontmatter declares hooks" || ok "no hooks"

echo "shared AWS context"
grep -q 'AWS_CONTEXT: unavailable' "$IR" && ok "aws-context block is rendered in" || no "aws-context block missing"
n="$(grep -c 'sts get-caller-identity' "$IR")"
[ "$n" = 1 ] && ok "no inline identity call besides the shared block" || no "sts get-caller-identity appears $n times"

echo "plan generation is read-only"
grep -q 'plan -lock=false -input=false -out=' "$TMP/all-blocks.sh" && ok "terraform plan -out without taking the state lock" \
  || no "no 'terraform plan -lock=false -input=false -out=' block"
grep -q 'show -json' "$TMP/all-blocks.sh" && ok "plan rendered with show -json" || no "no 'terraform show -json' block"
grep -q 'cdk diff' "$TMP/all-blocks.sh" && grep -q -- '--no-change-set' "$TMP/all-blocks.sh" \
  && ok "cdk diff runs without creating a change set" || no "cdk diff block missing or creates a change set"
bad="$(grep -nE 'terraform[^|;&]*[[:space:]](apply|destroy|import|state[[:space:]]+(rm|mv|push)|force-unlock)([[:space:]]|$)|cdk[[:space:]]+(deploy|destroy|bootstrap)' "$TMP/all-blocks.sh")"
[ -z "$bad" ] && ok "no apply/destroy/import/state-mutation/deploy in any block" || no "mutating command in a block: $bad"
kbad="$(grep -oE 'kubectl[[:space:]]+[a-z-]+([[:space:]]+[a-z-]+)?' "$TMP/all-blocks.sh" \
  | grep -vE '^kubectl[[:space:]]+(get|describe|version|config[[:space:]]+current-context|auth[[:space:]]+can-i)' | sort -u)"
[ -z "$kbad" ] && ok "kubectl calls are get/describe/version/current-context only" || no "non-read kubectl call: $kbad"
ebad="$(grep -oE 'aws[[:space:]]+eks[[:space:]]+[a-z-]+' "$TMP/all-blocks.sh" | grep -vE 'eks[[:space:]]+(describe|list)-' | sort -u)"
[ -z "$ebad" ] && ok "aws eks calls are describe-/list- only" || no "non-read aws eks call: $ebad"

echo "generated plan cleanup"
# Value: protects=a generated plan (secrets in clear text) never outlives a failed or interrupted run in TMPDIR; fails_when=the Step 1 block keeps the plan dir on failure, keeps the binary plan, or never sweeps an aborted run's dir; why_new=only Step 6 deleted the plan; seam=a fake terraform on PATH
block "$IR" 'PLAN_DIR="$(mktemp -d' > "$TMP/step1.tpl"
if [ -s "$TMP/step1.tpl" ]; then
  FT="$TMP/faketf"; mkdir -p "$FT" "$TMP/root/.terraform"
  for t in find touch mkdir sleep; do p="$(command -v "$t")" && ln -sf "$p" "$FT/$t"; done
  cat > "$FT/terraform" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    plan) [ "$TF_MODE" = fail ] && { echo "Error: boom" >&2; exit 1; }
          [ "$TF_MODE" = term ] && { kill -TERM "$PPID"; sleep 1; exit 1; }
          for b in "$@"; do case "$b" in -out=*) echo bin > "${b#-out=}" ;; esac; done; exit 0 ;;
    show) echo '{"format_version":"1.2","password":"hunter2"}'; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$FT/terraform"
  sed "s|<TF_DIR>|$TMP/root|" "$TMP/step1.tpl" > "$TMP/step1.sh"
  stale="$TMP/iac-review.OLDOLD"; mkdir -p "$stale"; echo secret > "$stale/plan.json"; touch -t 202001010000 "$stale"
  BASH_BIN="$(command -v bash)"
  out="$(env -i HOME="$TMP" TMPDIR="$TMP" TF_MODE=ok PATH="$FT:$TOOLS" "$BASH_BIN" "$TMP/step1.sh" 2>&1)"
  pd="$(printf '%s\n' "$out" | sed -n 's/^PLAN_DIR: //p')"
  [ -n "$pd" ] && [ -s "$pd/plan.json" ] && [ ! -e "$pd/plan.bin" ] \
    && ok "a generated plan keeps plan.json for Step 2 and drops the binary plan" || no "ok run: $(printf '%s' "$out" | tr '\n' '|'); $(ls "$pd" 2>&1 | tr '\n' ' ')"
  [ ! -e "$stale" ] && ok "an aborted run's plan dir older than an hour is swept" || no "stale iac-review dir left in TMPDIR"
  rm -rf "$pd"
  for mode in fail term; do
    out="$(env -i HOME="$TMP" TMPDIR="$TMP" TF_MODE=$mode PATH="$FT:$TOOLS" "$BASH_BIN" "$TMP/step1.sh" 2>&1)"
    pd="$(printf '%s\n' "$out" | sed -n 's/^PLAN_DIR: //p')"
    [ -n "$pd" ] && [ ! -e "$pd" ] && ok "terraform plan $mode: the plan dir is removed" \
      || no "terraform plan $mode: plan dir ${pd:-?} left behind: $(printf '%s' "$out" | tr '\n' '|')"
  done
else
  no "no Step 1 plan block found"
fi

echo "plan ranker"
block "$IR" 'RANKED:' > "$TMP/rank.sh"
if [ -s "$TMP/rank.sh" ] && grep -q "PLAN_JSON='<PLAN_JSON>'" "$TMP/rank.sh"; then
  ok "ranker block restates PLAN_JSON from a placeholder"
else
  no "no ranker block with PLAN_JSON='<PLAN_JSON>'"
fi
grep -q 'python3 -I' "$TMP/rank.sh" && ok "ranker runs python3 isolated" || no "ranker python3 lacks -I"

cat > "$TMP/risky.json" <<'JSON'
{"format_version":"1.2","terraform_version":"1.9.0","planned_values":{},
 "resource_changes":[
  {"address":"aws_db_instance.main","mode":"managed","type":"aws_db_instance","name":"main",
   "change":{"actions":["delete","create"],"after":{},"after_sensitive":{"password":true},"replace_paths":[["engine_version"]]}},
  {"address":"aws_security_group.old","mode":"managed","type":"aws_security_group","name":"old",
   "change":{"actions":["delete"],"after":null,"after_sensitive":false}},
  {"address":"aws_instance.web","mode":"managed","type":"aws_instance","name":"web",
   "change":{"actions":["create","delete"],"after":{},"after_sensitive":{}}},
  {"address":"aws_subnet.private[0]","mode":"managed","type":"aws_subnet","name":"private","index":0,
   "change":{"actions":["no-op"],"after":{},"after_sensitive":{}}},
  {"address":"aws_subnet.private[1]","mode":"managed","type":"aws_subnet","name":"private","index":1,
   "change":{"actions":["delete","create"],"after":{},"after_sensitive":{}}},
  {"address":"aws_subnet.private[2]","mode":"managed","type":"aws_subnet","name":"private","index":2,
   "change":{"actions":["delete"],"after":null,"after_sensitive":false}},
  {"address":"random_password.db","mode":"managed","type":"random_password","name":"db",
   "change":{"actions":["create"],"after":{},"after_sensitive":{"result":true}}},
  {"address":"aws_s3_bucket.logs","mode":"managed","type":"aws_s3_bucket","name":"logs",
   "change":{"actions":["no-op"],"after":{},"after_sensitive":{}}},
  {"address":"data.aws_caller_identity.me","mode":"data","type":"aws_caller_identity","name":"me",
   "change":{"actions":["read"],"after":{},"after_sensitive":{}}}
 ],
 "output_changes":{
  "db_password":{"actions":["create"],"after_sensitive":false},
  "db_password_safe":{"actions":["create"],"after_sensitive":true},
  "endpoint":{"actions":["create"],"after_sensitive":false}},
 "configuration":{
  "provider_config":{
   "aws":{"name":"aws","full_name":"registry.terraform.io/hashicorp/aws"},
   "random":{"name":"random","full_name":"registry.terraform.io/hashicorp/random","version_constraint":"~> 3.6"}},
  "root_module":{"module_calls":{
   "vpc":{"source":"terraform-aws-modules/vpc/aws","module":{"module_calls":{
     "nested":{"source":"git::https://example.com/mods.git//net","module":{}}}}},
   "eks":{"source":"terraform-aws-modules/eks/aws","version_constraint":"20.8.4","module":{}},
   "local":{"source":"./modules/local","module":{}},
   "pinned_git":{"source":"git::https://example.com/mods.git//dns?ref=v1.2.0","module":{}}}}}}
JSON
cat > "$TMP/clean.json" <<'JSON'
{"format_version":"1.2","terraform_version":"1.9.0","planned_values":{},
 "resource_changes":[
  {"address":"aws_s3_bucket.logs","mode":"managed","type":"aws_s3_bucket","name":"logs",
   "change":{"actions":["no-op"],"after":{},"after_sensitive":{}}},
  {"address":"aws_iam_role.app","mode":"managed","type":"aws_iam_role","name":"app",
   "change":{"actions":["update"],"after":{},"after_sensitive":{}}}],
 "configuration":{"provider_config":{"aws":{"name":"aws","version_constraint":"~> 5.40"}},"root_module":{}}}
JSON
printf '{"format_version":"1.2"' > "$TMP/malformed.json"
printf '{"version":4,"terraform_version":"1.9.0","serial":3,"resources":[]}\n' > "$TMP/state.json"
printf '{"format_version":"1.2","planned_values":{},"errored":true,"resource_changes":[]}\n' > "$TMP/errored.json"

rank() { # rank <shell> <plan-json> — prints the ranker output
  sed "s#'<PLAN_JSON>'#'$2'#" "$TMP/rank.sh" > "$TMP/rank-filled.sh"
  runblock "$1" "$TMP/rank-filled.sh"
}
for SH in $SHELLS; do
  SHP="$(command -v "$SH")"
  out="$(rank "$SHP" "$TMP/risky.json")"
  for want in 'CRITICAL stateful-replace aws_db_instance.main' 'HIGH destroy aws_security_group.old' \
              'HIGH replace aws_instance.web' 'HIGH count-churn aws_subnet.private' \
              'HIGH output-unmarked db_password' 'MEDIUM sensitive-in-state random_password.db' 'MEDIUM sensitive-in-state aws_db_instance.main (password)' \
              'MEDIUM unpinned-provider aws' 'MEDIUM unpinned-module vpc ' 'MEDIUM unpinned-module vpc.nested '; do
    printf '%s\n' "$out" | grep -qF -- "$want" && ok "$SH: risky plan -> $want" || no "$SH: risky plan lacks '$want': $(printf '%s' "$out" | tr '\n' '|')"
  done
  for never in 'aws_s3_bucket.logs' 'data.aws_caller_identity' 'unpinned-provider random' 'unpinned-module eks' \
               'unpinned-module local' 'unpinned-module pinned_git' 'db_password_safe' 'output-unmarked endpoint'; do
    printf '%s\n' "$out" | grep -qF -- "$never" && no "$SH: risky plan flags '$never'" || ok "$SH: not a finding: $never"
  done
  printf '%s\n' "$out" | grep -q '^PLAN: ok' && ok "$SH: risky plan reads PLAN: ok" || no "$SH: risky plan lacks PLAN: ok"
  printf '%s\n' "$out" | grep -qx 'RANKED: 12' && ok "$SH: risky plan ranks 12 findings" \
    || no "$SH: risky plan RANKED line wrong: $(printf '%s\n' "$out" | grep RANKED)"
  first="$(printf '%s\n' "$out" | grep -E '^(CRITICAL|HIGH|MEDIUM) ' | head -n1)"
  case "$first" in CRITICAL*) ok "$SH: findings ranked most severe first" ;; *) no "$SH: first finding is '$first'" ;; esac

  out="$(rank "$SHP" "$TMP/clean.json")"
  if printf '%s\n' "$out" | grep -q '^PLAN: ok' && printf '%s\n' "$out" | grep -qx 'RANKED: 0' \
     && ! printf '%s\n' "$out" | grep -qE '^(CRITICAL|HIGH|MEDIUM) '; then
    ok "$SH: clean plan -> PLAN: ok, RANKED: 0"
  else
    no "$SH: clean plan output: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  for f in malformed state errored missing; do
    out="$(rank "$SHP" "$TMP/$f.json")"
    if printf '%s\n' "$out" | grep -q '^PLAN: N-A' && ! printf '%s\n' "$out" | grep -q '^RANKED:'; then
      ok "$SH: $f plan -> PLAN: N-A, no RANKED line"
    else
      no "$SH: $f plan did not read N-A: $(printf '%s' "$out" | tr '\n' '|')"
    fi
  done
done

echo "repo scan"
block "$IR" 'TF_FILES:' > "$TMP/scan.sh"
[ -s "$TMP/scan.sh" ] && grep -q "TF_DIR='<TF_DIR>'" "$TMP/scan.sh" && ok "scan block restates TF_DIR from a placeholder" \
  || no "no scan block with TF_DIR='<TF_DIR>'"
mkrepo() { mkdir -p "$TMP/repos/$1"; printf '%s\n' "$2" > "$TMP/repos/$1/main.tf"; }
mkrepo s3bare 'terraform {
  backend "s3" {
    bucket = "state"
    key    = "app.tfstate"
    region = "eu-west-1"
  }
}'
mkrepo s3good 'terraform {
  backend "s3" {
    bucket       = "state"
    key          = "app.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}'
touch "$TMP/repos/s3good/.terraform.lock.hcl"
mkrepo s3ddb 'terraform {
  backend "s3" {
    bucket         = "state"
    key            = "app.tfstate"
    encrypt        = true
    dynamodb_table = "locks"
  }
}'
touch "$TMP/repos/s3ddb/.terraform.lock.hcl"
mkrepo nobackend 'resource "aws_sqs_queue" "q" {}'
mkdir -p "$TMP/repos/nobackend/.terraform/modules/x"
printf 'terraform {\n  backend "s3" {\n    bucket = "x"\n  }\n}\n' > "$TMP/repos/nobackend/.terraform/modules/x/main.tf"
mkrepo partial 'terraform {
  backend "s3" {}
}'
mkdir -p "$TMP/repos/empty"
scan() { # scan <shell> <dir>
  sed "s#'<TF_DIR>'#'$2'#" "$TMP/scan.sh" > "$TMP/scan-filled.sh"
  runblock "$1" "$TMP/scan-filled.sh"
}
for SH in $SHELLS; do
  SHP="$(command -v "$SH")"
  out="$(scan "$SHP" "$TMP/repos/s3bare")"
  printf '%s\n' "$out" | grep -q '^MEDIUM backend-unencrypted' && printf '%s\n' "$out" | grep -q '^HIGH backend-no-lock' \
    && printf '%s\n' "$out" | grep -q '^MEDIUM no-lock-file' \
    && ok "$SH: bare s3 backend -> unencrypted, no lock, no lock file" || no "$SH: bare s3 backend: $(printf '%s' "$out" | tr '\n' '|')"
  out="$(scan "$SHP" "$TMP/repos/s3good")"
  if printf '%s\n' "$out" | grep -q '^BACKEND: s3' && printf '%s\n' "$out" | grep -qx 'REPO_FINDINGS: 0'; then
    ok "$SH: encrypted, locked s3 backend with a lock file -> no finding"
  else
    no "$SH: good s3 backend flagged: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  out="$(scan "$SHP" "$TMP/repos/s3ddb")"
  printf '%s\n' "$out" | grep -qx 'REPO_FINDINGS: 0' && ok "$SH: dynamodb_table counts as locking" \
    || no "$SH: dynamodb lock flagged: $(printf '%s' "$out" | tr '\n' '|')"
  out="$(scan "$SHP" "$TMP/repos/nobackend")"
  if printf '%s\n' "$out" | grep -q '^MEDIUM backend-local' && printf '%s\n' "$out" | grep -qx 'TF_FILES: 1'; then
    ok "$SH: no backend -> backend-local, .terraform/ not scanned"
  else
    no "$SH: no-backend repo: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  out="$(scan "$SHP" "$TMP/repos/partial")"
  printf '%s\n' "$out" | grep -q '^N-A backend-s3' && ! printf '%s\n' "$out" | grep -q 'backend-unencrypted' \
    && ok "$SH: partial backend config -> N-A, not guessed" || no "$SH: partial backend: $(printf '%s' "$out" | tr '\n' '|')"
  out="$(scan "$SHP" "$TMP/repos/empty")"
  printf '%s\n' "$out" | grep -qx 'TF_FILES: 0' && ! printf '%s\n' "$out" | grep -q 'backend-local' \
    && ok "$SH: no Terraform files -> TF_FILES: 0, nothing claimed" || no "$SH: empty dir: $(printf '%s' "$out" | tr '\n' '|')"
done

echo "scanner probe"
block "$IR" 'SCANNER:' > "$TMP/scanners.sh"
SC="$TMP/scanner-bin"; mkdir -p "$SC"; printf '#!/bin/sh\nexit 0\n' > "$SC/tflint"; chmod +x "$SC/tflint"
for SH in $SHELLS; do
  out="$(runblock "$(command -v "$SH")" "$TMP/scanners.sh" "$SC")"
  if printf '%s\n' "$out" | grep -qx 'SCANNER: tflint present' && printf '%s\n' "$out" | grep -qx 'SCANNER: checkov absent' \
     && printf '%s\n' "$out" | grep -qx 'SCANNER: trivy absent' && printf '%s\n' "$out" | grep -qx 'SCANNER: kube-linter absent'; then
    ok "$SH: each scanner reported present or absent"
  else
    no "$SH: scanner probe output: $(printf '%s' "$out" | tr '\n' '|')"
  fi
done

echo "EKS section and links"
eks="$(awk '/^## EKS/ {on=1; print; next} on && /^## / {exit} on' "$IR")"
[ -n "$eks" ] && ok "## EKS section present" || no "no ## EKS section"
for term in endpoint_public_access public_access_cidrs IRSA 'Pod Identity' 'pod-security.kubernetes.io/enforce' \
            NetworkPolicy 'resources.requests' PodDisruptionBudget describe-addon-versions AskUserQuestion; do
  printf '%s\n' "$eks" | grep -qF -- "$term" && ok "EKS covers $term" || no "EKS section lacks $term"
done
grep -qF '/aws-cost --estimate' "$IR" && ok "links /aws-cost --estimate" || no "no /aws-cost --estimate link"
grep -qE '(^|[^a-z-])/cso([^a-z-]|$)' "$IR" && ok "links /cso" || no "no /cso link"
grep -qF 'N-A is never a pass' "$IR" && grep -qF 'INCOMPLETE' "$IR" \
  && ok "N-A never counts as a pass; INCOMPLETE verdict exists" || no "N-A rule or INCOMPLETE verdict missing"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
