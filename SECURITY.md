# Security & Trust

vibekit syncs configuration into `~/.claude/`, `~/.cursor/`, and `~/.kiro/` and
can run optional helpers. This document explains what runs, what it can reach,
and the trade-offs in the shipped defaults so you can make an informed choice
before installing.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository, or contact the
maintainer directly. Please do not file public issues for sensitive reports.

## Trust model

### The install one-liner

```bash
bash -c "$(curl -fsSL timurgaleev.github.io/vibekit/install.sh)"
```

This downloads and executes a script over the network. It is convenient but
gives the host (GitHub Pages) the ability to run code as your user. If you
prefer to inspect before running:

```bash
git clone https://github.com/timurgaleev/vibekit.git
cd vibekit
less install.sh        # review
./install.sh -n        # preview the diff, writes nothing
./install.sh           # apply
```

`-n` (preview) writes nothing — use it first on any machine you care about.

### `Bash(*)` auto-allow + `acceptEdits`

`claude/settings.json` ships `permissions.allow: ["Bash(*)"]` with
`defaultMode: "acceptEdits"`. This is a deliberate low-friction default for the
maintainer's own workflow: Claude can run shell commands and apply edits without
prompting. The `deny` list blocks a set of obviously destructive commands, but a
blocklist is **defense-in-depth, not a sandbox** — it can be bypassed.

If you sync vibekit to your own machine and want tighter control, edit
`~/.claude/settings.json` after install:
- Remove `"Bash(*)"` from `permissions.allow` to be prompted per command.
- Change `defaultMode` from `acceptEdits` to a prompting mode.

The sync deep-merges settings and preserves your `permissions.allow` additions,
but `defaultMode` is taken from the repo — re-apply your preference after a sync,
or fork and change the shipped value.

### Caveman skill (`-C`, opt-in, off by default)

`./install.sh -C` runs a third-party installer
([JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)). To avoid
silently executing whatever lands on the upstream `main` branch, the default
installer URL is **pinned to a specific commit**:

```
https://raw.githubusercontent.com/JuliusBrussee/caveman/25d22f864ad68cc447a4cb93aefde918aa4aec9f/install.sh
```

- Pinning means upstream changes are not pulled in until this repo bumps the SHA.
- To bump: replace the SHA in `install.sh` (`CAVEMAN_INSTALL_URL` default) after
  reviewing the upstream diff between the old and new commit.
- To use a different source (latest `main`, a fork, a mirror), override at runtime:
  `CAVEMAN_INSTALL_URL=<url> ./install.sh -C`.
- Requires Node >= 18; if missing, the step warns and skips without aborting.

Note: Caveman's own installer may self-update on later runs — review upstream
before enabling it on sensitive machines.

### deliberation plugin (`-D`, opt-in, off by default)

`./install.sh -D` installs a third-party plugin
([antonbabenko/deliberation](https://github.com/antonbabenko/deliberation))
through the `claude plugin` CLI. Like Ponytail it tracks the marketplace repo's
default branch — there is no commit-SHA pin, so review upstream before enabling
it on a sensitive machine.

- The flag installs the plugin and stops there. The plugin's `/deliberation:setup`
  is what writes `~/.claude/rules/deliberation/` (~12k tokens loaded in every
  session) and `~/.config/deliberation/config.json`; vibekit runs neither, and
  never edits an existing config or turns on a paid provider.
- **No key ever enters this repo.** The plugin's bridges read credentials from
  the environment (`XAI_API_KEY`, `OPENROUTER_API_KEY`) or from a provider CLI's
  own login. Export them from a shell profile that is not synced to cloud
  storage, and rotate any key that has been pasted into a chat.
- Once installed, the plugin can send the prompt — and, for providers that read
  the repo, file contents — to OpenAI, Google, xAI or OpenRouter. Treat it as an
  outbound channel and do not point it at a repository you may not share.
- Override the marketplace source with `DELIBERATION_REPO=<owner/repo>`.

### RTK (on by default, skip with `-R`)

`./install.sh` runs the third-party RTK installer
([rtk-ai/rtk](https://github.com/rtk-ai/rtk)) via `curl -fsSL ... | sh` unless
you pass `-R` (or `RTK=false`). RTK is a standalone Rust binary; the install is
idempotent — if `rtk` is already on `PATH` the download is skipped.

- The installer tracks the **latest tagged release** by default (no commit-SHA
  pin, unlike Caveman). It verifies SHA-256 checksums of the downloaded archive.
- Pin a known release with `RTK_VERSION=vX.Y.Z ./install.sh`, or point
  `RTK_INSTALL_URL` at a fork, mirror, or pinned ref to vet the script first.
- `rtk init -g` modifies `~/.claude/settings.json` (adds a `PreToolUse` hook)
  and writes `RTK.md` + a `rtk-rewrite.sh` hook script. The hook rewrites Bash
  commands to `rtk` equivalents before they run, so RTK sees your shell command
  output locally. Remove with `rtk init -g --uninstall`.
- If the installer or `rtk init` fails, the step warns and skips without
  aborting the sync.

### File deletion during sync

Since v1.6.0 `install.sh` deletes files, not just writes them. The scope is
bounded on several sides:

- Only paths recorded in the previous sync's manifest
  (`~/.local/state/vibekit/manifest_<target>`) are eligible. Anything you
  installed yourself was never recorded and is left alone.
- Manifest entries that are absolute or contain `..` are rejected, so a
  corrupted manifest cannot name a path outside the target.
- Each candidate is additionally resolved **physically** before deletion: if a
  symlinked directory component would land the delete outside the deploy
  directory, it is refused and reported. A lexical path check alone does not
  catch this.
- Files that vibekit merges rather than owns (`claude/CLAUDE.md`,
  `codex/config.toml`, `codex/hooks.json`, `cursor/hooks.json`,
  `codex/rules/default.rules`, `kiro/agents/default.json`)
  are deliberately never recorded in the manifest, so they can never be pruned —
  they hold runtime state the repo does not own.
- Filenames containing a newline are skipped rather than recorded, since the
  manifest is newline-delimited.

Preview every deletion first with `./install.sh -n`.

One cleanup is hard-coded rather than manifest-driven: a short list of files
earlier versions shipped and later dropped, removed once so machines that never
had a manifest also lose them. Because there is no ownership record for those,
each entry carries a content fingerprint — a file at the same path whose content
differs from the version vibekit shipped is kept and reported, not deleted.

Merges are written through a temporary file in the destination directory and
renamed into place, so an interrupted or failing write cannot leave a truncated
config behind; on failure the destination is left unchanged and the run reports
it.

## What is NOT in this repo

- No secrets, tokens, or API keys are committed. Token references are
  environment-variable lookups or documentation placeholders.
- Personal infrastructure references are kept out of the public config; the
  memory-MCP guidance is generic ("configure your own backend").
