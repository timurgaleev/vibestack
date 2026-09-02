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

**Read the knowledge base type first.** `knowledgeBaseConfiguration.type` is one of
`VECTOR`, `MANAGED`, `KENDRA` or `SQL`, and it decides which fields exist and which
retrieval request shape is valid in Steps 3 and 6:

- `VECTOR` — a knowledge base backed by a vector store you own. Embedding model ARN
  and dimensions come from `knowledgeBaseConfiguration.vectorKnowledgeBaseConfiguration`;
  the store comes from `storageConfiguration.type` (OpenSearch Serverless, Aurora
  with pgvector, S3 Vectors, Pinecone, or another). Query with
  `retrievalConfiguration.vectorSearchConfiguration`.
- `MANAGED` — Amazon Bedrock owns the vector store. Read
  `knowledgeBaseConfiguration.managedKnowledgeBaseConfiguration`: `embeddingModelType`
  is `MANAGED` (service-chosen model) or `CUSTOM` (with `embeddingModelArn`).
  `storageConfiguration` is optional on the KnowledgeBase object and is absent here —
  record the store as service-managed rather than reporting a missing field. Query
  with `retrievalConfiguration.managedSearchConfiguration`.
- `KENDRA` — an Amazon Kendra GenAI index holds the content, so there is no chunking,
  embedding or vector-store configuration to review. Query it with `Retrieve` as you
  would a standard knowledge base, `vectorSearchConfiguration` and all; the Kendra
  fields come back as metadata attributes and metadata filtering works on them. Say so,
  skip Steps 2, 4 and 7's store item, and run Steps 3, 5 and 6 unchanged.
- `SQL` — a structured data store answers by generated SQL, not by embeddings, so there
  is nothing chunked, embedded or stored as vectors to review. `Retrieve` returns the
  rows the generated query produced, and none of `retrievalConfiguration` applies:
  `numberOfResults`, search type, metadata filtering and reranking are all documented as
  applying to unstructured data sources only. Send the query on its own, with no
  `--retrieval-configuration` at all. Skip Steps 2, 4 and 7's store item. Step 3 keeps
  its question but changes its evidence — there is no metadata filter to check, so read
  the query engine's table and column inclusions and exclusions and the database grants
  on the role the knowledge base queries with. Steps 5 and 6 run with the row-based
  reading noted in each.

Sending a `vectorSearchConfiguration` to a managed knowledge base, or a
`managedSearchConfiguration` to a `VECTOR` one, is an invalid request — a failed call
there is a mistake in this review, not a finding about the knowledge base. So is sending
either one to a `SQL` knowledge base. Set the key once and reuse it:

```bash
SEARCH_KEY=vectorSearchConfiguration    # managedSearchConfiguration on a MANAGED KB
                                        # SQL: send no retrieval configuration at all
```

Then fill in the KB summary table: knowledge base id, name and type; the store and
embedding model from whichever branch above applies; and per data source its type
(S3, Confluence, SharePoint, OneDrive, Google Drive, Salesforce, Box, web crawler,
custom — record whatever `dataSourceConfiguration.type` reports, the connector set
grows), location, chunking configuration, parsing configuration and
`dataDeletionPolicy`.

**Sources.** For every S3 data source, size it without downloading it:

```bash
aws s3 ls s3://<bucket>/<prefix> --recursive --summarize | tail -2
aws s3 ls s3://<bucket>/<prefix> --recursive | awk '{print $4}' | sed -E 's/.*\.([A-Za-z0-9]+)$/\1/' | sort | uniq -c | sort -rn
```

Record object count, total size, and the format mix (PDF, DOCX, HTML, Markdown, CSV,
JSON). Count the image objects (`.jpeg`, `.png`) on their own line: Step 7 prices a
configured parser per page and per image, and neither number falls out of the object
count. When any data source sets a `parsingConfiguration`, carry a page estimate into
Step 7 as well — read the page count of each PDF sampled in Step 2 (`pdfinfo`, or
`mdls -name kMDItemNumberOfPages` on macOS), take the mean, multiply by the PDF object
count, and record the sample size beside it so the number is read as the estimate it
is. Note the update cadence from the newest and oldest `LastModified` values and
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

- **Strategy versus document shape.** Fixed-size chunks suit short, flat documents. Hierarchical chunking (parent and child levels) suits long manuals and policies where a paragraph only makes sense with its section heading. Semantic chunking suits prose with topic shifts. `NONE` means each document is treated as a single source chunk; the service applies its own chunk handling from there, and a document that violates a limit surfaces in the ingestion job, not as a quiet truncation. Do not infer truncation from the embedding model's input limit — check it. Read `numberOfDocumentsFailed` and `failureReasons` on the last job (Step 5), then run one retrieve for a phrase that appears only near the end of the largest sampled document and read `content.text` on the results. **HIGH** if documents failed ingestion, or if that tail phrase is in no returned chunk while the same document answers other questions. **MEDIUM** if the strategy is `NONE` on long documents and neither check could be run — the risk is real, the evidence is not there yet. Note also that `NONE` gives up page-number citations and the `x-amz-bedrock-kb-document-page-number` filter attribute.
- **Chunk size and overlap.** Read `maxTokens` and `overlapPercentage` (fixed) or the level `maxTokens` and `overlapTokens` (hierarchical). **MEDIUM** if chunks are under 200 tokens on documents with long paragraphs (answers get split across chunks) or over 1000 tokens on FAQ-style content (one chunk carries several unrelated questions). **LOW** if overlap is 0 on fixed-size chunking.
- **Tables and code.** Open a sampled PDF or DOCX that contains a table and find the corresponding chunk text with a `retrieve` call for a value from the table. **MEDIUM** if table rows come back as a run of numbers with no header context and no parsing configuration is set (`parsingConfiguration` with a foundation model or Bedrock Data Automation keeps table structure). Same check for code blocks in Markdown.
- **Metadata files.** Each document may carry a sidecar `<name>.metadata.json` with a `metadataAttributes` object. Count them: `aws s3 ls s3://<bucket>/<prefix> --recursive | grep -c '\.metadata\.json$'`. Compare with the document count. **MEDIUM** if fewer than 90% of documents have one and Step 3 relies on filtering.

---

## Step 3: Metadata and isolation

This is the step that decides whether one customer can read another customer's
documents. Treat every gap here as at least **HIGH**.

- **What is in the metadata.** Read three sampled `.metadata.json` files. The attributes that matter are tenant (or customer, account), department, and classification (public, internal, confidential). Record which exist and whether values are consistent (`tenant` versus `tenantId` versus `customer` across files is a finding).
- **Which mechanism is in play.** Two are supported and they are checked differently, so decide before judging anything. *Metadata filtering*: documents carry a tenant attribute and every query passes a `filter`. *ACL awareness*, on a managed knowledge base: the connector crawls document permissions (allowed and denied users and groups) at ingestion, and the query passes a `userContext` naming the user, and the crawled permissions filter the candidates before retrieval. Some connectors add a second stage, a live call to the source per query that catches permission changes made since the last sync. Which ones do is a per-connector property and the connector set grows, so read it from that connector's own ACL page rather than from a list held in your head. Today: SharePoint, OneDrive, Google Drive, Confluence and Box document both stages; S3 and custom document pre-retrieval filtering only, because their ACLs come from a file the customer writes and there is nothing live to re-check; the web crawler supports no ACLs at all. For any connector you have not checked, record its real-time support as unknown and go read the page before a severity leans on it. Read each data source's configuration for ACL awareness, and read the call sites for which of `filter` and `userContext` they send. A knowledge base may use one, both, or neither. An ACL-enabled data source returning nothing when `userContext` is absent is documented behaviour, not a retrieval bug; non-ACL data sources in the same knowledge base still return to everyone.
- **Filter applied on every retrieve.** Find every call site of `retrieve`, `retrieve_and_generate`, `RetrieveCommand`, or the agent's knowledge base configuration: `grep -rnE 'retrieve(_and_generate|AndGenerate)?\(|RetrieveCommand|RetrieveAndGenerateCommand' --include='*.py' --include='*.ts' --include='*.js' .` On a metadata-filtered knowledge base, check that `retrievalConfiguration.$SEARCH_KEY.filter` is set from the caller's authenticated session, not from a request parameter the caller controls. **CRITICAL** if a call site queries a multi-tenant knowledge base with neither a filter nor a user context. **HIGH** if the filter value comes from the request body, a header or a query parameter.
- **User context derived from a verified identity.** On an ACL-aware knowledge base the same question applies to `userContext.userId`. The service does not authenticate end users and cannot verify the identity it is handed — it filters on whatever you send — so that email must come from the verified session (the token subject or an ID-token claim). **CRITICAL** if `userId` is caller-supplied: one edited request reads another tenant's documents. **HIGH** if the address passed is not the one the connected source knows the user by; matching is on the email with no alias resolution, so a mismatch returns nothing and invites someone to "fix" it by dropping the context. **MEDIUM** if group membership is the only thing standing between tenants *and* the connector behind that data source has no real-time check — memberships are resolved from the last crawl, so a removal takes effect only at the next sync. On a connector that re-verifies per query the live check corrects that at query time: record it **INFO**. If which of the two the connector is was never established, say the real-time support is unknown and leave the severity off rather than guessing at one.
- **Prove the leakage path is closed.** Run one retrieve as tenant A with a question only tenant B's documents answer. Substitute `<kb-id>` and use the branch that matches the mechanism:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$EVAL_DIR"
OUT="$EVAL_DIR/kb-isolation-$(date +%Y-%m-%d).json"
SEARCH_KEY=vectorSearchConfiguration    # managedSearchConfiguration on a MANAGED KB
CFG=$(jq -nc --arg k "$SEARCH_KEY" '{($k):{numberOfResults:5,filter:{equals:{key:"tenant",value:"tenant-a"}}}}')
ERR=$(aws bedrock-agent-runtime retrieve --knowledge-base-id <kb-id> \
  --retrieval-query "$(jq -nc --arg text '<question only tenant B can answer>' '{text:$text}')" \
  --retrieval-configuration "$CFG" \
  --output json 2>&1 > "$OUT")
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ISOLATION: N-A (exit %s)\n%s\n' "$rc" "$ERR"
else
  jq -r '.retrievalResults[] | [(.location.type // "?"), (.documentId // "-"), (.score|tostring)] | @tsv' "$OUT"
  printf 'ISOLATION: %s result(s)\n' "$(jq '.retrievalResults | length' "$OUT")"
fi
```

On an ACL-aware knowledge base, drop the `filter` from `CFG` and add
`--user-context '{"userId":"user-a@example.com"}'` with an address that belongs to
tenant A.

On a `SQL` knowledge base there is no filter and no user context to send: drop
`--retrieval-configuration` and the `CFG` line with it, run the probe as the caller the
application would use for tenant A, and read whether the returned rows belong to tenant
A. What holds tenants apart there is the query engine's table and column inclusions and
exclusions plus the grants on the database role, so review those alongside the probe —
a generated query that can reach another tenant's rows is **CRITICAL** on the same
terms as a missing filter.

Pass the query as JSON, not as the `text=...` shorthand: the shorthand parser splits
on commas, so any question containing one is read as a list and the call fails with
`Invalid type for parameter retrievalQuery.text`. That kills German questions in
particular. Without `jq`, write the object out by hand:
`--retrieval-query '{"text":"Wie lange ist die Frist, wenn ich kuendige?"}'`.

Read the exit status before the results. An empty list is a pass only when `rc` is 0;
a denied `bedrock:Retrieve`, a throttle and a genuinely empty result all print
nothing, and only the status tells them apart, so report N-A on a non-zero exit
rather than a clean bill. On a zero exit, every returned document must belong to
tenant A. A tenant B document is **CRITICAL**, and the fix is at ingestion (missing or
wrong metadata, or permissions the connector did not crawl), not in the query.

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
filtered by tenant when the line has one, and record the ranked hits: the document
the hit came from, its `documentId`, its `content.type`, its `content.text`, its
`content.row` and its score. Keep the text — the metrics below cannot be computed
without it — and keep the row with it: a structured result carries its payload in
`content.row`, an array of `columnName`, `columnValue` and `type`, with `content.type`
set to `ROW` and `content.text` empty. `documentId` identifies the
document, not the chunk, and a retrieval result carries no per-chunk identifier, so
the passage judgement below is made from the text and nothing else can stand in for
it. The filter clause is dropped for a
line with no `tenant` field: filtering on a metadata key the documents do not carry
returns nothing for every question, which scores 0.00 and manufactures a HIGH finding
against a knowledge base that is fine.

Result locations come in ten shapes, one per source type, and only one is populated
per hit; `location` can also be absent. Reading three of them and calling the rest
null turns every Salesforce, SharePoint, OneDrive, Google Drive, Kendra, custom or
structured hit into a miss. Normalise all of them, and fall back to `documentId`.

With `jq` present the loop is this, with `<kb-id>` substituted before it runs (it
re-derives the eval-set path, since each block runs in its own shell):

```bash
set -o pipefail
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
EVAL_SET="$EVAL_DIR/kb-eval-$(date +%Y-%m-%d).jsonl"
RESULTS="$EVAL_DIR/kb-eval-results-$(date +%Y-%m-%d).jsonl"
SEARCH_KEY=vectorSearchConfiguration    # managedSearchConfiguration on a MANAGED KB
: > "$RESULTS"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | jq -r .id)
  q=$(printf '%s' "$line" | jq -r .question)
  t=$(printf '%s' "$line" | jq -r '.tenant // empty')
  if [ -n "$t" ]; then
    cfg=$(jq -nc --arg k "$SEARCH_KEY" --arg t "$t" '{($k):{numberOfResults:5,filter:{equals:{key:"tenant",value:$t}}}}')
  else
    cfg=$(jq -nc --arg k "$SEARCH_KEY" '{($k):{numberOfResults:5}}')
  fi
  raw=$(aws bedrock-agent-runtime retrieve --knowledge-base-id <kb-id> \
    --retrieval-query "$(jq -nc --arg text "$q" '{text:$text}')" \
    --retrieval-configuration "$cfg" \
    --output json 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    jq -nc --arg id "$id" --argjson rc "$rc" --arg err "$raw" \
      '{id:$id, status:"error", exit:$rc, error:$err, hits:[]}' >> "$RESULTS"
    continue
  fi
  printf '%s' "$raw" | jq -c --argjson g "$line" '
    {id:$g.id, status:"ok", expected:$g.expected_uri,
     hits:[.retrievalResults[] | {
       doc: (.location.s3Location.uri // .location.webLocation.url
             // .location.confluenceLocation.url // .location.salesforceLocation.url
             // .location.sharePointLocation.url // .location.oneDriveLocation.url
             // .location.googleDriveLocation.url // .location.kendraDocumentLocation.uri
             // .location.customDocumentLocation.id // .location.sqlLocation.query
             // .documentId // null),
       loc_type: (.location.type // "UNKNOWN"),
       doc_id: (.documentId // null),
       content_type: (.content.type // "UNKNOWN"),
       text: (.content.text // ""),
       row: (.content.row // []),
       score: .score}]}' >> "$RESULTS"
done < "$EVAL_SET"
```

Same reason for the query object as in Step 3: `text=$q` is shorthand and splits on
the first comma, so a question with a comma in it fails the call and silently drops
that line from the score.

On a `SQL` knowledge base drop `--retrieval-configuration` and both `cfg` branches —
the settings they carry apply to unstructured sources only — and judge each answer
against the expected value the golden line names rather than against a passage. The
judgement reads `row`, not `text` — `text` is empty on every structured hit, and the
returned value is the `columnValue` of the `row` entry whose `columnName` is the one
the golden line expects. There are no chunks to rank, so report the share of questions
answered with the right value and leave the passage and MRR columns blank.

**Check the denominator before scoring anything.** A throttle or a denied
`bedrock:Retrieve` costs one row, and a metric computed over the survivors reads
better than the truth:

This block runs in its own shell, so it re-derives the paths the same way Steps 3, 6
and 7 do. It exits non-zero on anything it cannot establish — an unwritable id file
prints an all-clear otherwise, which is the failure it exists to catch:

```bash
set -euo pipefail
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
EVAL_SET="$EVAL_DIR/kb-eval-$(date +%Y-%m-%d).jsonl"
RESULTS="$EVAL_DIR/kb-eval-results-$(date +%Y-%m-%d).jsonl"
ASKED="$EVAL_DIR/.ids-asked"
GOT="$EVAL_DIR/.ids-got"
for f in "$EVAL_SET" "$RESULTS"; do
  [ -s "$f" ] || { printf 'DENOMINATOR: N-A (missing or empty %s)\n' "$f"; exit 1; }
done
jq -r .id "$EVAL_SET" | sort > "$ASKED" || { printf 'DENOMINATOR: N-A (cannot write %s)\n' "$ASKED"; exit 1; }
jq -r .id "$RESULTS"  | sort > "$GOT"   || { printf 'DENOMINATOR: N-A (cannot write %s)\n' "$GOT"; exit 1; }
missing=$(comm -23 "$ASKED" "$GOT")
dupes=$(uniq -d < "$GOT")
errs=$(jq -r 'select(.status=="error") | .id' "$RESULTS" | tr '\n' ' ')
printf 'asked=%s got=%s\n' "$(wc -l < "$ASKED" | tr -d ' ')" "$(wc -l < "$GOT" | tr -d ' ')"
printf 'missing=[%s] duplicate=[%s] errors=[%s]\n' "$missing" "$dupes" "$errs"
[ -z "${missing}${dupes}${errs}" ] || { printf 'DENOMINATOR: FAIL — do not score this run\n'; exit 1; }
printf 'DENOMINATOR: OK\n'
```

A non-zero exit, or anything but `DENOMINATOR: OK` on the last line, stops the
scoring. Fix the cause and re-run the affected
questions — pause and retry on a throttle, get the permission for an authorization
error — or, if it cannot be fixed, report the metrics as N-A for that subset and
state how many questions were dropped and why. Do not score a partial set as if it
were whole.

Without `jq`, run the calls one at a time and record the ranks by hand; the set is
small enough.

**Metrics.** Two different measurements, and the difference decides what a number is
allowed to claim:

- **Document hit rate@5** — the share of answerable questions whose `expected_uri`
  matches the `doc` of any of the five hits. It says the right file came back. It
  says nothing about the passage: on a long manual, a chunk about an unrelated
  section scores exactly as a hit, so this number alone cannot support a claim about
  retrieval quality and cannot feed a rank-based metric.
- **Passage hit rate@5 and MRR** — read the `text` of the hits in rank order and mark
  the first one that actually answers the question. `expected_passage` is the
  reference; an equally correct passage elsewhere counts, a chunk from the right
  document that does not answer it does not. Passage hit rate@5 is the share with
  such a hit among the five; MRR is the mean of 1/rank of that hit, 0 when there is
  none. Record the rank you assigned per question alongside its row so the next
  review can see the judgement.

Report both, for the whole set and per language. If the passages were not judged,
print the document number under its own name, leave the passage and MRR columns
blank, and write "passage relevance not judged" under the table — do not carry the
document-level rank into the MRR column.

For the unanswerable questions, report how many returned a top score above the
threshold the application uses (a false positive).

Findings, all read off the passage numbers: **HIGH** if passage hit rate@5 is under
0.7, **MEDIUM** under 0.85, **LOW** if MRR is under 0.5 while passage hit rate@5 is
fine (the right chunk is there but ranked low; a reranker or smaller chunks are the
usual fix). **MEDIUM** if a language subset trails the other by more than 0.15. When
only the document number was measured, cap every one of these at **MEDIUM** and say
so — that evidence cannot tell a right passage from a wrong one in the right file.

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

The bill has more parts than the embeddings. Walk the list, mark the items this
knowledge base actually uses, and drop the rest with a line saying it is not
configured. Pull current unit prices from the billing MCP pricing tool when the
session has it, otherwise from the public pricing page for each service, and write
the date the price was read next to it.

1. **Vector store.** Read the live configuration; there is no fixed floor to assume.
   OpenSearch Serverless capacity is a minimum and a maximum OCU count for indexing
   and for search, set per collection group — or at account level for a Classic
   collection that belongs to no group. The minimum can be 0, in which case an idle
   group needs no OCUs at all, and collections inside a group share OCUs. So the idle
   cost is whatever the configured minimums are, divided across every collection
   sharing them, not two or four per collection. Read it and measure it:

   ```bash
   aws opensearchserverless batch-get-collection --names <collection-name> --output json
   aws opensearchserverless list-collection-groups --output json
   aws opensearchserverless batch-get-collection-group --ids <collection-group-id> --output json
   aws opensearchserverless get-account-settings --output json
   aws cloudwatch get-metric-statistics --namespace AWS/AOSS --metric-name SearchOCU \
     --start-time <30 days ago> --end-time <now> --period 3600 \
     --statistics Average Maximum --output json
   ```

   Record the configured minimums, the measured `SearchOCU` and `IndexingOCU`
   averages, and how many collections share the group; repeat the metric call for
   `IndexingOCU`. Aurora Serverless v2 bills ACU-hours plus storage — read the
   cluster's minimum capacity and the `ServerlessDatabaseCapacity` metric the same
   way. S3 Vectors bills storage plus requests, so it has no idle floor and its cost
   tracks query and put volume.
2. **Embedding tokens at ingestion.** Corpus tokens are roughly the bytes of
   extracted text divided by 4. Overlap repeats text: with fixed-size chunking at
   `maxTokens` M and `overlapPercentage` p as a fraction, consecutive chunks advance
   by M(1-p), so the corpus is embedded about 1/(1-p) times over — 1.25x at 20%, 2x
   at 50%. It is not 1+p, and the gap widens exactly where it costs most.
   Hierarchical chunking embeds both levels, so count parent and child separately.
   Multiply by the embedding price per 1,000 tokens. This is the cost of one full
   sync and of any re-embedding.
3. **Semantic chunking, when configured.** A `chunkingStrategy` of `SEMANTIC` calls a
   foundation model during ingestion and is charged for that on top of the
   embeddings, scaling with corpus size. Zero for every other strategy.
4. **Parsing, when configured.** Neither parser is charged per document, so the object
   count from Step 1 cannot price this line. `BEDROCK_DATA_AUTOMATION` is priced per
   page of the document and per image processed: multiply the page estimate and the
   image count recorded in Step 1 by the per-page and per-image rates.
   `BEDROCK_FOUNDATION_MODEL` is priced on the input and output tokens the parser
   model processes: estimate input tokens from the extracted text of the pages it
   parses, output tokens from the extraction it returns, and multiply by that model's
   input and output prices. On a large scanned-PDF corpus this can be the biggest
   single ingestion line, and per-document pricing understates a 200-page PDF by two
   orders of magnitude. Either parser, once set, is applied to every `.pdf` in the
   data source, text-only ones included, so the whole PDF count is in scope. The
   default parser adds nothing.
5. **Embedding tokens per query.** One query embedding per retrieve; small but
   nonzero.
6. **Reranking, when configured.** A `rerankingConfiguration` on the search
   configuration sends the candidate chunks through a reranker model on every query,
   which is charged per query and can rival the generation cost on a chatty
   application. Zero when `rerankingModelType` is `NONE` or no reranking is set.
7. **Vector store request and data-processing charges.** Separate from item 1's
   capacity or storage: S3 Vectors charges per query and per put, and the store's own
   data-processing charges scale with query volume. On a high-volume, small-corpus
   knowledge base these can exceed the embedding cost, which is why they cannot be
   left out of a per-query figure.
8. **Generation tokens per query.** Prompt tokens are the template plus the five
   chunks (chunk `maxTokens` times 5) plus the question; output tokens from the Step 6
   answers. Multiply by the model's input and output prices.

**Getting the store's real monthly figure.** Filter Cost Explorer down to this store.
A service-only filter returns the whole account's spend for that service, which on any
shared account is not this knowledge base's bill:

```bash
eval "$(~/.vibestack/bin/vibe-slug 2>/dev/null)" 2>/dev/null || SLUG="unknown"
EVAL_DIR="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}"
mkdir -p "$EVAL_DIR"
CE_OUT="$EVAL_DIR/kb-cost-$(date +%Y-%m-%d).json"
CE_ERR=$(aws ce get-cost-and-usage \
  --time-period Start=<first of last month>,End=<first of this month> \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"And":[{"Dimensions":{"Key":"SERVICE","Values":["Amazon OpenSearch Service"]}},{"Tags":{"Key":"<cost-allocation-tag>","Values":["<value>"]}}]}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --output json 2>&1 > "$CE_OUT")
rc=$?
[ "$rc" -ne 0 ] && printf 'COST: N-A (exit %s)\n%s\n' "$rc" "$CE_ERR"
```

`--filter` takes `Dimensions`, `Tags` and `CostCategories` combined with
`And`, `Or` and `Not`, so swap the tag clause for a cost category when the account
uses one. The tag has to be activated as a cost allocation tag and only covers usage
from its activation date. Cost Explorer is a separate permission from the rest of this
review: on a non-zero exit, or when the store carries no tag or category that isolates
it, report the store cost as N-A and price it instead from the measured usage in item
1 against published unit rates. Say in the report which of the two routes produced the
number. Never print an unfiltered service total as this store's cost.

Report a per-1000-queries figure: fixed monthly cost of the store divided by the
observed or expected monthly query volume, plus the per-query items. Findings:
**MEDIUM** if the store's idle floor is more than half of the monthly bill at the
current query volume (S3 Vectors or pgvector on an existing database would cost less)
— this one needs both the configured minimum capacity and a month of OCU or ACU
metrics showing usage sitting at that minimum; with only one of the two it is **LOW**
and written as a question for the user, not a verdict. **LOW** if prompt tokens per
query are over 4000 because of large chunks times `numberOfResults`.

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
Mode:      Bedrock knowledge base (type VECTOR) | hand-built pipeline

KB SUMMARY
Field              Value
-----------------  ----------------------------------------------
Knowledge base     kb-docs-prod (ABCD1234), type VECTOR
Vector store       OpenSearch Serverless, group min 2 index / 2 search OCU shared
                   with 3 collections, 1024-dim index
Embedding model    amazon.titan-embed-text-v2:0, 1024 dims
Data sources       s3://docs/tenant-*/ (1,240 PDF, 380 DOCX, 4.1 GB), confluence ENG space
Chunking           hierarchical, parent 1500 / child 300 tokens, overlap 60
Parsing            none (default text extraction)
Isolation          metadata filter on tenant (no ACL awareness configured)
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
5  MEDIUM    cost        min 2 OCU idle = 68% of tagged spend; SearchOCU avg 2.0  evaluate S3 Vectors for this volume

RETRIEVAL METRICS (golden set: 32 questions, 5 unanswerable, 0 retrieval errors)
Subset      n    doc hit@5   passage hit@5   MRR    false positives
----------  ---  ---------   -------------   ----   ---------------
all         27   0.81        0.70            0.55   1 of 5
de          19   0.79        0.68            0.52   -
en           8   0.88        0.75            0.63   -
Faithfulness (10 answers, <model id>): 7 faithful, 2 partly, 1 wrong

COST (prices read 2026-08-14; store cost from Cost Explorer, tag kb=docs-prod)
Item                            Monthly      Per 1,000 queries
------------------------------  ----------   -----------------
Vector store (min 2 OCU + 6 GB) $351.00      $39.00
Semantic chunking               not configured
Parsing                         default parser, no charge
Full re-embed (one-off)         $18.40       -
Query embeddings                $0.20        $0.02
Reranking                       not configured
Store requests                  included in OCU capacity above
Generation (<model id>)         $61.00       $6.80
Total at 9,000 queries/month    $412.20      $45.82

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
6. **Isolation findings are never downgraded.** A missing tenant filter, or a user context the caller can set, is CRITICAL regardless of how few tenants exist today. A retrieve that exits non-zero proves nothing either way: report it N-A, never as a pass.
7. **Prices carry a date.** Unit prices change; every cost figure names the day the price was read and the volume it assumes.
8. **No account ids or document text in learnings.** Refer to the account by alias or slug and to documents by their role, never by content.

{{include lib/snippets/capture-learnings.md}}
