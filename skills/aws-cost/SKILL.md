---
name: aws-cost
description: |
  Read-only AWS cost review for the account at hand: where the money went last month, what changed versus the month before, and the three actions worth taking. Uses the AWS billing MCP tools when the session has them, otherwise the aws CLI (ce, compute-optimizer, budgets). Use when someone asks why the AWS bill went up, wants a FinOps pass, or needs Savings Plans and RI coverage checked.
triggers:
  - aws cost
  - aws bill
  - why did aws cost go up
  - finops review
  - cost explorer
  - savings plans coverage
  - cloud spend review
allowed-tools:
  - Bash
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "aws cost", "aws bill", "why did AWS cost go up", "finops review", "cost explorer", "savings plans coverage", "cloud spend review", "what are we paying for".

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
When the user types `/aws-cost`, run this skill.

---

## Step 0: Pick the data path

Two ways to get billing data. Decide once, up front, and say which one you are on.

**MCP path.** Look at the tools available in this session. If any tool name starts
with `mcp__awslabs_billing`, the billing MCP server is connected. The ones this skill
uses: `cost-explorer`, `cost-comparison`, `cost-anomaly`, `cost-optimization`,
`compute-optimizer`, `sp-performance`, `ri-performance`, `budgets`, `free-tier-usage`.
Prefer this path when it exists: it returns structured JSON and handles pagination.

**CLI path.** If no billing MCP tool is present, the aws CLI must work. Settle the
profile first, then prove it authenticates. In this order:

1. If `$AWS_PROFILE` is set, use it. Do not ask.
2. Otherwise run `aws sts get-caller-identity --output json` against the `default`
   profile. If it succeeds, `default` is the profile; do not ask, even when other
   profiles exist.
3. If it fails and `aws configure list-profiles` prints more than one name, ask
   which one to use (AskUserQuestion, one option per name), export the answer as
   `AWS_PROFILE`, and run `aws sts get-caller-identity --output json` again.
4. If the check still fails, stop and print a setup note: which profile was tried,
   the error text, and the two fixes (`aws configure --profile <name>` or
   `aws sso login --profile <name>`). Do not guess at credentials. Do not read
   `~/.aws/credentials`.

The successful call returns `Account` and `Arn`. Keep the account id in `ACCOUNT` for
the budgets query in Step 1. On the MCP path the tool response carries the account.

**Is this the payer account?** The linked-account table in Step 1 only means anything for
an Organizations management account, and nothing else in this skill establishes whether
this is one. Ask Organizations and keep the exit status, because "no organization" and
"not allowed to look" are different answers:

```bash
MASTER=$(aws organizations describe-organization \
  --query 'Organization.MasterAccountId' --output text 2>&1); ORG_RC=$?
if [ "$ORG_RC" -eq 0 ] && [ "$MASTER" = "$ACCOUNT" ]; then
  ORG_ROLE="payer"
elif [ "$ORG_RC" -eq 0 ]; then
  ORG_ROLE="member"
elif printf '%s\n' "$MASTER" | grep -q 'AWSOrganizationsNotInUse'; then
  ORG_ROLE="standalone"
else
  ORG_ROLE="unknown"
fi
echo "ORG_ROLE: $ORG_ROLE"
```

- `payer` — this is the management account. Run the linked-account table in Step 1.
- `member` or `standalone` — there is nothing to break out. Skip that table and say which
  of the two it was.
- `unknown` — the call was denied or failed. Report the linked-account table as N-A with
  the error text. Never print "no linked accounts" on the strength of a denied call.

**Period.** Default: the last full calendar month, compared with the month before it.
Compute both ranges (Cost Explorer end dates are exclusive):

```bash
THIS_START=$(date -v-1m +%Y-%m-01 2>/dev/null || date -d "$(date +%Y-%m-01) -1 month" +%Y-%m-01)
THIS_END=$(date +%Y-%m-01)
PREV_START=$(date -v-2m +%Y-%m-01 2>/dev/null || date -d "$(date +%Y-%m-01) -2 month" +%Y-%m-01)
PREV_END=$THIS_START
echo "PERIOD: $THIS_START..$THIS_END vs $PREV_START..$PREV_END"
```

Only ask about the period when the user named one that is ambiguous ("this quarter",
"since the migration"). Otherwise use the default and state it in the report header.

**Conventions for every query in this skill:**

- Metric: `UnblendedCost`.
- Filter out `RecordType` values `Credit` and `Refund` so a one-off credit does not hide a real rise. This holds for the Cost Explorer `get-cost-and-usage` queries in Steps 1-3 only. Budgets carries its own cost basis and the commitment APIs report on an amortized basis; those steps say so where it matters.
- Group by `SERVICE` first. Group by `LINKED_ACCOUNT` only when `ORG_ROLE` is `payer`, and by the cost-allocation tag the user names in Step 3 when one is active.
- `REGION` is not a valid `GroupBy` dimension for `GetCostAndUsage` — the documented `DIMENSION` values are `AZ`, `INSTANCE_TYPE`, `LEGAL_ENTITY_NAME`, `INVOICING_ENTITY`, `LINKED_ACCOUNT`, `OPERATION`, `PLATFORM`, `PURCHASE_TYPE`, `SERVICE`, `TENANCY`, `RECORD_TYPE`, `USAGE_TYPE`. To get per-region numbers, filter on the `REGION` dimension one region at a time.
- Round to whole dollars in tables; keep cents only in the header total.
- Every `aws` call in this skill is a describe, get, or list. Capture the exit status of any call whose empty result would otherwise be read as a clean bill of health, and report N-A with the error text when it failed. An access-denied response is not a pass and not a finding.

---

## Step 1: Totals and month-over-month by service

Pull both months grouped by service and build the top-10 table. MCP path: call
`cost-comparison` with the two periods, or `cost-explorer` twice with
`granularity: MONTHLY` and `group_by: SERVICE`. CLI path:

```bash
aws ce get-cost-and-usage \
  --time-period Start="$PREV_START",End="$THIS_END" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}' \
  --output json
```

From the response compute: total per month, delta in dollars and percent, and the
per-service delta. Sort services by this month's spend and keep the top 10; fold the
rest into an `Other` row so the table still sums to the total.

What a finding looks like:

- **HIGH** — total up more than 20% month over month, or a single service up more than $500.
- **MEDIUM** — a service that was under $50 last month is now in the top 10.
- **LOW** — a service down more than 30% (worth a line: was something turned off on purpose?).

When `ORG_ROLE` is `payer`, run the same query grouped by `LINKED_ACCOUNT` and fill the
`BY LINKED ACCOUNT` section of the report with the accounts that moved more than 15%. For
`member` and `standalone`, say on the `Org role:` line which of the two it is and drop that
section; for `unknown`, keep the section and print it as N-A with the error text.

**Budgets.** Compare each budget against its own definition — not against the Step 1
total. MCP path: `budgets`. CLI path:

```bash
aws budgets describe-budgets --account-id "$ACCOUNT" --max-results 100 --output json
```

A budget's `CalculatedSpend` is the spend for *that budget's* current period on *that
budget's* cost basis. Before comparing anything, read the four fields that define it:

- `TimeUnit` — `DAILY`, `MONTHLY`, `QUARTERLY`, `ANNUALLY` or `CUSTOM`. Only a `MONTHLY`
  budget's period lines up with the report month, and even then `CalculatedSpend` covers
  the month in progress, not the last full month in the header.
- `TimePeriod` — where that period actually starts and ends.
- `FilterExpression` (or the deprecated `CostFilters`) — a budget scoped to one service,
  region, tag or linked account is not measuring the account total.
- `CostTypes` and `Metrics` — the metric may be `BlendedCost`, `AmortizedCost`,
  `NetUnblendedCost` or another value, and `CostTypes` decides whether credits and
  refunds are included. This is the account's choice, not the skill's convention.

Compare like with like or not at all:

- **HIGH** — `CalculatedSpend.ActualSpend` is over `BudgetLimit`, for any `COST` budget.
  The budget's own numbers settle this, whatever its period or filters.
- **MEDIUM** — `CalculatedSpend.ForecastedSpend` is over `BudgetLimit`, or actual is
  above 90% of it.
- **LOW** — no `COST` budget exists at all; nothing will alert when the bill jumps.
- Report a budget whose `TimeUnit`, `TimePeriod`, filters or metric differ from the report
  header alongside its scope in one clause ("quarterly, EC2 only, amortized"), so nobody
  reads it as a verdict on the header total.

---

## Step 2: Anomalies

MCP path: call `cost-anomaly` for the last 60 days. Keep anomalies with total impact
over $50 and note their root-cause dimension (service, account, region, usage type).

CLI path: Cost Anomaly Detection only reports when a monitor exists, so check first.

```bash
aws ce get-anomaly-monitors --output json
aws ce get-anomalies \
  --date-interval StartDate="$PREV_START",EndDate="$THIS_END" \
  --max-results 50 --output json
```

If there are no monitors, say so (it is itself a finding, LOW: "no anomaly monitor
configured") and fall back to the Step 1 data: any service whose month-over-month
delta exceeds 25% and $100 is treated as an anomaly. For each one, re-run the Step 1
query with `--group-by Type=DIMENSION,Key=USAGE_TYPE` and a filter that keeps the
credit and refund exclusion alongside the service, so the breakdown reconciles with
the Step 1 table:

```bash
aws ce get-cost-and-usage \
  --time-period Start="$PREV_START",End="$THIS_END" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --filter '{"And":[
    {"Dimensions":{"Key":"SERVICE","Values":["<service name>"]}},
    {"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}
  ]}' \
  --output json
```

The largest usage-type delta names the line item that moved.

A monthly figure says a line item moved, not when it moved, so no onset date exists
yet. When you need one — to match the change against a deploy or a launch — run the
same query once more for that usage type at daily granularity, and read the onset off
the first day that steps up:

```bash
aws ce get-cost-and-usage \
  --time-period Start="$PREV_START",End="$THIS_END" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter '{"And":[
    {"Dimensions":{"Key":"USAGE_TYPE","Values":["<usage type>"]}},
    {"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}
  ]}' \
  --output json
```

Without that drill-down, write the finding as a month-over-month change and give no
date. A date that no query returned is the failure this whole step exists to avoid.

Severity: **HIGH** when the impact is over $500 or the anomaly is still open; **MEDIUM**
otherwise. An anomaly that Cost Anomaly Detection already closed and that matches a
known change (the user tells you, or a tag says so) is **INFO**.

---

## Step 3: Waste

Four checks. Each is read-only. Sum the monthly figure for each check that produces one
and carry it to Step 5; a check that only produces candidates carries the candidate list.

**The region list.** Three of the four checks call regional APIs, so settle the region
list first, from the account rather than from spend. Spend-derived region lists miss
regions that hold only unattached volumes, snapshots, load balancers or NAT gateways —
exactly what this step is looking for.

```bash
REGIONS=$(aws account list-regions \
  --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
  --query 'Regions[].RegionName' --output text 2>&1); REG_RC=$?
if [ "$REG_RC" -ne 0 ]; then
  REGIONS=$(aws ec2 describe-regions \
    --query 'Regions[].RegionName' --output text 2>&1); REG_RC=$?
fi
if [ "$REG_RC" -ne 0 ]; then
  echo "REGIONS: N-A — $REGIONS"
else
  echo "REGIONS: $REGIONS"
fi
```

If both calls fail, the regional checks below are N-A, not clean. Say so with the error
text and carry no dollar figure from them. `aws ec2 describe-regions` lists regions the
account can reach; `aws account list-regions` is the one that reports opt-in status, so
prefer it and treat the EC2 call as the fallback.

**Over-provisioned compute.** MCP path: `compute-optimizer`, which covers the resource
types Compute Optimizer supports (EC2 instances, Auto Scaling groups, EBS volumes, Lambda
functions, ECS services on Fargate, RDS DB instances). CLI path, per region in
`$REGIONS`:

```bash
aws compute-optimizer get-enrollment-status --region "$R" --output json
aws compute-optimizer get-ec2-instance-recommendations --region "$R" --max-results 100 --output json
aws compute-optimizer get-ebs-volume-recommendations --region "$R" --max-results 100 --output json
```

If enrollment is `Inactive`, record it (LOW: "Compute Optimizer not enrolled — no
rightsizing data") and skip that region.

The two CLI calls cover EC2 instances and EBS volumes only. Say that in the report —
"EC2 instances and EBS volumes, <n> regions" — rather than implying the whole Compute
Optimizer surface was checked. Add `get-auto-scaling-group-recommendations`,
`get-lambda-function-recommendations` or `get-rds-database-recommendations` if you want
those, and widen the wording to match.

The `finding` values differ by resource type, so match each one against its own set:

- EC2 instances: `Underprovisioned | Overprovisioned | Optimized | NotOptimized`. Count
  `Overprovisioned` (the API may render it `OVER_PROVISIONED`).
- EBS volumes: `Optimized | NotOptimized` only. There is no `Overprovisioned` for a
  volume — count `NotOptimized`, and note that it also covers under-provisioned volumes,
  so it is a rightsizing candidate rather than proven waste on its own.

Savings live on the recommendation *options*, not on the recommendation:
`<type>RecommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value`. Take
the option with `rank: 1` — the top-ranked one — and sum those. Summing every option
counts the same resource several times over.

`savingsOpportunity` is only populated when the account has opted into Cost Explorer and
enabled EC2 resource recommendations there. When it is absent, report the count of
over-provisioned resources with no dollar figure and no severity above **LOW**; the
severity below needs the dollars.

**HIGH** when the summed rank-1 savings exceed $200/month.

**Idle resources.** MCP path: `cost-optimization` (Cost Optimization Hub) returns these
directly with estimated savings. CLI path: run each command below once per region in
`$REGIONS`, with `--region <name>`:

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,gb:Size,type:VolumeType}' --output json
aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[?StartTime<'$(date -v-1y +%Y-%m-%d 2>/dev/null || date -d '1 year ago' +%Y-%m-%d)'].{id:SnapshotId,started:StartTime,volume:VolumeId,gb:VolumeSize}" --output json
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerArn,State.Code]' --output json
aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'NatGateways[].{id:NatGatewayId,vpc:VpcId,mode:AvailabilityMode}' --output json
```

**Unattached EBS volumes** are billed on provisioned size whether or not anything reads
them, so size times list price is a fair estimate (gp3 about $0.08/GB-month). Confidence:
`medium` — it is list price, not the account's negotiated rate.

**Old snapshots** are a different case. EBS snapshots are incremental: a snapshot stores
only the blocks that changed since the previous one, and deleting it removes only the
blocks no other snapshot references. The EBS user guide is explicit — "Deleting a
snapshot might not reduce your organization's data storage costs. Other snapshots might
reference that snapshot's data, and referenced data is always preserved." `VolumeSize` is
the size of the source volume, not the bytes this snapshot holds, so `VolumeSize` times a
flat rate is not a saving and must not be printed as one. Age alone is not waste either:
a year-old snapshot may be a retained backup, and snapshots backing a registered AMI or
managed by AWS Backup cannot be deleted at all.

Report them as **candidates for review** with the evidence actually in hand — the count,
the oldest `started` value, and the `volume` ids — and no dollar figure. Those three come
from the projection above; the age filter alone does not select them, so a query that
projects only `SnapshotId` cannot report a date. Name a `volume` id only for a snapshot
taken from a volume in this account — the API reference is explicit that "snapshots created
by a copy snapshot operation have an arbitrary volume ID that you should not use for any
purpose". Severity **LOW**. To turn a
candidate into a number, the account needs per-snapshot stored bytes, which comes from
the Cost and Usage Report (`EBS:SnapshotUsage` line items) or S3 Storage Lens-style
reporting, not from `describe-snapshots`; say that is the next step rather than guessing.

**Load balancers.** Zero healthy targets right now does not make a load balancer idle —
it also looks like an outage, a failover, or something provisioned ahead of its targets.
Take the instantaneous health as a prompt, then confirm with traffic history over the
report period before assigning any saving:

```bash
aws elbv2 describe-target-groups --load-balancer-arn <arn> \
  --query 'TargetGroups[].TargetGroupArn' --output json
aws elbv2 describe-target-health --target-group-arn <target group arn> \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output json
aws cloudwatch get-metric-statistics --region "$R" \
  --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<lb dimension value> \
  --start-time "$THIS_START"T00:00:00Z --end-time "$THIS_END"T00:00:00Z \
  --period 86400 --statistics Sum --output json
```

Use `AWS/NetworkELB` with `ProcessedBytes` and `ActiveFlowCount` for a network load
balancer. Elastic Load Balancing only publishes these metrics while traffic is flowing —
"If there are no requests flowing through the load balancer or no data for a metric, the
metric is not reported" — so an empty datapoint list across the whole period, from a call
that exited 0, is real evidence of no traffic. A call that failed is N-A.

A load balancer with zero healthy targets *and* no traffic datapoints for the period is
idle at roughly $16-22/month, confidence `medium`. With one of the two, it is a candidate
at **LOW** and no dollar figure.

For NAT gateways, price them with their own usage-type query — NAT charges land under
the `EC2 - Other` service, which Step 1 only ever shows as a single service row:

```bash
aws ce get-cost-and-usage \
  --time-period Start="$THIS_START",End="$THIS_END" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --filter '{"And":[
    {"Dimensions":{"Key":"SERVICE","Values":["EC2 - Other"]}},
    {"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund"]}}}
  ]}' \
  --output json
```

Keep the `NatGateway-Hours` and `NatGateway-Bytes` rows. That is the account's total NAT
spend for the month: the query aggregates every gateway into one usage-type row, so it
cannot say what any single gateway cost. Divide by the gateway count only to state an
average, and label it as one.

A VPC with no running EC2 instances is not an idle NAT gateway. Lambda in a VPC, ECS and
Fargate tasks, EKS nodes, RDS, and anything reaching the VPC over peering, Transit
Gateway or a VPN all send traffic through it without a running instance in
`describe-instances`. The gateway's own CloudWatch metrics in namespace `AWS/NATGateway`
are what settle it — but only under the dimensions that gateway actually publishes. The
VPC user guide splits them by availability mode: "NatGatewayId — Zonal NAT gateways use
only this dimension. Regional NAT gateways use this dimension together with
`AvailabilityZone`." `GetMetricStatistics` matches the whole set — "CloudWatch treats each
unique combination of dimensions as a separate metric. If a specific combination of
dimensions was not published, you can't retrieve statistics for it" — so a
`NatGatewayId`-only query against a regional gateway exits 0 with an empty `Datapoints`
array however busy the gateway is.

The `mode` field from the discovery call says which kind it is, `zonal` or `regional`. Ask
CloudWatch which dimension sets it holds rather than inferring them, once per gateway:

```bash
aws cloudwatch list-metrics --region "$R" \
  --namespace AWS/NATGateway --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=<nat gateway id> \
  --query 'Metrics[].Dimensions' --output json
```

`ListMetrics` filters on dimension name rather than on the whole set — "if you specify one
dimension name and a metric has that dimension and also other dimensions, it will be
returned" — so this comes back with one entry for a zonal gateway and one entry per
Availability Zone for a regional one. It is also the fallback when `mode` is null because
the installed CLI predates the field.

Run the three metrics below once for each dimension set returned, adding
`Name=AvailabilityZone,Value=<az>` next to the gateway id for a regional gateway:

```bash
for M in BytesInFromSource BytesOutToDestination; do
  aws cloudwatch get-metric-statistics --region "$R" \
    --namespace AWS/NATGateway --metric-name "$M" \
    --dimensions Name=NatGatewayId,Value=<nat gateway id> \
    --start-time "$THIS_START"T00:00:00Z --end-time "$THIS_END"T00:00:00Z \
    --period 86400 --statistics Sum --output json || echo "N-A $M"
done
aws cloudwatch get-metric-statistics --region "$R" \
  --namespace AWS/NATGateway --metric-name ActiveConnectionCount \
  --dimensions Name=NatGatewayId,Value=<nat gateway id> \
  --start-time "$THIS_START"T00:00:00Z --end-time "$THIS_END"T00:00:00Z \
  --period 86400 --statistics Maximum --output json
```

`ActiveConnectionCount` is documented as "the total number of concurrent active TCP
connections through the NAT gateway. A value of zero indicates that there are no active
connections."

An empty `Datapoints` array does not mean zero here, and this is the opposite of the load
balancer case above. CloudWatch "delivers this metric data at 1-minute intervals" for a NAT
gateway, so a gateway that is up and idle reports zeros. No datapoints at all means the
dimension set was wrong or the metric was never published, which is **N-A**.

Call a gateway idle only when every dimension set it publishes under returns datapoints
from calls that exited 0, and all three metrics are zero across the period. A failed call,
an empty datapoint list, or a `list-metrics` call that returned no dimension sets each
make the gateway N-A. A gateway that is quiet but not silent is a candidate at **LOW**,
not a saving.

**MEDIUM** when idle spend is over $50/month, **HIGH** over $300/month. Both thresholds
apply to resources that cleared the evidence bar above — instantaneous state alone never
reaches MEDIUM.

**Untagged spend share.** List the active user-defined cost-allocation tags:

```bash
aws ce list-cost-allocation-tags --status Active --type UserDefined --output json
```

The API returns a flat list with no notion of a primary or ownership tag — `team`,
`env`, `project`, `cost-center` and `Name` all come back the same way. Picking one
arbitrarily classifies spend tagged under a different key as untagged and fires a finding
that is not true.

- No active tag at all: **LOW**, "no cost-allocation tags active", no percentage.
- Exactly one active tag: use it, and name it in the finding.
- More than one: ask which key carries ownership (AskUserQuestion, one option per key,
  plus "report all of them"). If the user does not pick, report coverage per candidate
  tag as separate rows and draw no single conclusion.

For the chosen key, query the month grouped by `Type=TAG,Key=<key>`. Grouping by `TAG`
returns all tag values including empty strings, and the empty-value row is the untagged
spend. Report its share of the total.

**MEDIUM** when more than 30% of spend carries no owner tag under a key the user
confirmed is the ownership tag; it blocks chargeback and usually hides the idle resources
above. Without that confirmation the same number is **LOW** and reported per key.

**Free tier.** MCP path only (`free-tier-usage`). Two things to get right in the wording:

- An account on the **paid** plan is charged standard pay-as-you-go rates as soon as
  usage passes a free allowance or the credit balance runs out — in the same month, not
  the next one. An account on the **free** plan incurs no charges, and that plan ends
  after six months or when its credits are used up, whichever comes first.
- Usage above a limit is therefore not "not yet paid for". Say which plan the account is
  on, and whether credits are still covering the overage, before saying anything about
  when it starts to bill.

**LOW** for any usage above 80% of its free-tier allowance, phrased as above. Skip
silently on the CLI path.

---

## Step 4: Commitments

Steady compute should sit under a Savings Plan or Reserved Instances. Two numbers
matter: coverage (share of eligible spend under commitment) and utilization (share of
purchased commitment actually used). MCP path: `sp-performance` and `ri-performance`
for the report month. CLI path:

```bash
aws ce get-savings-plans-coverage --time-period Start="$THIS_START",End="$THIS_END" --output json
aws ce get-savings-plans-utilization --time-period Start="$THIS_START",End="$THIS_END" --output json
aws ce get-reservation-coverage --time-period Start="$THIS_START",End="$THIS_END" --output json
aws ce get-reservation-utilization --time-period Start="$THIS_START",End="$THIS_END" --output json
```

Findings:

- **HIGH** — utilization under 70%. Money was paid for commitment that went unused; note the unused dollar amount for the month.
- **MEDIUM** — coverage under 60% while on-demand EC2, Fargate, or Lambda spend is steady (within 15% month over month). Take that steadiness reading from the on-demand usage-type rows of the Step 2 query (`BoxUsage:*`, Fargate vCPU and GB hours, Lambda duration), not from the service total, which does not separate on-demand from covered usage. If the on-demand line moved more than 15%, the precondition fails: report the coverage figure at **LOW**, say what the on-demand line did, and rank no commitment purchase until the new level has held for a full month. Pull the purchase recommendation for the size: `aws ce get-savings-plans-purchase-recommendation --savings-plans-type COMPUTE_SP --term-in-years ONE_YEAR --payment-option NO_UPFRONT --lookback-period-in-days THIRTY_DAYS --output json`. Report the recommended hourly commitment and the estimated monthly savings. Never purchase.
- **INFO** — a plan or reservation expiring within 60 days. Savings Plans come from `aws savingsplans describe-savings-plans`. Reserved Instances are per-service and per-region: `aws ec2 describe-reserved-instances --filters Name=state,Values=active --region <name>` returns EC2 reservations in one region only. Loop it over `$REGIONS` from Step 3, and use `aws rds describe-reserved-db-instances`, `aws elasticache describe-reserved-cache-nodes` or `aws redshift describe-reserved-nodes` for the other services, per region, if you report on them.

**Scope the coverage numbers, or the report will not reconcile.** `GetReservationCoverage`
spans EC2, ElastiCache, RDS and Redshift, and with no `SERVICE` filter Cost Explorer
defaults to EC2. The expiry check above is per region and per service. Pick one and be
explicit:

- Filter the coverage and utilization calls to the EC2 compute service value
  (`SERVICE = "Amazon Elastic Compute Cloud - Compute"`) and to the one region the expiry
  check covers (`REGION = "us-east-1"`, say). Both APIs take an `Expression` with `And`
  over those two dimensions, and both list `REGION` and `SERVICE` as filterable. Label the
  row "EC2, <region> only" — the cheap option, and the one that matches an
  EC2-in-one-region expiry check. Without a `REGION` filter the calls return EC2 across
  every region the account uses, and the row has to say "EC2, all regions" instead.
- Or query each service you care about, loop the expiry check over `$REGIONS` and every
  matching reservation API, and label the row with the services covered.

Never print an unlabelled coverage percentage next to a partial expiry list.

Note the cost basis: `GetSavingsPlansUtilization` reports `AmortizedCommitment` and
`Savings.NetSavings` against an `OnDemandCostEquivalent`. That is an amortized basis, not
the unblended credit-excluded basis in the header. Say "amortized" wherever these numbers
appear.

If there is no compute spend to speak of (under $100/month), say so and skip this step.

---

## Step 5: Three recommendations

Exactly three. Candidates come from Steps 2-4; pick by dollars, not by how easy they are.
Verified savings come first, ranked by monthly dollars; investigation candidates follow,
also ranked by dollars. A larger at-risk figure never outranks a smaller confirmed one.

**An anomaly is not a saving.** Step 2 measures what spend *changed*. It says nothing
about whether the new spend is avoidable — a legitimate launch, a migration and a
forgotten test fleet all look identical in Cost Explorer. Anomaly impact may only be
ranked against verified waste once resource-level evidence says the spend is avoidable:
utilization for the resources behind it, plus an owner or the absence of one. Until then
an anomaly belongs in the list as an **investigation candidate** — the action is "find
out what launched", the dollar figure is labelled "at risk, not yet a saving", and
confidence is `low`.

For each of the three write:

- the action in one sentence
- estimated monthly saving in dollars, with the period the estimate is based on, or
  "at risk" for an investigation candidate
- confidence: `high` (saving figure comes straight from the AWS tool), `medium` (list price times observed usage), `low` (assumes the workload is steady, or the spend has not been shown to be avoidable)
- the exact command or console path that does it, so the user can act after reading
- the risk: what breaks if the assumption is wrong (a "stopped" instance someone needed, a commitment that outlives the workload)

Every claim in a recommendation must trace to a step that collected it. Instance counts,
instance ids, tag status and launch dates come from `describe-instances`, not from a
Cost Explorer usage-type row — if the run did not make that call, the recommendation
names the usage type and says the ids are still to be established.

If fewer than three candidates clear $20/month, fill the remaining slots with the
hygiene findings (no anomaly monitor, untagged spend, Compute Optimizer not enrolled)
and say plainly that the bill is already lean.

---

## Step 6: Write and print the report

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
REPORT_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/aws-cost-$(date +%Y-%m-%d).md"
echo "REPORT: $REPORT"
```

Write the report in the Output format below to `$REPORT` (overwrite today's if it
exists), then print it in full. The file is for the next run to diff against.

---

## Output

```
AWS COST REVIEW
===============

Account:   <alias or last 4 digits of the account id> (profile: <name>)
Org role:  payer (4 linked accounts)
Period:    2026-07-01..2026-07-31 vs 2026-06-01..2026-06-30
Total:     $12,418.37  (+$1,904.12, +18.1% month over month)
Data path: MCP | CLI
Basis:     UnblendedCost, credits and refunds excluded (Cost Explorer queries;
           budgets and commitments carry their own basis, labelled inline)
Regions:   3 enabled (us-east-1, eu-west-1, ap-southeast-2)

BY SERVICE (top 10, UnblendedCost)
Service                    This month   Last month     Delta
-------------------------  ----------  -----------  --------
Amazon EC2                     $4,210       $3,180    +$1,030  +32%
Amazon RDS                     $2,940       $2,910       +$30   +1%
Amazon S3                      $1,120       $1,090       +$30   +3%
...
Other (14 services)              $610         $590       +$20   +3%

BY LINKED ACCOUNT (payer only; accounts that moved more than 15%)
Account                    This month   Last month     Delta
-------------------------  ----------  -----------  --------
prod (...4471)                 $7,980       $6,240    +$1,740  +28%
sandbox (...9902)                $410         $250      +$160  +64%

BUDGETS
[MEDIUM] "monthly-total" (monthly, unfiltered, unblended) limit $12,000 — forecast
         $12,900 for 2026-08-01..2026-08-31, actual so far $402 (1 day elapsed).
         Its period is the month in progress, so it is not a verdict on July's
         $12,418.37 header total.

ANOMALIES
[HIGH]   EC2 BoxUsage:m5.4xlarge +$980 month over month — largest usage-type delta
         in EC2; no daily drill-down run, so no onset date; owning resources not
         yet identified
[LOW]    No anomaly monitor configured — Cost Anomaly Detection is off for this account

WASTE
[HIGH]   Compute Optimizer (EC2 instances + EBS volumes, 3 regions):
         7 over-provisioned EC2 instances, $310/month (rank-1 options)
[MEDIUM] 12 unattached EBS volumes (1.4 TB) — $115/month at gp3 list price
[LOW]    31 snapshots older than 1 year (oldest 2023-11-04) — candidates for review;
         stored bytes unknown, so no saving figure (see CUR EBS:SnapshotUsage)
[LOW]    38% of spend carries no owner tag under key "team"
[LOW]    9% of spend carries no owner tag under key "project"
         Both keys are candidates: 2 active tags, neither confirmed as the ownership
         tag, so coverage is reported per key and no single figure is drawn from it.

COMMITMENTS
Savings Plans (EC2 only, amortized): coverage 41%, utilization 96%
RI (EC2, us-east-1 only): coverage 0%, utilization N-A
[LOW]    Coverage 41% is under 60%, but on-demand is not steady: BoxUsage:m5.4xlarge
         rose +$980 in July (+60% on the on-demand line). No commitment size ranked
         until that level holds for a full month.

RECOMMENDATIONS (verified savings first, each ranked by monthly $)
1. $310/month  confidence: high
   Apply the 7 Compute Optimizer downsizes (list in report body).
   Run:  aws compute-optimizer get-ec2-instance-recommendations --region us-east-1 --instance-arns <arns>
   Risk: CPU headroom during monthly batch; check the 14-day p99 before resizing.
2. $115/month  confidence: medium
   Delete the 12 unattached EBS volumes (1.4 TB, ids in report body) after confirming no owner claims them.
   Run:  aws ec2 describe-volumes --region us-east-1 --filters Name=status,Values=available
   Risk: gp3 list price, not the account's rate; a volume kept as a cold copy of data still holds it.
3. $980/month at risk, not yet a saving  confidence: low
   Find out what scaled up behind EC2 BoxUsage:m5.4xlarge in July, then decide.
   Run:  aws ce get-cost-and-usage --time-period Start=2026-07-01,End=2026-08-01 \
           --granularity DAILY --metrics UnblendedCost \
           --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["BoxUsage:m5.4xlarge"]}}'
         aws ec2 describe-instances --region us-east-1 \
           --filters Name=instance-type,Values=m5.4xlarge \
           --query 'Reservations[].Instances[].[InstanceId,LaunchTime,State.Name,Tags]'
   Risk: this is a spend change, not proven waste — it may be a deliberate scale-up.

Report written to: ~/.vibestack/projects/<slug>/aws-cost-2026-08-01.md
```

The header and the linked-account section carry whichever of the four `ORG_ROLE` outcomes
Step 0 produced. The example above is a payer. For `member` or `standalone` the `Org role:`
line names which of the two it is and the `BY LINKED ACCOUNT` section is dropped entirely.
For `unknown` keep the section heading and print `N-A — <error text>` under it: a denied
`describe-organization` call is never reported as no linked accounts.

Severity labels: `HIGH`, `MEDIUM`, `LOW`, `INFO`. A check that could not run is printed
as `N-A` with the error text — it is not a severity, and it is never a pass. Every dollar
figure names the period it covers, either in the header or inline ("$310/month",
"+$980 in July"), and a figure that is exposure rather than saving says so.

---

## Important Rules

1. **Read-only.** This skill describes, gets, and lists. It never calls purchase, create, modify, delete, terminate, or stop APIs, never applies a Compute Optimizer or Cost Optimization Hub recommendation, and never writes to the customer's AWS account. The commands in the recommendations are for the user to run after reading.
2. **No account IDs in learnings.** Anything logged with `vibe-learnings-log` refers to the account by alias or by the project slug, never by the 12-digit id, an ARN, or a profile that contains one.
3. **Dollars carry a period.** Never print a bare figure. "$4,210" means nothing; "$4,210 in July 2026" or "$310/month" does.
4. **One data path, stated up front.** Do not mix MCP and CLI numbers in one table; the two round and filter slightly differently.
5. **Credits and refunds are excluded from the Cost Explorer figures** — the service, usage-type and tag queries in Steps 1-3 — unless the user asks for the invoice view. Say so in the header. Two places do not follow that basis and must be labelled where they appear: a budget uses its own `CostTypes` and `Metrics`, which the account chose; the Savings Plans and Reserved Instance numbers in Step 4 are amortized.
6. **Exactly three recommendations.** Ranked by dollars. If the account is lean, say so rather than inventing savings.
7. **Missing data is a finding, not a failure.** No anomaly monitor, no Compute Optimizer enrollment, no cost-allocation tags: report each one and move on.
8. **Never guess at credentials.** If `sts get-caller-identity` fails, stop with the setup note. Do not read credential files or try other profiles unasked.

{{include lib/snippets/capture-learnings.md}}
