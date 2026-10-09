# vibe-upgrade migrations

Step 4.75 of `/vibe-upgrade` runs every `v{VERSION}.sh` in this directory whose
version is newer than the one being upgraded from, in version order, after the
new version has installed successfully. Use a migration only for state that
`./install` cannot fix on its own: a renamed state file, a moved directory, a
config key that changed meaning.

Contract for a migration script:

- Name it `v{VERSION}.sh`, where `{VERSION}` is the release that needs it.
- Start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Read the install directory from `VIBESTACK_INSTALL_DIR` (set by the upgrade;
  it may be a project-local copy, not the global checkout) and state from
  `${VIBESTACK_HOME:-$HOME/.vibestack}`. Never assume a fixed clone path.
- Refuse to run when `VIBESTACK_INSTALL_DIR` is empty:
  `: "${VIBESTACK_INSTALL_DIR:?}"`.
- Be idempotent: a second run must change nothing.
- Only touch vibestack's own files. A failure is reported as a warning and does
  not roll the upgrade back, so leave state usable if you stop partway.
