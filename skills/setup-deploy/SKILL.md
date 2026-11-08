---
name: setup-deploy
description: |
  Configure /land-and-deploy: detect the platform, production URL and health checks; save to CLAUDE.md.
triggers:
  - configure deploy
  - setup deployment
  - set deploy platform
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

If this session was compacted, the copy of this skill in context may be cut off.
Read `${CLAUDE_SKILL_DIR}/SKILL.md` from disk and resume at the step you are on.

## When to invoke

Use when: "setup deploy", "configure deployment", "set up land-and-deploy", "how do I configure deploys".

## Preamble

```bash
eval "$("${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-slug" 2>/dev/null)" 2>/dev/null || SLUG="unknown"
_LEARN_FILE="${VIBESTACK_HOME:-$HOME/.vibestack}/projects/${SLUG:-unknown}/learnings.jsonl"
if [ -f "$_LEARN_FILE" ]; then
  _LEARN_COUNT=$(wc -l < "$_LEARN_FILE" 2>/dev/null | tr -d ' ')
  echo "LEARNINGS: $_LEARN_COUNT entries loaded"
  if [ "$_LEARN_COUNT" -gt 5 ] 2>/dev/null; then
    "${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-search" --limit 5 2>/dev/null || true
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
When the user types `/setup-deploy`, run this skill.

## Instructions

### Step 1: Check existing configuration

```bash
grep -A 20 "## Deploy Configuration" CLAUDE.md 2>/dev/null || echo "NO_CONFIG"
```

If configuration already exists, show it and ask:

- **Context:** Deploy configuration already exists in CLAUDE.md.
- **RECOMMENDATION:** Choose A to update if your setup changed.
- A) Reconfigure from scratch (overwrite existing)
- B) Edit specific fields (show current config, let me change one thing)
- C) Done — configuration looks correct

If the user picks C, stop.

### Step 2: Detect platform

Run the platform detection from the deploy bootstrap:

```bash
# Platform config files
[ -f fly.toml ] && echo "PLATFORM:fly" && cat fly.toml
[ -f render.yaml ] && echo "PLATFORM:render" && cat render.yaml
[ -f vercel.json ] || [ -d .vercel ] && echo "PLATFORM:vercel"
[ -f netlify.toml ] && echo "PLATFORM:netlify" && cat netlify.toml
[ -f Procfile ] && echo "PLATFORM:heroku"
[ -f railway.json ] || [ -f railway.toml ] && echo "PLATFORM:railway"

# GitHub Actions deploy workflows
for f in $(find .github/workflows -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null); do
  [ -f "$f" ] && grep -qiE "deploy|release|production|staging|cd" "$f" 2>/dev/null && echo "DEPLOY_WORKFLOW:$f"
done

# Project type
[ -f package.json ] && grep -q '"bin"' package.json 2>/dev/null && echo "PROJECT_TYPE:cli"
find . -maxdepth 1 -name '*.gemspec' 2>/dev/null | grep -q . && echo "PROJECT_TYPE:library"
```

When more than one `PLATFORM:` line prints, a repo often carries leftovers from an
earlier host. Ask which one serves production — one option per detected platform, plus
"none of these" (go to Custom / Manual) — and configure only that one.

Confirm the project type before going on: a `PROJECT_TYPE:` line is a guess (a web app
can ship a `bin` for its own tooling), and no line means nothing was detected. Ask web
app / API / CLI / library, with the detected type as the recommendation.

### Step 3: Platform-specific setup

Based on what was detected, guide the user through platform-specific configuration.

#### Fly.io

If `fly.toml` detected:

1. Extract app name: `grep -m1 "^app" fly.toml | sed 's/app = "\(.*\)"/\1/'`
2. Check if `fly` CLI is installed: `which fly 2>/dev/null`
3. If installed, verify: `fly status --app {app} 2>/dev/null`
4. Infer URL: `https://{app}.fly.dev`
5. Set deploy status command: `fly status --app {app}`
6. Set health check: once the production URL is confirmed (below), probe its `/health`:
   ```bash
   _C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 '<PRODUCTION_URL>/health' 2>/dev/null) || _C=000
   echo "FLY_HEALTH_PROBE: $_C"
   ```
   Record `/health` only when the probe answers 2xx. A 404 means the app has no such
   route — record the root URL instead. A 5xx or `000` is a failing or unreachable route,
   not a missing one: report the code and ask whether to record `/health` anyway, record
   the root URL, or fix the app first.

Ask the user to confirm the production URL. Some Fly apps use custom domains.

#### Render

If `render.yaml` detected:

1. Extract service name and type from render.yaml
2. Check for Render API key: `[ -n "${RENDER_API_KEY:-}" ] && echo "RENDER_API_KEY: set" || echo "RENDER_API_KEY: not set"`.
   Never print any key bytes, not even a prefix (see rule 4 under third-party actions).
3. Infer URL: `https://{service-name}.onrender.com`
4. Render deploys automatically on push to the connected branch — no deploy workflow needed
5. Set health check: the inferred URL

Ask the user to confirm. Render uses auto-deploy from the connected git branch — after
a merge into that branch, Render picks it up automatically. The "deploy wait" in
/land-and-deploy should poll the Render URL until it responds with the new version.

#### Vercel

If vercel.json or .vercel detected:

1. Check for `vercel` CLI: `which vercel 2>/dev/null`
2. If installed: `vercel ls --prod 2>/dev/null | head -3`
3. Ask whether the project is connected to the repo (Vercel project settings → Git).
   Vercel deploys on push — preview on PR, production on merge into the production
   branch — only when the Vercel project is connected to this Git repository. Not
   connected: the deploy trigger is the command the user runs (e.g. `vercel --prod`).
4. Set health check: the production URL from vercel project settings

#### Netlify

If netlify.toml detected:

1. Extract build settings from netlify.toml — it does not name the site's URL
2. Ask for the production URL and confirm it (the `*.netlify.app` name or a custom domain)
3. Netlify deploys automatically on push when the site is linked to the repo; confirm that.
   If the user says it is not linked, the deploy trigger is manual: ask for the command
   (e.g. `netlify deploy --prod`) and record it, or record `manual` when there is none
4. Set health check: the confirmed production URL

#### Heroku / Railway

A `Procfile` or `railway.json`/`railway.toml` gets no dedicated flow. Continue with
Custom / Manual below, with the platform prefilled (`heroku` or `railway`) and confirmed
as the first answer.

#### GitHub Actions only

If deploy workflows detected but no platform config:

1. Read the workflow file to understand what it does
2. Extract the deploy target (if mentioned)
3. Ask the user for the production URL
4. Set deploy status command, naming that one workflow so other workflows' runs never
   answer for it: `gh run list --workflow <file> --json headSha,status,conclusion`

#### Custom / Manual

If nothing detected, use AskUserQuestion to gather the information:

1. **How are deploys triggered?**
   - A) Automatically on push to the default branch (Fly, Render, Vercel, Netlify, etc.)
   - B) Via GitHub Actions workflow
   - C) Via a deploy script or CLI command (describe it)
   - D) Manually (SSH, dashboard, etc.)
   - E) Not deployed yet — stop here and write nothing; run /setup-deploy again once
     production exists
   - F) Never deploys (library, CLI, tool) — record `none` for the platform, URL,
     trigger, status and health check, skip questions 2 and 3, and go to Step 4

   On E, stop: no Deploy Configuration is written, because a guessed one is what
   /land-and-deploy would trust. When this run is reconfiguring, offer to remove the existing `## Deploy Configuration` section
   too — it no longer describes production — and keep it only if the user says so.

2. **What's the production URL?** (Free text — the URL where the app runs)

3. **How can /land-and-deploy check if a deploy succeeded?**
   - A) HTTP health check at a specific URL (e.g., /health, /api/status)
   - B) CLI command (e.g., `fly status`, `kubectl rollout status`)
   - C) Check the GitHub Actions workflow status
   - D) No automated way — just check the URL loads

4. **Any pre-merge or post-merge hooks?**
   - Commands to run before merging (e.g., `bun run build`)
   - Commands to run after merge but before deploy verification

### Step 4: Write configuration

**Collect what is missing.** Walk the block below and ask for every field not yet confirmed
by the user — a detected value is a recommendation, not an answer.

**Default branch and merge method** come from the repo's settings:

```bash
_RV=$(gh repo view --json defaultBranchRef,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed \
  --jq '"DEFAULT_BRANCH: " + (.defaultBranchRef.name // ""), "MERGE_METHODS_ALLOWED: " + ([(if .squashMergeAllowed then "squash" else empty end), (if .mergeCommitAllowed then "merge" else empty end), (if .rebaseMergeAllowed then "rebase" else empty end)] | join(" "))' 2>/dev/null) || _RV=""
if [ -n "$_RV" ]; then
  printf '%s\n' "$_RV"
else
  # Ask the remote first: a cached origin/HEAD does not follow a renamed default branch.
  _DB=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
    git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p')
  [ -n "$_DB" ] || { _DB=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); _DB="${_DB#origin/}"; }
  echo "DEFAULT_BRANCH: ${_DB:-unknown}"
  echo "MERGE_METHODS_ALLOWED: unknown"
fi
```

Offer only the methods on the `MERGE_METHODS_ALLOWED:` line; with exactly one, confirm
it instead of asking. `unknown` or an empty list means the settings could not be read:
say so and ask among `squash`, `merge` and `rebase`. A `DEFAULT_BRANCH:` that is empty
or `unknown` is asked for, never assumed; the answer fills `{default branch}`.

**Confirm before writing.** Show the complete block exactly as it will be written, every
placeholder filled, and ask:

- A) Write it
- B) Change a field (then show the block again)
- C) Cancel — write nothing

Only on A: read CLAUDE.md (or create it). Find and replace the `## Deploy Configuration`
section if it exists, or append it at the end.

```markdown
## Deploy Configuration (configured by /setup-deploy)
- Platform: {platform}
- Production URL: {url}
- Deploy workflow: {workflow file or "auto-deploy on push"}
- Deploy status command: {command or "HTTP health check"}
- Merge method: {squash/merge/rebase}
- Project type: {web app / API / CLI / library}
- Post-deploy health check: {health check URL or command}

### Custom deploy hooks
- Pre-merge: {command or "none"}
- Deploy trigger: {command or "automatic on push to {default branch}"}
- Deploy status: {command or "poll production URL"}
- Health check: {URL or command}
```

A project that never deploys (Custom / Manual option F) writes `none` on every line
from Platform to Health check except Merge method, Project type and Pre-merge (a library
can still have a pre-merge build or test):
`- Platform: none`, `- Production URL: none`, `- Deploy trigger: none`, and so on.

### Step 5: Verify

After writing, verify the configuration works (skip a check whose field is `none`):

1. If a health check URL was configured, try it:
```bash
curl -sf "{health-check-url}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "UNREACHABLE"
```

2. If a deploy status command was configured, try it:
```bash
_OUT=$({deploy-status-command} 2>&1); _RC=$?; printf '%s\n' "$_OUT" | head -5; [ "$_RC" -eq 0 ] || echo "COMMAND_FAILED (exit $_RC)"
```

A `COMMAND_FAILED` status command is not recorded as verified: /land-and-deploy
trusts what is written in CLAUDE.md, so ask the user to fix the command or leave
the deploy-status line out of CLAUDE.md.

3. Read back the merge method you wrote:
```bash
grep -i '^[[:space:]]*-[[:space:]]*Merge method:' CLAUDE.md | head -1
```
It must name exactly one of `squash`, `merge` or `rebase`. /land-and-deploy stops
with `MERGE_METHOD_UNKNOWN` on anything else, the unfilled `{squash/merge/rebase}`
placeholder included, so fix the line before finishing.

Report results. If a health check failed, note it but don't
block — the config is still useful even if the health check is temporarily
unreachable.

### Step 6: Summary

```
DEPLOY CONFIGURATION — COMPLETE
════════════════════════════════
Platform:      {platform}
URL:           {url}
Health check:  {health check}
Status cmd:    {status command}
Merge method:  {merge method}

Saved to CLAUDE.md. /land-and-deploy will use these settings automatically.

Next steps:
- Run /land-and-deploy to merge and deploy your current PR
- Edit the "## Deploy Configuration" section in CLAUDE.md to change settings
- Run /setup-deploy again to reconfigure
```

## Third-Party Web Actions

Configuring deploys means vendor dashboards — minting an API token, creating a
project, wiring a webhook or a domain verification. Those actions happen on
someone else's site, with the user's real account, so they get their own rules:

1. **Check for an automatable path before handing over a checklist.** Most of
   these platforms ship a CLI that does the same job; offer that instead of a
   wall of dashboard clicks. Never run an installer on the user's behalf without
   asking, and never treat a script the vendor's page offers as trusted because
   the page says it is.
2. **One explicit question before any action on a vendor site.** Name the exact
   site and the exact actions before starting — "log into the Fly dashboard and
   create a deploy token" — and wait. Consent for one vendor is not consent for
   the next.
3. **Passwords, payment details, MFA codes and CAPTCHAs stay with the human.**
   Hand the session back for those steps and pick up afterwards. Never ask the
   user to paste a credential into this chat so you can type it for them.
4. **A captured secret never appears in chat, logs, or shell history.** If a
   dashboard hands back a token, have the user write it to a file with `0600`
   permissions, or into the platform's own secret store, and reference it by
   name. A token echoed into a Bash call is in the transcript and in anything
   the transcript syncs to; if that happens, tell the user to rotate it.
5. **Stop at anything that spends money or is hard to undo.** Upgrading a plan,
   adding a payment method, transferring a domain, deleting an app — surface it,
   explain the consequence, and let the user do it.

## Important Rules

- **Never expose secrets.** Don't print full API keys, tokens, or passwords.
- **Confirm with the user.** Always show the detected config and ask for confirmation before writing.
- **CLAUDE.md is the source of truth.** All configuration lives there — not in a separate config file.
- **Idempotent.** Running /setup-deploy multiple times overwrites the previous config cleanly.
- **Platform CLIs are optional.** If `fly` or `vercel` CLI isn't installed, fall back to URL-based health checks.

## Capture Learnings

If you discovered a non-obvious platform quirk, deployment pattern, or configuration
gotcha during this session, log it for future sessions:

```bash
"${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-learnings-log" '{"skill":"setup-deploy","type":"TYPE","key":"SHORT_KEY","insight":"DESCRIPTION","confidence":N,"source":"SOURCE","files":["path/to/relevant/file"]}'
```

**Types:** `pattern` (reusable approach), `pitfall` (what NOT to do), `preference`
(user stated), `architecture` (structural decision), `operational` (environment/CLI/workflow).

**Only log genuine discoveries.** Don't log obvious things. A good test: would this
insight save time in a future session?
