---
name: kb-review
description: |
  Read-only review of a retrieval-augmented setup, Amazon Bedrock Knowledge Bases first and hand-built RAG pipelines second: sources, chunking, metadata and tenant filtering, embedding model, vector store, sync, retrieval quality and cost per query. Builds a golden question set, measures recall@5 and MRR against the live knowledge base, and leaves the eval set behind as JSONL. Use when someone asks whether the knowledge base is set up right, why answers miss the right document, or what a RAG pipeline costs to run.
triggers:
  - knowledge base review
  - rag review
  - bedrock knowledge base
  - chunking strategy
  - retrieval quality
  - recall at k
  - vector store review
allowed-tools:
  - Bash
  - Read
  - Grep
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "knowledge base review", "rag review", "bedrock knowledge base", "chunking strategy", "retrieval quality", "recall at k", "vector store review", "why does the bot not find the document".

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
When the user types `/kb-review`, run this skill.

---

## Step 1: Inventory

Find out what the knowledge base is made of before judging any of it. Two places to
look: infrastructure code in the repo, and the live account.

**Repo first.** Grep for the Terraform resources and for the SDK calls a hand-built
pipeline would use:

```bash
grep -rnE 'aws_bedrockagent_(knowledge_base|data_source)|aws_opensearchserverless_collection|pgvector|s3_vectors|S3_VECTORS' --include='*.tf' --include='*.py' --include='*.ts' --include='*.yaml' --include='*.yml' . 2>/dev/null | head -40
grep -rnE 'RecursiveCharacterTextSplitter|SentenceSplitter|chunk_size|chunk_overlap|embed_documents|Pinecone|Qdrant|Weaviate|pgvector' --include='*.py' --include='*.ts' . 2>/dev/null | head -40
```

If the first grep hits, this is a Bedrock Knowledge Base and the Terraform is the
source of truth for configuration. If only the second hits, it is a hand-built
pipeline: read the ingestion and query code and map each of the following steps
onto it. If neither hits, ask where the knowledge base lives.

**Live account, when the CLI works.** Check credentials once and stop with a setup
note if they fail (profile tried, error text, `aws configure` or `aws sso login`).
Then list what exists:

```bash
aws sts get-caller-identity --output json
aws bedrock-agent list-knowledge-bases --output json
aws bedrock-agent get-knowledge-base --knowledge-base-id <kb-id> --output json
aws bedrock-agent list-data-sources --knowledge-base-id <kb-id> --output json
aws bedrock-agent get-data-source --knowledge-base-id <kb-id> --data-source-id <data-source-id> --output json
```

Every angle-bracket value in this skill — `<kb-id>`, `<data-source-id>`, `<bucket>`,
`<prefix>` and the rest — is substituted by hand from the output of the preceding
command before the line is run. They are placeholders, not shell variables.

From these, fill in the KB summary table: knowledge base id and name; vector store
type from `storageConfiguration.type` (OpenSearch Serverless, Aurora with pgvector,
S3 Vectors, Pinecone, or another); embedding model ARN and dimensions from
`knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration`; and per data source
its type (S3, Confluence, SharePoint, web crawler, custom), location, chunking
configuration, parsing configuration and `dataDeletionPolicy`.

**Sources.** For every S3 data source, size it without downloading it:

```bash
aws s3 ls s3://<bucket>/<prefix> --recursive --summarize | tail -2
aws s3 ls s3://<bucket>/<prefix> --recursive | awk '{print $4}' | sed -E 's/.*\.([A-Za-z0-9]+)$/\1/' | sort | uniq -c | sort -rn
```

Record object count, total size, and the format mix (PDF, DOCX, HTML, Markdown, CSV,
JSON). Note the update cadence from the newest and oldest `LastModified` values and
from whatever writes to the prefix (a pipeline, a person, a Confluence export). For
Confluence and web sources, record the space keys or seed URLs and the crawl scope.

Findings at this step: **INFO** for every data source, **MEDIUM** if a data source
points at a bucket prefix that also holds unrelated files (logs, exports, backups)
that will be embedded along with the documents.

---

## Step 2: Chunking

Read `vectorIngestionConfiguration.chunkingConfiguration` from each data source (or
the splitter call in a hand-built pipeline) and compare it against the shape of the
documents. Sample three to five documents per format into the scratchpad with
`aws s3 cp`; look at them, do not paste them into the report.

Check:

- **Strategy versus document shape.** Fixed-size chunks suit short, flat documents. Hierarchical chunking (parent and child levels) suits long manuals and policies where a paragraph only makes sense with its section heading. Semantic chunking suits prose with topic shifts. `NONE` means each document is one chunk, which only works for documents already under the embedding model's token limit. **HIGH** if strategy is `NONE` and any sampled document exceeds that limit: those documents are silently truncated at ingestion.
- **Chunk size and overlap.** Read `maxTokens` and `overlapPercentage` (fixed) or the level `maxTokens` and `overlapTokens` (hierarchical). **MEDIUM** if chunks are under 200 tokens on documents with long paragraphs (answers get split across chunks) or over 1000 tokens on FAQ-style content (one chunk carries several unrelated questions). **LOW** if overlap is 0 on fixed-size chunking.
- **Tables and code.** Open a sampled PDF or DOCX that contains a table and find the corresponding chunk text with a `retrieve` call for a value from the table. **MEDIUM** if table rows come back as a run of numbers with no header context and no parsing configuration is set (`parsingConfiguration` with a foundation model or Bedrock Data Automation keeps table structure). Same check for code blocks in Markdown.
- **Metadata files.** Each document may carry a sidecar `<name>.metadata.json` with a `metadataAttributes` object. Count them: `aws s3 ls s3://<bucket>/<prefix> --recursive | grep -c '\.metadata\.json$'`. Compare with the document count. **MEDIUM** if fewer than 90% of documents have one and Step 3 relies on filtering.

---

## Step 3: Metadata and isolation

This is the step that decides whether one customer can read another customer's
documents. Treat every gap here as at least **HIGH**.

- **What is in the metadata.** Read three sampled `.metadata.json` files. The attributes that matter are tenant (or customer, account), department, and classification (public, internal, confidential). Record which exist and whether values are consistent (`tenant` versus `tenantId` versus `customer` across files is a finding).
- **Filter applied on every retrieve.** Find every call site of `retrieve`, `retrieve_and_generate`, `RetrieveCommand`, or the agent's knowledge base configuration, and check that `retrievalConfiguration.vectorSearchConfiguration.filter` is set from the caller's identity, not from a request parameter the caller controls. `grep -rnE 'retrieve(_and_generate|AndGenerate)?\(|RetrieveCommand|RetrieveAndGenerateCommand' --include='*.py' --include='*.ts' --include='*.js' .` **CRITICAL** if any call site queries the knowledge base with no filter while the knowledge base holds more than one tenant. **HIGH** if the filter value comes from the request body or a query parameter.
- **Prove the leakage path is closed.** Run one retrieve with a filter for tenant A and a question that only tenant B's documents answer:

```bash
aws bedrock-agent-runtime retrieve --knowledge-base-id <kb-id> \
  --retrieval-query "$(jq -nc --arg text '<question only tenant B can answer>' '{text:$text}')" \
  --retrieval-configuration '{"vectorSearchConfiguration":{"numberOfResults":5,"filter":{"equals":{"key":"tenant","value":"tenant-a"}}}}' \
  --output json | grep -E '"uri"|"score"'
```

Pass the query as JSON, not as the `text=...` shorthand: the shorthand parser splits
on commas, so any question containing one is read as a list and the call fails with
`Invalid type for parameter retrievalQuery.text`. That kills German questions in
particular. Without `jq`, write the object out by hand:
`--retrieval-query '{"text":"Wie lange ist die Frist, wenn ich kuendige?"}'`.

Every returned `uri` must belong to tenant A. A tenant B document in the result is **CRITICAL**, and the fix is at ingestion (missing or wrong metadata), not in the query.

- **Source access control mirrored.** If the S3 bucket, Confluence space, or SharePoint site restricts who can read what, that restriction has to be reproduced as metadata plus a filter, because the knowledge base reads everything with its service role. **HIGH** if a restricted source feeds the knowledge base and no metadata carries the restriction.

---

## Step 4: Embeddings

- **Model and dimension.** From Step 1, record the embedding model id (for example `amazon.titan-embed-text-v2:0` or `cohere.embed-multilingual-v3`) and the configured dimensions. Confirm the vector index in the store was created with the same dimension: for OpenSearch Serverless read the index mapping, for pgvector read the column type (`vector(1024)`). A mismatch fails at ingestion and shows up as every job failing; **HIGH**.
- **Language coverage.** Ask which languages the documents and the users are in. The usual case is German plus English. **HIGH** if the corpus or the questions include German and the model is English-only (`cohere.embed-english-v3`). Titan Text Embeddings v2 and Cohere Embed Multilingual cover both. Verify with the golden set in Step 6: include at least five German questions against English passages and five the other way round, and report their recall separately.
- **Re-embedding plan.** An embedding model cannot be changed on an existing Bedrock knowledge base; a model change means a new knowledge base, a full ingestion, and a cutover. **MEDIUM** if nothing in the repo or runbooks describes how that is done, and note the full ingestion cost from Step 7 next to the finding.

---

## Step 5: Sync

The knowledge base only knows what the last ingestion job saw.

```bash
aws bedrock-agent list-ingestion-jobs --knowledge-base-id <kb-id> --data-source-id <data-source-id> --max-results 20 --output json
```

For each data source, record the last job's status, start time, and its
`statistics` (documents scanned, new, modified, deleted, failed) plus
`failureReasons` when present. Then check:

- **Schedule.** Find what starts the job: an EventBridge rule, a Step Functions state machine, a CI step, or a person. `grep -rnE 'start_ingestion_job|StartIngestionJob|start-ingestion-job' .` and `aws events list-rules --output json | grep -i ingest`. **MEDIUM** if the only trigger is manual and the source changes weekly or faster. **HIGH** if the last successful job is older than two update cycles of the source.
- **Failure alerts.** **MEDIUM** if a job can fail with nobody told; look for a CloudWatch alarm or a notification on the job status. `numberOfDocumentsFailed` above zero on the last job with no alert is the same finding.
- **Deletions propagate.** `dataDeletionPolicy` on the data source: `DELETE` removes vectors when a document leaves the source, `RETAIN` keeps them. **HIGH** if `RETAIN` is set and documents are ever removed for legal or contractual reasons; the knowledge base will keep answering from them.
- **Source versioning.** **LOW** if the S3 bucket has versioning off and nobody can say what the knowledge base was built from a month ago. **INFO** if it is on.

For a hand-built pipeline, the same four questions apply to whatever loop upserts
into the vector store.

---

## Step 6: Retrieval quality

Numbers, not opinions. Build a golden set, run retrieve-only against it, then check a
sample of generated answers.

**Golden set.** Write 20 to 40 question and expected-passage pairs. Draw questions
from the sampled documents in Step 2, from support tickets or chat logs if the user
can share them, and from the user directly. Each line names the source document that
answers it and a short quote of the passage. Include the language split from Step 4
and at least three questions that the corpus does not answer (the right result is
nothing above the score threshold). Write it here:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$EVAL_DIR"
EVAL_SET="$EVAL_DIR/kb-eval-$(date +%Y-%m-%d).jsonl"
echo "EVAL_SET: $EVAL_SET"
```

One JSON object per line:

```json
{"id":"q01","question":"Wie lange ist die Kündigungsfrist?","lang":"de","tenant":"tenant-a","expected_uri":"s3://docs/tenant-a/contract-terms.pdf","expected_passage":"Die Kündigungsfrist beträgt drei Monate zum Quartalsende.","answerable":true}
```

The `tenant` field belongs there only when Step 3 found a tenant attribute in the
document metadata. On a knowledge base with no such attribute, leave it out — every
line then carries the same fields minus `tenant`.

**Retrieve-only run.** For every line, call `retrieve` with `numberOfResults` 5,
filtered by tenant when the line has one, and record the ranked list of `uri` values
and scores. The filter clause is dropped for a line with no `tenant` field: filtering
on a metadata key the documents do not carry returns nothing for every question, which
scores recall@5 at 0.00 and manufactures a HIGH finding against a knowledge base that
is fine. With `jq` present the loop is this, with `<kb-id>` substituted before it runs
(it re-derives the eval-set path, since each block runs in its own shell):

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
EVAL_SET="$EVAL_DIR/kb-eval-$(date +%Y-%m-%d).jsonl"
RESULTS="$EVAL_DIR/kb-eval-results-$(date +%Y-%m-%d).jsonl"
: > "$RESULTS"
while IFS= read -r line; do
  q=$(printf '%s' "$line" | jq -r .question)
  t=$(printf '%s' "$line" | jq -r '.tenant // empty')
  if [ -n "$t" ]; then
    cfg=$(jq -nc --arg t "$t" '{vectorSearchConfiguration:{numberOfResults:5,filter:{equals:{key:"tenant",value:$t}}}}')
  else
    cfg='{"vectorSearchConfiguration":{"numberOfResults":5}}'
  fi
  aws bedrock-agent-runtime retrieve --knowledge-base-id <kb-id> \
    --retrieval-query "$(jq -nc --arg text "$q" '{text:$text}')" \
    --retrieval-configuration "$cfg" \
    --output json \
  | jq -c --argjson g "$line" '{id:$g.id, expected:$g.expected_uri, hits:[.retrievalResults[] | {uri:(.location.s3Location.uri // .location.webLocation.url // .location.confluenceLocation.url), score:.score}]}' >> "$RESULTS"
done < "$EVAL_SET"
```

Same reason for the query object as in Step 3: `text=$q` is shorthand and splits on
the first comma, so a question with a comma in it fails the call and silently drops
that line from the score.

Without `jq`, run the calls one at a time and record the ranks by hand; the set is
small enough.

**Metrics.** For the answerable questions: recall@5 is the share whose
`expected_uri` appears anywhere in the five hits; MRR is the mean of 1/rank of the
first hit (0 when absent). For the unanswerable questions, report how many returned a
top score above the threshold the application uses (a false positive). Report each
metric for the whole set and per language. Findings: **HIGH** if recall@5 is under
0.7, **MEDIUM** under 0.85, **LOW** if MRR is under 0.5 while recall@5 is fine (the
right chunk is there but ranked low; a reranker or smaller chunks are the usual fix).
**MEDIUM** if a language subset trails the other by more than 0.15.

**Generation and faithfulness.** Pick 10 answerable questions and run
`aws bedrock-agent-runtime retrieve-and-generate` (or the application's own answer
endpoint) with citations on. For each answer check two things by reading the cited
passages: every factual claim in the answer appears in a cited passage, and the
citation points at the expected document. Score each answer `faithful`, `partly`
(a claim with no support), or `wrong`. **HIGH** if two or more of ten are `wrong`.
Record the model id and the prompt template used, since both move the result.

These calls cost tokens. Say the count before running (40 retrieves plus 10
generations is the default) and do not loop beyond the golden set.

---

## Step 7: Cost

Four line items make up the bill. Pull current unit prices from the billing MCP
pricing tool when the session has it, otherwise from the public pricing page for
each service, and write the date the price was read next to it.

1. **Vector store.** OpenSearch Serverless bills OCU-hours with a floor (two OCUs for a collection with redundancy off, four with it on) plus GB-month of index storage; the floor dominates for small corpora. Aurora Serverless v2 bills ACU-hours plus storage. S3 Vectors bills storage plus per-query and per-put requests. Take the actual monthly figure from Cost Explorer when the account allows it: `aws ce get-cost-and-usage --time-period Start=<first of last month>,End=<first of this month> --granularity MONTHLY --metrics UnblendedCost --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon OpenSearch Service"]}}'`, adjusting the service name to the store in use.
2. **Embedding tokens at ingestion.** Total corpus tokens (roughly total bytes of extracted text divided by 4, times 1 plus the overlap fraction) times the embedding price per 1000 tokens. This is the cost of one full sync and of any re-embedding.
3. **Embedding tokens per query.** One query embedding per retrieve; small but nonzero.
4. **Generation tokens per query.** Prompt tokens are the template plus the five chunks (chunk `maxTokens` times 5) plus the question; output tokens from the Step 6 answers. Multiply by the model's input and output prices.

Report a per-1000-queries figure: fixed monthly cost of the store divided by the
observed or expected monthly query volume, plus items 3 and 4. Findings: **MEDIUM** if
the store's idle floor is more than half of the monthly bill at the current query
volume (S3 Vectors or pgvector on an existing database would cost less); **LOW** if
prompt tokens per query are over 4000 because of large chunks times `numberOfResults`.

---

## Output

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$EVAL_DIR"
REPORT="$EVAL_DIR/kb-review-$(date +%Y-%m-%d).md"
echo "REPORT: $REPORT"
```

Write the report to `$REPORT` (overwrite today's if it exists) and print it in full.

```
KNOWLEDGE BASE REVIEW
=====================

Account:   <alias or last 4 digits> (profile: <name>)     Region: <region>
Date:      2026-08-14
Mode:      Bedrock Knowledge Base | hand-built pipeline

KB SUMMARY
Field              Value
-----------------  ----------------------------------------------
Knowledge base     kb-docs-prod (ABCD1234)
Vector store       OpenSearch Serverless, 2 OCU floor, 1024-dim index
Embedding model    amazon.titan-embed-text-v2:0, 1024 dims
Data sources       s3://docs/tenant-*/ (1,240 PDF, 380 DOCX, 4.1 GB), confluence ENG space
Chunking           hierarchical, parent 1500 / child 300 tokens, overlap 60
Parsing            none (default text extraction)
Metadata           tenant, classification on 1,580 of 1,620 documents
Deletion policy    RETAIN
Last sync          2026-08-12 03:10 UTC, 0 failed, EventBridge nightly
Languages          de 70% / en 30%

FINDINGS
#  Severity  Area        Evidence                                              Fix
-  --------  ----------  ----------------------------------------------------  --------------------------------------------
1  CRITICAL  isolation   api/search.py:88 retrieve() has no filter             derive filter from the session tenant
2  HIGH      sync        dataDeletionPolicy RETAIN; legal deletes monthly      set DELETE, re-run sync, verify vector count
3  MEDIUM    chunking    table values in pricing.pdf split across 3 chunks     parsingConfiguration with a foundation model
4  MEDIUM    metadata    40 documents without .metadata.json                   generate sidecars in the export job
5  LOW       cost        OCU floor is 68% of monthly spend at 9k queries       evaluate S3 Vectors for this volume

RETRIEVAL METRICS (golden set: 32 questions, 5 unanswerable)
Subset      n    recall@5   MRR    false positives
----------  ---  --------   ----   ---------------
all         27   0.81       0.62   1 of 5
de          19   0.79       0.58   -
en           8   0.88       0.71   -
Faithfulness (10 answers, <model id>): 7 faithful, 2 partly, 1 wrong

COST (prices read 2026-08-14)
Item                          Monthly      Per 1,000 queries
----------------------------  ----------   -----------------
Vector store (2 OCU + 6 GB)   $351.00      $39.00
Full re-embed (one-off)       $18.40       -
Query embeddings              $0.20        $0.02
Generation (<model id>)       $61.00       $6.80
Total at 9,000 queries/month  $412.20      $45.82

Eval set:    ~/.vibestack/projects/<slug>/kb-eval-2026-08-14.jsonl
Results:     ~/.vibestack/projects/<slug>/kb-eval-results-2026-08-14.jsonl
Report:      ~/.vibestack/projects/<slug>/kb-review-2026-08-14.md
```

Severity labels: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `INFO`. Every finding names a
file, a resource id, or a command output as evidence.

---

## Important Rules

1. **Read-only against AWS.** This skill calls get, list, describe, retrieve and retrieve-and-generate. It never starts an ingestion job, never creates, updates or deletes a knowledge base or data source, never writes to S3, and never changes a vector index. The fixes in the findings are for the user to apply.
2. **Never start a sync.** Even when the last job is stale. Report it; a sync costs embedding tokens and can surface documents the user did not mean to publish yet.
3. **Sample, do not dump.** Copy at most five documents per format into the scratchpad, read them there, and quote at most one sentence per finding. Document contents never go into the report or into learnings.
4. **The eval set is the deliverable.** Write it before scoring anything, keep it in the project directory under `~/.vibestack`, and print its path. The next review reuses it so the numbers are comparable.
5. **Say what the runtime calls cost.** Retrieve and generate calls are billed. State the count before running the golden set and stay within it.
6. **Isolation findings are never downgraded.** A missing tenant filter is CRITICAL regardless of how few tenants exist today.
7. **Prices carry a date.** Unit prices change; every cost figure names the day the price was read and the volume it assumes.
8. **No account ids or document text in learnings.** Refer to the account by alias or slug and to documents by their role, never by content.

{{include lib/snippets/capture-learnings.md}}
