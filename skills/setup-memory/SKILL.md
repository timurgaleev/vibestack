---
name: setup-memory
description: |
  Set up persistent memory for this coding agent using secondbrain: install the CLI,
  initialize a local PGLite or Supabase brain, register MCP, capture per-remote
  trust policy. One command from zero to "persistent memory is running and this
  agent can call it." Use when: "setup memory", "setup secondbrain", "connect secondbrain",
  "start secondbrain", "install secondbrain", "configure memory for this machine".
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

---

## Step 2: Pick a path (AskUserQuestion)

Only fire this if Step 1 shows no existing working config AND no shortcut
flag was passed. The question title: "Where should your brain live?"

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
- **Switch** (only if Step 1 detected an existing engine): "You already have
  a `<engine>` brain. Migrate it to the other engine?" → runs
  `secondbrain migrate --to <other>` wrapped in `timeout 180s`.

Do NOT silently pick; fire the AskUserQuestion.

---

## Step 3: Install memory CLI (secondbrain)

Only if `SBRAIN_ON_PATH=false`:

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

If yes, register the secondbrain binary at **user scope** with an **absolute path**.
User scope makes the MCP available in every Claude Code session on this machine,
not just the current workspace.

```bash
SBRAIN_BIN=$(command -v secondbrain)
[ -z "$SBRAIN_BIN" ] && SBRAIN_BIN="$HOME/.bun/bin/secondbrain"
# Remove any existing local-scope registration to avoid conflicts
claude mcp remove secondbrain 2>/dev/null || true
claude mcp add --scope user secondbrain -- "$SBRAIN_BIN" serve
claude mcp list | grep secondbrain
```

If `claude` is not on PATH: emit "MCP registration skipped — register `secondbrain serve`
in your agent's MCP config manually." Continue to step 6.

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

## Step 8: Persist ## Memory Configuration in CLAUDE.md

Find-and-replace (or append) this section in CLAUDE.md:

```markdown
## Memory Configuration (configured by /setup-memory)
- Engine: {pglite|postgres}
- Config file: ~/.secondbrain/config.json (mode 0600)
- Setup date: {today}
- MCP registered: {yes/no}
- Memory sync: {off|artifacts-only|full}
- Current repo policy: {read-write|read-only|deny|unset}
```

---

## Step 9: Smoke test

```bash
SLUG="setup-memory-smoke-test-$(date +%s)"
echo "Set up on $(date). Smoke test for /setup-memory." | secondbrain put "$SLUG"
secondbrain search "smoke test" | grep -i "$SLUG"
```

Confirms the round trip. On failure, surface `secondbrain doctor --json` output and STOP.

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
