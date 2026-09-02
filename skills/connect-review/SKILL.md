---
name: connect-review
description: |
  Review an Amazon Connect contact-center solution built on Lex bots and Bedrock-backed conversational logic: contact flows, bot design, Lambda integrations, prompts, latency budget, state handling, observability and cost per contact. Produces a severity-ranked findings report with a latency table, a cost estimate and three test calls to make next. Use when asked to review an IVR, voice bot, phone assistant or contact flow, or when a Connect solution feels slow, brittle or expensive.
triggers:
  - review contact flow
  - amazon connect review
  - lex bot review
  - voice bot review
  - connect latency
  - ivr review
  - review the phone assistant
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "review the contact flow", "review this Connect solution", "is the Lex bot well designed", "why is the voice bot slow", "review the IVR", "check the phone assistant before go-live".

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
When the user types `/connect-review`, run this skill.

---

## Step 0: Find the inputs

Locate the five inputs in the repo before reviewing anything. Use Glob and Grep; do not guess from file names alone.

| Input | How to find it |
|-------|----------------|
| Contact flows | JSON exports: files containing `"Version": "2019-10-30"` and `"Actions"`. IaC: `aws_connect_contact_flow`, `aws_connect_hours_of_operation`, `aws_connect_instance` (Terraform) or `CfnContactFlow` (CDK). |
| Lex V2 bot | Export zips unpacked to `BotLocales/<locale>/Intents/*/Intent.json` and `Slots/*/Slot.json`, or `aws_lexv2models_bot`, `aws_lexv2models_intent`, `aws_lexv2models_slot`, `aws_lexv2models_bot_locale`. |
| Lambda source | Handlers referenced by `InvokeLambdaFunction` in flows, by `fulfillmentCodeHook` / `dialogCodeHook` in intents, or `aws_lambda_function` / SAM `AWS::Serverless::Function`. |
| Prompts | Files under `prompts/`, names matching `*prompt*`, or a `system`/`systemPrompt` string near `converse(`, `invoke_model(`, `InvokeModel`, `ConverseCommand`. |
| Session schema | `aws_dynamodb_table` or `AWS::DynamoDB::Table` with a `ttl`/`expiresAt` attribute, plus any `sessionAttributes` writes in Lambda code. |

```bash
grep -rlE '"Version": *"2019-10-30"' --include='*.json' . 2>/dev/null | head
grep -rlE 'aws_connect_|aws_lexv2models_|CfnContactFlow|CfnBot' --include='*.tf' --include='*.ts' --include='*.py' . 2>/dev/null | head
grep -rlE 'converse\(|invoke_model\(|InvokeModelCommand|ConverseCommand|bedrock-runtime' . 2>/dev/null | grep -vE 'node_modules|\.venv' | head
grep -rlE 'sampleUtterances|"intentName"' --include='*.json' . 2>/dev/null | head
```

If an input is missing, ask the user for the path or the resource id. If the `aws` CLI is configured, fill gaps with read-only calls and record the region — it decides whether the German-market notes apply:

```bash
aws sts get-caller-identity --query Account --output text
aws configure get region
aws connect list-instances --query 'InstanceSummaryList[].[Id,InstanceAlias]' --output table
aws connect list-contact-flows --instance-id "$INSTANCE_ID" --output table
aws connect describe-contact-flow --instance-id "$INSTANCE_ID" --contact-flow-id "$FLOW_ID" --query 'ContactFlow.Content' --output text > "${TMPDIR:-/tmp}/connect-review-flow.json"
aws lexv2-models list-bots --output table
aws lexv2-models describe-bot --bot-id "$BOT_ID"
aws lexv2-models list-intents --bot-id "$BOT_ID" --bot-version DRAFT --locale-id de_DE
aws lambda get-function-configuration --function-name "$FN" --query '[Timeout,MemorySize,Runtime]'
```

Only `describe`, `list`, `get` and `filter-log-events` calls are allowed. Never call `update-*`, `create-*`, `build-bot-locale` or `put-*`.

Write down the solution shape in one paragraph before continuing: entry number → flow → Lex bot → Lambda → Bedrock → back, plus which locale, which model and which region. This becomes the "Solution summary" in the report.

---

## Step 1: Flow structure

Walk every flow from `StartAction` following `Transitions.NextAction`, `Transitions.Conditions[].NextAction` and `Transitions.Errors[].NextAction`. Build the graph before judging it — a block that looks unreachable in the JSON often is.

| Check | How | Finding |
|-------|-----|---------|
| Error branch on every fallible block | For each action of type `InvokeLambdaFunction`, `ConnectParticipantWithLexBot`, `GetParticipantInput`, `TransferContactToQueue`, `TransferToPhoneNumber`, `CheckHoursOfOperation`, `UpdateContactAttributes`: does `Transitions.Errors` exist and point somewhere other than the same block? | Missing → HIGH. The caller hears silence and the contact drops. |
| Disconnect and timeout paths | `GetParticipantInput` and Lex blocks carry `InputTimeLimitExceeded` / `NoMatchingCondition` / `NoMatchingError` error names. Each must route to a re-prompt with a counter, then to a human or a polite disconnect. | Missing → MEDIUM. Timeout routed straight to `DisconnectParticipant` → HIGH. |
| Transfer to agent reachable | Is there a path from `StartAction` to `TransferContactToQueue`? Is it reachable from the Lex fallback branch and from the Lambda error branch? | No path at all → HIGH. Not reachable from fallback → MEDIUM. |
| Hours of operation and overrides | `CheckHoursOfOperation` precedes every queue transfer; the closed branch plays a message and offers callback, voicemail or disconnect. Holidays and short days live on the hours-of-operation resource as overrides — recurring, temporary, or inherited from a linked parent — not in the flow, so read the resource before judging the flow. The block also supports an optional branch per named override; the flow-language reference documents only the True/False conditions for this action, so read the flow JSON rather than assume a branch shape. | No hours check → HIGH. Resource read, no override on it or on its parents, and no other holiday mechanism (Lambda, attribute, DynamoDB flag) → MEDIUM (LOW if the business is 24/7). Resource not readable → N-A. |
| Loop guards | Every `Loop` action has a bounded `LoopCount`. Any cycle through `GetParticipantInput` or a Lex block without a counter is an infinite loop for a confused caller. | Unbounded loop → HIGH. |
| Attribute naming | Collect all keys from `UpdateContactAttributes`. Mixed `camelCase`, `snake_case` and `Title Case`, or the same concept under two names (`customerId`, `CustomerID`). | LOW. |
| No secrets in attributes | Grep attribute values and Lambda return maps for `api[_-]?key`, `token`, `password`, `secret`, `Bearer`. Contact attributes appear in contact records, the agent workspace and Contact Lens exports. A keyword hit names a candidate, not a leak — read the matched line and decide whether the value is credential material or a field name, a placeholder or a boolean flag. | Credential value confirmed in an attribute → CRITICAL. Hit whose value cannot be resolved from the source (built at runtime, read from a variable) → MEDIUM, and name what would confirm it. |
| Flow logging | A `UpdateFlowLoggingBehavior` action with `"FlowLoggingBehavior": "Enabled"` early in the flow. Logging set by that action carries into any flow the contact is transferred to, even one that has no such action, so trace back to the entry flow before judging a transferred flow. | Absent from the entry flow and from every flow on the path to it → MEDIUM. Nothing in CloudWatch when a call goes wrong. Absent only from a transferred flow whose entry flow enables it → not a finding. |

Evidence for a flow finding is the flow name plus the block `Identifier` (or Terraform resource address and line).

```bash
# Overrides live on the hours-of-operation resource, not in the flow. An empty
# override list only means something if the call succeeded — otherwise N-A.
if hoo=$(aws connect describe-hours-of-operation \
      --instance-id "$INSTANCE_ID" --hours-of-operation-id "$HOO_ID" \
      --query 'HoursOfOperation.[Name,TimeZone,ParentHoursOfOperations[].Id]' \
      --output json 2>/dev/null); then
  printf '%s\n' "$hoo"
  aws connect list-hours-of-operation-overrides \
    --instance-id "$INSTANCE_ID" --hours-of-operation-id "$HOO_ID" \
    --query 'HoursOfOperationOverrideList[].[Name,OverrideType,EffectiveFrom,EffectiveTill]' \
    --output json 2>/dev/null \
    || echo "OVERRIDES: N-A (list call failed for $HOO_ID)"
else
  echo "HOURS: N-A (describe failed — no access, or wrong instance/hours id)"
fi
# Repeat both calls for every id in ParentHoursOfOperations: a child inherits the
# parent's overrides, and they are not in the child's own list.
```

---

## Step 2: Lex bot design

Read every `Intent.json` and `Slot.json` in each locale, or the equivalent IaC resources.

| Check | How | Finding |
|-------|-----|---------|
| Intent overlap | Normalise sample utterances (lowercase, strip punctuation) and compare across intents. Identical utterance in two intents, or two intents whose utterance sets share most of their tokens (`kündigen` vs `vertrag kündigen` vs `kündigung widerrufen`). | Identical utterance → HIGH. Heavy overlap → MEDIUM. |
| Slot elicitation | `valueElicitationSetting.promptSpecification.maxRetries` is 2 or 3 and the retry messages differ from the first prompt (a caller who did not understand the question the first time will not understand it the third time). | No retries → MEDIUM. Retries with identical wording → LOW. |
| Fallback routes somewhere useful | `AMAZON.FallbackIntent` either hands to a Lambda that offers a menu or sets a session attribute the flow uses to transfer to a queue. Fallback that re-prompts the same intent forever is a dead end. | Fallback loops → HIGH. Fallback disconnects → MEDIUM. |
| Confidence threshold | `nluIntentConfidenceThreshold` on the bot locale. Unset means 0.40 by default. | Unset → MEDIUM (say what the default does). Below 0.40 → LOW. |
| Locale and voice match | `localeId` (`de_DE`), `voiceSettings.voiceId` and the flow's `SetVoice` block must agree. Bedrock prompt language must match too. | Mismatch → HIGH. The caller hears a German sentence in an English voice, or ASR runs on the wrong language. |
| Sensitive slots obfuscated | Slots for IBAN, card number, date of birth, address, customer number carry `obfuscationSetting.obfuscationSettingType: DefaultObfuscation`. Also check whether conversation logs are enabled with text logs. | Sensitive slot without obfuscation → HIGH. In eu-* regions with text logs on → CRITICAL. |

```bash
# An utterance is a collision only when two DIFFERENT intents in the SAME locale
# share it. Keep locale and intent from the export path
# (BotLocales/<locale>/Intents/<intent>/Intent.json) and normalise the text
# before comparing — dropping the filenames turns repeats inside one intent, and
# the same utterance in two locales, into false collisions. grep exits 1 for
# "no matches" and above 1 for a real failure; tell them apart instead of
# reading an empty result as "no duplicates". Case folding is ASCII only, so a
# capitalised umlaut is compared as written.
BOT_ROOT="${BOT_ROOT:-BotLocales}"
raw=$(grep -rHoE '"utterance"[[:space:]]*:[[:space:]]*"[^"]*"' \
        --include='Intent.json' "$BOT_ROOT" 2>/dev/null)
st=$?
if [ "$st" -gt 1 ]; then
  echo "UTTERANCES: N-A (scan failed, grep status $st)"
elif [ "$st" -eq 1 ]; then
  echo "UTTERANCES: N-A (no sample utterances found under $BOT_ROOT)"
else
  printf '%s\n' "$raw" | awk '
    {
      if (match($0, /BotLocales\/[^\/]+\/Intents\/[^\/]+\/Intent\.json:/) == 0) { skipped++; next }
      path = substr($0, RSTART, RLENGTH - 1)
      rest = substr($0, RSTART + RLENGTH)
      split(path, p, "/")
      if (match(rest, /"[^"]*"$/) == 0) next
      u = tolower(substr(rest, RSTART + 1, RLENGTH - 2))
      gsub(/[[:punct:]]/, " ", u)
      gsub(/[[:space:]]+/, " ", u)
      sub(/^ /, "", u); sub(/ $/, "", u)
      if (u == "") next
      k = p[2] SUBSEP u
      if (!(k in ints)) ints[k] = p[4]
      else if (index("," ints[k] ",", "," p[4] ",") == 0) ints[k] = ints[k] "," p[4]
    }
    END {
      for (k in ints) if (index(ints[k], ",")) {
        split(k, q, SUBSEP)
        print "COLLISION  locale=" q[1] "  intents=" ints[k] "  utterance=" q[2]
      }
      if (skipped) print "UTTERANCES: " skipped " line(s) N-A — path is not BotLocales/<locale>/Intents/<intent>/Intent.json"
    }'
fi
```

---

## Step 3: Bedrock / LLM turn

Read the Lambda that calls Bedrock end to end. Trace the input from the Lex event to the model call and the output from the model to the spoken message.

| Check | How | Finding |
|-------|-----|---------|
| System prompt present, scoped, versioned | A `system` block that names the assistant's role, the allowed topics and the refusal behaviour. Loaded from a file with a version, or from Bedrock Prompt Management with a pinned `promptVersion`. | No system prompt → HIGH. Inline string with no version → MEDIUM. |
| PII stripped before the model call | Caller number (`CustomerEndpoint.Address`), name and any slot value tagged sensitive are removed or tokenised before they enter the prompt. | Raw caller data in the prompt → HIGH. In eu-* → CRITICAL unless a DPA covers the model region. |
| Hallucination guard | Either retrieval (`retrieve`, `retrieve_and_generate`, a Knowledge Base id) with the prompt instructing "answer only from the provided context", or an explicit "I don't know — let me transfer you" branch in the prompt and the flow. | Neither → HIGH. |
| Output validation | Model output is checked before it is spoken: max length, no URLs or phone numbers the model invented, escaped for SSML if injected into `<speak>`. | No validation → MEDIUM. Unescaped output inside SSML → HIGH. |
| Where the model call lands | In a Lambda the runtime sets `AWS_REGION`, so a client built without `region_name` already resolves to the deployed region — the absence of the argument is not itself a defect. Check the destination instead: the `modelId` or inference profile prefix (`eu.`, `us.`, `apac.`), any explicit `endpoint_url`, and the function's own region from `get-function-configuration`. | Cross-region profile whose geography sits outside the function's region — a `us.` profile called from an eu-* function → HIGH (data leaves the EU). Model id or region supplied at runtime from configuration this review cannot read → N-A; name the value to check. |
| Timeouts and retries | `botocore.config.Config(connect_timeout=, read_timeout=, retries={...})` or the JS SDK `requestHandler` timeouts. Default read timeout is 60 s, which is far beyond what Lex or Connect will wait. | Defaults left in place → HIGH. |
| Streaming | `converse_stream` / `InvokeModelWithResponseStream` when the audio path can consume partial output (custom media with Polly). In a plain Lex-in-Connect design the full response is needed before TTS, so streaming buys nothing — note that rather than report it. | Custom media path without streaming → MEDIUM. |

```bash
grep -nE 'read_timeout|connect_timeout|requestTimeout|retries' "$LAMBDA_FILE"
grep -nE 'region_name|AWS_REGION|inferenceProfile|modelId|model_id' "$LAMBDA_FILE"
grep -nE 'system=|"system"|systemPrompt|SYSTEM_PROMPT' "$LAMBDA_FILE"
```

---

## Step 4: Latency budget

Callers perceive a gap of more than about 800 ms after they stop talking as the bot not understanding them. Build the budget for the slowest turn (usually the Bedrock turn).

| Check | How | Finding |
|-------|-----|---------|
| Lambda timeout inside the Connect limit | Read `InvocationType` on the `InvokeLambdaFunction` action first. `SYNCHRONOUS` holds the contact and waits at most 8 s; `ASYNCHRONOUS` allows up to 60 s and the contact moves on immediately, so only the synchronous case puts the caller-facing limit at risk. The wait is `InvocationTimeLimitSeconds` on the action, not the Lambda's own `Timeout`. The Lambda `Timeout` belongs at or below it, and the Bedrock read timeout lower still, so the Lambda fails cleanly instead of Connect taking the error branch while the Lambda keeps running. Lex code hooks wait 30 s by default (raised with the `x-amz-lex:codehook-timeout-ms` session attribute) and the caller hears silence throughout. | Synchronous, Lambda `Timeout` ≥ `InvocationTimeLimitSeconds` → HIGH. Bedrock read timeout ≥ Lambda `Timeout` → HIGH. Asynchronous → no finding on the 8 s limit; check instead that a `Wait` block or a `Load Lambda result` action collects the response. `InvocationType` not in the source → N-A. |
| Measured turn time | If CloudWatch is reachable, take p50/p95 of the `Duration` field on Lambda `REPORT` lines. `Duration` is the handler's own wall clock: the model call made inside the handler is already inside it, and cold start is not — `Init Duration` is reported separately. So this measurement separates handler-plus-model from init, and separates neither of them from ASR or TTS, which happen outside the function. | Measured turn over 800 ms with no filler → HIGH. No measurement available and every stage estimated → MEDIUM, and say so in the latency table. |
| Filler prompt or streaming | Lex V2 `fulfillmentUpdatesSpecification` with `startResponse` (spoken immediately) and `updateResponse` (spoken while waiting), or a `PlayPrompt` before the Lambda block. | Missing on a turn over 800 ms → HIGH. |
| Barge-in | Long prompts and menus have `allowInterrupt: true` on Lex messages; `PlayPrompt` blocks that read a menu are followed by input blocks that accept DTMF during playback. | Missing on menus → MEDIUM. |
| Cold starts on the hot path | `aws_lambda_provisioned_concurrency_config`, SnapStart, or a scheduled warmer on the Lex fulfilment and Connect Lambdas. Weigh by runtime: Java or Python with large dependencies cold-starts in seconds. | Heavy runtime, no mitigation → HIGH. Slim Node/Python, no mitigation → LOW. |

```bash
# A REPORT line carries Duration, Billed Duration and Init Duration (and Restore
# Duration under SnapStart). Strip the qualified ones first — only wall-clock
# Duration belongs in the latency budget. Init Duration is the cold-start
# number for the latency table — it comes out of a second pass below.
# Capture the aws status: an empty pipeline here means "no access" as often as
# it means "no invocations", and those are not the same answer.
if ! raw=$(aws logs filter-log-events --log-group-name "/aws/lambda/$FN" \
      --filter-pattern "REPORT" --start-time "$(( $(date +%s) - 86400 ))000" \
      --query 'events[].message' --output text 2>/dev/null); then
  echo "LATENCY: N-A (filter-log-events failed — no access, or no such log group)"
else
  printf '%s\n' "$raw" \
    | sed -E 's/(Billed|Init|Restore) Duration: [0-9.]+ ms//g' \
    | grep -oE 'Duration: [0-9.]+ ms' | awk '{print $2}' | sort -n \
    | awk 'function q(a, n, p,   i) { i = int(n * p); if (i < n * p) i++; if (i < 1) i = 1; if (i > n) i = n; return a[i] }
           { a[NR] = $1 }
           END { if (NR) printf "handler p50=%s p95=%s n=%d\n", q(a, NR, 0.5), q(a, NR, 0.95), NR;
                 else print "LATENCY: N-A (no REPORT lines in the window)" }'
  # Second pass for the cold-start row. The aws call already succeeded, so an
  # absence of Init Duration lines means no cold start was sampled, not no
  # access — which is a different answer from the N-A above.
  printf '%s\n' "$raw" \
    | grep -oE 'Init Duration: [0-9.]+ ms' | awk '{print $3}' | sort -n \
    | awk 'function q(a, n, p,   i) { i = int(n * p); if (i < n * p) i++; if (i < 1) i = 1; if (i > n) i = n; return a[i] }
           { a[NR] = $1 }
           END { if (NR) printf "init p50=%s p95=%s n=%d\n", q(a, NR, 0.5), q(a, NR, 0.95), NR;
                 else print "INIT: no cold start in the sampled window — leave the init row out, or mark it estimated" }'
fi
```

The percentile is nearest-rank: index `ceil(n × p)`, clamped to the array. Adding one to the floor overshoots by a place whenever `n × p` is already a whole number.

Estimate any stage you cannot measure and mark it as an estimate. Typical ranges: Lex ASR 300–600 ms after end of speech; Lambda cold start 200 ms–3 s by runtime; Bedrock first token 400–1500 ms and full answer proportional to output tokens; Polly neural TTS 200–400 ms for one sentence. Sum them in the latency table in the report — but never add an estimated model time on top of a measured handler `Duration`, which already contains it. Init Duration is its own row, for the cold-start case only.

---

## Step 5: State and idempotency

| Check | How | Finding |
|-------|-----|---------|
| Session data with TTL | The DynamoDB session table has TTL enabled and every write sets the TTL attribute. | No TTL → MEDIUM. In eu-* with caller data stored → HIGH (retention with no expiry). |
| Idempotent handlers | Connect retries an invocation that is throttled or hits a 500, and retries up to three times when the invocation returns an error, all inside the configured timeout; Lex takes its configured timeout or failure response instead of retrying. So a repeat is possible rather than guaranteed — and a caller who redials repeats the side effect either way. Any side effect (create ticket, send SMS, book appointment) needs a key covering both the contact and the operation — `<ContactId>#<operation>#<hash of the arguments>` — behind a conditional write or an idempotency table. `ContactId` or `sessionId` alone collides as soon as one contact legitimately performs two side effects, and the second one is silently dropped. | Side effect with no key → HIGH. Key that is only the contact or session id where the handler can perform more than one side effect → MEDIUM. |
| Retries are safe | SDK retry config on non-idempotent calls (payments, notifications) is off or guarded. | Unguarded retries on a side-effecting call → MEDIUM. |
| Attribute size limits | Contact attributes total 32 KB; Lex session attributes are also bounded. Storing a transcript, a model response history or a JSON blob in attributes hits the limit mid-call. | Transcript or history in attributes → HIGH. |

```bash
# TTL is spelled differently per tool: a `ttl` block in Terraform,
# TimeToLiveSpecification in CloudFormation, timeToLiveAttribute (TS) or
# time_to_live_attribute (Python) in CDK. A hit is not proof — read the match
# and confirm it is enabled and names a real attribute.
ttl=$(grep -rnE '(^|[^[:alnum:]_])ttl[[:space:]]*\{|TimeToLiveSpecification|timeToLiveAttribute|time_to_live|ttl_enabled' \
  --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.ts' --include='*.py' . 2>/dev/null)
st=$?
if [ "$st" -gt 1 ]; then
  echo "TTL: N-A (scan failed, grep status $st)"
elif [ "$st" -eq 1 ]; then
  echo "TTL: no declaration in the scanned files — a finding only if the table is defined here; otherwise N-A"
else
  printf '%s\n' "$ttl"
fi
grep -nE 'ConditionExpression|attribute_not_exists|idempotency' "$LAMBDA_FILE"
```

---

## Step 6: Observability

| Check | How | Finding |
|-------|-----|---------|
| Transcripts | Contact Lens enabled on the instance and the flow, or a transcript export to S3 via Lex conversation logs / Kinesis. | Neither → MEDIUM. |
| Metrics and alarms | CloudWatch alarms on Lambda `Errors`, `Throttles`, `Duration` p95; Lex `MissedUtteranceCount` and `RuntimeRequestErrors`; Bedrock `InvocationClientErrors`, `InvocationServerErrors`, `InvocationLatency`. | No alarms → MEDIUM. Alarm with an empty `AlarmActions` list, or with `ActionsEnabled` false → LOW. Nothing reaches anyone when it fires. |
| Trace id end to end | `ContactId` is logged in every Lambda log line and passed as request metadata to Bedrock, or X-Ray is enabled across Lambda and the SDK client. | Cannot correlate a bad call across flow, Lambda and model → MEDIUM. |

```bash
# An empty AlarmActions list is the case being hunted, so project the list
# itself. Keep --output json: the table formatter cannot render a list cell.
if ! aws cloudwatch describe-alarms \
      --query 'MetricAlarms[].{Alarm:AlarmName,Namespace:Namespace,Metric:MetricName,ActionsEnabled:ActionsEnabled,AlarmActions:AlarmActions}' \
      --output json 2>/dev/null; then
  echo "ALARMS: N-A (describe-alarms failed — no access)"
fi
grep -nE 'ContactId|contactId|sessionId|correlation' "$LAMBDA_FILE"
```

German-market note (eu-* regions): transcripts and conversation logs are personal data under the DSGVO. Report where transcripts land, the S3 lifecycle rule that deletes them, and whether the retention period is documented. Missing lifecycle rule → HIGH.

---

## Step 7: Cost per contact

Do not hardcode prices. Every line of the formula needs its own rate, fetched one component at a time. `get-products` without `--filters` returns whatever products happen to match the service code, and truncating that JSON with `head` leaves a fragment of unrelated products rather than a rate — an estimate built on it would be invented. The Price List API is served from `us-east-1`, `eu-central-1` and `ap-south-1` regardless of where the workload runs: `--region` picks the endpoint, the `regionCode` filter picks the priced region.

```bash
# What each service can be filtered on. Do this before writing any filter — a
# guessed field or value returns an empty set that reads like a zero rate.
# The authoritative service-code list is:
#   aws pricing describe-services --region us-east-1 --query 'Services[].ServiceCode'
for svc in AmazonConnect AmazonLex AmazonBedrock AWSLambda AmazonPolly AmazonDynamoDB; do
  if attrs=$(aws pricing describe-services --region us-east-1 --service-code "$svc" \
        --query 'Services[0].AttributeNames' --output text 2>/dev/null); then
    printf '%s: %s\n' "$svc" "$attrs"
  else
    printf '%s: N-A (describe-services failed — no access, or wrong service code)\n' "$svc"
  fi
done

# Values that actually exist for one attribute, so the TERM_MATCH filter matches.
aws pricing get-attribute-values --region us-east-1 \
  --service-code AmazonConnect --attribute-name usagetype --max-results 100 \
  --query 'AttributeValues[].Value' --output text 2>/dev/null \
  || echo "ATTRIBUTES: N-A (get-attribute-values failed for AmazonConnect/usagetype)"

# One filtered query per formula line. Repeat with the service code, region and
# usage type for each component; keep --output json and do not truncate it.
aws pricing get-products --region us-east-1 --service-code "$SVC" \
  --filters "Type=TERM_MATCH,Field=regionCode,Value=$WORKLOAD_REGION" \
            "Type=TERM_MATCH,Field=usagetype,Value=$USAGE_TYPE" \
  --max-results 10 --output json 2>/dev/null \
  || echo "PRICING: N-A (get-products failed for $SVC/$USAGE_TYPE)"
```

Telephony is priced per country, number type and direction, and negotiated rates are common, so ask the user for the per-minute rate on the numbers actually in use rather than deriving one.

```
cost_per_call =
    call_minutes           x (connect_service_rate + telephony_rate_per_minute)
  + lex_speech_requests    x lex_speech_rate
  + lex_text_requests      x lex_text_rate
  + bedrock_input_tokens   x input_token_rate
  + bedrock_output_tokens  x output_token_rate
  + lambda_invocations     x lambda_request_rate
  + lambda_gb_seconds      x lambda_duration_rate
  + call_minutes           x contact_lens_rate            (if enabled)
  + tts_characters         x polly_neural_rate            (if neural voices are used)
  + dynamodb_writes        x write_request_rate
```

Fill a rate only from a query that returned one. Mark every other rate "user input", and then report the total as an order of magnitude rather than a price — say which lines are missing. What the user has to supply:

- inbound per-minute telephony rate for the country and number type in use
- the model id, and its input and output token rates
- average call length and Lex turns per call, from a real call sample
- Lambda memory, and the measured duration from Step 4
- whether Contact Lens, neural voices and any analytics add-on are enabled

Estimate the per-call quantities from a representative call: count Lex turns from the flow, tokens from the prompt size plus a typical answer, Lambda GB-seconds from memory × measured duration. Show the assumptions next to each number. Then name the largest line item and the one change that would cut it.

---

## Output

```
CONNECT REVIEW
==============

Solution summary
  <one paragraph: entry point, flows, bot and locale, Lambdas, model and region, session store>
  Region: <region>  (DSGVO notes: yes/no)

Findings
| #  | Severity | Area        | Evidence                                   | Fix |
|----|----------|-------------|--------------------------------------------|-----|
| 1  | CRITICAL | Flow        | main-inbound.json block 3f2a (UpdateContactAttributes) | Remove `apiKey` from attributes; read it from Secrets Manager inside the Lambda |
| 2  | HIGH     | Latency     | handler.py:41 read_timeout unset           | Config(read_timeout=4, connect_timeout=1, retries={"max_attempts": 1}) |
| 3  | MEDIUM   | Lex         | BotLocales/de_DE/Intents/Cancel/Intent.json | Add two distinct retry prompts, maxRetries 2 |

Latency budget (slowest turn)
| Stage                           | Measured / Estimated | ms    |
|---------------------------------|----------------------|-------|
| Lex ASR end-of-speech           | estimated            | 500   |
| Lambda init (cold start)        | measured p95         | 1800  |
| Lambda handler incl. model call | measured p95         | 2100  |
| TTS                             | estimated            | 300   |
| Total                           |                      | 4700  |
| Budget                          |                      | 800   |

  Filler prompt: <none / startResponse at 400 ms>

Cost per call (assumptions in brackets)
  <one line per formula item: quantity x rate = amount, each rate marked fetched or user input>
  Total: <amount>  — order of magnitude if any rate is user input
  Largest item: <name> — <one change that cuts it>

What to test next
  1. <call scenario that exercises the worst finding, e.g. say nothing for 10 s at the main menu>
  2. <call scenario for the fallback path, e.g. ask an off-topic question twice>
  3. <call scenario for latency, e.g. ask the longest knowledge question at 09:00 after a cold night>

Not checked
  <check> — <why: no CLI access, input missing, value only resolved at runtime>
```

The handler row already contains the model call. Never add a separately estimated model time to a measured handler duration.

Severity meaning: CRITICAL — caller data or credentials exposed, or callers dropped; HIGH — a real call fails or the caller gives up; MEDIUM — degrades quality or costs money at scale; LOW — hygiene; N-A — the check could not run, which is reported as N-A and never as a pass or a fail.

If the user asks for a file, write the report to `docs/connect-review-<YYYY-MM-DD>.md` with Write. Otherwise print it.

---

## Important Rules

1. **Read-only against AWS.** Only `describe`, `list`, `get` and log queries. Never modify a flow, bot, Lambda, alarm or table, never publish a bot version, never purchase anything and never write to the customer account.
2. **Never modify flows or bots in the repo either.** Report the fix; do not apply it. This skill produces findings, not diffs.
3. **Evidence or it is not a finding.** Every row cites a file and line, a flow block identifier, or a resource id. A concern without evidence goes into "What to test next", not into the table.
4. **Never log real caller data into learnings.** Phone numbers, names, transcripts and slot values seen during the review stay out of the learnings log and out of the report. Use placeholders.
5. **German-market notes when the region is eu-*.** Add DSGVO notes on transcript retention, log obfuscation, model region and session TTL. Do not add them for other regions.
6. **Estimates are labelled.** A latency or cost number you did not measure says "estimated" next to it.
7. **Say what you could not check.** If an input was missing or the CLI had no access, the row is N-A and goes under "Not checked" at the end of the report. Never let a failed call read as a clean result: capture the exit status of every `aws` call and every grep whose emptiness would otherwise be taken as evidence.

{{include lib/snippets/capture-learnings.md}}
