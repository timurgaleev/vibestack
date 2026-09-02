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
- Filter out `RecordType` values `Credit` and `Refund` so a one-off credit does not hide a real rise.
- Group by `SERVICE` first. Group by `LINKED_ACCOUNT` when the account is a payer, and by a cost-allocation tag (`team`, `env`, `project`) when one is active.
- Round to whole dollars in tables; keep cents only in the header total.

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

If the account is a payer, run the same query grouped by `LINKED_ACCOUNT` and add a
second table when any linked account moved more than 15%.

**Budgets.** Compare the month against what the account said it would spend.
MCP path: `budgets`. CLI path:

```bash
aws budgets describe-budgets --account-id "$ACCOUNT" --max-results 100 --output json
```

For each `COST` budget compare `CalculatedSpend.ActualSpend` and
`CalculatedSpend.ForecastedSpend` with `BudgetLimit`:

- **HIGH** — actual spend is over the limit.
- **MEDIUM** — forecasted spend is over the limit, or actual is above 90% of it.
- **LOW** — no budget exists at all; nothing will alert when the bill jumps.

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

Severity: **HIGH** when the impact is over $500 or the anomaly is still open; **MEDIUM**
otherwise. An anomaly that Cost Anomaly Detection already closed and that matches a
known change (the user tells you, or a tag says so) is **INFO**.

---

## Step 3: Waste

Four checks. Each is read-only. Sum the monthly figure for each and carry it to Step 5.

**Over-provisioned compute.** MCP path: `compute-optimizer` for EC2, ASG, EBS, Lambda,
RDS. CLI path:

```bash
aws compute-optimizer get-enrollment-status --output json
aws compute-optimizer get-ec2-instance-recommendations --max-results 100 --output json
aws compute-optimizer get-ebs-volume-recommendations --max-results 100 --output json
```

If enrollment is `Inactive`, record it (LOW: "Compute Optimizer not enrolled — no
rightsizing data") and skip. Otherwise count findings with `finding: Overprovisioned`
and add up `estimatedMonthlySavings`. **HIGH** when the sum is over $200/month.

**Idle resources.** MCP path: `cost-optimization` (Cost Optimization Hub) returns
these directly with estimated savings. CLI path: first find the regions in use by
re-running the Step 1 query for this month grouped by region and service together
(`--group-by Type=DIMENSION,Key=REGION Type=DIMENSION,Key=SERVICE --time-period Start="$THIS_START",End="$THIS_END"`).
Every region whose EC2 rows sum above $1 is in use; `global` and `NoRegion` are not
regions and are skipped. Then run each command below once per region with
`--region <name>`:

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,gb:Size,type:VolumeType}' --output json
aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[?StartTime<'$(date -v-1y +%Y-%m-%d 2>/dev/null || date -d '1 year ago' +%Y-%m-%d)'].[SnapshotId,VolumeSize]" --output json
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerArn,State.Code]' --output json
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].[NatGatewayId,VpcId]' --output json
```

Unattached EBS volumes and snapshots older than a year are waste at list price (gp3
about $0.08/GB-month, snapshots about $0.05/GB-month). For each load balancer, check
target health; one with zero healthy targets across all its target groups is idle at
roughly $16-22/month:

```bash
aws elbv2 describe-target-groups --load-balancer-arn <arn> \
  --query 'TargetGroups[].TargetGroupArn' --output json
aws elbv2 describe-target-health --target-group-arn <target group arn> \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output json
```

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

Keep the `NatGateway-Hours` and `NatGateway-Bytes` rows; a NAT gateway in a VPC with
no running instances is $32/month of nothing.
**MEDIUM** when idle spend is over $50/month, **HIGH** over $300/month.

**Untagged spend share.** Query the month grouped by the account's primary
cost-allocation tag (`aws ce list-cost-allocation-tags --status Active` names them).
The row with an empty tag value is untagged spend. Report its share of the total.
**MEDIUM** when more than 30% of spend carries no owner tag; it blocks chargeback and
usually hides the idle resources above.

**Free tier.** MCP path only (`free-tier-usage`): **LOW** for any usage above 80% of
its free-tier limit — nothing is being paid for yet, but the next month will bill.
Skip silently on the CLI path.

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
- **MEDIUM** — coverage under 60% while on-demand EC2, Fargate, or Lambda spend is steady (within 15% month over month). Pull the purchase recommendation for the size: `aws ce get-savings-plans-purchase-recommendation --savings-plans-type COMPUTE_SP --term-in-years ONE_YEAR --payment-option NO_UPFRONT --lookback-period-in-days THIRTY_DAYS --output json`. Report the recommended hourly commitment and the estimated monthly savings. Never purchase.
- **INFO** — a plan or reservation expiring within 60 days (`aws savingsplans describe-savings-plans`, `aws ec2 describe-reserved-instances --filters Name=state,Values=active`).

If there is no compute spend to speak of (under $100/month), say so and skip this step.

---

## Step 5: Three recommendations

Exactly three. Rank by estimated monthly dollar impact, largest first. Candidates come
from Steps 2-4; pick the top three by dollars, not by how easy they are. For each one
write:

- the action in one sentence
- estimated monthly saving in dollars, with the period the estimate is based on
- confidence: `high` (saving figure comes straight from the AWS tool), `medium` (list price times observed usage), `low` (assumes the workload is steady)
- the exact command or console path that does it, so the user can act after reading
- the risk: what breaks if the assumption is wrong (a "stopped" instance someone needed, a commitment that outlives the workload)

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
Period:    2026-07-01..2026-07-31 vs 2026-06-01..2026-06-30
Total:     $12,418.37  (+$1,904.12, +18.1% month over month)
Data path: MCP | CLI
Excludes:  credits, refunds

BY SERVICE (top 10, UnblendedCost)
Service                    This month   Last month     Delta
-------------------------  ----------  -----------  --------
Amazon EC2                     $4,210       $3,180    +$1,030  +32%
Amazon RDS                     $2,940       $2,910       +$30   +1%
Amazon S3                      $1,120       $1,090       +$30   +3%
...
Other (14 services)              $610         $590       +$20   +3%

BUDGETS
[MEDIUM] "monthly-total" limit $12,000 — actual $12,418 (103%), forecast $12,900

ANOMALIES
[HIGH]   EC2 BoxUsage:m5.4xlarge +$980 from 2026-07-12 — 4 new instances, untagged, us-east-1
[MEDIUM] No anomaly monitor configured — Cost Anomaly Detection is off for this account

WASTE
[HIGH]   Compute Optimizer: 7 over-provisioned EC2 instances, $310/month
[MEDIUM] 12 unattached EBS volumes (1.4 TB), 31 snapshots older than 1 year — $140/month
[MEDIUM] 38% of spend carries no owner tag

COMMITMENTS
Savings Plans: coverage 41%, utilization 96%   RI: coverage 0%, utilization n/a
[MEDIUM] Steady on-demand compute of $2,600/month with 41% coverage

RECOMMENDATIONS (ranked by monthly $)
1. $980/month  confidence: medium
   Stop or right-size the 4 m5.4xlarge instances launched 2026-07-12 in us-east-1.
   Run:  aws ec2 describe-instances --instance-ids <ids> --query 'Reservations[].Instances[].[InstanceId,Tags]'
   Risk: they may be a deliberate scale-up nobody tagged; confirm the owner first.
2. $620/month  confidence: high
   Buy a 1-year no-upfront Compute Savings Plan at $1.10/hour (Cost Explorer recommendation, 30-day lookback).
   Path: Billing console > Savings Plans > Recommendations
   Risk: commitment outlives the workload if the EC2 fleet shrinks in the next year.
3. $310/month  confidence: high
   Apply the 7 Compute Optimizer downsizes (list in report body).
   Run:  aws compute-optimizer get-ec2-instance-recommendations --instance-arns <arns>
   Risk: CPU headroom during monthly batch; check the 14-day p99 before resizing.

Report written to: ~/.vibestack/projects/<slug>/aws-cost-2026-08-01.md
```

Severity labels: `HIGH`, `MEDIUM`, `LOW`, `INFO`. Every dollar figure names the period
it covers, either in the header or inline ("$310/month", "+$980 in July").

---

## Important Rules

1. **Read-only.** This skill describes, gets, and lists. It never calls purchase, create, modify, delete, terminate, or stop APIs, never applies a Compute Optimizer or Cost Optimization Hub recommendation, and never writes to the customer's AWS account. The commands in the recommendations are for the user to run after reading.
2. **No account IDs in learnings.** Anything logged with `vibe-learnings-log` refers to the account by alias or by the project slug, never by the 12-digit id, an ARN, or a profile that contains one.
3. **Dollars carry a period.** Never print a bare figure. "$4,210" means nothing; "$4,210 in July 2026" or "$310/month" does.
4. **One data path, stated up front.** Do not mix MCP and CLI numbers in one table; the two round and filter slightly differently.
5. **Credits and refunds are excluded** from every figure unless the user asks for the invoice view. Say so in the header.
6. **Exactly three recommendations.** Ranked by dollars. If the account is lean, say so rather than inventing savings.
7. **Missing data is a finding, not a failure.** No anomaly monitor, no Compute Optimizer enrollment, no cost-allocation tags: report each one and move on.
8. **Never guess at credentials.** If `sts get-caller-identity` fails, stop with the setup note. Do not read credential files or try other profiles unasked.

{{include lib/snippets/capture-learnings.md}}
