# How to run the AWS review skills for the first time

Four skills in the pack read an AWS account, or the code that deploys to one:
`/aws-cost`, `/bedrock-guardrails`, `/kb-review` and `/connect-review`. They share a
prerequisite set and a set of reporting conventions, so the first run of any of them
looks much the same.

This page is the first-run path: what has to be in place, what you type, what the
skill asks you, and what comes back. What each skill covers is in
[`docs/skills.md`](skills.md) — that is not repeated here.

---

## Prerequisites

**The pack is installed.** `git clone` plus `./install`, per the
[README](../README.md#install-in-30-seconds). None of the four declares hooks or
reads `${CLAUDE_SKILL_DIR}`, and the compatibility matrix rates all four `full` in
Claude Code, Cursor and Kiro — see the per-skill rows in
[`docs/agent-skills-compatibility-audit.md`](agent-skills-compatibility-audit.md).
Codex CLI has no runtime data in that matrix, so treat it as untested. All four
list `AskUserQuestion` in `allowed-tools`, which the same audit classes as a
Claude Code tool; `/aws-cost` uses it to pick between AWS profiles and
`/bedrock-guardrails` to settle the EU residency question.

**The `aws` CLI works on the machine already.** vibestack does not bundle, install or
configure it, and none of these skills reads `~/.aws/credentials` or asks you for
keys — they use the profile, SSO session or instance role that is already there.
[`docs/external-tools.md`](external-tools.md#aws-cli) has the full statement of what
the CLI is used for and what happens when it is absent.

Check credentials before you start anything:

```bash
aws sts get-caller-identity --output json
```

If that fails, fix it with `aws configure --profile <name>` or
`aws sso login --profile <name>` first. `/aws-cost` stops with a setup note rather
than guessing, and the other three degrade instead of erroring.

**Per skill, on top of that:**

| Skill | Also needs | Works with no AWS session? |
|---|---|---|
| `/aws-cost` | Read access to the APIs it calls: `ce`, `budgets`, `organizations`, `account`, `ec2`, `elbv2`, `cloudwatch`, `compute-optimizer`, `savingsplans`, plus the reservation API of any other service you ask it to report on | No — this skill is the account |
| `/bedrock-guardrails` | Nothing, to audit code. A session adds the live half (`bedrock`, IAM, logging config) | Yes — every live control is reported `N-A (no CLI)` |
| `/kb-review` | The knowledge base id, or a session that can list them, and Bedrock retrieve permissions beyond a plain read-only policy | Partly — falls back to the Terraform and ingestion code |
| `/connect-review` | The Connect instance and flow ids, or exported flow JSON in the repo | Partly — greps the repo, then asks for what it cannot resolve |

`/aws-cost` has a second data path: when the session has the AWS billing MCP tools
connected (tool names starting `mcp__awslabs_billing`), it uses those instead of the
CLI and says which path it took in the report header.

---

## Conventions all four follow

Worth knowing before you read your first report, because they change how a result
should be read.

- **Read-only.** Every call is a describe, get, list, or query. Nothing creates,
  updates, deletes, enables or purchases. `/kb-review` will not start an ingestion
  job even when the last sync is stale; `/aws-cost` prints the command for a
  recommendation and leaves you to run it.
- **`N-A` is not a pass.** A check that could not run — access denied, no
  credentials, a missing input — is reported `N-A` with the error text. It is never
  folded into a clean result.
- **Estimates are labelled.** A latency or cost figure that was not measured says so,
  and every dollar figure names the period it covers.
- **`/kb-review` costs money to run.** Its golden-set pass calls `retrieve` and
  `retrieve-and-generate` against the live knowledge base, and those are billed like
  any other query. The skill states the call count before running it.

---

## Run `/aws-cost`

The one to start with — it needs no ids and no repo context.

1. Open a session in any repo and type:

   ```
   /aws-cost
   ```

   In Codex CLI, `/` is reserved for Codex's own commands; write
   `Use $aws-cost` in an ordinary message instead. The same applies to every
   command on this page.

2. Answer what it asks. On a working `default` profile it asks nothing. It asks only
   when the check fails and more than one profile exists, when you named an ambiguous
   period ("this quarter", "since the migration"), or when more than one
   cost-allocation tag is active and it needs to know which key carries ownership.

3. It works through totals and month-over-month by service, anomalies, waste,
   commitments, then picks exactly three recommendations ranked by dollars.

**Default period:** the last full calendar month against the month before it. Say so
explicitly if you want something else.

**Where the output goes:** printed in full, and written to
`~/.vibestack/projects/<slug>/aws-cost-<YYYY-MM-DD>.md` (`$VIBESTACK_HOME` overrides
the root; `<slug>` comes from the git remote). Today's file is overwritten on a
re-run. The file exists so the next run has something to diff against.

**You know it worked when** the printed report has a header block, a by-service
table, and three numbered recommendations. The header names the data path and the
cost basis:

```
Account:   <alias or last 4 digits of the account id> (profile: <name>)
Org role:  payer (4 linked accounts)
Period:    2026-07-01..2026-07-31 vs 2026-06-01..2026-06-30
Total:     $12,418.37  (+$1,904.12, +18.1% month over month)
Data path: MCP | CLI
```

That block is the skill's own output template with its example figures; the full
template is the `## Output` section of `skills/aws-cost/SKILL.md`.

---

## Run `/bedrock-guardrails`

Point it at a repo that talks to Bedrock. It audits code first and the account
second, so it is useful before any credentials exist.

1. From the repo root:

   ```
   /bedrock-guardrails
   ```

2. It inventories every Bedrock call site — infrastructure code and application code
   separately — and that list is the row source for everything after it.

3. It then asks one thing that matters: **does this workload have a written EU data
   residency commitment?** It will not infer one from an `eu-*` provider block or a
   GDPR mention in a README. Answer honestly. Under `RESIDENCY=EU` any call that
   resolves to a `us-*` region or a `us.` / `global.` inference profile is a HIGH
   finding; with no commitment the same routing is scored as an undocumented
   cross-region decision at MEDIUM.

**Where the output goes:** printed. Ask for a file and it writes the same report to
`docs/bedrock-guardrails-audit.md`.

**You know it worked when** you get a control table — rows `R1`-`R4`, `I1`-`I4`,
`G1`-`G8`, `D1`-`D5`, `T1`-`T3`, `P1`-`P3`, `Q1`-`Q3`, each PASS, FAIL or N-A with
evidence as `file:line` — followed by `Totals:`, the call-site list, and a Terraform
snippet for each remediation group that has at least one FAIL.

**With no AWS session** the code-derived controls still resolve; the rest read
`N-A (no CLI)` with a note on what to run. That is a usable first pass, not a
degraded one.

---

## Run `/kb-review`

This one has a live half that is billed, so decide before you start whether you want
the retrieval measurement or only the configuration review.

1. From the repo that holds the knowledge base's infrastructure code:

   ```
   /kb-review
   ```

2. It greps for `aws_bedrockagent_knowledge_base` and friends first, then for the
   splitter and vector-store names a hand-built pipeline uses. If neither hits, it
   asks where the knowledge base lives.

3. It reads `knowledgeBaseConfiguration.type` before judging anything —
   `VECTOR`, `MANAGED`, `KENDRA` or `SQL` decide which fields exist and which
   retrieval request shape is valid, and the wrong shape is an invalid request rather
   than a finding.

4. For the retrieval measurement it writes a golden set of 20 to 40 question and
   expected-passage pairs, runs retrieve-only against them, and scores document
   hit@5, passage hit@5 and MRR. It states the call count first.

**Where the output goes:** `~/.vibestack/projects/<slug>/`. Three paths are printed
at the end of the report —

```
kb-eval-<YYYY-MM-DD>.jsonl           the golden set
kb-eval-results-<YYYY-MM-DD>.jsonl   the ranked hits per question
kb-review-<YYYY-MM-DD>.md            the report
```

Those three are not everything in the directory. The steps that run write
`kb-isolation-<YYYY-MM-DD>.json` for the tenant-isolation probe,
`kb-cost-<YYYY-MM-DD>.json` for the Cost Explorer pull, and the `.ids-asked` /
`.ids-got` pair the denominator check diffs — none of them announced.
[`docs/internals.md`](internals.md) has the full tree.

**You know it worked when** the report carries a KB summary block, a findings table,
a `RETRIEVAL METRICS` table with a row per language subset, and a `COST` table whose
prices carry the date they were read.

**Keep the eval set.** It is the deliverable that makes the next review comparable —
the numbers only mean something against the same questions.

---

## Run `/connect-review`

The one that needs the most from you, because a contact-center solution is spread
across five places.

1. From the repo:

   ```
   /connect-review
   ```

2. It looks for five inputs — contact flows, the Lex V2 bot, the Lambda handlers,
   the prompts, and the session schema — by content rather than by file name: flow
   exports are found by `"Version": "2019-10-30"` plus `"Actions"`, bots by the
   `aws_lexv2models_*` resources or an unpacked export tree. Anything it cannot find,
   it asks you for by path or resource id.

3. With a working CLI it fills the gaps with read-only Connect, Lex and Lambda calls,
   and records the region. The region matters: DSGVO notes on transcript retention,
   log obfuscation, model region and session TTL are added for `eu-*` and for nothing
   else.

**Where the output goes:** printed. Ask for a file and it writes
`docs/connect-review-<YYYY-MM-DD>.md`.

**You know it worked when** the report opens with a one-paragraph solution summary
(entry number → flow → bot → Lambda → model → back), then a severity-ranked findings
table, a latency budget table where each row says measured or estimated, a cost per
contact with its assumptions in brackets, three call scenarios to test next, and a
`Not checked` section.

**On the latency table:** the Lambda handler row already contains the model call.
Nothing adds a separately estimated model time on top of a measured handler duration.

---

## Troubleshooting

**`/aws-cost` stops with a setup note.** The credential check failed. It names the
profile it tried and the error, and gives the two fixes. It will not try other
profiles on its own.

**A whole section comes back `N-A`.** The call was denied or failed. Read the error
text printed with it — that is the finding. An empty result from a failed call is
never reported as nothing to see.

**"No anomaly monitor configured", "Compute Optimizer not enrolled", "no
cost-allocation tags active".** These are findings, not failures. `/aws-cost` reports
each one and carries on with the fallback path.

**A report says the call-site inventory is partial.** `/bedrock-guardrails` caps its
grep output on a large repo and then refuses to hand out a PASS on anything
downstream of it. Narrow the run to a subdirectory, or point it at the wrapper module
that hides the calls from the default patterns.

**`/kb-review` scores 0.00 across the board.** Most often a tenant filter applied to
documents that carry no such metadata key — filtering on a key that does not exist
returns nothing for every question. The skill drops the filter for questions with no
`tenant` field for exactly this reason; if you edited the eval set by hand, check
that first.

**Nothing is written to your account.** If a report ever reads as though something
was changed, it is a wording bug — say so. The rule is in each skill's
`## Important Rules` section.

---

## Related

- [`docs/skills.md`](skills.md) — what each skill covers, and its triggers
- [`docs/external-tools.md`](external-tools.md#aws-cli) — the `aws` CLI dependency,
  stated in full
- [`docs/llm-checks-first-run.md`](llm-checks-first-run.md) — the repo-side
  companions: `/ai-cost-guard`, `/agent-eval`, `/mcp-review`
- [`docs/internals.md`](internals.md) — what lives under `~/.vibestack/projects/<slug>/`
