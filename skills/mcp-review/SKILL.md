---
name: mcp-review
description: |
  Review an MCP server (Python FastMCP or the TypeScript SDK) for tool design, scope, auth, input validation, error shape, transport and prompt-injection exposure. Use it before publishing a server, before wiring one into an agent, or when someone asks whether an MCP server is safe to run. Produces a findings table with severities and proposed tool schema changes; never modifies the server or its credentials.
triggers:
  - mcp review
  - review my mcp server
  - mcp tool schema
  - mcp auth
  - mcp security
  - is this mcp server safe
allowed-tools:
  - Bash
  - Read
  - Grep
  - Write
  - AskUserQuestion
---

## When to invoke

Use when: "review my MCP server", "is this MCP server safe", "check the tool schemas", "MCP auth", "MCP security", or before an MCP server is published, deployed over HTTP, or given to an agent with real credentials.

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
When the user types `/mcp-review`, run this skill. An optional argument names the server directory or entry file; without one, review the current repository.

---

## Step 1: Locate the server

Find the entry point and the SDK before reading anything else. The SDK decides which registration patterns to look for.

```bash
# SDK and entry point
grep -rlE 'from (mcp|fastmcp)|import (mcp|fastmcp)' --include='*.py' . 2>/dev/null | grep -v node_modules | head
grep -rlE '@modelcontextprotocol/sdk' --include='*.ts' --include='*.js' --include='package.json' . 2>/dev/null | grep -v node_modules | head

# Transport
grep -rnE 'stdio|streamable|StreamableHTTP|sse|transport=' --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules | head -20

# Registrations
grep -rnE '@(mcp|server|app)\.(tool|resource|prompt)\(|server\.(registerTool|registerResource|registerPrompt|tool|resource|prompt)\(' \
  --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
```

Record: entry file, transport (`stdio` or streamable HTTP; flag legacy SSE), the count of tools, resources and prompts, and whether any auth middleware is mounted (`bearer`, `OAuth`, `verify_token`, `requireBearerAuth`, `authMiddleware`). Then read every tool registration in full, including its input schema (Pydantic model, `zod` object, or hand-written JSON schema) and its description string. Keep a list of tool names with their schemas; Steps 2 and 4 work from that list.

If no entry point is found, stop and ask the user where the server lives. Do not guess.

---

## Step 2: Tool design

Go through the tool list from Step 1 and check each item below. A tool that fails a check is a finding; the severity is given per check.

- **Name is a verb plus a noun** (`search_issues`, `create_ticket`), unique across the server, no near-duplicates (`get_user` next to `fetch_user`). Near-duplicates confuse tool selection. Severity: MEDIUM.
- **Description says when to use it and when not to.** A description that only restates the name ("Gets a user") gives the model nothing to route on. Severity: MEDIUM.
- **Required and optional fields are explicit.** In Pydantic, every field either has a default or is required on purpose; in zod, `.optional()` is deliberate. A field that is required in the schema but ignored in the handler, or optional in the schema but crashes when absent, is a finding. Severity: MEDIUM.
- **Enums instead of free strings** wherever the handler branches on the value (`format`, `mode`, `status`). Grep the handler for `if x == "..."` chains over a field typed as `str`. Severity: LOW.
- **Bounded output.** List and search tools take `limit` plus a cursor or page token and cap the result size; anything that can return an unbounded body needs a `token_budget` or `max_bytes` argument. Severity: MEDIUM. Unbounded and fed by a database query: HIGH.
- **Reads separated from writes.** One tool must not both read and mutate based on a flag. Write tools carry an annotation (`readOnlyHint: false`, `destructiveHint: true` in the TypeScript SDK; the equivalent `annotations=` argument in FastMCP). Severity: MEDIUM.
- **Destructive tools require an explicit `confirm: true` parameter** and refuse without it. Look for delete, drop, purge, revoke, overwrite, send, pay. Severity: HIGH.

```bash
# Quick sweep for destructive verbs and for missing limits
grep -rnEi 'def (delete|drop|purge|remove|revoke|send|pay|overwrite)_|(delete|drop|purge|remove|revoke|send|pay|overwrite)[A-Za-z]*[[:space:]]*[:=(]' --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
grep -rnE 'def (list|search|find|query)_|(list|search|find|query)[A-Za-z]*[[:space:]]*[:=(]' --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
```

For each list/search hit, confirm the schema has a `limit` (with a maximum) and a cursor. For each destructive hit, confirm the schema has `confirm` and the handler checks it before doing anything.

---

## Step 3: Auth and scope

Check three layers: who may talk to the server, what each client may do, and what the server itself can reach.

- **HTTP transport without auth.** A streamable HTTP server with no bearer or OAuth check on the MCP endpoint is open to anyone who can reach the port. Look for `requireBearerAuth`, `ProxyOAuthServerProvider`, `TokenVerifier`, `auth=` on the FastMCP constructor, or a framework middleware on the route. Missing on a network-bound server: CRITICAL. stdio-only server: not applicable, say so.
- **Per-client scopes.** When auth exists, does the server read scopes from the token and check them per tool (`scopes_required`, `requiredScopes`), or is every authenticated client allowed everything? Every tool reachable with any valid token, when the server has write tools: HIGH.
- **Least privilege on the server's own credentials.** Read the env vars and config the server consumes (`os.environ`, `process.env`, `.env.example`, `config.*`). A server that only reads issues should not hold a token with delete scope; a database server should not connect as an owner role. Compare the credential's scope against the union of what the tools need. Over-scoped: HIGH.
- **Secrets from the environment, never from code or logs.**

```bash
# Literal tokens and keys in source
grep -rnE '(api[_-]?key|secret|token|password|passwd|bearer)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_./+=-]{12,}' \
  --include='*.py' --include='*.ts' --include='*.js' --include='*.json' --include='*.yaml' --include='*.yml' . 2>/dev/null | grep -v node_modules
# Secrets reaching log lines
grep -rnE '(log|logger|console)\.(info|debug|warn|error|log)\(.*(token|secret|password|api_key|authorization)' \
  --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
```

A literal credential in tracked source: CRITICAL. A credential interpolated into a log line: HIGH. A `.env` file that is not in `.gitignore`: HIGH.

---

## Step 4: Input validation and error shape

The schema is the outer boundary; the handler is the inner one. Both must hold.

- **Schema plus range.** Numbers carry min and max (`ge`/`le`, `.min()/.max()`), strings carry a max length, arrays carry a max item count. A `limit` with no upper bound is a finding. Severity: MEDIUM.
- **Path traversal.** Any tool that takes a path or filename must resolve it and confirm it stays under an allowed root. Grep for `open(`, `readFile`, `os.path.join`, `path.join` inside handlers and trace the argument back to the schema. A user-supplied path joined to a base without a `realpath`-and-prefix check: HIGH.
- **Injection in queries.** SQL built by string concatenation or f-string with a tool argument, shell commands built with `subprocess(..., shell=True)` or `exec(` from arguments, or search filters passed straight into a query language. Severity: CRITICAL.

```bash
grep -rnE 'f"[^"]*(SELECT|INSERT|UPDATE|DELETE|WHERE)|\+[[:space:]]*["'"'"'].*(SELECT|WHERE)|shell=True|child_process|execSync|exec\(' \
  --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
```

- **Error shape.** Errors return a structured object such as `{"error": "<what went wrong>", "suggestion": "<what to try>"}` with `isError: true`, never a raw stack trace, an internal hostname, a SQL fragment, or a token. Grep for `traceback.format_exc`, `err.stack`, `str(e)` returned directly to the client. Stack traces to the client: MEDIUM; secrets or connection strings in error text: HIGH.
- **Rate limits.** A network-bound server, or any tool that calls a paid or quota-limited backend, needs a per-client rate limit. Missing on HTTP transport: MEDIUM.

---

## Step 5: Prompt-injection surface

A tool result is model input. Anything the server fetches from a third party — web pages, tickets, emails, documents, other users' data — can carry instructions aimed at the model.

- **Third-party text is labelled as untrusted data.** The result wraps such content in a clear delimiter and a note that it is data, not instructions (for example a `content` field plus `"source": "external", "trust": "untrusted"`, or a text preamble the description explains). Raw third-party text returned as the bare result: HIGH.
- **No tool executes instructions found in its own results.** Trace any handler that reads a result and then acts on it: fetches a URL found in the page, runs a command found in a ticket, sends a message whose recipient came from fetched content. Severity: CRITICAL.
- **Resources and tools that take URLs fetch against an allowlist.** Look for `httpx.get`, `requests.get`, `fetch(` with an argument from the schema. Confirm a host allowlist, a scheme check (`https` only), a size cap and a timeout, and a block on private ranges (`127.0.0.0/8`, `10.0.0.0/8`, `169.254.0.0/16`, `::1`). Missing allowlist or private-range block: HIGH.
- **Descriptions do not contain instructions to the model beyond describing the tool.** A description that says "always call this first" or "ignore other tools" is a finding. Severity: MEDIUM.

```bash
grep -rnE 'httpx\.(get|post|AsyncClient)|requests\.(get|post)|fetch\(|urllib' --include='*.py' --include='*.ts' . 2>/dev/null | grep -v node_modules
grep -rnEi 'ignore (previous|all|other)|always (call|use) this|do not tell the user' --include='*.py' --include='*.ts' --include='*.md' . 2>/dev/null | grep -v node_modules
```

---

## Step 6: Operability

- **Health and version.** A `health` or `server_info` tool, or the `serverInfo` block in the initialize response, reports the version and the backends it depends on. Missing: LOW.
- **Logging without payload secrets.** Log lines carry the tool name, duration and outcome; they do not carry argument values that could hold tokens, PII or document bodies. Check `logger.*` / `console.*` calls inside handlers. Full arguments logged: MEDIUM.
- **Timeouts** on every outbound call (`timeout=` in httpx/requests, `AbortSignal.timeout` or `signal` in fetch, statement timeout on database connections). Outbound call with no timeout: MEDIUM.
- **Idempotency for write tools.** A create or send tool accepts an `idempotency_key` or checks for an existing record, so a retried call does not double-create. Missing on a tool that creates, sends or charges: MEDIUM.
- **Scripted test.** Run the server against a scratch config and list its tools through a client. Prefer the MCP inspector when it is installed; otherwise a short script.

Confirm three things before running the block below, and record the outcome on the `Live check:` line of the report:

1. `$SCRATCH/.env` holds placeholder values only — `cat` it and read every line. If `.env.example` is missing or carries real values, write the file by hand instead.
2. The entry command is the server under review, written as an absolute path, and takes no side-effecting action at startup (no migration, no outbound post). The block changes directory, so a relative path will not resolve.
3. Nothing in the command invokes a tool. `tools/list` is the whole live check.

```bash
# Scratch env: placeholder values only, never the real credentials
SCRATCH="${VIBESTACK_HOME:-$HOME/.vibestack}/scratch/mcp-review"
mkdir -p "$SCRATCH"
: > "$SCRATCH/.env"
[ -f .env.example ] && sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2=scratch-placeholder/' \
  .env.example > "$SCRATCH/.env"
cat "$SCRATCH/.env"

# The child environment is built from that file and nothing else
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SCRATCH/.env" > "$SCRATCH/env.list" || true
SCRATCH_ENV=("MCP_REVIEW_SCRATCH=1")
while IFS= read -r _line; do
  SCRATCH_ENV+=("$_line")
done < "$SCRATCH/env.list"

# Inspector, if available, in CLI mode. env -i drops the inherited environment, so
# an exported GITHUB_TOKEN or DATABASE_URL cannot reach the server; HOME and the
# working directory point at the scratch dir, so a dotenv server loads
# "$SCRATCH/.env" rather than the repository's .env.
command -v npx >/dev/null 2>&1 && \
  ( cd "$SCRATCH" && env -i \
      HOME="$SCRATCH" TMPDIR="$SCRATCH" PATH="$PATH" \
      "${SCRATCH_ENV[@]}" \
      npx --yes @modelcontextprotocol/inspector --cli <absolute entry command> --method tools/list 2>&1 | head -80 )
```

`PATH` is carried over so `node` and `npx` are still found; it holds no credentials. `HOME` points at the scratch dir, which also hides `~/.aws`, `~/.config/gh` and the rest from the server — the first run therefore re-fetches the inspector into a fresh npm cache.

If the inspector is not available, use Write to create a small client script under `$SCRATCH` (Python `mcp.client.stdio` or the TypeScript `Client` with `StdioClientTransport`) that connects, calls `tools/list`, and prints each tool's name and schema. Launch it through the same `cd "$SCRATCH" && env -i ... "${SCRATCH_ENV[@]}"` wrapper; a client that inherits the environment hands the server the real credentials through the transport it spawns. Compare the live schema with what you read in Step 1: a tool that exists in code but not in the listing, or a listed schema that differs from the source, is a finding. Severity: MEDIUM.

Only run the server with the scratch environment. If it refuses to start without real credentials, report that and skip the live check; do not supply real values.

---

## Output

Write the report to the terminal and, if the user asks for a file, to `docs/mcp-review-<YYYY-MM-DD>.md` with Write.

```
MCP SERVER REVIEW
=================

Server:     <name or entry file>
SDK:        <FastMCP x.y | @modelcontextprotocol/sdk x.y>
Transport:  <stdio | streamable HTTP | SSE (legacy)>
Tools:      <N> (<reads> read, <writes> write, <destructive> destructive)
Resources:  <N>    Prompts: <N>
Auth:       <none | bearer | OAuth (<provider>)>   Scopes enforced: <yes | no | n/a>
Live check: <inspector | scripted client | skipped: <reason>>

FINDINGS
--------
#  | Severity | Tool            | Issue                                        | Fix
---|----------|-----------------|----------------------------------------------|------------------------------------------
1  | CRITICAL | run_query       | SQL built with f-string from `where` arg     | Parameterize; accept structured filters
2  | HIGH     | delete_record   | No `confirm` parameter                       | Add `confirm: bool`, refuse when false
3  | HIGH     | fetch_page      | Fetches any URL, no allowlist, no timeout    | Host allowlist, https only, 10s timeout
4  | MEDIUM   | list_items      | No `limit` maximum                           | `limit: int = Field(20, ge=1, le=200)`
5  | LOW      | (server)        | No version/health tool                       | Add `server_info` returning version

Counts: CRITICAL <n>  HIGH <n>  MEDIUM <n>  LOW <n>
Verdict: <SAFE TO RUN | RUN ONLY OVER STDIO WITH SCOPED CREDENTIALS | DO NOT RUN UNTIL CRITICAL FIXED>

TOOL SCHEMA DIFF
----------------
<tool name>
- <current field or absence>
+ <proposed field, type, constraint>
  why: <one line>

<repeat per tool with a proposed change>
```

Severity meanings:
- **CRITICAL** — exploitable now: injection, credential in source, tool that acts on instructions in fetched content, open HTTP endpoint with write tools.
- **HIGH** — a real path to damage or leakage that needs one more condition.
- **MEDIUM** — design gap that will bite under load or misuse.
- **LOW** — quality of life; fix when touching the file.

Every finding names the tool (or `(server)`), the file and line, and a fix that could be applied as-is. A finding without a location is not finished.

---

## Important Rules

1. **Read-only.** This skill reviews. It never edits the server, its config, or any cloud resource, and never writes to a customer account. Proposed schema changes go in the report, not in the code.
2. **Never start the server against production credentials.** The live check uses a scratch environment with placeholder values. If the server cannot start that way, skip the live check and say so.
3. **Never purchase, provision, or send.** If a tool would send email, post a message, or spend money, do not call it during the live check; `tools/list` is enough.
4. **Read every tool schema.** Sampling three of twenty tools is not a review. If the server is too large for one pass, say which tools were covered.
5. **Report only what you verified.** A grep hit is a lead, not a finding. Open the file, read the handler, then decide.
6. **Severity is about consequence, not effort.** A one-line fix can still be CRITICAL.
7. **stdio is not a security boundary.** A stdio server still runs with the credentials it holds; Steps 3 through 5 apply in full.

{{include lib/snippets/capture-learnings.md}}
