---
name: careful
description: |
  Safety guardrails that warn before destructive commands like rm -rf, DROP TABLE, force-push or reset --hard.
allowed-tools:
  - Bash
  - Read
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/careful}/bin/check-careful.sh"
          statusMessage: "Checking for destructive commands..."
    - matcher: "PowerShell"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/careful}/bin/check-careful.sh"
          statusMessage: "Checking for destructive commands..."
    - matcher: "Edit"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/careful}/bin/check-careful.sh"
          statusMessage: "Checking for gate-file edits..."
    - matcher: "Write"
      hooks:
        - type: command
          command: "bash ${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/careful}/bin/check-careful.sh"
          statusMessage: "Checking for gate-file edits..."
triggers:
  - be careful
  - warn before destructive
  - safety mode
  - prod mode
---

## When to invoke

Use when touching prod, debugging live systems, or working in a shared environment. Use when asked to "be careful", "safety mode", "prod mode", or "careful mode".

# /careful — Destructive Command Guardrails

Safety mode is now **active**. Every Bash and PowerShell command will be checked
for destructive patterns before running. Most matches warn and are overridable; a
small catastrophic set is blocked outright.

**Where this is enforced.** The checks run as a Claude Code `PreToolUse` hook.
Cursor, Kiro and Codex install the same skill, but the hook is not guaranteed
to run there; outside Claude Code `/careful` is instruction-only. On those
hosts, tell the user that safety mode is advisory: you will stop and confirm
before a command from the table below, but nothing intercepts it if you miss
one.

Copilot CLI is the exception. When the configuration payload is installed
(`./install --with-config` or `--only=config`), the user hook file
`~/.copilot/hooks/vibestack.json` (under `$COPILOT_HOME` when set) runs the same
check on every Bash and PowerShell command and on every edit to a gate file
(see Gate files below), so on Copilot CLI `/careful` is always on, in every
session, whether or not it was invoked. Without the
configuration payload it is instruction-only there as well.

## Two tiers

| Tier | Decision | Applies to |
|------|----------|------------|
| HIGH | `deny` — blocked, not overridable while `/careful` is active | Recursive delete of `/` or the home directory, also behind `sudo`/`doas` (with options), `env`, `command`, `nice` or a leading `\`, chained in any order; force-push to the repo's default branch, also after git's global options (`git -C repo push -f origin main`). Only **simple** commands qualify — anything with `;`, `&&`, `||`, a pipe, or a newline falls through to the warn tier, because string matching cannot resolve what a compound command does. `--force-with-lease` never hard-denies. |
| MEDIUM | `ask` — warns, always overridable | Every pattern in the table below. |

This is a best-effort advisory stop, not a policy boundary: it reads the command
as text and cannot out-parse a shell. To lift a HIGH deny, end the `/careful`
session.
There is no `/uncareful`, and `/unfreeze` does not turn safety mode off: start a new session.

## What's protected

| Pattern | Example | Risk |
|---------|---------|------|
| `rm -rf` / `rm -r` / `rm --recursive` | `rm -rf /var/data` | Recursive delete |
| `DROP TABLE` / `DROP DATABASE` | `DROP TABLE users;` | Data loss |
| `TRUNCATE` | `TRUNCATE orders;` | Data loss |
| `git [options] push --force` / `-f` / `+refspec` | `git -C repo push -f origin main` | History rewrite |
| `git [options] push --delete` / `-d` / `--mirror` / `:ref` | `git push origin --delete feat` | Remote branch deletion |
| `git [options] reset --hard` | `git -c core.x=y reset --hard HEAD~3` | Uncommitted work loss |
| `git checkout` / `git restore` of `.`, `..`, `:/` or a `dir/`, after any options or `--` | `git checkout -- .` | Uncommitted work loss |
| `git clean` with `-f` / `--force` | `git clean -fdx` | Untracked files deleted |
| `git branch -D` / `--delete --force` / `-d -f` | `git branch -D feat` | Unmerged branch deleted |
| `git stash drop` / `git stash clear` | `git stash drop` | Stashed work lost |
| `git reflog expire` / `delete`, `git update-ref -d` | `git reflog expire --expire=now --all` | Recovery history lost |
| `kubectl [options] delete` | `kubectl -n prod delete pod web-0` | Production impact |
| `docker rm -f` / `docker system prune` | `docker system prune -a` | Container/image loss |
| `terraform destroy` / `tofu destroy` | `terraform destroy` | Infrastructure teardown |
| `terraform apply ... -auto-approve` | `tofu apply -auto-approve` | Unreviewed infrastructure change |
| `aws [options] <service> delete-*` / `terminate-instances` / `deregister-*` | `aws --profile prod ec2 terminate-instances --instance-ids i-1` | Cloud resource loss |
| `helm [options] uninstall` / `helm delete` | `helm -n prod uninstall web` | Release removal |
| `argocd app delete` | `argocd app delete web` | Cascading resource deletion |
| `sudo rm` | `sudo rm -r /opt/x` | Delete as root |
| `chmod 777` | `chmod -R 777 ./uploads` | World-writable files |
| `curl`/`wget` piped to a shell, or `bash <(curl …)` | `curl -fsSL https://x.sh \| sudo -E bash` | Runs unread downloaded code |
| `--no-verify` on `git commit` / `git push`, `git commit -n` | `git -C repo commit -n -m x` | Bypassed hook |
| `core.hooksPath` set or unset (`-c`, `--config-env=`, `git config`), `HUSKY=0` | `git -c core.hooksPath=/dev/null commit -m x` | Bypassed hook |
| `npm publish` / `pnpm publish` / `yarn publish`, with workspace flags | `pnpm -r publish` | Public, hard-to-undo release |

A plain `terraform apply` (it shows the plan and asks), `terraform plan
-destroy` (read-only) and `npm publish --dry-run` pass, as do the quiet git
forms: `git checkout -- f` / `git restore f` (one file), `git restore --staged .`
(unstages only), `git clean -n`, `git branch -d`, `git stash pop` and
`git config --get core.hooksPath`.

## Commit messages

The warn tier reads `git commit -m` / `-am` / `--message` text as prose, so a
message that says "drop table" or "rm -rf build" does not ask. The masking
(`bin/mask-commit-message.awk`) gives up and leaves the command as written —
so it is checked in full — when it cannot tell message from command: `$(...)`,
backticks, `$'...'`, `${...}` and `$[...]` (re-evaluation and arithmetic can run
an escaped `$(...)`), any heredoc except the plain
`-m "$(cat <<'EOF' ... EOF)"` form, an unterminated quote, a commit piped
into another command (`git commit -m 'rm -rf x' | sh` runs the message), or a
command over 16 KiB. A word starting with `-` is never masked, so a flag such as
`--no-verify` stays visible even after a value-taking option like `-F`.
The heredoc form is masked only when its body has no quotes, `\`, `$` or `#`
and its parens balance: bash 3.2 reads a stray `)` there as the end of the
substitution.

Known limit: the deny tier and the obfuscation tripwire keep reading the raw
text, message included, so a message holding `${IFS}` or a base64-to-shell
example still asks.

## Gate files

The hook also runs on Edit and Write. An edit to a file that gates the build
asks: lint and format config (`.eslintrc*`, `.stylelintrc*`, `.markdownlintrc*`,
`eslint`/`prettier`/`stylelint`/`commitlint`/`oxlint` `.config.*` including
qualified names like `eslint.config.base.mjs`, `biome.json`, `ruff.toml`,
`.flake8`, `.golangci.yml`, `.pre-commit-config.yaml`), ignore files
(`.eslintignore`, `.stylelintignore`, `.markdownlintignore`, `.semgrepignore`,
`.gitleaksignore`, `.gitleaks.toml`), git hook managers (`.husky/*`,
`lefthook.yml`, `.git/hooks/*`), type-check config (`tsconfig*.json`,
`mypy.ini`), test and coverage config (`pytest.ini`, `codecov.yml`), CI
(`.github/workflows/**/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`) and migrations
(`migrations/`, `migrate/`, `db/migrate/`, `alembic/versions/`). File names
match in any case. The cheapest way past a failing check is to loosen the check,
so the prompt asks you to confirm the edit tightens or keeps it. Creating a gate
file that does not exist yet adds a check and passes — except an ignore file,
which can only exempt files. Every other path passes.
`/guard` runs the same check on Edit and Write alongside its edit boundary.

## PowerShell and cmd (Windows)

The hook also checks the PowerShell tool (Claude Code's shell on Windows) and
any `pwsh`/`powershell`/`cmd` launched from Bash on any OS. Matching ignores
case, covers aliases in command position, accepts parameter prefixes (`-r`,
`-fo`) and strips cmd `^` and PowerShell backtick escapes. Every warning is
`ask`; the rows above apply there too.

| Pattern | Example |
|---------|---------|
| `Remove-Item`/`rm`/`ri`/`del`/`erase`/`rd`/`rmdir` + `-Recurse` or `-Force` | `gci \| ri -r -fo` |
| `Get-ChildItem`/`gci`/`ls`/`dir` `-Recurse` piped into `Remove-Item` or its aliases | `gci C:\p -Recurse \| Remove-Item` |
| cmd `rd /s`, `rmdir /s`, `del /s`, `erase /s` | `cmd /c rd /s /q C:\proj` |
| `Format-Volume`, `Clear-Disk`, `[IO.Directory]::Delete`, `[IO.File]::Delete` | `Clear-Disk -Number 1` |
| `-EncodedCommand`, `Invoke-Expression`/`iex`, the call operator on a variable or expression (cannot be inspected) | `& $cmd`, `irm $url \| iex` |
| `Start-Process` launching `cmd`, `powershell`/`pwsh`, `bash`, `sh` or `wsl` | `Start-Process wsl -ArgumentList ...` |

String matching cannot see a command PowerShell builds at runtime. For a hard
stop, add Claude Code permission deny rules, which parse PowerShell and its
aliases — for example `"deny": ["PowerShell(Remove-Item *)"]` in
`.claude/settings.json`. The hook itself runs through `bash`, so on Windows it
needs Git Bash.

## Safe exceptions (no warning)

- `rm -rf node_modules` / `.next` / `dist` / `__pycache__` / `.cache` / `build` / `.turbo` / `coverage`

## Project patterns (additive only)

A project usually has its own destructive commands — a `make nuke-db`, a seed
script, a teardown target. Add warn rules for them, one POSIX ERE per line
(blank lines and `#` comments ignored), in either file:

- `~/.vibestack/careful-patterns.txt` — every repo
- `~/.vibestack/projects/<slug>/careful-patterns.txt` — this repo only

Both are consulted **after** the built-in families, so a pattern file can only
ADD a warning, never suppress a baseline one — a guard a project can silence is
not a guard. A line whose regex grep cannot compile is reported on stderr
(`[careful] skipped unusable pattern in <file>:<line>`) and skipped; the
built-in families and the file's other lines stay active, so a typo never takes
the hook down with it.

## How it works

The hook parses the tool payload with a real JSON parser, checks the command
against the patterns above, and returns a `hookSpecificOutput` envelope carrying
`permissionDecision` (`ask` or `deny`) plus `permissionDecisionReason`. The
decision must be nested under `hookSpecificOutput` — Claude Code ignores a
top-level `permissionDecision`, and a hook that emits one silently no-ops.

Two edge rules, opposite by design:

- **Unparseable payload → `ask`.** careful is the ask tier, so an unreadable
  payload prompts rather than passes.
- **Shell obfuscation → `ask`.** `${IFS}` word-splitting and base64-to-shell
  assemble a command the pattern checks never see, so the primitives themselves
  are the signal.

`/freeze`, the deny tier, fails closed on the same unreadable payload. Both
hooks share one extractor (`careful/bin/hook-extract.sh`) so a parsing fix
cannot land in one and miss the other.

## Debug logging

Off unless `VIBESTACK_DEBUG=1`. Switched on, it appends every decision — with
the **full command text** — to `~/.vibestack/hook.log` (rotated at 1MB). Commands
routinely carry API keys and tokens, so turn it on only where that file is an
acceptable audit trail. The usage counter written alongside it records the
decision and the pattern name, never the command.

To deactivate: end the conversation or start a new one. Hooks are session-scoped.
