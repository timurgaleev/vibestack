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

The inventory has to be complete: a call site missed here is skipped by every region, IAM, guardrail, logging and cost check downstream, and shows up in the report as nothing at all. So neither search is truncated, and both cover the whole current invocation surface — `InvokeModel`, `InvokeModelWithResponseStream`, `Converse`, `ConverseStream`, `StartAsyncInvoke`, `ApplyGuardrail`, `InvokeGuardrailChecks`, `RetrieveAndGenerate`, `RetrieveAndGenerateStream`, `InvokeAgent`, `InvokeInlineAgent`, `InvokeFlow`, and the OpenAI-compatible `chat/completions` and `responses` paths on the `bedrock-runtime` endpoint.

```bash
grep -rnE 'aws_bedrock|bedrock:|AWS::Bedrock|aws_bedrockagent|bedrock_guardrail' \
  --include='*.tf' --include='*.tf.json' --include='*.hcl' --include='*.yaml' --include='*.yml' --include='*.json' --include='*.ts' --include='*.py' . 2>/dev/null \
  | grep -vE 'node_modules|\.terraform/|dist/|build/|vendor/'

grep -rnE 'bedrock-(agent-)?runtime|Bedrock(Agent)?Runtime|bedrock_(agent_)?runtime|client\(["'"'"']bedrock|@aws-sdk/client-bedrock|[Ii]nvoke[_]?[Mm]odel([Ww]ith[Rr]esponse[Ss]tream|_with_response_stream)?|[Cc]onverse([_]?[Ss]tream)?[[:space:]]*[(A-Za-z]|[Rr]etrieve[_]?[Aa]nd[_]?[Gg]enerate([_]?[Ss]tream)?|[Ii]nvoke[_]?([Ii]nline[_]?)?[Aa]gent|[Ii]nvoke[_]?[Ff]low|[Ss]tart[_]?[Aa]sync[_]?[Ii]nvoke|[Aa]pply[_]?[Gg]uardrail|[Ii]nvoke[_]?[Gg]uardrail[_]?[Cc]hecks|chat/completions|/v1/responses' \
  --include='*.py' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.go' --include='*.java' --include='*.kt' --include='*.rb' --include='*.cs' --include='*.rs' --include='*.php' . 2>/dev/null \
  | grep -vE 'node_modules|\.terraform/|dist/|build/|vendor/|_test\.|\.test\.|spec\.'
```

Record each hit as a call site: file, line, model or profile id, and whether a guardrail is passed. This list is the row source for the rest of the audit. If a repo is large enough that you cap the output to read it, say so in the report and mark the downstream controls `N-A (call-site inventory partial)` naming what was cut — a partial inventory cannot carry a PASS. If the repo wraps Bedrock in a library the greps do not reach, widen the pattern to that wrapper's own function names before moving on.

Then decide the residency regime, and take it from a commitment, not from an inferred one. An `eu-*` provider block is where the account happens to deploy today, and accounts routinely span regions; a GDPR mention in a README is about processing personal data, not about where inference runs. `RESIDENCY=EU` needs an explicit written commitment — a DPA or contract clause, a documented residency statement in the product docs, an ADR that names EU-only inference, or a compliance control the repo references. Record which one, with its `file:line`. If nothing states it, use AskUserQuestion to ask whether the workload has an EU residency commitment; if the answer is no or unavailable, leave `RESIDENCY=none` and score cross-region routing under R3 as an undocumented cross-region decision (MEDIUM), not as a residency breach. Under `RESIDENCY=EU`, any call that resolves to a `us-*` region or a `us.` / `global.` inference profile is a HIGH finding, no exceptions.

Check whether the CLI is usable for read-only evidence with `aws sts get-caller-identity --output text 2>/dev/null || echo "NO_AWS_CLI_SESSION"`. If there is no session, mark every control that needs live account state as `N-A (no CLI)` with a note on what to run, and audit from code alone. Do not ask for credentials.

Every live check below runs through one probe helper, so that a call which fails cannot be read as a call which found nothing. An `AccessDenied`, an unknown region, a missing endpoint and an expired token all exit non-zero and produce `N-A`; only a zero exit with an empty result means "none configured". Write the helper once and source it in each later block, because shell state does not survive between tool calls.

```bash
cat > "${TMPDIR:-/tmp}/bg-probe.sh" <<'PROBE'
# bg_probe <control-label> <read-only aws command...>
bg_probe() {
  bg_label="$1"; shift
  if bg_out=$("$@" 2>&1); then
    printf '%s: OK\n%s\n' "$bg_label" "$bg_out"
  else
    bg_rc=$?
    printf '%s: N-A (exit %s) %s\n' "$bg_label" "$bg_rc" "$bg_out"
  fi
}
PROBE
. "${TMPDIR:-/tmp}/bg-probe.sh"
bg_probe "identity" aws sts get-caller-identity --output json
```

---

## Step 2: Region control

For each call site, determine the effective region and model target.

What to check:

- The client is built with an explicit region (`region_name=`, `region:`, `AWS_REGION` read at startup), not the SDK default chain. A client with no region is a FAIL (MEDIUM; HIGH under EU).
- The model id is either a plain foundation model in the pinned region, or an inference profile whose prefix matches the residency regime: `eu.` stays inside EU regions, `us.` inside US regions, `global.` can route anywhere. Under `RESIDENCY=EU`, a `us.` or `global.` prefix is HIGH.
- Cross-region inference is a written decision. Search `docs/`, `docs/adr/`, the README, and the lines around each invoke with grep, then Read the file a hit points at and confirm it names the destination regions and why. A `global.` or cross-region profile with no written decision is MEDIUM.
- IAM region conditions account for inference profiles. This is the trap: `aws:RequestedRegion` checks the endpoint the caller hit, not where the profile routes, and on a `global.` profile Bedrock sets it to `unspecified` for the routed leg, so no region name ever matches there. A policy that relies only on `aws:RequestedRegion` to lock a `global.` or cross-region profile is a FAIL (HIGH). The documented shape is:
  - Geographic profile (`eu.`, `us.`, `apac.`), two statements: the regional inference-profile ARN `arn:aws:bedrock:<source-region>:<account>:inference-profile/<prefix>.<model>`, then the foundation-model ARN in the source region and in every destination region the profile lists, with `StringEquals` on `bedrock:InferenceProfileArn` set to that profile ARN.
  - `global.` profile, three statements: the regional inference-profile ARN gated on `aws:RequestedRegion` equal to the source region; the regional foundation-model ARN gated on the same region plus `bedrock:InferenceProfileArn`; and the region-less foundation-model ARN `arn:aws:bedrock:::foundation-model/<model>` gated on `aws:RequestedRegion` equal to `unspecified` plus `bedrock:InferenceProfileArn`. The destination set of a global profile is not enumerable, which is what the region-less ARN is for.
  - Either way, a foundation-model ARN granted without the `bedrock:InferenceProfileArn` condition is a direct grant on the model outside the profile. That is control I1, not a region finding.

```bash
grep -rnE 'region_name|region:|AWS_REGION|AWS_DEFAULT_REGION' --include='*.py' --include='*.ts' --include='*.js' --include='*.go' . 2>/dev/null | grep -vE 'node_modules|dist/' | head -40
grep -rnoE '(eu|us|apac|global)\.[a-z0-9-]+\.[a-z0-9.:-]+' --include='*.py' --include='*.ts' --include='*.tf' --include='*.yaml' --include='*.json' . 2>/dev/null | grep -vE 'node_modules|dist/' | sort -u | head -40
grep -rnE 'aws:RequestedRegion' --include='*.tf' --include='*.json' --include='*.yaml' . 2>/dev/null | head -20

# the destination model ARNs a geographic profile can route to. Remediation B is
# generated from this list; it is not guessable from the prefix.
. "${TMPDIR:-/tmp}/bg-probe.sh"
bg_probe "R4-profile" aws bedrock get-inference-profile --inference-profile-identifier "$PROFILE_ID" --region "$SOURCE_REGION" --query 'models[].modelArn' --output json
```

Finding shape: `FAIL HIGH: src/llm/client.ts:41 invokes global.anthropic.claude-... from an eu-central-1 account; IAM locks only aws:RequestedRegion, so routing to us-east-1 is not blocked.`

---

## Step 3: IAM

What to check on every role or policy that grants `bedrock:*` actions:

- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` list model and inference-profile ARNs in `Resource`. `Resource: "*"` or `arn:aws:bedrock:*::foundation-model/*` is a FAIL (HIGH). These two actions are the whole invocation grant: `bedrock:InvokeModel` authorizes both `InvokeModel` and `Converse`, and `bedrock:InvokeModelWithResponseStream` authorizes both `InvokeModelWithResponseStream` and `ConverseStream`. There is no `bedrock:Converse` or `bedrock:ConverseStream` IAM action, so a policy that omits those names is correctly scoped, not a finding — and a policy that lists them has granted nothing by them, which is worth a LOW note when the role's only invoke grant is a name that does not exist.
- One role per workload and, in multi-tenant systems, per tenant or per tenant tier. A single shared role used by the API, the batch job, and the admin tool is MEDIUM.
- No long-lived access keys in app config. Search `.env*`, `config/`, Helm values, docker-compose, and CI variables for `AKIA` and `aws_secret_access_key`. A hit is HIGH regardless of whether the key is live; the repo should use roles (IRSA, task roles, instance profiles, OIDC).
- `bedrock:ApplyGuardrail` is granted only where the app applies guardrails outside of invoke, and `bedrock:CreateGuardrail` / `bedrock:DeleteGuardrail` / `bedrock:PutModelInvocationLoggingConfiguration` sit in an ops role, not the runtime role. A runtime role that carries the guardrail or logging management actions is MEDIUM: whoever reaches the application can delete the guardrail in front of it and turn off the log it would be caught in. Score this from policy documents you read in full — if any part of the set below came back `N-A`, so does this row.

```bash
grep -rnE '"bedrock:[A-Za-z*]+"|bedrock:(InvokeModel|Converse|ApplyGuardrail|\*)' --include='*.tf' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.ts' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE '"Resource"[[:space:]]*:[[:space:]]*"\*"|resources[[:space:]]*=[[:space:]]*\["\*"\]' --include='*.tf' --include='*.json' . 2>/dev/null | head -20
grep -rnE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|AWS_SECRET_ACCESS_KEY[[:space:]]*[:=]' . 2>/dev/null | grep -vE 'node_modules|\.git/|example|sample|\.md:' | head -10
```

When the CLI works, pull the live policy set for each role you found in code and compare, because drift between Terraform and the account is common. One customer-managed policy is not the policy set: a role's effective Bedrock permissions are the union of its attached managed policies, its inline policies, and whatever its permissions boundary and the SCPs and RCPs above the account cut back. Enumerate first, then read each document.

```bash
. "${TMPDIR:-/tmp}/bg-probe.sh"
ROLE_NAME="<role from Terraform or the running task definition>"

bg_probe "I-attached:${ROLE_NAME}" aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json
bg_probe "I-inline:${ROLE_NAME}"   aws iam list-role-policies --role-name "$ROLE_NAME" --output json
bg_probe "I-boundary:${ROLE_NAME}" aws iam get-role --role-name "$ROLE_NAME" --query 'Role.PermissionsBoundary' --output json

# one per attached managed policy ARN
POLICY_ARN="<arn from the attached list>"
DEFAULT_VER=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.DefaultVersionId --output text 2>&1) || DEFAULT_VER=""
if [ -z "$DEFAULT_VER" ]; then
  printf 'I-policy:%s: N-A (default version not readable)\n' "$POLICY_ARN"
else
  bg_probe "I-policy:${POLICY_ARN}" aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VER" --query PolicyVersion.Document --output json
fi

# one per inline policy name
bg_probe "I-inline-doc:${ROLE_NAME}" aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "<inline policy name>" --query PolicyDocument --output json

# authorization policies above the account; usually AccessDenied from a member account
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1) || ACCOUNT_ID=""
bg_probe "I-scp" aws organizations list-policies-for-target --target-id "$ACCOUNT_ID" --filter SERVICE_CONTROL_POLICY --output json
bg_probe "I-rcp" aws organizations list-policies-for-target --target-id "$ACCOUNT_ID" --filter RESOURCE_CONTROL_POLICY --output json
```

A PASS on I1, I2, I4 or R4 needs that whole set to have been read. If any part of it came back `N-A` — a policy version you could not read, a boundary you could not fetch, SCPs denied from a member account — mark the affected control `N-A (IAM coverage incomplete)` and name what was missing. A policy that looks tightly scoped in Terraform can still be widened by a second attachment you never saw, so partial coverage is not evidence of a scoped role. Nothing here changes the FAILs: a wildcard you did read stays a FAIL whatever else was unreadable.

Finding shape: `FAIL HIGH: infra/iam.tf:58 bedrock:InvokeModel on Resource "*"; any model in any region is callable from the API role.`

---

## Step 4: Bedrock Guardrails resource

What to check:

- A guardrail exists in code (`aws_bedrock_guardrail`, `CfnGuardrail`, `bedrock.Guardrail`) or in the account (`aws bedrock list-guardrails`). None at all is a FAIL (HIGH) for any workload that takes user input.
- Every invoke passes it. The spelling depends on the API: `guardrailConfig` with `guardrailIdentifier` and `guardrailVersion` for Converse and ConverseStream, the `amazon-bedrock-guardrailConfig` block or the guardrail request headers for Invoke, and a nested `generationConfiguration.guardrailConfiguration` with `guardrailId` and `guardrailVersion` for Knowledge Bases (`RetrieveAndGenerate`, `RetrieveAndGenerateStream`) — a grep that looks only for `guardrailIdentifier` reads real protection on a knowledge base as missing. Check all of them at each call site from Step 1. If some call sites have it and others do not, list each missing one.
- A call site that names no guardrail is not automatically unprotected: an enforced guardrail applies to every model invocation in the account or organization without the request configuring anything. Before emitting a HIGH for a bare call site, look for one in each region a call site resolves to. Account-level enforcement is regional, so `list-enforced-guardrails-configuration` has to run once per region; organization-level enforcement is read with `describe-effective-policy --policy-type BEDROCK_POLICY`, callable from any account in the organization. Then read what the config actually covers before scoring: `modelEnforcement.includedModels` / `excludedModels` decide whether the model this call site uses is in scope, and `selectiveContentGuarding` (`messages`, `system`) decides which parts of the request get evaluated. An enforced guardrail whose inclusions cover the call site's model and content is a PASS, cited by config id with the coverage terms named. One that covers it only partly — the model excluded, the system prompt not guarded — is MEDIUM. Only a bare call site with no enforced guardrail covering it is HIGH. If neither lookup is readable, the row is `N-A (enforcement not readable)`, because the HIGH rests on having confirmed the absence.
- Version is a number, not `DRAFT`, in anything deployed to production. A `DRAFT` reference in prod config is MEDIUM; the guardrail can change under the app without a deploy.
- PII policy names each entity and the action is deliberate: `ANONYMIZE` for entities the app legitimately needs to pass through in masked form (names, emails in support tickets), `BLOCK` for entities that should never reach the model (credit card numbers, national IDs, credentials). A PII policy with no entities, or `ANONYMIZE` on card numbers, is MEDIUM. No PII policy at all where users can type free text is HIGH.
- Denied topics exist when the product has a scope (a banking assistant that should not give legal advice), and word filters cover the managed profanity list plus the product's own list when relevant. Either missing where it clearly applies is LOW.
- Content filters set explicit strengths for `HATE`, `INSULTS`, `SEXUAL`, `VIOLENCE`, `MISCONDUCT`, `PROMPT_ATTACK` on both input and output. `PROMPT_ATTACK` missing or `NONE` on input is MEDIUM.
- Contextual grounding check is enabled when the app does RAG (`retrieve_and_generate`, a knowledge base, or a retrieval step before the invoke) — and it is a runtime contract, not just a resource setting, so do not score this row from `contextual_grounding_policy_config` alone. The check needs three things per request: the grounding source, the query, and the content to guard, which is the model response, so it runs on output only and does nothing at all when the request supplies no source and no query. Converse marks them with the `qualifiers` field on each `guardContent` text block — `["grounding_source"]` and `["query"]`; Invoke wraps them in `amazon-bedrock-guardrails-groundingSource_<suffix>` and `amazon-bedrock-guardrails-query_<suffix>` tags with a matching `tagSuffix`. Read the RAG call sites, or a runtime trace, for those. Filters plus a correctly qualified request is a PASS citing both. Filters configured but no grounding source and query in the request is MEDIUM — the policy exists and never fires. No filters at all on a RAG answer path is MEDIUM. If the request is assembled behind a wrapper you cannot read, the row is `N-A (runtime request shape not visible)` with the guardrail `trace` field named as what to check; a resource-only reading does not carry a PASS.

```bash
grep -rnE 'aws_bedrock_guardrail|aws_bedrock_guardrail_version|CfnGuardrail|guardrailIdentifier|guardrail_identifier|guardrailVersion|guardrail_version|guardrailConfig|guardrailConfiguration|guardrail_configuration|guardrailId|guardrail_id|amazon-bedrock-guardrailConfig' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE 'pii_entities_config|piiEntitiesConfig|topics_config|topicsConfig|filters_config|filtersConfig|PROMPT_ATTACK|contextual_grounding|contextualGrounding|words_config|managed_word_lists' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE 'grounding_source|groundingSource|guardContent|qualifiers|tagSuffix|amazon-bedrock-guardrails-' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -30

. "${TMPDIR:-/tmp}/bg-probe.sh"
bg_probe "G1" aws bedrock list-guardrails --output json
bg_probe "G-detail" aws bedrock get-guardrail --guardrail-identifier "$GUARDRAIL_ID" --guardrail-version "$GUARDRAIL_VERSION" --output json

# enforced guardrails: once per region a Step 1 call site resolves to, then the org policy
CALL_SITE_REGIONS=(eu-central-1)
for _rgn in "${CALL_SITE_REGIONS[@]}"; do
  bg_probe "G2-enforced:${_rgn}" aws bedrock list-enforced-guardrails-configuration --region "$_rgn" --output json
done
bg_probe "G2-org" aws organizations describe-effective-policy --policy-type BEDROCK_POLICY --output json
```

Finding shape: `FAIL MEDIUM: infra/guardrail.tf:22 pii_entities_config has CREDIT_DEBIT_CARD_NUMBER with action ANONYMIZE; card numbers should be BLOCK.`

---

## Step 5: Data, logging, and encryption

What to check:

- Model invocation logging is on. `aws bedrock get-model-invocation-logging-configuration` returns a config, or `aws_bedrock_model_invocation_logging_configuration` exists in Terraform. Off is MEDIUM (you cannot investigate an incident without it).
- The destination has retention. A CloudWatch log group with no `retention_in_days`, or an S3 bucket with no lifecycle rule, is LOW. Logs of prompts grow fast and hold user text.
- The logs do not carry raw PII. A guardrail does not clear this control, whatever its PII policy says: masking applies to what is sent to the model and what comes back from it, and the `input` field in the invocation log always holds the original, unmodified request regardless of guardrail intervention. So an `ANONYMIZE` policy is never the evidence here. What does clear it: every data delivery flag off, so only metadata is kept; or a CloudWatch Logs data protection policy on the destination log group; or a documented redaction step on the S3 destination. There are five delivery flags, not four — `text_`, `image_`, `embedding_`, `video_` and `audio_data_delivery_enabled` — and each defaults to true, so a config that turns off text alone still ships image, audio, video and embedding payloads. Full payload delivery with none of the three controls in front of it is HIGH under EU, MEDIUM otherwise.
- KMS customer-managed keys on the log group, the log bucket, the knowledge base vector store, and the S3 data sources. AWS-managed keys where the product promises customer-controlled encryption is MEDIUM. A data source bucket with no explicit encryption block is not unencrypted — S3 applies SSE-S3 to every new object as the base level of encryption — so that is a customer-managed-key gap, LOW on its own and MEDIUM where a CMK is a stated requirement, and never an unencrypted-data finding.
- VPC endpoints for `bedrock-runtime` (and `bedrock-agent-runtime` when knowledge bases are used) exist when the workload runs in private subnets. Private workload with no endpoint means traffic leaves through a NAT to the public API; MEDIUM. The MEDIUM rests on the workload actually being private, so establish that first — a task or function attached to subnets the repo marks private, or a route table with no internet gateway. If nothing in the repo places it there, the row is `N-A (subnet placement not established)` naming what to check, not a FAIL.

```bash
grep -rnE 'aws_bedrock_model_invocation_logging_configuration|ModelInvocationLogging|_data_delivery_enabled|retention_in_days|lifecycle_rule|kms_key_id|kms_key_arn|sse_kms|server_side_encryption' --include='*.tf' --include='*.ts' --include='*.yaml' . 2>/dev/null | grep -vE 'node_modules|\.terraform/' | head -40
grep -rnE 'com\.amazonaws\.[a-z0-9-]+\.bedrock(-runtime|-agent-runtime)?|aws_vpc_endpoint' --include='*.tf' --include='*.ts' . 2>/dev/null | head -20

. "${TMPDIR:-/tmp}/bg-probe.sh"
bg_probe "D1" aws bedrock get-model-invocation-logging-configuration --output json
bg_probe "D3-account-dp" aws logs describe-account-policies --policy-type DATA_PROTECTION_POLICY --output json
bg_probe "D3-group-dp" aws logs get-data-protection-policy --log-group-identifier "$LOG_GROUP_NAME" --output json
bg_probe "D5-vpce" aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=com.amazonaws.${AWS_REGION:-eu-central-1}.bedrock-runtime" --query 'VpcEndpoints[].VpcEndpointId' --output json
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

. "${TMPDIR:-/tmp}/bg-probe.sh"
bg_probe "Q1" aws service-quotas list-service-quotas --service-code bedrock --query 'Quotas[?contains(QuotaName, `tokens per minute`) || contains(QuotaName, `requests per minute`)].[QuotaName,Value]' --output json
bg_probe "Q3-provisioned" aws bedrock list-provisioned-model-throughputs --output json
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
Residency: EU (commitment at <file:line> or "user confirmed") | none (nothing states one)
Call sites: <n>, complete | <n>, partial — <what was cut> (see list below)

Control                                   Status   Severity  Evidence                          Fix
----------------------------------------  -------  --------  --------------------------------  ----------------------
R1 Region pinned at every client          PASS     -         src/llm/client.ts:12
R2 Inference profile matches residency    FAIL     HIGH      src/llm/client.ts:41 global.*     Remediation A
R3 Cross-region decision documented       FAIL     MEDIUM    no ADR found                      write docs/adr/000x
R4 IAM locks profile + model ARNs         FAIL     HIGH      infra/iam.tf:58 Resource "*"      Remediation B
I1 InvokeModel scoped to model ARNs       FAIL     HIGH      infra/iam.tf:58                   Remediation B
I2 Role per workload / tenant             PASS     -         infra/iam.tf:20,44
I3 No long-lived access keys              PASS     -         no AKIA in .env*/CI; task role
I4 Ops actions out of runtime role        FAIL     MEDIUM    infra/iam.tf:70 DeleteGuardrail   Remediation B
G1 Guardrail exists                       PASS     -         aws bedrock list-guardrails
G2 Guardrail attached at every invoke     FAIL     HIGH      summarise.py:77, none enforced    Remediation C
G3 Numbered version in prod               FAIL     MEDIUM    config/prod.yaml:9 DRAFT          Remediation C
G4 PII entities + action per entity       FAIL     MEDIUM    infra/guardrail.tf:22             Remediation C
G5 Denied topics                          N-A      -         open-domain assistant
G6 Content filters with strengths         PASS     -         infra/guardrail.tf:30-48
G7 Word filters (managed + custom)        PASS     -         infra/guardrail.tf:50-56
G8 Contextual grounding for RAG           FAIL     MEDIUM    api/rag.py:60 no source/query     Remediation C + call site
D1 Invocation logging on                  PASS     -         get-model-invocation-logging-configuration
D2 Log retention set                      FAIL     LOW       infra/logging.tf:14               Remediation D
D3 No raw PII in logs                     FAIL     HIGH      all 5 delivery flags on, no CW DP Remediation D
D4 KMS CMK on logs / KB / sources         FAIL     MEDIUM    infra/s3.tf:31 AES256, CMK req'd  Remediation D
D5 VPC endpoint for bedrock-runtime       N-A      -         subnet placement not established
T1 KB per tenant or server-side filter    N-A      -         single tenant
T2 Session / memory keyed by tenant       N-A      -         single tenant
T3 Cache prefix holds no tenant data      N-A      -         single tenant
P1 System prompt separated                PASS     -         src/llm/prompt.ts:5
P2 Tool / retrieved text marked as data   FAIL     MEDIUM    api/rag.py:71                     wrap in <document> block
P3 Output validated before action         PASS     -         agent/tools.py:40 zod schema
Q1 Quotas known vs load                   FAIL     LOW       no capacity note                  record TPM in README
Q2 Token budget per request               FAIL     MEDIUM    api/chat.ts:52                    set maxTokens + input cap
Q3 Provisioned throughput decision        FAIL     LOW       Q3 probe: 1 bought, no note       record the decision

Totals: PASS 9  FAIL 16  N-A 5    HIGH 5  MEDIUM 8  LOW 3

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
  #
  # This resource list is the exact models[].modelArn set from
  #   aws bedrock get-inference-profile --inference-profile-identifier <id> \
  #     --region <source> --query 'models[].modelArn'
  # Do not hand-write it and do not carry the ARNs below over from this template:
  # a profile's destinations are not derivable from its prefix, and a list that
  # misses one region produces intermittent AccessDenied only when routing lands
  # there. If that call came back N-A, leave the resources block as a named
  # placeholder with the command beside it rather than a guessed region set.
  statement {
    sid     = "InvokeModelThroughProfileOnly"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      # <models[].modelArn from get-inference-profile, one entry per routed region>
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
    # metadata only. Every delivery flag defaults to true, so all five have to be
    # written out: turning off text alone still delivers image, audio, video and
    # embedding payloads. The guardrail from C does not substitute for this — the
    # log's input field holds the original request whatever the guardrail masked.
    # To turn payload delivery back on, put a CloudWatch Logs data protection
    # policy on the destination group first.
    #
    # audio_data_delivery_enabled is in the API; confirm the pinned AWS provider
    # version exposes the argument before emitting this line, since an unknown
    # argument fails terraform plan. If it does not, drop the line and say in the
    # Fix cell that the audio flag has to be set through the API or console.
    text_data_delivery_enabled      = false
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false
    audio_data_delivery_enabled     = false
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
3. **EU residency is strict, once it is established.** Establishing it takes a written commitment — a DPA or contract clause, a residency statement in the product docs, an ADR naming EU-only inference — or the user's answer, not an `eu-*` provider block and not a GDPR mention. Once established, every `us-*` model call, `us.` profile, or `global.` profile is HIGH, and you do not downgrade it because "the data is not sensitive". Without it, `RESIDENCY=none`: cross-region routing is scored under R3 as an undocumented decision, and R2 is `N-A (no residency commitment)`.
4. **Inference profiles beat region conditions.** Never mark R4 as PASS on the strength of `aws:RequestedRegion` alone. A geographic profile is locked by the regional inference-profile ARN plus the foundation-model ARNs in the source and destination regions, gated on `bedrock:InferenceProfileArn`. A `global.` profile is locked by the regional profile ARN gated on the requesting region, the regional model ARN, and the region-less model ARN `arn:aws:bedrock:::foundation-model/<model>` under `aws:RequestedRegion` equal to `unspecified` — its destination regions cannot be listed, so the condition key is the only binding, and a model ARN granted without it is control I1.
5. **Evidence or N-A.** Every PASS cites a file and line or a CLI command output. A control you could not check is `N-A` with the reason, not a PASS by default. If the CLI has no session, say so and audit from code; never ask the user to paste keys. An empty result is only evidence when the command succeeded, so every live check runs through `bg_probe` and every `N-A (exit …)` it prints stays `N-A` in the table — an `AccessDenied`, a region with no endpoint, or an expired token is never a FAIL and never a PASS.
6. **Severity is per finding, not per control.** Two call sites missing the guardrail are two HIGH findings under G2. Controls that do not apply get N-A, not padding.
7. **A severity has to be carried by the evidence the step gathered.** Where the higher severity depends on a fact the step did not establish — no enforced guardrail covers this call site, the residency commitment exists, the whole IAM policy set was readable, the request supplies a grounding source — either gather that evidence first or record the lower severity, with the gap named in the Evidence cell.

{{include lib/snippets/capture-learnings.md}}
