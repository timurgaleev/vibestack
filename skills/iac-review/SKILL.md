---
name: iac-review
description: |
  Read-only review of a Terraform plan or cdk diff: destroys, replacements, state safety, pins, secrets, EKS.
triggers:
  - review the terraform plan
  - iac review
  - review the cdk diff
  - is this plan safe to apply
  - eks review
  - review the eks cluster
  - check the terraform state backend
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

If this session was compacted, the copy of this skill in context may be cut off.
Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.

## When to invoke

Use when: "review this terraform plan", "is this plan safe to apply", "what will this cdk diff destroy", "review our Terraform", "review the EKS cluster config", "check the state backend". Read-only: it never applies, deploys, imports, moves state or edits a file.

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

## User-invocable
When the user types `/iac-review`, run this skill. `/iac-review <plan.json | planfile | dir>` reviews that input.

**N-A is never a pass.** Every check below ends as FINDING, PASS or `N-A (<reason>)`. A check that could not run — no plan, a failed call, a scanner not installed, a partial backend config — is N-A with the reason, and it keeps the verdict at INCOMPLETE. An empty result counts as PASS only when the call that produced it succeeded.

---

## Step 0: Find the inputs

```bash
find . \( -name .terraform -o -name node_modules -o -name .git -o -name cdk.out \) -prune -o \
  \( -name '*.tf' -o -name cdk.json -o -name Chart.yaml -o -name '*.tfplan' -o -name 'plan*.json' \) -print 2>/dev/null | head -n 60
grep -rlE '^kind:[[:space:]]*(Deployment|StatefulSet|DaemonSet|Namespace|NetworkPolicy|PodDisruptionBudget)' \
  --include='*.yaml' --include='*.yml' . 2>/dev/null | grep -vE 'node_modules|/\.terraform/' | head -n 40
grep -rlE 'aws_eks_|AWS::EKS::|eks\.Cluster|terraform-aws-modules/eks' --include='*.tf' --include='*.ts' \
  --include='*.py' --include='*.json' . 2>/dev/null | grep -vE 'node_modules|/\.terraform/|cdk\.out' | head -n 20
```

A Terraform root module is a directory whose `.tf` files hold a `backend` or `cloud` block, or the provider configuration. When there are several roots (`envs/prod`, `envs/staging`), ask which one (AskUserQuestion) unless the request named it. Write the scope in one line: root module or CDK app, environment, and whether EKS resources, manifests or Helm values are present — that decides whether the `## EKS` section runs.

{{include lib/snippets/aws-context.md}}

The identity matters here because a plan and a `cdk diff` read live state with it: a plan run against the wrong account reports a diff for the wrong environment.

---

## Step 1: Get the plan

Prefer a plan the user already has. A `terraform show -json` file is used as-is; a binary plan file is rendered with `terraform show -json <planfile>`; a `cdk diff` printout is read as text. Only when there is none, generate one.

Generating a plan runs the providers with the user's credentials and executes any `external` data source in the configuration; `cdk diff` synthesizes the app, which runs its code. Ask once (AskUserQuestion) before the first of these, naming the root module, the profile and region from the context block, and that `terraform init` downloads the providers and modules the configuration names when `.terraform/` is missing. On no, every plan check is `N-A (no plan: declined)` and Step 3 still runs.

```bash
TF_DIR='<TF_DIR>'
PLAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iac-review.XXXXXX")"
echo "PLAN_DIR: $PLAN_DIR"
INIT_OK=1; NEW_LOCK=0
if [ ! -d "$TF_DIR/.terraform" ]; then
  if [ -f "$TF_DIR/.terraform.lock.hcl" ]; then
    terraform -chdir="$TF_DIR" init -input=false -lockfile=readonly >"$PLAN_DIR/plan.log" 2>&1 || INIT_OK=0
  else
    NEW_LOCK=1
    terraform -chdir="$TF_DIR" init -input=false >"$PLAN_DIR/plan.log" 2>&1 || INIT_OK=0
  fi
fi
if [ "$INIT_OK" = 0 ]; then
  echo "PLAN_JSON: N-A (terraform init failed)"; tail -n 20 "$PLAN_DIR/plan.log"
elif terraform -chdir="$TF_DIR" plan -lock=false -input=false -out="$PLAN_DIR/plan.bin" >>"$PLAN_DIR/plan.log" 2>&1 \
  && terraform -chdir="$TF_DIR" show -json "$PLAN_DIR/plan.bin" >"$PLAN_DIR/plan.json" 2>>"$PLAN_DIR/plan.log"; then
  echo "PLAN_JSON: $PLAN_DIR/plan.json"
else
  echo "PLAN_JSON: N-A (terraform plan failed)"; tail -n 20 "$PLAN_DIR/plan.log"
fi
if [ "$NEW_LOCK" = 1 ]; then rm -f "$TF_DIR/.terraform.lock.hcl"; fi
```

`-lock=false` keeps a read-only review from holding the state lock someone else's apply needs. `-lockfile=readonly` stops init from rewriting an existing `.terraform.lock.hcl`; a root with none gets a plain init, and the lock file that init writes is removed afterwards so Step 3 still sees it missing. The plan JSON carries sensitive values in clear text: never print it, never paste from it, and delete it in Step 6.

For a CDK app, use the project's own CDK (no download); `--no-change-set` diffs against the deployed template without creating a CloudFormation change set:

```bash
CDK_DIR='<CDK_DIR>'
(cd "$CDK_DIR" && npx --no-install cdk diff --no-change-set 2>&1) | tail -n 400
```

---

## Step 2: Rank what the plan changes

```bash
PLAN_JSON='<PLAN_JSON>'
python3 -I - "$PLAN_JSON" <<'PY'
import json, re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        plan = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"PLAN: N-A (cannot read the plan JSON: {type(exc).__name__})")
    sys.exit(0)
if not isinstance(plan, dict) or "format_version" not in plan or "planned_values" not in plan:
    print("PLAN: N-A (not terraform show -json output for a plan; a state file or other JSON)")
    sys.exit(0)
if plan.get("errored"):
    print("PLAN: N-A (the plan errored, so its change list is incomplete)")
    sys.exit(0)

STATEFUL = {
    "aws_db_instance", "aws_rds_cluster", "aws_rds_cluster_instance", "aws_docdb_cluster", "aws_neptune_cluster",
    "aws_redshift_cluster", "aws_dynamodb_table", "aws_s3_bucket", "aws_efs_file_system", "aws_ebs_volume",
    "aws_fsx_lustre_file_system", "aws_fsx_windows_file_system", "aws_fsx_ontap_file_system",
    "aws_elasticache_cluster", "aws_elasticache_replication_group", "aws_elasticache_serverless_cache",
    "aws_memorydb_cluster", "aws_opensearch_domain", "aws_elasticsearch_domain", "aws_msk_cluster",
    "aws_kinesis_stream", "aws_sqs_queue", "aws_kms_key", "aws_secretsmanager_secret", "aws_cognito_user_pool",
    "aws_route53_zone", "aws_eks_cluster", "aws_backup_vault", "aws_ecr_repository",
    "google_sql_database_instance", "google_storage_bucket", "google_bigquery_dataset", "google_container_cluster",
    "azurerm_storage_account", "azurerm_mssql_database", "azurerm_postgresql_flexible_server",
    "azurerm_kubernetes_cluster", "azurerm_key_vault",
}
SECRET_NAME = re.compile(r"password|passwd|secret|token|private_?key|api_?key|credential", re.I)
RANK = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2}
found = []

def add(sev, label, subject, detail=""):
    found.append((RANK[sev], sev, label, subject, detail))

def sensitive_paths(node, prefix=""):
    if node is True:
        yield prefix or "whole value"
    elif isinstance(node, dict):
        for key, val in node.items():
            yield from sensitive_paths(val, f"{prefix}.{key}" if prefix else str(key))
    elif isinstance(node, list):
        for i, val in enumerate(node):
            yield from sensitive_paths(val, f"{prefix}[{i}]")

changed, groups = 0, {}
for rc in plan.get("resource_changes") or []:
    change = rc.get("change") or {}
    acts = change.get("actions") or []
    if rc.get("mode") != "managed" or not acts or set(acts) <= {"no-op", "read"}:
        continue
    changed += 1
    addr, rtype = rc.get("address", "?"), rc.get("type", "?")
    replace = "delete" in acts and "create" in acts
    delete = acts == ["delete"]
    forced = ", ".join(".".join(map(str, p)) for p in change.get("replace_paths") or [])
    detail = "(" + "+".join(acts) + (f"; forced by {forced}" if forced else "") + ")"
    if rtype in STATEFUL and (replace or delete):
        add("CRITICAL", "stateful-replace" if replace else "stateful-destroy", addr, detail)
    elif delete:
        add("HIGH", "destroy", addr, detail)
    elif replace:
        add("HIGH", "replace", addr, detail)
    indexed = re.fullmatch(r"(.+)\[(\d+)\]", addr)
    if indexed and not rc.get("previous_address"):
        groups.setdefault(indexed.group(1), []).append((int(indexed.group(2)), replace or delete))
    if not delete:
        paths = list(sensitive_paths(change.get("after_sensitive")))
        if paths:
            add("MEDIUM", "sensitive-in-state", addr, "(" + ", ".join(paths[:3]) + ")")

for base, members in sorted(groups.items()):
    if len(members) >= 2 and any(destructive for _, destructive in members):
        idx = ",".join(str(i) for i, _ in sorted(members))
        add("HIGH", "count-churn", base, f"(indexes {idx} change together: an element moved in a count list)")

for name, oc in sorted((plan.get("output_changes") or {}).items()):
    if (oc.get("actions") or []) != ["delete"] and SECRET_NAME.search(name) and oc.get("after_sensitive") is not True:
        add("HIGH", "output-unmarked", name, "(secret-named output without sensitive = true)")

cfg = plan.get("configuration") or {}
pinned = {}
for key, pc in (cfg.get("provider_config") or {}).items():
    name = pc.get("name", key)
    pinned[name] = pinned.get(name, False) or bool(pc.get("version_constraint"))
for name in sorted(n for n, ok in pinned.items() if not ok and n != "terraform"):
    add("MEDIUM", "unpinned-provider", name, "(no version constraint in required_providers)")

def walk(calls, prefix):
    for name, mc in sorted((calls or {}).items()):
        full, src = prefix + name, mc.get("source", "")
        if src.startswith(("./", "../")):
            pass
        elif "::" in src or "://" in src or src.startswith(("github.com/", "bitbucket.org/", "git@")):
            if not re.search(r"[?&]ref=", src):
                add("MEDIUM", "unpinned-module", full, f"{src} (no ?ref=)")
        elif not mc.get("version_constraint"):
            add("MEDIUM", "unpinned-module", full, f"{src} (no version)")
        walk((mc.get("module") or {}).get("module_calls"), full + ".")

walk((cfg.get("root_module") or {}).get("module_calls"), "")

print(f"PLAN: ok {changed} resource changes")
for _, sev, label, subject, detail in sorted(found, key=lambda f: f[0]):
    print(" ".join(part for part in (sev, label, subject, detail) if part))
print(f"RANKED: {len(found)}")
PY
```

The block prints addresses and attribute paths, never values. What each label means and what to recommend:

- **stateful-replace / stateful-destroy** (CRITICAL) — a database, bucket, volume, queue, key or cluster is deleted or recreated, and its data with it. Name the attribute that forces it (`forced by`). Fix: revert that attribute, or plan the migration (snapshot, `create_before_destroy`, a new resource plus cut-over); add `lifecycle { prevent_destroy = true }` and the service's deletion protection.
- **destroy / replace** (HIGH) — read each one: a replaced security group, IAM role or launch template is often harmless, a replaced load balancer or NAT gateway changes an endpoint or IP. Downgrade to MEDIUM with the reason when the address is clearly disposable; never drop it.
- **count-churn** (HIGH) — several indexes of one `count` resource change together: an element was inserted or removed mid-list and every later index shifts. Fix: `for_each` keyed by a stable value, with `moved` blocks so the existing objects keep their addresses.
- **output-unmarked** (HIGH) — a secret-named output is printed in plain text by every `plan` and `apply`, and in CI logs. Fix: `sensitive = true`, or drop the output.
- **sensitive-in-state** (MEDIUM) — the value is redacted in the CLI but stored in clear text in state. This is normal for Terraform; the finding is what it makes the backend checks worth. Raise it to HIGH when Step 3 finds the backend unencrypted or local.
- **unpinned-provider / unpinned-module** (MEDIUM) — the next `init -upgrade` or a fresh checkout pulls a different version. A git source pinned to a branch (`?ref=main`) is not a pin either; read the `ref`.

**CDK diff.** Read the printed diff the same way: a `[-]` resource is a destroy; `requires replacement` or `may be replaced` is a replace; a stateful CloudFormation type (`AWS::RDS::*`, `AWS::DynamoDB::Table`, `AWS::S3::Bucket`, `AWS::EFS::FileSystem`, `AWS::ElastiCache::*`, `AWS::OpenSearchService::Domain`, `AWS::KMS::Key`, `AWS::SQS::Queue`, `AWS::EKS::Cluster`) destroyed or replaced is CRITICAL unless its `DeletionPolicy` is `Retain` or `Snapshot`. A `[-]` and a `[+]` of the same type with different logical ids is the CDK form of count churn — a construct was renamed or moved; fix with the original id (`overrideLogicalId`) or a planned migration.

---

## Step 3: State backend, lock file and pins

```bash
TF_DIR='<TF_DIR>'
python3 -I - "$TF_DIR" <<'PY'
import os, re, sys

root = sys.argv[1]
if not os.path.isdir(root):
    print("TF_FILES: N-A (not a directory)")
    sys.exit(0)
skip = {".terraform", ".git", "node_modules", "cdk.out", ".terragrunt-cache"}
tf_files = []
for here, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in skip]
    tf_files += [os.path.join(here, f) for f in files if f.endswith(".tf")]
print(f"TF_FILES: {len(tf_files)}")
if not tf_files:
    sys.exit(0)

def block_body(text, brace):
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    return text[brace + 1:]

backends, findings = [], []
for path in sorted(tf_files):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = re.sub(r"(?m)^\s*(#|//).*$", "", fh.read())
    except OSError:
        continue
    rel = os.path.relpath(path, root)
    for m in re.finditer(r'\bbackend\s+"([A-Za-z0-9_]+)"\s*\{', text):
        backends.append((m.group(1), rel, block_body(text, m.end() - 1)))
    if re.search(r"(?m)^\s*cloud\s*\{", text):
        backends.append(("cloud", rel, ""))

if not backends:
    findings.append(("MEDIUM", "backend-local", "(no backend block: state stays on one disk, unlocked and unshared)"))
for kind, rel, body in backends:
    print(f"BACKEND: {kind} {rel}")
    if kind == "s3":
        if not re.search(r"(?m)^\s*bucket\s*=", body):
            print(f"N-A backend-s3 {rel} (partial config: values come from -backend-config at init; read that file)")
            continue
        if not re.search(r"(?m)^\s*encrypt\s*=\s*true\b", body):
            findings.append(("MEDIUM", "backend-unencrypted", f"{rel} (no encrypt = true; check the bucket's default encryption)"))
        if not re.search(r"(?m)^\s*(use_lockfile\s*=\s*true\b|dynamodb_table\s*=)", body):
            findings.append(("HIGH", "backend-no-lock", f"{rel} (no use_lockfile or dynamodb_table: two applies can corrupt state)"))
    elif kind == "local":
        findings.append(("MEDIUM", "backend-local", f"{rel} (local backend)"))
    elif kind not in ("gcs", "azurerm", "remote", "cloud"):
        print(f"N-A backend-{kind} {rel} (encryption and locking not assessed for this backend)")

if not os.path.exists(os.path.join(root, ".terraform.lock.hcl")):
    findings.append(("MEDIUM", "no-lock-file", "(no .terraform.lock.hcl in the root module: provider builds are not pinned)"))
order = {"HIGH": 0, "MEDIUM": 1}
for sev, label, detail in sorted(findings, key=lambda f: order[f[0]]):
    print(sev, label, detail)
print(f"REPO_FINDINGS: {len(findings)}")
PY
```

`gcs`, `azurerm` and HCP (`remote`, `cloud`) encrypt and lock natively. For an `N-A backend-s3` partial config, read the `-backend-config` file the repo uses (`*.tfbackend`, `backend.hcl`, a CI step) and judge it by the same two rules. With the context block's identity confirmed, the state bucket can be checked read-only: `aws s3api get-bucket-encryption`, `get-bucket-versioning` and `get-public-access-block` on the bucket the backend names — a failed call is N-A. Without a plan, read `required_providers` and each `module` block's `source`/`version` by hand for the pin checks.

---

## Step 4: Static scanners, only when installed

```bash
for _t in checkov tfsec trivy tflint kube-linter kubeconform; do
  if command -v "$_t" >/dev/null 2>&1; then echo "SCANNER: $_t present"; else echo "SCANNER: $_t absent"; fi
done
```

Run each present one read-only against the root module or the manifest directory: `checkov -d <dir> --compact --quiet`, `tfsec <dir>`, `trivy config --skip-check-update <dir>`, `tflint --chdir=<dir>`, `kube-linter lint <dir>`, `kubeconform -summary <dir>`. Never install one, and never run `tflint --init` or anything else that downloads. Name every absent scanner in the report; the review does not depend on them. A scanner hit is a candidate: confirm it in the source before it becomes a finding, and report a confirmed one under its own check.

---

## EKS

Run this section when the plan or the repo holds `aws_eks_*` resources, the `terraform-aws-modules/eks` module, an `AWS::EKS::Cluster`, Kubernetes manifests or Helm values; otherwise every row is `N-A (no EKS in scope)`. Static first: read the Terraform, the manifests, and Helm values (`helm template <local chart> -f <values>` when `helm` is installed — never `install`, `upgrade` or `dependency update`).

| Check | Where to read it | Finding |
|-------|------------------|---------|
| API endpoint exposure | `vpc_config.endpoint_public_access` and `public_access_cidrs` on `aws_eks_cluster` (module: `cluster_endpoint_public_access[_cidrs]` or `endpoint_public_access[_cidrs]`). Both default to public and `0.0.0.0/0`, so an absent setting is public to the internet. | Public with `0.0.0.0/0` → HIGH. Public with narrow CIDRs → LOW. Private only → PASS. |
| Workload identity vs node-role sprawl | IRSA (an OIDC provider plus `eks.amazonaws.com/role-arn` on service accounts) or Pod Identity (`aws_eks_pod_identity_association`, the `eks-pod-identity-agent` add-on). Then the node group role's policies: beyond `AmazonEKSWorkerNodePolicy`, the ECR read/pull policy, `AmazonEKS_CNI_Policy` and `AmazonSSMManagedInstanceCore`, every pod on the node inherits them. Launch template `http_put_response_hop_limit` above 1 lets pods reach the node's credentials. | Admin, `*` or a service-wide FullAccess policy on the node role → HIGH. Extra app policies on the node role, or hop limit > 1 → MEDIUM. |
| Pod Security admission | Namespace label `pod-security.kubernetes.io/enforce` on every application namespace (`kube-system` and add-on namespaces excepted). No label means `privileged`. | Missing or `privileged` on an app namespace → MEDIUM. `baseline` or `restricted` → PASS. |
| Network policies | A `NetworkPolicy` (default-deny plus allows) in every namespace with workloads, and something enforcing it: the VPC CNI with `enableNetworkPolicy` set in the `vpc-cni` add-on's configuration values, Calico or Cilium. | Policies with no enforcing engine → HIGH (they read as protection and do nothing). A workload namespace without any policy → MEDIUM. |
| Requests and limits | `resources.requests` (cpu and memory) on every container; Helm `resources: {}` counts as missing. | Missing requests → MEDIUM. Missing memory limit → LOW. |
| Disruption budgets | A `PodDisruptionBudget` matching every Deployment or StatefulSet with 2+ replicas. | None for a multi-replica workload → LOW (MEDIUM for a StatefulSet or the ingress controller). `maxUnavailable: 0` or `minAvailable` equal to replicas → MEDIUM: it blocks node drains and upgrades. |
| Version and add-on lag | Cluster `version`; each `aws_eks_addon` `addon_version` against `aws eks describe-addon-versions` for that Kubernetes version. | Cluster past standard support → HIGH (extended support also bills more: `/aws-cost`). Add-on incompatible with the cluster version → HIGH. Behind the default version → LOW. No live data → N-A. |

**Live, read-only, optional.** Only when the static pass leaves rows N-A and the tools are present. Print what a call would touch first — this reads local config only:

```bash
command -v kubectl >/dev/null 2>&1 && kubectl config current-context 2>/dev/null || echo "KUBECTL: absent or no current context"
```

Then ask once (AskUserQuestion), naming the kube context printed above, the cluster, and the AWS profile and region from the context block. On yes, only these calls; each failed call makes its rows `N-A (<command> failed)`:

```bash
CLUSTER='<CLUSTER>'
REGION='<REGION>'
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --output json \
  --query 'cluster.{version:version,public:resourcesVpcConfig.endpointPublicAccess,cidrs:resourcesVpcConfig.publicAccessCidrs}' \
  || echo "EKS_CLUSTER: N-A (describe-cluster failed)"
aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --output text || echo "EKS_ADDONS: N-A (list-addons failed)"
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" --output text \
  || echo "EKS_POD_IDENTITY: N-A (list-pod-identity-associations failed)"
kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' \
  || echo "PSA: N-A (kubectl get namespaces failed)"
kubectl get networkpolicies -A --no-headers || echo "NETPOL: N-A (kubectl get networkpolicies failed)"
kubectl get pdb -A --no-headers || echo "PDB: N-A (kubectl get pdb failed)"
```

For an add-on's lag: `aws eks describe-addon --cluster-name "$CLUSTER" --addon-name <name> --region "$REGION"` for the installed version, and `aws eks describe-addon-versions --kubernetes-version <cluster version> --addon-name <name> --region "$REGION"` for the default one. Never `kubectl apply`, `edit`, `delete`, `exec` or `port-forward`, and no `aws eks update-*`, `create-*` or `delete-*`.

---

## Step 5: Severity and verdict

- **CRITICAL** — data loss on apply: a stateful resource destroyed or replaced.
- **HIGH** — an outage, an exposure or a corrupted state is likely: destroys and replacements, count churn, unlocked state, secrets printed in plain text, a world-open cluster endpoint, an over-privileged node role, unenforced network policies.
- **MEDIUM** — a weakness that needs a second mistake to hurt: unpinned versions, unencrypted or local state, sensitive values in state, missing Pod Security, policies or requests.
- **LOW** — hygiene.

Verdict: **BLOCK** if any CRITICAL; **FIX FIRST** if any HIGH; **INCOMPLETE** if neither but any check is N-A — including no plan at all; **OK** only when every check ran and none is above LOW.

---

## Step 6: Report and clean up

```
IAC REVIEW
==========
Scope:     <root module / CDK app / manifests>   Environment: <name>
Plan:      <PLAN: line, or N-A + reason>  (source: provided file | generated | none)
AWS:       PROFILE / REGION / ACCOUNT / PRINCIPAL from the context block, or N-A
Scanners:  <present: what ran and its hit count>  <absent: names>
Verdict:   BLOCK | FIX FIRST | INCOMPLETE | OK

Findings (most severe first)
| # | Severity | Check | Address / file:line | Evidence | Fix |

Checks
| Check | Result |   one row per check in Steps 2-4 and the EKS table: FINDING (#n) / PASS / N-A (<reason>)

Next
- Cost of this change: /aws-cost --estimate <plan JSON>   (before Step 6 deletes it)
- Secrets, CI/CD and supply chain beyond this plan: /cso
```

Offer `/aws-cost --estimate` while the plan JSON still exists. Then delete the generated plan — it holds secrets in clear text:

```bash
PLAN_DIR='<PLAN_DIR>'
rm -f "$PLAN_DIR/plan.bin" "$PLAN_DIR/plan.json" "$PLAN_DIR/plan.log" && rmdir "$PLAN_DIR" && echo "PLAN_DIR: removed"
```

Skip that block when the user supplied the plan; it is theirs. Finish with the completion status from the working protocols.
