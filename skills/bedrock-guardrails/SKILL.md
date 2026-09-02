---
name: bedrock-guardrails
description: |
  Audit the guardrail layer around Amazon Bedrock usage: region pinning and cross-region inference profiles, IAM scoping to model ARNs, Bedrock Guardrails configuration (PII, denied topics, content and word filters, grounding, versioning), invocation logging and KMS, per-tenant isolation, prompt injection boundaries, quotas and cost controls. Use before shipping an LLM feature on Bedrock, during a security or EU data residency review, or when designing the Terraform for a new Bedrock workload. Read-only; produces a PASS/FAIL/N-A control table with Terraform remediation for every FAIL.
triggers:
  - bedrock guardrails
  - bedrock security review
  - bedrock region lock
  - pii in prompts
  - bedrock iam policy
  - tenant isolation bedrock
  - eu data residency llm
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "bedrock guardrails", "review our bedrock setup", "is bedrock locked to eu-central-1", "do we leak PII into prompts", "bedrock IAM policy", "tenant isolation for the knowledge base", "EU data residency for the LLM feature", or when a PR adds a Bedrock invoke and nobody has looked at the surrounding controls yet.

## Preamble

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    ~/.vibestack/bin/vibe-learnings-search --limit 5 2>/dev/null || true
  fi
else
  echo "LEARNINGS: none yet"
fi
```

{{include lib/snippets/session-host.md}}

{{include lib/snippets/decision-brief.md}}

{{include lib/snippets/working-protocols.md}}

{{include lib/snippets/state-protocols.md}}

## User-invocable
When the user types `/bedrock-guardrails`, run this skill.

---

## Step 1: Locate Bedrock usage and decide the residency regime

Find every place the repo talks to Bedrock. Search infrastructure code and application code separately, because the controls live in different files.

```bash
grep -rnE 'aws_bedrock|bedrock:|AWS::Bedrock|aws_bedrockagent|bedrock_guardrail|InvokeModel' \
  --include='*.tf' --include='*.ts' --include='*.py' --include='*.yaml' --include='*.yml' --include='*.json' . 2>/dev/null \
  | grep -vE 'node_modules|\.terraform/|dist/|build/' | head -80
grep -rnE 'bedrock-runtime|BedrockRuntime|bedrock_runtime|boto3\.client\(["'"'"']bedrock|@aws-sdk/client-bedrock|invoke_model|InvokeModel|converse\(|Converse(Stream)?Command|retrieve_and_generate|RetrieveAndGenerate' \
  --include='*.py' --include='*.ts' --include='*.js' --include='*.go' --include='*.java' --include='*.kt' --include='*.rb' . 2>/dev/null \
  | grep -vE 'node_modules|\.terraform/|dist/|build/|_test\.|\.test\.|spec\.' | head -80
```

Record each hit as a call site: file, line, model or profile id, and whether a guardrail is passed. This list is the row source for the rest of the audit.

Then decide the residency regime. Look for the deploying account's region in `provider "aws"` blocks, `AWS_REGION`/`AWS_DEFAULT_REGION` in env files and CI, and `aws configure get region` when the CLI is present. If the account region is `eu-central-1`, `eu-west-1`, or any other `eu-*`, or the repo's docs mention GDPR, EU customers, or data residency, set `RESIDENCY=EU`. Under `RESIDENCY=EU`, any call that resolves to a `us-*` region or a `us.` / `global.` inference profile is a HIGH finding, no exceptions.

Check whether the CLI is usable for read-only evidence with `aws sts get-caller-identity --output text 2>/dev/null || echo "NO_AWS_CLI_SESSION"`. If there is no session, mark every control that needs live account state as `N-A (no CLI)` with a note on what to run, and audit from code alone. Do not ask for credentials.

---

## Step 2: Region control

For each call site, determine the effective region and model target.

What to check:

- The client is built with an explicit region (`region_name=`, `region:`, `AWS_REGION` read at startup), not the SDK default chain. A client with no region is a FAIL (MEDIUM; HIGH under EU).
- The model id is either a plain foundation model in the pinned region, or an inference profile whose prefix matches the residency regime: `eu.` stays inside EU regions, `us.` inside US regions, `global.` can route anywhere. Under `RESIDENCY=EU`, a `us.` or `global.` prefix is HIGH.
- Cross-region inference is a written decision. Grep for an ADR, a README section, or a comment near the invoke, then Read that file and confirm it names the destination regions and why. A `global.` or cross-region profile with no written decision is MEDIUM.
- IAM region conditions account for inference profiles. This is the trap: `aws:RequestedRegion` checks the endpoint the caller hit, not where the profile routes, and on a `global.` profile Bedrock sets it to `unspecified` for the routed leg, so no region name ever matches there. A policy that relies only on `aws:RequestedRegion` to lock a `global.` or cross-region profile is a FAIL (HIGH). The documented shape is:
  - Geographic profile (`eu.`, `us.`, `apac.`), two statements: the regional inference-profile ARN `arn:aws:bedrock:<source-region>:<account>:inference-profile/<prefix>.<model>`, then the foundation-model ARN in the source region and in every destination region the profile lists, with `StringEquals` on `bedrock:InferenceProfileArn` set to that profile ARN.
  - `global.` profile, three statements: the regional inference-profile ARN gated on `aws:RequestedRegion` equal to the source region; the regional foundation-model ARN gated on the same region plus `bedrock:InferenceProfileArn`; and the region-less foundation-model ARN `arn:aws:bedrock:::foundation-model/<model>` gated on `aws:RequestedRegion` equal to `unspecified` plus `bedrock:InferenceProfileArn`. The destination set of a global profile is not enumerable, which is what the region-less ARN is for.
  - Either way, a foundation-model ARN granted without the `bedrock:InferenceProfileArn` condition is a direct grant on the model outside the profile. That is control I1, not a region finding.

```bash
grep -rnE 'region_name|region:|AWS_REGION|AWS_DEFAULT_REGION' --include='*.py' --include='*.ts' --include='*.js' --include='*.go' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -40
grep -rnoE '(eu|us|apac|global)\.[a-z0-9-]+\.[a-z0-9.:-]+' --include='*.py' --include='*.ts' --include='*.tf' --include='*.yaml' --include='*.json' . 2>/dev/null | grep -vE 'node_modules|dist/' | sort -u | head -40
grep -rnE 'aws:RequestedRegion' --include='*.tf' --include='*.json' --include='*.yaml' . 2>/dev/null | head -20
```

Finding shape: `FAIL HIGH: src/llm/client.ts:41 invokes global.anthropic.claude-... from an eu-central-1 account; IAM locks only aws:RequestedRegion, so routing to us-east-1 is not blocked.`

---

## Step 3: IAM

What to check on every role or policy that grants `bedrock:*` actions:

- `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, `bedrock:Converse`, `bedrock:ConverseStream` list model and inference-profile ARNs in `Resource`. `Resource: "*"` or `arn:aws:bedrock:*::foundation-model/*` is a FAIL (HIGH).
- One role per workload and, in multi-tenant systems, per tenant or per tenant tier. A single shared role used by the API, the batch job, and the admin tool is MEDIUM.
- No long-lived access keys in app config. Search `.env*`, `config/`, Helm values, docker-compose, and CI variables for `AKIA` and `aws_secret_access_key`. A hit is HIGH regardless of whether the key is live; the repo should use roles (IRSA, task roles, instance profiles, OIDC).
- `bedrock:ApplyGuardrail` is granted only where the app applies guardrails outside of invoke, and `bedrock:CreateGuardrail` / `DeleteGuardrail` / `PutModelInvocationLoggingConfiguration` sit in an ops role, not the runtime role.

```bash
grep -rnE '"bedrock:[A-Za-z*]+"|bedrock:(InvokeModel|Converse|ApplyGuardrail|\*)' --include='*.tf' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.ts' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE '"Resource"[[:space:]]*:[[:space:]]*"\*"|resources[[:space:]]*=[[:space:]]*\["\*"\]' --include='*.tf' --include='*.json' . 2>/dev/null | head -20
grep -rnE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|AWS_SECRET_ACCESS_KEY[[:space:]]*[:=]' . 2>/dev/null | grep -vE 'node_modules|\.git/|example|sample|\.md:' | head -10
```

When the CLI works, pull the live policy for each role you found in code and compare, because drift between Terraform and the account is common:

```bash
aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.DefaultVersionId --output text)" --query PolicyVersion.Document
```

Finding shape: `FAIL HIGH: infra/iam.tf:58 bedrock:InvokeModel on Resource "*"; any model in any region is callable from the API role.`

---

## Step 4: Bedrock Guardrails resource

What to check:

- A guardrail exists in code (`aws_bedrock_guardrail`, `CfnGuardrail`, `bedrock.Guardrail`) or in the account (`aws bedrock list-guardrails`). None at all is a FAIL (HIGH) for any workload that takes user input.
- Every invoke passes it. `guardrailIdentifier` and `guardrailVersion` (or `guardrailConfig` in Converse) appear at each call site from Step 1. A call site without them is HIGH; if some call sites have it and others do not, list each missing one.
- Version is a number, not `DRAFT`, in anything deployed to production. A `DRAFT` reference in prod config is MEDIUM; the guardrail can change under the app without a deploy.
- PII policy names each entity and the action is deliberate: `ANONYMIZE` for entities the app legitimately needs to pass through in masked form (names, emails in support tickets), `BLOCK` for entities that should never reach the model (credit card numbers, national IDs, credentials). A PII policy with no entities, or `ANONYMIZE` on card numbers, is MEDIUM. No PII policy at all where users can type free text is HIGH.
- Denied topics exist when the product has a scope (a banking assistant that should not give legal advice), and word filters cover the managed profanity list plus the product's own list when relevant. Either missing where it clearly applies is LOW.
- Content filters set explicit strengths for `HATE`, `INSULTS`, `SEXUAL`, `VIOLENCE`, `MISCONDUCT`, `PROMPT_ATTACK` on both input and output. `PROMPT_ATTACK` missing or `NONE` on input is MEDIUM.
- Contextual grounding check is enabled when the app does RAG (`retrieve_and_generate`, a knowledge base, or a retrieval step before the invoke). A RAG answer path with no `GROUNDING` and `RELEVANCE` filter is MEDIUM.

```bash
grep -rnE 'aws_bedrock_guardrail|aws_bedrock_guardrail_version|CfnGuardrail|guardrailIdentifier|guardrail_identifier|guardrailVersion|guardrail_version|guardrailConfig' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE 'pii_entities_config|piiEntitiesConfig|topics_config|topicsConfig|filters_config|filtersConfig|PROMPT_ATTACK|contextual_grounding|contextualGrounding|words_config|managed_word_lists' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40

aws bedrock list-guardrails --output table 2>/dev/null
aws bedrock get-guardrail --guardrail-identifier "$GUARDRAIL_ID" --guardrail-version "$GUARDRAIL_VERSION" 2>/dev/null
```

Finding shape: `FAIL MEDIUM: infra/guardrail.tf:22 pii_entities_config has CREDIT_DEBIT_CARD_NUMBER with action ANONYMIZE; card numbers should be BLOCK.`

---

## Step 5: Data, logging, and encryption

What to check:

- Model invocation logging is on. `aws bedrock get-model-invocation-logging-configuration` returns a config, or `aws_bedrock_model_invocation_logging_configuration` exists in Terraform. Off is MEDIUM (you cannot investigate an incident without it).
- The destination has retention. A CloudWatch log group with no `retention_in_days`, or an S3 bucket with no lifecycle rule, is LOW. Logs of prompts grow fast and hold user text.
- The logs do not carry raw PII. Either the guardrail anonymizes before the model sees the text (so the logged input is already masked), or every data-delivery flag is off so only metadata is kept, or there is a documented redaction step. All four flags — `text_data_delivery_enabled`, `image_data_delivery_enabled`, `embedding_data_delivery_enabled`, `video_data_delivery_enabled` — default to true, so a config that sets only the text one to false still ships image, video and embedding payloads and does not clear this control. Full prompt logging with no PII policy in front of it is HIGH under EU, MEDIUM otherwise.
- KMS customer-managed keys on the log group, the log bucket, the knowledge base vector store, and the S3 data sources. AWS-managed keys where the product promises customer-controlled encryption is MEDIUM; no encryption setting at all on a data source bucket is HIGH.
- VPC endpoints for `bedrock-runtime` (and `bedrock-agent-runtime` when knowledge bases are used) exist when the workload runs in private subnets. Private workload with no endpoint means traffic leaves through a NAT to the public API; MEDIUM.

```bash
grep -rnE 'aws_bedrock_model_invocation_logging_configuration|ModelInvocationLogging|_data_delivery_enabled|retention_in_days|lifecycle_rule|kms_key_id|kms_key_arn|sse_kms|server_side_encryption' --include='*.tf' --include='*.ts' --include='*.yaml' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE 'com\.amazonaws\.[a-z0-9-]+\.bedrock(-runtime|-agent-runtime)?|aws_vpc_endpoint' --include='*.tf' --include='*.ts' . 2>/dev/null | head -20

aws bedrock get-model-invocation-logging-configuration 2>/dev/null || echo "LOGGING: not readable"
aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=com.amazonaws.${AWS_REGION:-eu-central-1}.bedrock-runtime" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null
```

Finding shape: `FAIL MEDIUM: infra/logging.tf:14 invocation logs go to a log group with no retention_in_days and the default AWS-managed key.`

---

## Step 6: Tenant isolation

Skip with `N-A (single tenant)` when the system serves one customer. Otherwise check:

- Knowledge base per tenant, or one knowledge base with metadata filtering that the server applies from the authenticated tenant id. The filter must be built server-side from the session, never from a request parameter the client can set. Filter value taken from the request body is HIGH.
- Session and memory storage (agent sessions, conversation history, DynamoDB tables, Redis keys) is keyed by tenant, and reads check the tenant on the way out. A session id that is a bare UUID with no tenant scope is MEDIUM.
- Prompt caching is not shared across tenants when the cached prefix contains tenant data. A cache checkpoint placed after tenant-specific context (retrieved documents, customer records) is HIGH; a checkpoint after only the static system prompt is fine.

```bash
grep -rnE 'retrievalConfiguration|retrieval_configuration|vectorSearchConfiguration|filter[[:space:]]*[:=]|metadata_filter|equals[[:space:]]*[:=]' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -30
grep -rnE 'tenant_?[iI]d|org_?[iI]d|account_?[iI]d' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -iE 'session|memory|cache|knowledge|filter' | grep -vE 'node_modules|dist/' | head -30
grep -rnE 'cachePoint|cache_point|promptCaching|prompt_caching' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -20
```

Finding shape: `FAIL HIGH: api/rag.py:88 knowledge base filter reads tenant from request.json["tenant"]; a caller can read another tenant's documents.`

---

## Step 7: Prompt injection boundaries

What to check at each call site:

- The system prompt is passed in the `system` field (Converse) or the model's system slot, not concatenated into the user turn. Concatenation is MEDIUM.
- Tool results and retrieved documents are wrapped as untrusted data: a clear delimiter or a `toolResult` block, with an instruction that content inside is data, not commands. Retrieved text pasted straight into the prompt with no framing is MEDIUM.
- Anything the model output drives (a database write, an email, a payment, a shell command) goes through a validator first: a schema check, an allowlist of actions, a confirmation step. Model output that reaches an action with no validation is HIGH. Output filtering on the guardrail (Step 4) covers the response text, not the action.

```bash
grep -rnE 'system[[:space:]]*[:=]|"system"|systemPrompt|system_prompt|toolResult|tool_result|<document>|<untrusted' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -30
grep -rnE 'json\.loads\(.*(response|output|completion)|JSON\.parse\(.*(response|output|completion)|zod|pydantic|jsonschema' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -20
```

Finding shape: `FAIL HIGH: agent/tools.py:130 model output is passed to subprocess.run without a validator or allowlist.`

---

## Step 8: Quotas and cost

What to check:

- The team knows the per-model quotas for the account in the deployed region (tokens per minute, requests per minute) and has compared them to expected load. Read the capacity note, load-test result, or README section that records them; no mention anywhere is LOW, and a note that references the actual quota values is a PASS.
- A per-request token budget: `maxTokens` / `max_tokens` set at every call site, and an input length cap before the call. Missing `maxTokens` is LOW; no input cap on user-controlled text is MEDIUM (a cost and denial-of-wallet issue).
- Provisioned throughput: a written decision on whether it is needed, either way. Provisioned throughput bought with no decision note is LOW; an on-demand workload with a documented "not needed until X rps" is a PASS.

```bash
grep -rnE 'maxTokens|max_tokens|inferenceConfig|inference_config' --include='*.py' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -20
grep -rniE 'service.?quota|tokens per minute|TPM|provisioned.?throughput|ThrottlingException|backoff' --include='*.md' --include='*.py' --include='*.ts' --include='*.tf' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -20

aws service-quotas list-service-quotas --service-code bedrock --query 'Quotas[?contains(QuotaName, `Claude`) || contains(QuotaName, `tokens per minute`)].[QuotaName,Value]' --output table 2>/dev/null | head -40
aws bedrock list-provisioned-model-throughputs --output table 2>/dev/null
```

Finding shape: `FAIL MEDIUM: api/chat.ts:52 user message is forwarded with no length cap and no maxTokens; one caller can burn the monthly budget.`

---

## Output

Print the report in this shape. One row per control, evidence as `file:line` or the CLI command that produced it, fix as one line pointing at the Remediation section. When the user asks for a file, write the same report to `docs/bedrock-guardrails-audit.md` with Write; otherwise print only.

```
BEDROCK GUARDRAILS AUDIT
========================

Project:   <name>
Account:   <account id or "no CLI session">
Region:    <effective region(s)>
Residency: EU | none
Call sites: <n> (see list below)

Control                                   Status   Severity  Evidence                          Fix
----------------------------------------  -------  --------  --------------------------------  ----------------------
R1 Region pinned at every client          PASS     -         src/llm/client.ts:12
R2 Inference profile matches residency    FAIL     HIGH      src/llm/client.ts:41 global.*     Remediation A
R3 Cross-region decision documented       FAIL     MEDIUM    no ADR found                      write docs/adr/000x
R4 IAM locks profile + model ARNs         FAIL     HIGH      infra/iam.tf:58 Resource "*"      Remediation B
I1 InvokeModel scoped to model ARNs       FAIL     HIGH      infra/iam.tf:58                   Remediation B
I2 Role per workload / tenant             PASS     -         infra/iam.tf:20,44
G1 Guardrail exists                       PASS     -         aws bedrock list-guardrails
G2 Guardrail attached at every invoke     FAIL     HIGH      src/batch/summarise.py:77         Remediation C
G3 Numbered version in prod               FAIL     MEDIUM    config/prod.yaml:9 DRAFT          Remediation C
G4 PII entities + action per entity       FAIL     MEDIUM    infra/guardrail.tf:22             Remediation C
G5 Denied topics                          N-A      -         open-domain assistant
G6 Content filters with strengths         PASS     -         infra/guardrail.tf:30-48
G7 Word filters (managed + custom)        PASS     -         infra/guardrail.tf:50-56
G8 Contextual grounding for RAG           FAIL     MEDIUM    api/rag.py:60 no grounding        Remediation C
D1 Invocation logging on                  PASS     -         get-model-invocation-logging-configuration
D2 Log retention set                      FAIL     LOW       infra/logging.tf:14               Remediation D
D3 No raw PII in logs                     FAIL     HIGH      full text logging, no PII policy  Remediation C + D
D4 KMS CMK on logs / KB / sources         FAIL     MEDIUM    infra/s3.tf:31 AES256             Remediation D
T1 KB per tenant or server-side filter    N-A      -         single tenant
T2 Session / memory keyed by tenant       N-A      -         single tenant
P1 System prompt separated                PASS     -         src/llm/prompt.ts:5
P2 Tool / retrieved text marked as data   FAIL     MEDIUM    api/rag.py:71                     wrap in <document> block
P3 Output validated before action         PASS     -         agent/tools.py:40 zod schema
Q1 Quotas known vs load                   FAIL     LOW       no capacity note                  record TPM in README
Q2 Token budget per request               FAIL     MEDIUM    api/chat.ts:52                    set maxTokens + input cap

Totals: PASS 8  FAIL 14  N-A 3    HIGH 5  MEDIUM 7  LOW 2

CALL SITES
  src/llm/client.ts:41        global.anthropic.claude-...          guardrail: yes (v3)
  src/batch/summarise.py:77   anthropic.claude-... (eu-central-1)  guardrail: NONE

REMEDIATION
  A. Region / inference profile   B. IAM scoped to ARNs   C. Guardrail resource   D. Logging and encryption
```

Under REMEDIATION emit one Terraform snippet per group A-D that has at least one FAIL, filled in with the repo's actual names, regions, and account id. Templates to start from:

```hcl
# A. Region pinned and the profile kept inside the residency regime
provider "aws" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

# new resource — application profile over the EU system profile, so the app
# never names a us. or global. id. A system-defined inference profile ARN is
# account-scoped, so the account id belongs in copy_from.
resource "aws_bedrock_inference_profile" "app" {
  name = "${var.app}-${var.env}"

  model_source {
    copy_from = "arn:aws:bedrock:eu-central-1:${data.aws_caller_identity.current.account_id}:inference-profile/eu.anthropic.claude-sonnet-4-20250514-v1:0"
  }
}

# B. IAM: profile + model ARNs, no wildcards, no aws:RequestedRegion reliance
data "aws_iam_policy_document" "bedrock_invoke" {
  # the application profile from A — the only model id the app names
  statement {
    sid       = "InvokeThroughProfile"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [aws_bedrock_inference_profile.app.arn]
  }

  # the foundation model in the source region and in every destination region the
  # profile routes to, reachable only through that profile. Without the condition
  # this is a direct grant on the model outside the profile — control I1.
  statement {
    sid     = "InvokeModelThroughProfileOnly"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:eu-central-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
      "arn:aws:bedrock:eu-west-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
      "arn:aws:bedrock:eu-west-3::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
    ]

    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = [aws_bedrock_inference_profile.app.arn]
    }
  }

  # A global. profile is shaped differently, because its destinations cannot be
  # listed: three statements, all carrying the same bedrock:InferenceProfileArn
  # condition — the profile ARN gated on aws:RequestedRegion = the source region,
  # the regional model ARN, and the region-less model ARN
  # "arn:aws:bedrock:::foundation-model/<model>" gated on
  # aws:RequestedRegion = "unspecified".
  # Under RESIDENCY=EU do not write it — the global profile is itself the finding.

  statement {
    sid       = "ApplyGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [aws_bedrock_guardrail.main.guardrail_arn]
  }
}

# C. Guardrail with a pinned version
resource "aws_bedrock_guardrail" "main" {
  name                      = "${var.app}-${var.env}"
  blocked_input_messaging   = "This request cannot be processed."
  blocked_outputs_messaging = "This response cannot be shown."
  kms_key_arn               = aws_kms_key.bedrock.arn

  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
  }

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
    words_config {
      text = "competitor-name"
    }
  }

  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.7
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = 0.7
    }
  }
}

resource "aws_bedrock_guardrail_version" "main" {
  guardrail_arn = aws_bedrock_guardrail.main.guardrail_arn
  description   = "pinned for ${var.env}"
}

# the numbered version has to reach the app, or the call site keeps sending
# DRAFT — publish it wherever the app reads its config from
output "guardrail_version" {
  value = aws_bedrock_guardrail_version.main.version
}

# D. Invocation logging with retention and a customer-managed key
resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/bedrock/${var.app}/${var.env}"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.bedrock.arn
}

resource "aws_bedrock_model_invocation_logging_configuration" "main" {
  logging_config {
    # metadata only. Every delivery flag defaults to true, so all four have to be
    # written out: turning off text alone still delivers image, video and
    # embedding payloads. Turn them back on once the guardrail from C is attached
    # at every call site and anonymizing the entities that would land here.
    text_data_delivery_enabled      = false
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false
    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
  }
}
```

Every snippet must reference resource names that exist in the repo or be marked `# new resource`. Do not invent a module the repo does not have.

Some FAILs are not infrastructure. A Fix cell that names a prose action — write the ADR, wrap retrieved text in a delimiter, record the quota numbers, set `maxTokens` and an input cap — is a code or docs change at the call site, so give it one line under the templates naming the file and what to change, and no Terraform.

---

## Important Rules

1. **Read-only.** Every `aws` call is a `list-*`, `get-*`, or `describe-*`. This skill never creates, updates, or deletes a policy, logging configuration, endpoint, or any other resource, never purchases provisioned throughput, and never writes to the customer account. The only write is the local report file, and only when asked.
2. **Never create or delete guardrails.** Not even a scratch one "to test". Remediation is Terraform text for the user to review and apply.
3. **EU residency is strict.** When the account is in `eu-central-1`, `eu-west-1`, or another `eu-*` region, or the product promises EU data residency, every `us-*` model call, `us.` profile, or `global.` profile is HIGH. Do not downgrade it because "the data is not sensitive".
4. **Inference profiles beat region conditions.** Never mark R4 as PASS on the strength of `aws:RequestedRegion` alone. A geographic profile is locked by the regional inference-profile ARN plus the foundation-model ARNs in the source and destination regions, gated on `bedrock:InferenceProfileArn`. A `global.` profile is locked by the regional profile ARN gated on the requesting region, the regional model ARN, and the region-less model ARN `arn:aws:bedrock:::foundation-model/<model>` under `aws:RequestedRegion` equal to `unspecified` — its destination regions cannot be listed, so the condition key is the only binding, and a model ARN granted without it is control I1.
5. **Evidence or N-A.** Every PASS cites a file and line or a CLI command output. A control you could not check is `N-A` with the reason, not a PASS by default. If the CLI has no session, say so and audit from code; never ask the user to paste keys.
6. **Severity is per finding, not per control.** Two call sites missing the guardrail are two HIGH findings under G2. Controls that do not apply get N-A, not padding.

{{include lib/snippets/capture-learnings.md}}
