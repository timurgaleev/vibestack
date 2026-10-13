# Configuration reference

The pack has two halves. `./install` installs the skills; `./install
--with-config` also deploys the always-on configuration described here —
`CLAUDE.md`, the behaviour rules, the sub-agents and the statusline — into
`~/.claude`, `~/.cursor`, `~/.kiro`, `~/.codex` and `~/.copilot`. `--only=config` runs that
half alone, and `./uninstall --with-config` removes it again.

The payload lives under `config/` in this repository: `config/claude/`,
`config/cursor/`, `config/kiro/`, `config/codex/` and `config/copilot/`, one directory per
destination. Everything on this page is optional — the defaults work out of the
box, so reach for it only when you want to change something.

## Status line

A custom status bar rendered in the Claude Code UI, showing real-time session info:

```
project  feature/xxx *  Opus 4  12.5K / 3.2K  $0.45  2m30s  17:00  +42 -15  62%
```

Shows: project name, git branch, model, token usage, cost, session time, token
reset timer, diff stats, and context-window usage.

Two environment variables tune it:

| Variable | Default | Meaning |
|----------|---------|---------|
| `CLAUDE_TOKEN_RESET_HOURS` | `5` | Length of the token window; `0` disables the timer |
| `CLAUDE_STATUSLINE_STATE_DIR` | `~/.claude/statusline` | Where the window-start timestamp is kept |

## Codex CLI

`config/codex/` deploys to `~/.codex/`. Codex loads no `rules/` directory, so
`AGENTS.md` has to be self-contained — every rule inlined, not pointed at. It is
**generated** from `config/claude/CLAUDE.md` + `config/claude/rules/` by
`scripts/gen-codex-agents.py`; edit those, not `AGENTS.md`. A project-root
`AGENTS.md` still wins over it.

Two files there are rewritten by Codex itself, so the sync merges instead of
overwriting:

| File | How it syncs |
|------|--------------|
| `config.toml` | Adds only tables and keys you do not already have. Project trust, TUI state, and any value you changed are preserved. |
| `rules/default.rules` | Replaces only the region between `# BEGIN vibekit managed codex rules` and `# END …`. Prefix rules Codex appended when you approved a command live outside the markers and survive. |
| `hooks.json` | Adds only missing keys. |

`kiro/agents/default.json` uses the same add-only-missing merge.

## Copilot CLI

`config/copilot/` deploys to `${COPILOT_HOME:-~/.copilot}/`. The skills
themselves install separately, into `${COPILOT_HOME:-~/.copilot}/skills/` (or
`.github/skills/` with `--scope=project`), and Copilot invokes them as `/name`.

| File | How it syncs |
|------|--------------|
| `copilot-instructions.md` | **Generated** from `config/claude/CLAUDE.md` + `config/claude/rules/` by `scripts/gen-codex-agents.py --target copilot`, self-contained like Codex's `AGENTS.md`. Replaces only the region above its own end marker (`<!-- END vibekit-managed copilot-instructions.md … -->`); lines you add below it survive every sync, and uninstall strips only the managed region. |
| `agents/*.agent.md` | **Generated** from every `config/claude/agents/*.md` (except `README.md`) by `scripts/gen-copilot-agents.py`. `name`, `description` and `tools` carry over; `model` is dropped, since Claude tier names are not Copilot model ids. Whole files, owned by the manifest. |
| `hooks/vibestack.json` | Whole file, owned by the manifest. Wires `/careful` and `/freeze` into Copilot's `PreToolUse` and the context snapshot into `PreCompact`. Each command exits silently when the script it calls is not installed. |
| `settings.json` | Adds only missing keys. It carries exactly one, `"includeCoAuthoredBy": false` — Copilot otherwise defaults it to `true` and adds an AI co-author trailer to every commit it makes. A value you already set is kept, and `./uninstall --with-config` restores or drops the key through the same pre/post snapshots as the other merged files. |

`config.json` in that directory is never read or written: it is Copilot's own
internal state (auth, trusted folders, plugins), and the setting keys it
contains are ignored by Copilot anyway.

Copilot hooks are user-level, not scoped to a skill, so the `hooks:` frontmatter
that drives `/careful` and `/freeze` in Claude Code is inert there. Once
`hooks/vibestack.json` is deployed, **`/careful` is always on** under Copilot —
every destructive command asks, whether or not you invoked the skill. `/freeze`
still enforces only while `~/.vibestack/freeze-dir.txt` exists. The hook file
installs only with `--with-config` or `--only=config`; a skills-only install
leaves both instruction-only. A crash in a hook script counts as a deny under
Copilot, and a hook that runs past its timeout fails open.

Copilot also reads `~/.agents/skills` (when `COPILOT_HOME` is unset), so a
Codex-only install already exposes the skills there — without the hook file,
the instructions or the agents.

## Pruning removed files

Every sync writes the list of files it manages to
`~/.local/state/vibekit/manifest_<target>`. The next sync deletes anything that
was in the previous manifest but is no longer in the repo — so a rule dropped upstream
stops loading on your machine instead of lingering forever.

Files that are not in the manifest were installed by you (hand-written skills,
vendored packs) and are never touched. `./install --with-config -n` lists what would be
pruned without deleting anything.

## Cursor editor settings

Cursor stores editor settings at an OS-specific path, so the configuration phase doesn't
write them automatically:

```bash
# macOS
cp cursor/settings.json ~/Library/Application\ Support/Cursor/User/settings.json
# Linux
cp cursor/settings.json ~/.config/Cursor/User/settings.json
```

`./install --with-config` warns you when this file has changed and needs re-applying.

## Caveman skill (`-C`, opt-in)

[Caveman](https://github.com/JuliusBrussee/caveman) compresses agent output
(`/caveman`, `/caveman-commit`, …). It is **not vendored** — `./install -C` runs
Caveman's own installer, pinned to a specific upstream commit (override with
`CAVEMAN_INSTALL_URL`). Requires Node >= 18; if missing, the step warns and
skips. See [`SECURITY.md`](../SECURITY.md) for the trust model.

## Ponytail plugin (`-Y`, opt-in)

[Ponytail](https://github.com/DietrichGebert/ponytail) steers the agent toward
minimal, stdlib-first code (the "best code is the code you never wrote"). It is
**not vendored** — `./install -Y` installs it through the official
`claude plugin` CLI (`marketplace add DietrichGebert/ponytail` + `install
ponytail@ponytail`). Override the source with `PONYTAIL_REPO`. Requires the
`claude` CLI; if missing, the step warns and skips. Unlike Caveman it tracks the
marketplace repo's default branch (no commit-SHA pin). Restart Claude Code after
install to load it.

## deliberation plugin (`-D`, opt-in)

[deliberation](https://github.com/antonbabenko/deliberation) delegates a second
opinion to GPT (via the Codex CLI), Gemini, Grok or an OpenRouter model over MCP,
with seven expert personas and the `/deliberation:ask-all` and
`/deliberation:consensus` commands. It is **not vendored** — `./install -D`
installs it through the `claude plugin` CLI (`marketplace add
antonbabenko/agent-plugins` + `install deliberation@antonbabenko`). Override the
source with `DELIBERATION_REPO`. Requires the `claude` CLI; if missing, the step
warns and skips.

Installing is all the flag does. Configuration stays manual: run
`/deliberation:setup` inside Claude Code when you want it. That command writes
four rule files into `~/.claude/rules/deliberation/` — roughly 12k tokens loaded
in **every** session — and seeds `~/.config/deliberation/config.json`. vibekit
never runs it, never edits that config, and never stores a provider key; each
provider reads its own credentials from the environment (`codex login`, the `agy`
CLI for Gemini, `XAI_API_KEY`, `OPENROUTER_API_KEY`). Routing lives in
`claude/rules/skills.md`. See [`SECURITY.md`](../SECURITY.md) for the trust model.

## RTK (`-R` to skip, on by default)

[RTK](https://github.com/rtk-ai/rtk) ("Rust Token Killer") is a standalone Rust
CLI that compresses shell-command output before it reaches the model. Unlike
Caveman and Ponytail it is **on by default** within that phase — `./install --with-config` installs it via
`curl | sh` and runs `rtk init -g` to apply the Claude Code `PreToolUse` hook.
The install is idempotent: if `rtk` is already on `PATH` the binary download is
skipped and only the hook is refreshed. Init runs **after** the `settings.json`
merge so the RTK hook survives every sync.

The Claude projection ships an `attribution` object (empty `commit` and `pr`,
`sessionUrl` false, so the harness adds no co-author trailer or PR footer) and a
`PreCompact` hook that runs `vibe-compact-snapshot` (a silent no-op when that
bin is not installed). That hook writes the git
state and the transcript path — never its contents — to
`~/.vibestack/projects/<slug>/compact-snapshots/` before each compaction, keeping
the 10 newest; `VIBESTACK_COMPACT_SNAPSHOT=0` turns it off. The settings merge
is per hook event: it sets `PreCompact` and keeps every other event a tool added
there, such as RTK's `PreToolUse`.

- Skip entirely with `-R` (or `RTK=false`).
- The installer tracks the latest tagged release and verifies SHA-256
  checksums. Pin with `RTK_VERSION=vX.Y.Z`; override the source with
  `RTK_INSTALL_URL`.
- Restart Claude Code after install to load the hook. Remove it with
  `rtk init -g --uninstall`. See [`SECURITY.md`](../SECURITY.md) for the trust
  model.
