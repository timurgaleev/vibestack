---
name: setup-memory
description: |
  Set up persistent memory for this coding agent using secondbrain: install the CLI, initialize a local PGLite or Supabase brain, register MCP, capture per-remote trust policy. One command from zero to "persistent memory is running and this agent can call it."
triggers:
  - setup memory
  - setup secondbrain
  - install secondbrain
  - connect secondbrain
  - start secondbrain
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

## When to invoke

Use when: "setup memory", "setup secondbrain", "connect secondbrain", "start secondbrain", "install secondbrain", "configure memory for this machine".

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

# /setup-memory — Persistent Memory Setup

You are setting up persistent memory for this coding agent. The underlying engine
is secondbrain, a knowledge base that runs as both
a CLI and an MCP tool on the user's local Mac.

**Scope honesty:** This skill's MCP registration step (5a) uses
`claude mcp add` and targets Claude Code specifically. Other local hosts
(Cursor, Codex CLI, etc.) will still get the secondbrain CLI on PATH — they can
register `secondbrain serve` in their own MCP config manually after setup.

**Audience:** local-Mac users. openclaw/hermes agents typically run in cloud
docker containers with their own memory engine; "sharing" a brain between them
and local Claude Code is only possible through shared Postgres (Supabase).

## User-invocable
When the user types `/setup-memory`, run this skill. Three shortcut modes:

- `/setup-memory` — full flow (default)
- `/setup-memory --repo` — only flip the per-remote policy for the current repo
- `/setup-memory --switch` — only migrate the engine (PGLite ↔ Supabase)
- `/setup-memory --resume-provision <ref>` — re-enter a previously interrupted
  Supabase auto-provision at the polling step
- `/setup-memory --cleanup-orphans` — list + delete in-flight Supabase projects

Parse the invocation args yourself — these are prose hints to the skill, not
implemented as a dispatcher binary.

---

## Concurrent-run lock

At skill start:
```bash
mkdir ~/.vibestack/.setup-memory.lock.d 2>/dev/null || {
  echo "Another /setup-memory instance is running. Wait for it, or remove the lock with:"
  echo "  rm -rf ~/.vibestack/.setup-memory.lock.d"
  exit 1
}
```

Release the lock on normal exit AND in the SIGINT trap.

---

## Step 1: Detect current state

```bash
SBRAIN_ON_PATH=false
SBRAIN_VERSION=""
SBRAIN_CONFIG_EXISTS=false
SBRAIN_ENGINE=""
SBRAIN_DOCTOR_OK=false
MEMORY_SYNC_MODE=""

command -v secondbrain >/dev/null 2>&1 && SBRAIN_ON_PATH=true
$SBRAIN_ON_PATH && SBRAIN_VERSION=$(secondbrain --version 2>/dev/null || echo "")
[ -f "$HOME/.secondbrain/config.json" ] && SBRAIN_CONFIG_EXISTS=true
if $SBRAIN_CONFIG_EXISTS; then
  SBRAIN_ENGINE=$(python3 -c "import json; d=json.load(open('$HOME/.secondbrain/config.json')); print(d.get('engine',''))" 2>/dev/null || echo "")
fi
if $SBRAIN_ON_PATH; then
  secondbrain doctor --json >/tmp/vibe-memory-doctor.json 2>/dev/null
  STATUS=$(python3 -c "import json; d=json.load(open('/tmp/vibe-memory-doctor.json')); print(d.get('status',''))" 2>/dev/null || echo "")
  [ "$STATUS" = "ok" ] || [ "$STATUS" = "warnings" ] && SBRAIN_DOCTOR_OK=true
fi
MEMORY_SYNC_MODE=$(vibe-config get memory_sync_mode 2>/dev/null || echo "")

echo "Detected: memory_engine=secondbrain on_path=$SBRAIN_ON_PATH version=${SBRAIN_VERSION:-none} engine=${SBRAIN_ENGINE:-none} doctor_ok=$SBRAIN_DOCTOR_OK sync=${MEMORY_SYNC_MODE:-off}"
```

Report the detected state in one line. Skip downstream steps that are already done.

Branch on the `--repo`, `--switch`, `--resume-provision`, `--cleanup-orphans`
invocation flags here and skip to the matching step.

Also capture `sbrain_local_status` (one of `ok`, `broken-db`, `broken-config`,
`no-cli`, `missing-config`), `sbrain_mcp_name` (the registered MCP name —
`memex`, `secondbrain`, or other compliant brand) and `sbrain_mcp_mode`
(`local-stdio`, `remote-http`, or empty) so Step 1.5 and Step 2 can branch on
them. Compute them inline:

```bash
SBRAIN_LOCAL_STATUS="ok"
if ! $SBRAIN_ON_PATH; then
  SBRAIN_LOCAL_STATUS="no-cli"
elif ! $SBRAIN_CONFIG_EXISTS; then
  SBRAIN_LOCAL_STATUS="missing-config"
elif ! $SBRAIN_DOCTOR_OK; then
  # Distinguish broken-db (config valid but engine unreachable) from broken-config
  # (config malformed). Falls back to broken-db if json parse worked at Step 1.
  if [ -n "$SBRAIN_ENGINE" ]; then SBRAIN_LOCAL_STATUS="broken-db"; else SBRAIN_LOCAL_STATUS="broken-config"; fi
fi
# Detect any compliant brain MCP — backend-agnostic per vibestack policy.
# `claude mcp list` lines look like:
#   memex: https://brain.example.com/mcp (HTTP) - ✓ Connected
#   secondbrain: /Users/foo/.bun/bin/secondbrain serve - ✓ Connected
# Match either name, strip the trailing colon, and infer mode from the (HTTP)
# marker. First match wins; downstream code should NOT assume the name is
# `secondbrain`.
_BRAIN_LINE=$(claude mcp list 2>/dev/null | awk '/^(memex|secondbrain):[[:space:]]/{print; exit}')
SBRAIN_MCP_NAME=$(printf '%s\n' "$_BRAIN_LINE" | awk '{name=$1; sub(/:$/, "", name); print name}')
SBRAIN_MCP_MODE=$(printf '%s\n' "$_BRAIN_LINE" | awk '{print (tolower($3)=="(http)")?"remote-http":"local-stdio"}')
[ -z "$_BRAIN_LINE" ] && SBRAIN_MCP_MODE=""
echo "sbrain_local_status=$SBRAIN_LOCAL_STATUS sbrain_mcp_name=${SBRAIN_MCP_NAME:-none} sbrain_mcp_mode=${SBRAIN_MCP_MODE:-none}"
```

---

## Step 1.5: Broken-local-engine remediation

If `SBRAIN_LOCAL_STATUS` is `broken-db` or `broken-config` AND no shortcut flag
was passed, the user has a non-working local engine (config exists but the
engine it points at isn't reachable, OR the config itself is malformed). Fire
a targeted AskUserQuestion BEFORE Step 2:

> D# — Your local secondbrain engine isn't responding. How do you want to fix it?
> Project/branch/task: <one-sentence grounding using detected slug + branch>
> ELI10: secondbrain has a config at `~/.secondbrain/config.json` but the engine
> it points at isn't reachable. That could be a transient outage (Postgres container
> stopped, Tailscale down) OR a stale config you want to abandon. Different
> remediation for each case.
> Stakes if we pick wrong: "Switch to PGLite" overwrites your existing config
> (one-way door if the user actually wanted the broken engine). "Retry" preserves
> existing state for transient cases.
> Recommendation: A (Retry) — always try the cheap option first; if engine is
> just temporarily down it'll come back without any destructive change.
> Note: options differ in kind, not coverage — no completeness score.
> A) Retry — re-probe the engine (recommended; ~80ms)
>   ✅ Cheapest test: re-runs `secondbrain doctor --json` to see if engine is back
>   ✅ Zero side effects; existing config preserved
>   ❌ If engine is permanently dead, retries forever; user must choose another option
> B) Switch to local PGLite (one-way — moves existing config to .bak)
>   ✅ Fastest path to a working local engine if user has abandoned the old one
>   ✅ ~30s; no accounts; private to this machine
>   ❌ Destructive — existing config moved to ~/.secondbrain/config.json.vibestack-bak-{ts}
> C) Switch brain mode (continue to Step 2 path picker)
>   ✅ Lets user pick Path 1/2/3/4 to re-init from scratch
>   ✅ Preserves existing config until they explicitly init the new one
>   ❌ Longer flow if user just wants to repair to PGLite
> D) Quit (do nothing)
>   ✅ No cons — this is a hard-stop choice
>   ❌ N/A
> Net: A is the right starting move; B/C are explicit destructive paths; D bails.

**If A (Retry)**: re-run the detect block from Step 1. If the new
`sbrain_local_status` is `ok`, continue to Step 2. If still `broken-db` or
`broken-config`, fire the same AskUserQuestion again (the user picks again).

**If B (Switch to PGLite)** — execute the rollback-safe init sequence:

```bash
BACKUP="$HOME/.secondbrain/config.json.vibestack-bak-$(date +%s)"
mv "$HOME/.secondbrain/config.json" "$BACKUP"
if ! secondbrain init --pglite --json; then
  # Restore on failure
  mv "$BACKUP" "$HOME/.secondbrain/config.json"
  echo "secondbrain init failed. Your previous config was restored at $HOME/.secondbrain/config.json." >&2
  echo "PGLite directory at ~/.secondbrain/pglite/ may be in a partial state — \`rm -rf ~/.secondbrain/pglite\` if needed before retrying." >&2
  exit 1
fi
echo "Switched to local PGLite. Previous config saved at $BACKUP — review before deleting."
```

Then jump to Step 5a (MCP registration; the new PGLite engine is registered as
local-stdio).

**If C (Switch brain mode)**: continue to Step 2's normal path picker.

**If D (Quit)**: STOP the skill cleanly.

For `SBRAIN_LOCAL_STATUS` values of `no-cli` or `missing-config`, do NOT fire
Step 1.5 — fall through to Step 2 (where `no-cli` triggers Step 3 install and
`missing-config` triggers Step 4 init).

---

## Step 2: Pick a path (AskUserQuestion)

Only fire this if Step 1 shows no existing working config AND no shortcut
flag was passed. **Special case:** if `sbrain_mcp_mode=remote-http` in the
detect output (regardless of whether `sbrain_mcp_name` is `memex`,
`secondbrain`, or another compliant brand), an HTTP MCP brain is already
registered — skip directly to Step 5a verification (re-test the existing
registration under its detected name) and Step 6 onward, treating this run
as idempotent. Don't ask Step 2 again, and **never register a parallel
`secondbrain` entry pointing at the same URL** — that creates a duplicate
brain in `claude mcp list`.

The question title: "Where should your brain live?"

Options (present based on detected state):

- **1 — Supabase, I already have a connection string.** Cloud-agent users
  whose openclaw/hermes provisioned one already. Paste the Session Pooler
  URL from the Supabase dashboard (Settings → Database → Connection Pooler
  → Session). *Trust-surface caveat:* "Pasting this URL gives your local
  Claude Code full read/write access to every page your cloud agent can see.
  If that's not the trust level you want, pick PGLite local instead and
  accept the brains are disjoint."
- **2a — Supabase, auto-provision a new project.** You'll need a Supabase
  Personal Access Token (~90 seconds). Best choice for a shared team brain.
- **2b — Supabase, create manually.** Walk through supabase.com signup
  yourself; paste the URL back when ready.
- **3 — PGLite local.** Zero accounts, ~30 seconds. Isolated brain on this
  Mac only. Best for try-first.
- **4 — Remote secondbrain MCP.** Someone else (or another machine of yours) is
  already running `secondbrain serve` with HTTP transport. You paste the MCP URL
  + a bearer token; this skill registers it as your MCP. No local brain DB,
  no local install needed. Recommended when the brain is shared across
  machines or run by a teammate.
- **Switch** (only if Step 1 detected an existing engine): "You already have
  a `<engine>` brain. Migrate it to the other engine?" → runs
  `secondbrain migrate --to <other>` wrapped in `timeout 180s`.

Do NOT silently pick; fire the AskUserQuestion.

---

## Step 3: Install memory CLI (secondbrain)

**SKIP entirely on Path 4 (Remote MCP).** Path 4 doesn't need a local secondbrain
binary — all calls go through MCP to the remote server. Jump to Step 4 (the
Path 4 subsection).

For Paths 1, 2a, 2b, 3, switch — only if `SBRAIN_ON_PATH=false`:

```bash
# Try bun first, fall back to npm
if command -v bun >/dev/null 2>&1; then
  bun install -g secondbrain
elif command -v npm >/dev/null 2>&1; then
  npm install -g secondbrain
else
  echo "ERROR: Neither bun nor npm found. Install one first."
  exit 1
fi
```

After install, verify:
```bash
secondbrain --version
```

If `secondbrain --version` fails, check PATH:
```bash
# bun global bin
export PATH="$HOME/.bun/bin:$PATH"
secondbrain --version
```

If it still fails, surface the error and STOP — the environment is broken until
the user fixes PATH. Do not continue the skill.

**PATH-shadow validation.** Even when `secondbrain --version` succeeds, another
binary earlier on `$PATH` may be shadowing the one we just installed (a stale
global from a prior install, a colleague's fork checked into `~/bin/`, etc.).
Validate that the resolved `secondbrain` lives in the expected install
directory:

```bash
RESOLVED=$(command -v secondbrain)
EXPECTED_DIRS=("$HOME/.bun/install/global/node_modules/secondbrain" "$HOME/.npm/global/node_modules/secondbrain" "$(npm prefix -g 2>/dev/null)/lib/node_modules/secondbrain")
SHADOWED=true
for d in "${EXPECTED_DIRS[@]}"; do
  if printf '%s' "$RESOLVED" | grep -q "$(dirname "$d")"; then SHADOWED=false; break; fi
done
if $SHADOWED; then
  echo "WARN: \`secondbrain\` resolves to $RESOLVED, which is outside the expected global install paths."
  echo "      Another binary may be shadowing your install. Check \`type -a secondbrain\` and rearrange PATH if needed."
fi
```

The warning is non-blocking — the user may have intentionally installed a fork —
but surface it before continuing so half-broken setups don't get silently wired.

---

## Step 4: Initialize the brain

Path-specific.

### Path 1 (Supabase, existing URL)

Collect the URL securely (never as argv):

```bash
printf "Paste Session Pooler URL: "
read -rs SBRAIN_POOLER_URL
echo
printf "URL received (redacted): %s\n" "$(echo "$SBRAIN_POOLER_URL" | sed 's#://[^@]*@#://***@#')"
```

Validate structurally (must start with `postgresql://` and contain port 6543):

```bash
echo "$SBRAIN_POOLER_URL" | grep -qE '^postgresql://.+:6543/' || {
  echo "ERROR: URL does not look like a Session Pooler URL (expected port 6543)."
  echo "Get it from: Supabase dashboard → Settings → Database → Connection Pooler → Session"
  exit 1
}
```

On success, hand off to the memory CLI via env var (never argv):

```bash
export SBRAIN_DATABASE_URL="$SBRAIN_POOLER_URL"
secondbrain init --non-interactive --json
unset SBRAIN_POOLER_URL SBRAIN_DATABASE_URL
```

The URL is now persisted in `~/.secondbrain/config.json` at mode 0600 by the secondbrain CLI itself.

### Path 2a (Supabase, auto-provision)

Show the PAT scope disclosure BEFORE collecting the token:

> *This Supabase Personal Access Token grants full read/write/delete access
> to every project in your Supabase account, not just the `secondbrain` one we're
> about to create. Supabase doesn't currently support scoped tokens. We use
> this PAT only to: create one project, poll it until healthy, read the
> Session Pooler URL — then discard it from process memory. The token
> remains valid on Supabase's side until you manually revoke it at
> https://supabase.com/dashboard/account/tokens — we recommend revoking
> immediately after setup completes.*

Then collect securely:

```bash
printf "Paste PAT: "
read -rs SUPABASE_ACCESS_TOKEN
echo
export SUPABASE_ACCESS_TOKEN
```

Ask the tier prompt via AskUserQuestion: "Which Supabase tier?" Present
Free (2-project limit, pauses after 7d inactivity) vs Pro ($25/mo, no
pauses, recommended for real use). Explain that tier is **org-level** — user
picks their org based on its current tier.

List orgs:

```bash
curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  https://api.supabase.com/v1/organizations
```

If the orgs array is empty, surface: "Your Supabase account has no
organizations. Create one at https://supabase.com/dashboard, then re-run
`/setup-memory`." STOP.

If multiple orgs, use AskUserQuestion to pick one.

Ask the user for a region (default `us-east-1`).

Generate the DB password (never shown to the user):

```bash
export DB_PASS=$(openssl rand -base64 24)
```

Set up a SIGINT trap:

```bash
trap 'echo ""; echo "vibe-setup-memory: interrupted. In-flight ref: $INFLIGHT_REF"; \
      echo "Resume: /setup-memory --resume-provision $INFLIGHT_REF"; \
      echo "Delete: https://supabase.com/dashboard/project/$INFLIGHT_REF"; \
      unset SUPABASE_ACCESS_TOKEN DB_PASS; \
      rm -rf ~/.vibestack/.setup-memory.lock.d; exit 130' INT TERM
```

Create + wait + fetch:

```bash
# Create project
CREATE_RESULT=$(curl -s -X POST \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"secondbrain\",\"organization_id\":\"$ORG_ID\",\"region\":\"$REGION\",\"db_pass\":\"$DB_PASS\"}" \
  https://api.supabase.com/v1/projects)
INFLIGHT_REF=$(echo "$CREATE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")

# Poll until healthy (max 3 min)
ATTEMPTS=0
until curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$INFLIGHT_REF" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('status')=='ACTIVE_HEALTHY' else 1)" 2>/dev/null; do
  ATTEMPTS=$((ATTEMPTS+1))
  [ "$ATTEMPTS" -ge 36 ] && echo "ERROR: project did not become healthy in 3 minutes" && exit 1
  sleep 5
done

# Fetch pooler URL
POOLER=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$INFLIGHT_REF/database/connection")
export SBRAIN_DATABASE_URL=$(echo "$POOLER" | python3 -c "import json,sys; print(json.load(sys.stdin).get('db_url',''))")
secondbrain init --non-interactive --json
unset SUPABASE_ACCESS_TOKEN DB_PASS SBRAIN_DATABASE_URL INFLIGHT_REF
trap - INT TERM
```

After success, emit the PAT revocation reminder:

> "Setup complete. Revoke the PAT you pasted at
> https://supabase.com/dashboard/account/tokens — we've already discarded
> it from memory and don't need it again. The memory project will continue
> working because it uses its own embedded database password."

### Path 2b (Supabase, manual)

Walk the user through the supabase.com steps:
1. Login at https://supabase.com/dashboard
2. Click "New Project," name it `secondbrain`, pick a region
3. Wait ~2 min for the project to initialize
4. Settings → Database → Connection Pooler → Session → copy the URL (port 6543)

Then follow the same secret-read + verify + init flow as Path 1.

### Path 3 (PGLite local)

```bash
secondbrain init --pglite --json
```

Done. No network, no secrets.

### Path 4 (Remote secondbrain MCP — HTTP transport with bearer token)

For users whose brain runs on another machine (Tailscale, ngrok, internal
LAN, or a teammate's server). No local secondbrain CLI install, no local DB.
This skill registers the remote MCP and stops; ingestion + indexing happens
on the brain host.

**4a. Collect MCP URL.** Prompt the user:

```
Paste your secondbrain MCP URL (e.g. https://wintermute.tail554574.ts.net:3131/mcp):
```

Read with plain `read -r` (no secret hygiene needed — the URL alone isn't
a credential). Validate it starts with `https://` (require TLS for any
non-loopback host); refuse `http://` for non-localhost.

```bash
printf "Paste secondbrain MCP URL: "
read -r MCP_URL
case "$MCP_URL" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;;
  *) echo "ERROR: Non-localhost URLs must use https://. Got: $MCP_URL"; exit 1 ;;
esac
```

**4b. Collect bearer token securely (never argv).**

```bash
printf "Paste bearer token: "
read -rs SBRAIN_MCP_TOKEN
echo
printf "Token received (redacted): %s***\n" "$(printf '%s' "$SBRAIN_MCP_TOKEN" | head -c 4)"
export SBRAIN_MCP_TOKEN
```

**4c. Verify the MCP server is reachable + authed + on a compatible protocol.**

```bash
verify_resp=$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $SBRAIN_MCP_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "$MCP_URL" 2>&1)
verify_exit=$?
if [ "$verify_exit" -ne 0 ]; then
  echo "ERROR: Could not reach $MCP_URL (curl exit $verify_exit). Network/DNS/firewall?"
  echo "       Raw: $verify_resp"
  unset SBRAIN_MCP_TOKEN
  exit 1
fi
if printf '%s' "$verify_resp" | grep -q '"error"'; then
  echo "ERROR: MCP server rejected the request. Likely auth failure (bad/expired token) or unsupported method."
  echo "       Raw: $verify_resp"
  unset SBRAIN_MCP_TOKEN
  exit 1
fi
SERVER_VERSION=$(printf '%s' "$verify_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('serverInfo',{}).get('version','unknown'))" 2>/dev/null || echo "unknown")
echo "Verified: secondbrain server v$SERVER_VERSION reachable at $MCP_URL"
```

If verify fails, surface the classified failure (network / auth / malformed)
and STOP with a clear "fix and re-run /setup-memory" message. Do NOT continue
to Step 5a on a failed verify — partial registration would leave the user
with a half-broken state.

**4d. (Path 4) Offer local PGLite for code search.** Ask:

> D# — Want symbol-aware code search on this machine?
> ELI10: The remote brain at `<MCP_URL>` is great for cross-machine knowledge,
> but symbol queries like `secondbrain code-def` / `code-refs` / `code-callers`
> need a local index of THIS machine's code. We can spin up a tiny isolated
> PGLite database (~30 seconds, no accounts, ~120 MB disk) just for code,
> separate from your remote brain. Local PGLite stays code-only.
> Stakes: without it, semantic code search in this repo's worktrees falls
> back to Grep.
> Recommendation: A — 30 seconds, no ongoing cost, unlocks the symbol tools.
> A) Yes, set up local PGLite for code (recommended)
> B) No, remote MCP only

**If A (Yes)**: install + init local PGLite with rollback-safe semantics:

```bash
# Install secondbrain CLI per Step 3 (skipped above for Path 4 — run it now).
if ! command -v secondbrain >/dev/null 2>&1; then
  if command -v bun >/dev/null 2>&1; then bun install -g secondbrain; else npm install -g secondbrain; fi
fi
if [ -f "$HOME/.secondbrain/config.json" ]; then
  BACKUP="$HOME/.secondbrain/config.json.vibestack-bak-$(date +%s)"
  mv "$HOME/.secondbrain/config.json" "$BACKUP"
fi
if ! secondbrain init --pglite --json; then
  if [ -n "${BACKUP:-}" ] && [ -f "$BACKUP" ]; then mv "$BACKUP" "$HOME/.secondbrain/config.json"; fi
  echo "secondbrain init failed. Existing config (if any) was restored. PGLite at ~/.secondbrain/pglite/ may be in a partial state — \`rm -rf ~/.secondbrain/pglite\` to reset." >&2
  echo "Continuing setup without local code search; you can re-run /setup-memory to retry." >&2
fi
```

Then continue to Step 5a. The remote-http MCP registration in 5a runs as
described in the Path 4 subsection; the local PGLite is independent of MCP
registration (Claude Code talks to the remote brain via MCP for queries;
`secondbrain` CLI talks to local PGLite for code-def/refs/callers).

**If B (No)**: skip the install + init. The local engine stays absent.
Skip Step 7.5 (transcript ingest) — memory-stage routes through the remote
brain in remote-http mode.

**4e. Token handoff.** `SBRAIN_MCP_TOKEN` stays in process env until Step 5a's
`claude mcp add --header` consumes it; then `unset SBRAIN_MCP_TOKEN`
immediately. Trade-off: brief argv exposure during `claude mcp add` (visible
to `ps` for ~10ms), resting state in `~/.claude.json` mode 0600.

### Switch (from detected existing-engine state)

```bash
# Going PGLite → Supabase, collect URL first (Path 1 flow), then:
timeout 180s secondbrain migrate --to supabase --url "$URL" --json
# Going Supabase → PGLite:
timeout 180s secondbrain migrate --to pglite --json
```

If `timeout` returns 124: surface "Migration didn't complete in 3 minutes —
another session may be holding a lock on the source brain. Close other
workspaces and re-run `/setup-memory --switch`. Your original brain is
untouched." STOP.

---

## Step 5: Verify memory health

**SKIP entirely on Path 4 (Remote MCP).** The brain host runs its own
doctor; we don't have local DB access to introspect. Step 4c's verify
round-trip already proved the server is reachable, authed, and on a
compatible MCP version.

For Paths 1, 2a, 2b, 3, switch:

```bash
doctor=$(secondbrain doctor --json)
status=$(echo "$doctor" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")
```

If status is `ok` or `warnings`, proceed. Anything else → surface the full
doctor output and STOP.

---

## Step 5a: Register memory (secondbrain) as Claude Code MCP

Only if `which claude` resolves. Ask: "Give Claude Code MCP access to persistent
memory (secondbrain)? (recommended yes)"

The registration form depends on the path picked in Step 2:

### Path 4 (Remote MCP — HTTP transport with bearer)

Reuse the detected MCP name when one already exists; otherwise default to
`secondbrain`. This prevents the skill from creating a duplicate `secondbrain`
registration when the user already has a brain wired under a different name
(typically `memex`).

```bash
TARGET_NAME="${SBRAIN_MCP_NAME:-secondbrain}"
# Tear down any prior registration under the same name (could be local-stdio
# from an old setup, or stale remote-http with a rotated token).
claude mcp remove "$TARGET_NAME" -s user 2>/dev/null || true
claude mcp remove "$TARGET_NAME" 2>/dev/null || true
claude mcp add --scope user --transport http "$TARGET_NAME" "$MCP_URL" \
  --header "Authorization: Bearer $SBRAIN_MCP_TOKEN"
unset SBRAIN_MCP_TOKEN  # zero from process env after registration
claude mcp list | grep "$TARGET_NAME"  # verify: should show "✓ Connected"
```

**Token-storage note:** `claude mcp add --header "Authorization: Bearer ..."`
puts the bearer on argv during process startup, briefly visible to `ps` for
~10ms. The token's resting state is `~/.claude.json` (mode 0600 — Claude
Code's own credential surface for every MCP server). If a future Claude Code
release adds a stdin or env-var input form for headers, switch to that.

### Paths 1, 2a, 2b, 3 (Local stdio)

Register at **user scope** with an **absolute path** to the secondbrain
binary. User scope makes the MCP available in every Claude Code session on
this machine, not just the current workspace. Absolute path avoids PATH
resolution issues when Claude Code spawns `secondbrain serve` as a subprocess.

```bash
TARGET_NAME="${SBRAIN_MCP_NAME:-secondbrain}"
SBRAIN_BIN=$(command -v secondbrain)
[ -z "$SBRAIN_BIN" ] && SBRAIN_BIN="$HOME/.bun/bin/secondbrain"
# Remove any existing local-scope registration under the same name
claude mcp remove "$TARGET_NAME" -s user 2>/dev/null || true
claude mcp remove "$TARGET_NAME" 2>/dev/null || true
claude mcp add --scope user "$TARGET_NAME" -- "$SBRAIN_BIN" serve
claude mcp list | grep "$TARGET_NAME"  # verify: should show "✓ Connected"
```

### Both paths

If `claude` is not on PATH: emit "MCP registration skipped — register `secondbrain serve`
(or your remote MCP URL) in your agent's MCP config manually." Continue to step 6.

Tell the user: "Restart any open Claude Code sessions to see `mcp__secondbrain__*` tools
— they're loaded at session start, not mid-session."

---

## Step 6: Per-remote policy

If we're in a git repo with an `origin` remote, check the policy:

```bash
REMOTE=$(git remote get-url origin 2>/dev/null | sed 's|\.git$||' | sed 's|.*[:/]||2')
CURRENT_TIER=$(vibe-config get "secondbrain_policy_$REMOTE" 2>/dev/null || echo "unset")
echo "Current policy for $REMOTE: $CURRENT_TIER"
```

Branches:
- `read-write` → import this repo: `secondbrain import "$(pwd)" --no-embed` then
  `secondbrain embed --stale &` in the background.
- `read-only` → skip import (this tier is enforced by secondbrain resolver injection).
- `deny` → do nothing.
- `unset` → AskUserQuestion: "How should `<normalized-remote>` interact with memory (secondbrain)?"
  - `read-write` — agent can search AND write new pages from this repo
  - `read-only` — agent can search but never write
  - `deny` — no interaction at all
  - `skip-for-now` — don't persist, ask next time

  On answer (other than skip-for-now):
  ```bash
  vibe-config set "secondbrain_policy_$REMOTE" "$TIER"
  ```
  Then import if `read-write`.

If outside a git repo OR no origin remote: skip this step with a note.

For `/setup-memory --repo` invocations, execute ONLY Step 6 and exit.

---

## Step 7: Offer memory sync

Separate AskUserQuestion: "Also sync your vibestack session memory (learnings,
plans, retros) to a private git repo that the memory engine (secondbrain) can index across machines?"

Options:
- Yes, full sync (everything allowlisted)
- Yes, artifacts-only (plans, designs, retros — skip behavioral data)
- No thanks

If yes:

```bash
# Initialize a sync repo (user provides URL or we create one)
# Then set the mode in vibe-config
vibe-config set memory_sync_mode artifacts-only
# or "full" if user picked yes-full
```

---

## Step 7.5: Transcript & memory ingest gate (single-machine)

**SKIP entirely on Path 4 (Remote MCP).** Transcript ingest shells out to the
local `secondbrain` CLI which Path 4 doesn't install when the user picked 4d-B
("remote MCP only"). When 4d-A (local PGLite for code) was picked, ingest is
still optional but useful: surface the prompt below.

For Paths 1, 2a, 2b, 3 (and Path 4 with PGLite code search enabled):

After memory engine is initialized but before persisting the CLAUDE.md config
(Step 8), offer to bring this Mac's coding-agent transcripts +
curated `~/.vibestack/` artifacts into secondbrain so the retrieval surface
has data to surface.

Probe the current state inline (federation/cross-machine sync is intentionally
out of scope — this is single-machine ingest only):

```bash
TRANS_ROOT="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/sessions"
if [ -d "$TRANS_ROOT" ]; then
  TOTAL_FILES=$(find "$TRANS_ROOT" -name '*.jsonl' -type f 2>/dev/null | wc -l | tr -d ' ')
  TOTAL_BYTES=$(du -sk "$TRANS_ROOT" 2>/dev/null | awk '{print $1*1024}')
else
  TOTAL_FILES=0; TOTAL_BYTES=0
fi
echo "Probe: $TOTAL_FILES transcript files, $TOTAL_BYTES bytes total."
```

If `$TOTAL_FILES = 0`, skip — there's nothing to ingest. Set
`vibe-config set transcript_ingest_mode incremental` silently and continue
to Step 8.

If `$TOTAL_FILES < 200` AND `$TOTAL_BYTES < 100000000` (100MB): silent bulk
ingest, then set `transcript_ingest_mode=incremental`:

```bash
find "$TRANS_ROOT" -name '*.jsonl' -type f 2>/dev/null | while IFS= read -r f; do
  TITLE="session-$(basename "$f" .jsonl)"
  secondbrain put "$TITLE" < "$f" 2>/dev/null || true
done
vibe-config set transcript_ingest_mode incremental
```

Otherwise (the "many transcripts on disk" path): AskUserQuestion with the
exact counts AND the value promise. Default scope is **current repo only,
last 90 days**:

> "Found <N_repo> transcripts in THIS repo (<repo-slug>) over the last
> 90 days, totalling <bytes>. Ingest into secondbrain?
>
> What you get: every vibestack skill auto-loads recent salience from your
> past sessions in this repo, so the agent finds your prior work without you
> describing it. You can query 'what was I doing on day X' and get a real
> answer. Per-session pages are searchable, taggable, and deletable.
>
> What stays the same: nothing leaves this machine — vibestack does not sync
> secondbrain across machines. Per-repo trust policies still apply.

Options:
- A) Yes — this repo, last 90 days (recommended)
- B) Yes — this repo, ALL history
- C) Skip historical, track new from now (`transcript_ingest_mode=incremental`)
- D) Never ingest transcripts (`transcript_ingest_mode=off`)

After answer:
```bash
vibe-config set transcript_ingest_mode "<choice>"
```

Reference doc for users: `setup-memory/memory.md` (linked from CLAUDE.md
Step 8).

---

## Step 8: Persist ## Memory Configuration in CLAUDE.md

Find-and-replace (or append) the section in CLAUDE.md. Block format depends on
mode:

### Path 4 (Remote MCP)

```markdown
## Memory Configuration (configured by /setup-memory)
- Mode: remote-http
- MCP URL: {MCP_URL}
- Server version: secondbrain v{SERVER_VERSION}  (from Step 4c verify)
- Setup date: {today}
- MCP registered: yes (user scope)
- Token: stored in ~/.claude.json (do not commit; never written to CLAUDE.md)
- Memory sync: off (vibestack does not sync across machines)
- Current repo policy: {read-write|read-only|deny|unset}
```

The bearer token is **never** written to CLAUDE.md (CLAUDE.md is checked in
to git in many projects). It lives only in `~/.claude.json` where
`claude mcp add` placed it.

### Paths 1, 2a, 2b, 3 (Local stdio)

```markdown
## Memory Configuration (configured by /setup-memory)
- Mode: local-stdio
- Engine: {pglite|postgres}
- Config file: ~/.secondbrain/config.json (mode 0600)
- Setup date: {today}
- MCP registered: {yes/no}
- Memory sync: {off|artifacts-only|full}
- Current repo policy: {read-write|read-only|deny|unset}
```

**After Step 9 (smoke test) passes, also write the `## Memory Search Guidance`
block** so the coding agent learns when to prefer `secondbrain` over Grep.
This block is gated on the smoke test passing — write the Configuration block
first (so the user knows what state they're in even if the smoke test fails),
then return here after Step 9 and write the guidance block only if smoke
test succeeded.

When Step 9 passes, find-and-replace (or append) this block. Use HTML-comment
delimiters so removal regex is unambiguous and never eats user content. The
block content is machine-agnostic — no engine type, no page counts, no
last-sync time. Machine state stays in the Configuration block above.

```markdown
## Memory Search Guidance (configured by /setup-memory)
<!-- vibestack-memory-search-guidance:start -->

Secondbrain is set up on this machine. The agent should prefer secondbrain
over Grep when the question is semantic or when you don't know the exact
identifier yet. Available via the `secondbrain` CLI and the `mcp__secondbrain__*`
tools:
- This repo's code (registered as `vibestack-code-<repo>` source when imported).
- `~/.vibestack/` curated memory (registered as `vibestack-memory-<user>` source).

Prefer secondbrain when:
- "Where is X handled?" / semantic intent, no exact string yet:
    `secondbrain search "<terms>"` or `secondbrain query "<question>"`
- "Where is symbol Y defined?" / symbol-based code questions:
    `secondbrain code-def <symbol>` or `secondbrain code-refs <symbol>`
- "What calls Y?" / "What does Y depend on?":
    `secondbrain code-callers <symbol>` / `secondbrain code-callees <symbol>`
- "What did we decide last time?" / past plans, retros, learnings:
    `secondbrain search "<terms>" --source vibestack-memory-<user>`

Grep is still right for known exact strings, regex, multiline patterns, and
file globs. Re-run `/setup-memory` to refresh state.

<!-- vibestack-memory-search-guidance:end -->
```

If Step 9 smoke test fails, skip the guidance block write entirely. The user's
next `/setup-memory` run will re-evaluate capability and write the block when
the round-trip works.

---

## Step 9: Smoke test

### Path 4 (Remote MCP)

The `mcp__secondbrain__*` tools aren't visible mid-session — they're loaded at
Claude Code session start. So the live smoke test in this same skill run is
informational: print the curl-equivalent the user can run after restarting
Claude Code. The verify round-trip in Step 4c already proved the server is
reachable + authed + on a compatible MCP version, so we don't re-test that.

Print to stdout:

```
After restarting Claude Code, the `mcp__secondbrain__*` tools become callable.
Smoke test: ask the agent to run `mcp__secondbrain__search` with any query
("test page" works). You should see a JSON list of pages.

To verify from the shell right now (without waiting for restart):
  curl -s -X POST -H 'Content-Type: application/json' \
       -H 'Accept: application/json, text/event-stream' \
       -H 'Authorization: Bearer <YOUR_TOKEN>' \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
       <YOUR_MCP_URL>
```

Do NOT print the actual token in the curl command — leave the placeholder
`<YOUR_TOKEN>` so the snippet is safe to copy into chat / share.

### Paths 1, 2a, 2b, 3 (Local stdio)

```bash
SLUG="setup-memory-smoke-test-$(date +%s)"
echo "Set up on $(date). Smoke test for /setup-memory." | secondbrain put "$SLUG"
secondbrain search "smoke test" | grep -i "$SLUG"
```

Confirms the round trip. On failure, surface `secondbrain doctor --json` output and STOP.

---

## Step 10: GREEN/YELLOW/RED verdict block (idempotent doctor output)

After Steps 1-9 complete, summarize. Re-running `/setup-memory` on a configured
Mac is a first-class doctor path: every step detects existing state, repairs
only what's missing, and reports here.

```bash
# Re-detect to surface fresh state (matches the Step 1 detection block —
# accept any compliant brain MCP name, strip trailing colon, infer mode from
# the (HTTP) marker).
_BRAIN_LINE=$(claude mcp list 2>/dev/null | awk '/^(memex|secondbrain):[[:space:]]/{print; exit}')
SBRAIN_MCP_NAME=$(printf '%s\n' "$_BRAIN_LINE" | awk '{name=$1; sub(/:$/, "", name); print name}')
SBRAIN_MCP_MODE=$(printf '%s\n' "$_BRAIN_LINE" | awk '{print (tolower($3)=="(http)")?"remote-http":"local-stdio"}')
[ -z "$_BRAIN_LINE" ] && { SBRAIN_MCP_NAME=""; SBRAIN_MCP_MODE=""; }
TRANSCRIPT_INGEST=$(vibe-config get transcript_ingest_mode 2>/dev/null || echo "off")
MEMORY_SYNC=$(vibe-config get memory_sync_mode 2>/dev/null || echo "off")
```

Pick the right verdict template based on `SBRAIN_MCP_MODE`. Each row is
`[OK]/[FIX]/[WARN]/[ERR]`.

### Path 4 (Remote MCP)

Substitute `{SBRAIN_MCP_NAME}` with the detected MCP name (e.g. `memex` or
`secondbrain`) so the verdict reflects what's actually registered. The
`mcp__*__*` tool prefix follows the same name.

```
{SBRAIN_MCP_NAME} status: GREEN  (mode: remote-http)

  MCP ............. OK   {SBRAIN_MCP_NAME} v{SERVER_VERSION} at {MCP_URL}
  Auth ............ OK   bearer accepted (verified via /tools/list)
  Engine .......... N/A  remote mode
  Doctor .......... N/A  remote mode (brain admin runs the engine's own doctor)
  Repo policy ..... OK   {read-write|read-only|deny}
  Memory sync ..... OK   {memory_sync_mode}
  Transcripts ..... {OK|N/A declined at Step 4d}
  Code search ..... {OK local-pglite (~/.secondbrain/pglite) | N/A declined at Step 4d}
  CLAUDE.md ....... OK
  Smoke test ...... INFO printed for post-restart manual verification

Restart Claude Code to pick up the `mcp__{SBRAIN_MCP_NAME}__*` tools.
Re-run `/setup-memory` any time the bearer rotates or the URL moves.
```

### Paths 1, 2a, 2b, 3 (Local stdio)

```
secondbrain status: GREEN  (mode: local-stdio)

  CLI ............. OK   <secondbrain version>
  Engine .......... OK   <pglite|postgres> at <path>
  doctor .......... OK
  MCP ............. OK   registered (user scope)
  Repo policy ..... OK   <read-write|read-only|deny>
  Code import ..... OK   <last_imported_head>
  Memory sync ..... {OK|off}
  Transcripts ..... <N> sessions, last ingest <when> (or "off")
  CLAUDE.md ....... OK
  Smoke test ...... OK   put → search → delete round-trip

Run `/setup-memory` again any time secondbrain feels off; it's safe and idempotent.
```

If any row is YELLOW or RED, the verdict line says so and the failing rows
surface a one-line "next action" (e.g.,
`Engine .......... ERR  PGLite corrupt — \`rm -rf ~/.secondbrain/pglite\` and re-run \`/setup-memory\``).

---

## `/setup-memory --cleanup-orphans`

Re-collect a PAT (Step 4 path-2a scope disclosure), then:

```bash
export SUPABASE_ACCESS_TOKEN="<collected from read -rs>"
projects=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  https://api.supabase.com/v1/projects)
```

Parse the response, identify any project named starting with `secondbrain` whose
`ref` doesn't match the user's active `~/.secondbrain/config.json` pooler URL.
For each orphan, AskUserQuestion per project: "Delete orphan project
`<ref>` (`<name>`, created `<created_at>`)?" — NEVER batch; per-project
confirm is a one-way door.

On confirmed delete:
```bash
curl -s -X DELETE -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/$REF"
```

Never delete the active brain without a second explicit confirmation.

At end: `unset SUPABASE_ACCESS_TOKEN`. Revocation reminder.

---

## `/setup-memory --resume-provision <ref>`

Re-collect a PAT, then poll until healthy using the saved `$INFLIGHT_REF`:

```bash
until curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$INFLIGHT_REF" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('status')=='ACTIVE_HEALTHY' else 1)" 2>/dev/null; do
  sleep 5
done
```

Then fetch the pooler URL and continue from memory init (`secondbrain init`) onward.

---

## Important Rules

- **One rule for every secret.** PAT, DB_PASS, pooler URL: env-var only,
  never argv, never logged, never persisted to disk by us. The only file
  that holds the pooler URL long-term is `~/.secondbrain/config.json`, written
  by the secondbrain CLI's own `init` at mode 0600.
- **STOP points are hard.** Memory doctor not healthy, PATH shadow, migrate
  timeout, smoke test failure — each is a STOP. Do not paper over.
- **Concurrent-run lock.** Release `~/.vibestack/.setup-memory.lock.d` on
  normal exit AND in the SIGINT trap.
- **CLAUDE.md is the audit trail.** Always update it in Step 8 after a
  successful setup.
- **Never log secrets.** No `SUPABASE_ACCESS_TOKEN`, `DB_PASS`, pooler URL,
  or any `postgresql://` substring in output or logs.
