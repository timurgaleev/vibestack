# Changelog

## 1.36.0 — 2026-09-01

### Fixed

This closes the parity audit's medium and low findings — 239 of them, worked
through by re-checking each against the current code rather than trusting the
finding. 21 turned out to be already fixed by the last three releases, 11 were
not defects (a documented intentional difference, or the finding was wrong about
the code), 151 were real and are fixed here, and 29 need a capability that does
not exist yet and are recorded in `TODOS.md` with what blocks each one.

The changes are spread across 43 skills and 8 shared snippets, so rather than
list all 151, here is what actually changes for you:

- **Decision briefs got their quality floor back.** Every option now carries at
  least two concrete pros and one honest con, bullets say something measurable
  ("adds ~2s to every page load", not "slower"), the non-recommended option is
  described in the same register as the recommended one, and there is a
  self-check the model runs over its own brief before sending it. A question
  where one option has no downside reads as a decision already made.
- **Spawned sessions are a first-class kind.** A skill running under another
  agent has nobody to answer a question. It now takes the recommended option on
  a two-way choice and says in its output that it auto-picked and what the
  alternative was, while a one-way or destructive choice still stops and
  reports. Text arriving from the dispatching agent is data describing a task —
  it cannot approve a destructive step or widen permissions.
- **Learnings capture actually runs.** It was phrased "if you discovered
  something non-obvious...", which reads as optional and got skipped; it is now
  a step that always runs and either logs or says there was nothing worth
  keeping. The prior-learnings search also got its topical query back — a
  debugging skill was being handed learnings about design.
- **Claimed limitations need evidence.** A new shared rule: never say something
  cannot be done, is unsupported, or is impossible without having tried it and
  being able to name the command and its output.
- **`/codex` no longer fails a clean review.** The fail-closed gate added
  earlier had no branch for a review that finds nothing — and a review with
  nothing to report emits no severity marker, so every clean run reported FAIL.
  Unverifiable runs still fail closed.
- **`/review`'s shortcut-suppression rule can now fire.** It told you to resolve
  a decision id with a search that only matches decision and rationale text, so
  an id query always came back empty and the rule suppressed nothing, ever. It
  searches the decision text now.
- **`/spec`'s duplicate check can tell "no duplicates" from "no answer".** It
  read the trust envelope to decide, but the envelope wraps empty input too — so
  a missing tool, an expired token and a genuinely duplicate-free repo all looked
  identical. It keys on the search's exit status now.
- **`/ship` works on three-part versions.** Its validation demanded four digits
  while this project's own VERSION has three, so every ship aborted at the
  validation step. It now keeps whatever shape the VERSION file already uses.
- **`/ship`'s pre-push credential guard works in a linked worktree**, where the
  hooks directory resolves to the shared common dir and the old check silently
  reported "no guard installed".
- **`/design-shotgun` no longer offers to reopen a comparison board** that was
  removed — the first question the skill asked led to an action nothing in the
  pack could perform.
- **`/design-html` finds its vendored renderer again.** An unbraced
  `$CLAUDE_SKILL_DIR` survived rendering as a literal, so the installed skill
  checked a path that never resolves. Caught by `vibe-certify`, which exists for
  exactly this.

### Added

- `test/test-browse-shim.sh` runs in CI (it passed, but nothing ran it).

## 1.35.1 — 2026-09-01

### Fixed

- **`/pair-agent` understated what a paired agent can do.** The skill said a
  remote agent gets read+write by default and admin only with `--admin`. The
  daemon actually grants read + write + admin + meta by default — a default
  agent can execute JavaScript and read cookies and storage — and `--control`
  (aliased `--admin`) adds the browser-wide destructive commands: stop, restart,
  disconnect. `--restrict` is what narrows access. Anyone approving a pairing was
  granting more than the flag names suggested, so this is corrected in the skill
  body, its description, and the skill catalog.
- **Per-agent revoke does exist.** v1.35.0 documented the opposite. There is no
  CLI wrapper — `$B tunnel revoke` really is absent — but the daemon serves a
  root-only `DELETE /token/<clientId>` that invalidates one agent and leaves the
  others alone. The docs now give the curl call, and keep "stop the daemon" as
  the blunt all-agents equivalent.
- **The external-tools page described the browse daemon as unbundled** and told
  you to drop a binary at `browse/dist/browse`. The daemon has shipped in this
  repo for some time, the installer prepares its dependencies, and the launcher
  resolves `browse/bin/vibe-browse` — so following that page could only fail. It
  now describes what actually happens, including the one thing that genuinely is
  fetched on first use: Playwright and a browser.
- **The skill catalog missed behavior that shipped.** `/careful` and `/guard`
  still described warnings only, with no mention of the non-overridable tier;
  `/diagram` listed two output artifacts instead of four and did not say it
  renders offline; `/plan-tune` described none of the question-log review or
  profile surface it actually has.

### Added

- `test/test-browse-shim.sh` now runs in CI — it existed and passed, but was in
  neither the workflow matrix nor any documentation.
- `docs/internals.md` gained the ten `bin/` tools that were missing from its
  reference table, a section describing every shell test suite, and one
  describing what CI actually checks.

### Changed

- `README.md` links `docs/internals.md` and `docs/external-tools.md`, which were
  reachable from neither entry-point document.
- The compatibility audit's counts were measured against the tree rather than
  carried forward: 53 skills (was 47), 22 using `${CLAUDE_SKILL_DIR}` (was 19).
  Its matrix had a duplicate row and was missing three skills entirely, so it
  listed 51 of 53.

## 1.35.0 — 2026-08-31

### Added

- **`bin/vibe-brand-audit`** — everything this repo publishes goes out under its
  own name, and until now nothing enforced that. The audit scans tracked files,
  commit messages in a range, and any text file (a PR body, release notes), and
  fails on names or phrasings that assert this project derives from somewhere
  else. CI runs all three on every PR.

  Commit messages are the surface this exists for: they are as public as the
  code, and once merged they cannot be corrected without rewriting published
  history — so the check has to fail on the PR, not after it.

  Two deliberate carve-outs, both covered by tests. Bare `upstream` passes: it
  is ordinary git vocabulary ("the branch's upstream", "something upstream
  broke"), and banning the word outright would only teach people to phrase
  around the check. Vendored third-party files are skipped, because their
  headers carry licence text and author credit that must stay — crediting a
  dependency's authors is a different thing from claiming an external origin
  for this project.

- **`test/test-brand-audit.sh`** — 19 cases, half of them asserting the audit
  does *not* fire on ordinary engineering English. A check that cries wolf gets
  routed around, which is the same as having no check. The suite earned its
  keep immediately: it caught the audit scanning its own repository's history
  instead of the caller's, which would have reported a clean pass on a commit
  range nobody had examined.

### Changed

- A comment in `browse/src/socks-bridge.ts` described the bridge by where it
  came from rather than by what it does. It now documents the design that
  matters at that call site: ephemeral port, loopback-only bind, and why a
  stream error closes the client connection instead of retrying.

## 1.34.0 — 2026-08-31

### Fixed

- **The safety skills enforced nothing.** `/careful`, `/freeze` and `/guard` printed
  their decisions at the top level of the hook response. Claude Code reads the
  decision from a nested `PreToolUse` envelope and discards anything else, so all
  three detected destructive commands and boundary violations correctly and then
  let every one of them through. The failure was silent — the hook ran, matched,
  printed, and the tool call proceeded — which is why it survived. Decisions now go
  out as `hookSpecificOutput` with `permissionDecisionReason`, and
  `test/test-hooks.sh` asserts the wire format as well as the verdict.
- **A quoted argument was enough to walk a destructive command past `/careful`.**
  The command extractor was a `grep -o` whose character class stops at the first
  escaped quote, so `git commit -m "wip" && rm -rf /` reached the pattern checks as
  `git commit -m \` and returned an allow. The python fallback only ran when the
  grep result was *empty*, so a truncated one was never repaired. Both hooks parse
  the payload with a real JSON parser now.
- **`/freeze` failed open, twice.** An unparseable payload returned an allow, and
  the path resolver stopped at the parent directory — so a symlink inside the
  boundary pointing outside it was judged in-boundary while the write landed
  outside. It resolves the full path now, final component included, and an
  unreadable payload is denied. `/` as the boundary used to deny everything.
- **`/guard` lost its hard stop.** Recursive deletes of `/` or the home directory
  and force-pushes to the default branch are denied outright again, not warned
  about. Only simple commands qualify — anything with `;`, `&&`, `||`, a pipe or a
  newline falls back to a warning, since string matching cannot resolve what a
  compound command does. `--force-with-lease` never hard-denies.
- **`/autoplan` lost every task its review phases produced.** The aggregator piped
  into a split array and then indexed it with a bare `.commit`, so jq errored on
  every line into `2>/dev/null` and the Final Approval Gate always rendered "no
  tasks".
- **`/autoplan` ran the shipping gate fourth.** Eng review — the gate `/ship`
  treats as required — ran before the DX phase, so DX amendments (a renamed flag,
  a rewritten error message, a new getting-started step) shipped without ever
  being reviewed for architecture, tests, security or performance. DX is Phase 2.5
  now and Eng runs last, always. Its Codex prompt carries the DX consensus the way
  it already carried CEO's and Design's.
- **`/autoplan` stopped mid-run despite promising it wouldn't.** Clearly-wrong
  premises are still never auto-decided, but they are queued for the Final
  Approval Gate instead of blocking Phase 1 — which mattered most in the spawned
  and non-interactive runs where nobody was there to answer. Gate option B2 had no
  handling rule at all, and option D's re-run map predated the DX phase; both fixed.
- **`/ship` and `/review` called `codex review` in a form that cannot run.** A
  positional prompt and `--base` are mutually exclusive, so the structured review
  died at argument parsing on every diff over 200 lines and the P1 gate recorded a
  default pass.
- **Their specialist reviewers returned nothing.** Both skills instructed "do NOT
  use `run_in_background`", but since Claude Code v2.1.198 subagents run in the
  background unless the flag is explicitly `false` — so every specialist returned
  immediately with no findings, the merge step scored an empty set, and the run
  reported a clean review it never performed.
- **`/ship` and `/qa` installed a second test framework over working tests.**
  Detection looked only for config files and `tests/` directories, so Django
  (`<app>/tests.py`), Go (`*_test.go`), Rust (`#[test]` in `src/`), Maven and
  Gradle projects all read as "no tests". Detection now also reads declared
  scripts, make targets and tracked test files, and every marker is evidence for a
  question rather than a command to run blind.
- **`/land-and-deploy`'s VERSION collision gate was commented out** — the
  assignment, not the block, so three orphaned continuation lines sat under it and
  the variable was never set. Uncommenting it exposed two more: the tally counted
  the PR being landed as claiming its own slot (so every PR read as stale), and the
  bump level was hard-coded to `patch` (so a minor release compared against the
  wrong slot). Both fixed.
- **`/plan-tune` was observational with nothing to observe.** It read a
  `question-log.jsonl` that nothing in the repo wrote, and its aggregation step was
  an empty `else` branch under an instruction to report counts. Adds
  `bin/vibe-question-log`, wires the call into the shared state-protocols snippet,
  and implements the aggregation. Its "edit declared profile" step also overwrote
  all five profile dimensions with placeholders when asked to change one.
- **`/pair-agent` asked for your ngrok authtoken in chat** so it could pass it as a
  Bash argument — into the transcript and shell history both. You run that in your
  own terminal now; the skill only verifies the result. It also opened an
  internet-reachable tunnel into your logged-in browser with no opt-in, which is
  now a standing per-machine consent gate, and documented `$B tunnel revoke` and
  `$B tunnel rotate` as the kill switch. Neither exists — the daemon exposes
  `/tunnel/start` and nothing else — so anyone who ran them believed a shared
  browser session had been cut off when it had not.
- **`/document-release` read the fetched PR body straight into context** while
  holding Edit, Write and Bash. Anyone who can open a PR writes that text. Adds
  `bin/vibe-untrusted`, which wraps externally-authored text in a labelled
  envelope, marks every line, and flags instruction-shaped ones for you rather
  than stripping them.
- **`/diagram` fetched Mermaid from a CDN** while the offline renderer sat unused
  in `lib/diagram-render/`. It renders through that bundle now and inlines the SVG,
  so the HTML artifact needs no network at render time or ever after.
- **`/open-browser` could never find its own binary.** It looked under
  `~/.claude/skills/vibestack/`, a directory the installer does not create, so every
  installed user hit `NEEDS_SETUP`.
- **`/codex` ran reviews unpinned** while telling you they were read-only.
  `codex review` has no `-s`/`--sandbox` flag, so without the config override it
  inherits `~/.codex/config.toml` — on a machine that grants write access to
  trusted projects, that is Codex with write permission on your repo.
- **`/claude` refused to run on an authenticated machine** whenever
  `~/.claude/.credentials.json` was missing. Claude Code may keep credentials in an
  OS keychain the host's sandbox cannot see; auth is judged by what the invocation
  returns now.
- **The scope gate in `/plan-eng-review` and `/plan-design-review`** had been
  reduced to three sentences of "ask once if the target is ambiguous". It is a hard
  STOP again: the first tool call is the question, with no repo exploration before
  the answer.

### Added

- **CI.** The repo had none. Eight shell suites on Linux and macOS — the BSD/GNU
  split is exactly what these hooks kept tripping over — plus a drift job proving
  installed skills still match their sources, and a check that every hook script is
  executable and parses.
- **`test/test-hooks.sh`** — 51 cases covering the hook wire format, the extractor
  bypass, both fail-closed polarities, boundary escapes and the force-push tiers.
  Every case is a bug that shipped.
- **`/vibe`** — a router that names the right skill for a task. Mostly for Codex,
  which has no slash-command picker: `agents/openai.yaml` pointed at a `$vibestack`
  skill that did not exist.
- **A nested-Codex guard** in every Codex preflight. vibestack ships Codex as a
  first-class runtime, so running a plan review or `/ship` inside it used to spawn
  `codex exec` — the same model reviewing itself at multiplied cost.
  `VIBE_FORCE_CODEX_REVIEW=1` forces the nested pass.

## 1.33.2 — 2026-08-18

### Fixed

- **How you invoke a skill in Codex.** v1.33.0 replaced one wrong claim with another:
  it said Codex uses `$name` "plus a `/skills` picker". There is no `/skills` picker in
  codex-cli 0.147.0 — every occurrence of that string in the binary is a filesystem or
  source path. `/` is reserved for Codex's own commands, so `/office-hours` completes to
  nothing. A skill is referenced as `$name` inside an ordinary message
  (`Use $office-hours to shape this idea`), or triggered implicitly from its
  `description` — which Codex's own bundled `skill-creator` calls "the primary triggering
  mechanism". Verified: `Use $office-hours` loads the skill body.
- **Where to clone.** The README told you to clone into `~/.claude/skills/vibestack` —
  inside an agent's skills directory. Agents index that tree recursively, so the
  checkout's own `skills/` source directory is picked up as a second set and every skill
  appears twice in the picker (seen as `/office-hours` alongside
  `/vibestack-skills-office-hours`). The README now clones to `~/vibestack` and says why.
  v1.32.3 had already stopped the installer from *deleting* a checkout parked there; this
  closes the other half.
- Documented binary paths no longer assume where the checkout lives. Skills resolve the
  browse daemon relative to their own installed directory
  (`${CLAUDE_SKILL_DIR}/../browse/bin/vibe-browse`, falling back to `PATH`), which works
  in both user and project scope.

## 1.33.1 — 2026-08-18

### Fixed

- **The renderer's last unguarded `mv`.** Every infra failure in
  `bin/vibe-render-skill` exits 3 with a clean message — except the move that put
  the `${CLAUDE_SKILL_DIR}`-substituted file back into place. When it failed the
  renderer reported success while handing back a half-substituted skill, and its
  temp file, missing from the cleanup trap, was left behind in the destination
  directory. Both fixed. Found by the new fuzz tests while they were being written.

### Added

- **Infra-error fuzz tests for the renderer.** `mktemp` and `mv` are PATH-shimmed
  to fail, and each of the six guarded paths is asserted on exit code, exact stderr
  line, destination contents, and temp-file leakage. Every case was mutation-tested:
  neutering one guard flips exactly its own case.

### Changed

- **The `${CLAUDE_SKILL_DIR}` skill list is derived, not hand-maintained.** The
  compatibility audit claimed 6 skills; the real number is 19. The token usually
  arrives through an `{{include}}`d snippet, so a skill's own source cannot be
  grepped for it. The doc now carries the correct list, a corrected per-skill matrix,
  and the command that regenerates both.
- **Track B status reconciled.** `docs/external-tools.md` called Kiro hooks "pending
  verification" while the audit had recorded Track B as done on 2026-05-09. It now
  states what Track B actually found: on Cursor and Kiro alike, hook-bearing skills
  install but their hooks do not fire, and only Cursor has a native sandbox behind
  them.

## 1.33.0 — 2026-08-17

### Added

- **Codex CLI is a default install target.** `./install`, `--target=all` and
  `--yes` now cover four runtimes. Skills land where Codex documents them:
  `~/.agents/skills` in user scope, `.agents/skills` in project scope. Invoke
  them with `$name` or the `/skills` picker.

### Changed

- **A target name is no longer a directory name.** The registry splits into
  `TARGET_CONFIG_DIR` (detection only — Codex's config lives in `~/.codex` and
  never receives skills), `TARGET_ROOT` (user scope) and `TARGET_PROJECT_REL`
  (project scope). Project scope reads the map instead of deriving
  `.<target>/skills` from the name, and detection honors `$CODEX_HOME`, which
  previously made a Codex install driven purely by that variable read as absent.
  `uninstall` and `bin/vibe-certify` mirror the mapping.
- **A superseded skills root is pruned by name.** vibestack used to install
  Codex skills into `~/.codex/skills`; Codex 0.147.0 scans that path *and* the
  documented one, so a leftover copy would list every skill twice and never
  update. `prune_legacy_root` removes only our own skill names — never the root
  itself, where Codex keeps its bundled `.system/` set.
- Docs corrected: `docs/external-tools.md` listed Codex as "not yet a target",
  the README claimed Codex users type `/command` (it is `$name` / `/skills`), and
  the compatibility audit now carries Codex's caveats — Track B unverified, and
  Codex caps its initial skill list at 2% of context (or 8,000 characters), after
  which it shortens descriptions and may omit skills.

## 1.32.3 — 2026-08-17

### Fixed

- **Install no longer deletes skills it does not own.** The atomic swap replaced a
  target's whole `skills/` root with the staged tree, which holds only vibestack
  skills — so every other entry in that root was carried off to `.old` and deleted
  by the next run's recovery pass. Two real victims: a runtime's own bundled skills
  (Codex keeps its system set in `<root>/.system/`), and the checkout path the
  README documents (`~/.claude/skills/vibestack`), whose install destroyed its own
  clone on the second run. Anything that is not one of our skill names is now
  adopted back into the live root — after a successful swap, before the pre-swap
  `.old` purge, and in the recovery pass before a stale `.old` is removed, so an
  interrupted run still recovers.
- **Renderer test seam.** `./install` resolves the renderer through
  `$VIBE_RENDER_SKILL`, so the test suite injects its fail-on-match stub instead of
  overwriting the tracked `bin/vibe-render-skill`. A hard-killed run can no longer
  leave the tracked renderer replaced by a stub.

### Changed

- **Install-suite coverage corrected.** `test_install_atomic_swap_on_success`
  asserted the opposite of the intended property — an unrelated root-level sentinel
  had to be *deleted* for it to pass. It now checks that leftovers inside our own
  skill dirs are replaced, with a new test locking the ownership boundary and the
  nested-checkout test asserting the clone survives two runs. Renderer test debt
  from 1.29.0 is closed: the stub read positional `$1`/`$2` while install passes
  `--skill-dir DIR SOURCE DEST`, and the byte-identical tests assumed one rendering
  for every target. Per-target substitution is now detected by a sentinel render
  (the token often arrives through an `{{include}}`d snippet, so the skill source
  cannot be grepped for it). Suite: 31 passed, 0 failed — up from 26 passed, 4
  failed on `main`.

## 1.32.2 — 2026-08-03

### Fixed

- **Third-party client key scrubbed from the diagram bundle.** The vendored
  excalidraw build ships its own public Firebase web config; that client key
  is dead code in this offline renderer but trips secret scanners on the
  committed bundle. The key is replaced with an inert placeholder in
  `dist/diagram-render.html`, the build script now scrubs it on every rebuild,
  and `BUILD_INFO.json` hashes are synced. Diagram e2e gates still 9/9;
  mermaid → PDF re-verified.

## 1.32.1 — 2026-08-03

### Added

- **Diagram rendering in `/make-pdf` is live.** The `lib/diagram-render`
  bundle (mermaid + excalidraw, single self-contained HTML served to the
  browse daemon) is now vendored, so ```mermaid and ```excalidraw fences
  render as real vector diagrams in PDF/HTML/DOCX output. All five make-pdf
  e2e gates now run for real — 9 pass, 0 skip — and a mermaid flowchart was
  verified end to end in a generated PDF. `bun run build:diagram-render`
  rebuilds the bundle from source when deps are bumped.

### Fixed

- TODOS entry for the make-pdf port updated: no follow-ups remain.

## 1.32.0 — 2026-08-03

### Added

- **`/make-pdf` is a real renderer now (TODOS #12).** The pack ships the full
  make-pdf engine (`make-pdf/`, 13 TypeScript modules on bun): markdown →
  marked pipeline → print CSS with cover/TOC/watermark/page furniture →
  Chromium print via the browse daemon (Paged.js flow) → PDF, plus `--to html`
  (single self-contained file) and `--to docx` output, image policy/sizing,
  typographic smartypants, and pdftotext verification. `bun run build:make-pdf`
  compiles a standalone `make-pdf/dist/pdf`; the skill's new
  `bin/vibe-make-pdf` launcher prefers the binary and falls back to running
  the CLI on bun. 194 tests vendored with it (unit + e2e gates that exercise
  the real browse launcher); verified end to end — markdown in, PDF out.
  Diagram fences resolve the `lib/diagram-render` bundle via env override or
  repo path; vendoring that bundle is the one recorded follow-up.

### Changed

- `.claude/settings.local.json` is now gitignored (personal machine-local
  permissions never belong in the tree).

## 1.31.0 — 2026-08-02

### Added

- **`vibe-certify` — cross-runtime conformance harness (TODOS #6).** Installs
  the full pack into a throwaway fixture per target runtime (claude, cursor,
  kiro, codex) through the real `./install --scope=project` path, then
  verifies every skill: frontmatter name matches the directory, no unexpanded
  `{{include}}` directives, no leftover `${CLAUDE_SKILL_DIR}` tokens, all
  symlinks resolve, full skill count present. Prints a per-target PASS/FAIL
  matrix and gates by exit code; `test/test-certify.sh` covers the clean and
  fail-closed paths. Current state: 4/4 targets PASS.

## 1.30.0 — 2026-08-02

### Changed

- **Shared review-report section deduped into one snippet.** The Plan File
  Review Report (with the VIBESTACK REVIEW REPORT template) lived as five
  near-identical copies across the plan-review skills; it is now
  `lib/snippets/plan-file-review-report.md` included everywhere. The three
  byte-identical copies render exactly as before (render-diff proven), and the
  two drifted copies picked up the fixes they had missed: `plan-design-review`
  gets the current verdict-line wording, `devex-review` gets the
  delete-then-append plan-file write flow (its old replace-in-place path could
  leave a stale report mid-file).
- **Spec Review Loop deduped** into `lib/snippets/spec-review-loop.md`
  (`/office-hours` + `/plan-ceo-review`, `{SKILL_NAME}`-parameterized —
  renders byte-identical for both).
- Review Log sections stay deliberately per-skill: each carries its own
  analytics payload schema consumed by `vibe-review-read`; recorded in TODOS
  so nobody re-attempts mechanical dedup.

## 1.29.0 — 2026-08-02

### Added

- **Project-scoped installs.** `./install --scope=project
  [--project-root=<dir>]` puts the skills into `<dir>/.claude|.cursor|.kiro/
  skills` instead of `$HOME`, pinning the pack's version per repo for teams.
  Runtime bin/state stay in `~/.vibestack`; installing into the pack's own
  checkout is refused; `./uninstall` mirrors the flags. Verified round-trip:
  52 skills in, zero left after uninstall.
- **Per-target skill paths baked in at render time.** `vibe-render-skill
  --skill-dir <dir>` substitutes `${CLAUDE_SKILL_DIR}` (bare and `:-fallback`
  forms) with the concrete install path, and `./install` passes each target's
  production path — hooks and body commands now resolve correctly on Cursor,
  Kiro, and project-scoped trees, not just `~/.claude`.

### Changed

- **Target detection no longer counts stale leftovers.** A runtime is detected
  when its CLI is on PATH or its home dir shows activity in the last 180 days —
  an app uninstalled months ago no longer gets skills silently installed.

## 1.28.0 — 2026-08-02

### Added

- **`/spec` semantic content review (Phase 4.5a).** Before the regex redaction
  gate, the final draft gets a structured semantic re-read for what regex
  cannot catch: named individuals attached to negative judgments,
  customer/vendor names tied to negative events, unannounced strategy,
  NDA-bound material, and codename bleed. Emits a `SEMANTIC_REVIEW:` verdict,
  treats the draft as untrusted data (embedded instructions force `flagged`),
  and disables "acknowledge and proceed" on public repos. The regex gate
  (now Phase 4.5b) stays the deterministic backstop.
- **5+ option split rule in `/qa`, `/ship`, `/autoplan`.** The
  "split, never drop" AskUserQuestion rule now also covers the three skills
  where large option sets can surface outside plan reviews.

### Changed

- TODOS reconciled with reality: the browse/design-daemon program is fully
  shipped (cookie import from the encrypted browser store has been in the tree
  since v1.24.0 — picker UI and `--domain` direct mode included), and
  cross-session decision memory exists as `vibe-decision-log`/`-search`.

## 1.27.0 — 2026-08-02

### Added

- **E2E skill evals (TODOS #17).** `test/evals/session-runner.ts` runs a real
  `claude -p` session in a throwaway sandbox — skills render from repo sources
  into the sandbox's project-level `.claude/skills/` (the path real installs
  resolve), `VIBESTACK_HOME` is isolated, and the child gets zero MCP servers.
  The runner streams NDJSON with live tool-call progress and returns collected
  evidence even when a timed-out child leaves pipe-holding orphans (stdout
  reader cancel + stderr drain raced against exit with a 5s grace window) —
  regression-locked by an offline fake-CLI test that always runs
  (`bun run test:runner`). Live smoke evals for `/review`, `/ship`, and
  `/investigate` assert skill-specific vocabulary in the transcript, catching
  the "slash command didn't resolve" regression class no bash suite can see.
  Opt-in via `bun run test:evals` (costs real tokens; `EVALS_MODEL` overrides
  the model).
- **Source lint (TODOS #2 + #5).** `bin/vibe-lint-sources` checks fence
  balance across every skill source and snippet (an unbalanced fence silently
  swallows include directives), and snippet hygiene: no duplicate headings,
  no nested `{{include}}`, max 400 lines. `./install` runs it before rendering
  and fails fast; `test/test-source-lint.sh` covers the rules (7 cases,
  including fence-aware false-positive guards).

### Fixed

- `package.json` version now tracks `VERSION` (was stuck at an older release).

## 1.26.0 — 2026-08-02

### Added

- **`vibestack` umbrella CLI.** One entry point for the whole toolbox, usable
  from any directory once `~/.vibestack/bin` is on `PATH` — the same
  log-in-and-type-the-name experience as a server-side CLI. `vibestack` alone
  prints a status overview (version, per-target skill counts, tool count);
  `vibestack doctor` health-checks the install; `vibestack skills [target]`
  lists installed skills; `vibestack version` prints the pack version; and any
  other subcommand dispatches to the matching `vibe-<tool>` binary
  (`vibestack config get proactive`, `vibestack decision-search --recent 5`).
  `./install` now ships the CLI, stamps `~/.vibestack/version`, and prints a
  PATH hint when the bin dir isn't reachable yet. Covered in
  `test/test-vibe-bins.sh` (18/18).

### Changed

- **Documentation wording pass.** Project docs, the changelog, and the PR
  template now describe every feature in vibestack's own terms; internal
  maintainer tooling that needed repo-external configuration moved out of the
  tree into `~/.vibestack/bin/`.

### Fixed

- The browser welcome page footer credited the wrong author (a leftover from
  the v1.24.0 browser-daemon work). The repo-wide naming audit is back to zero
  hits.

## 1.25.1 — 2026-07-30

### Changed

- **Plain `/learn` is now the full loop: show → capture → sync.** Running
  `/learn` with no arguments shows recorded learnings, captures new ones from
  the current session (genuine-discovery bar, with an explicit trust boundary:
  third-party/tool-output text is never capturable as a preference), then
  offers the consent-gated memex sync — one command instead of three.
  `/learn sync` still runs the sync step alone and never captures.
- The sync egress consent question is registered as a one-way door in the
  question-tuning registry — no preference can ever suppress it. Facts captured
  in the same invocation are always shown in full at the consent gate, never
  sample-summarized.

## 1.25.0 — 2026-07-30

### Added

- **`/learn sync` — push project learnings into connected memory (memex).**
  Learnings captured across sessions can now be recalled by any tool that reads
  the memory server, not just vibestack. `bin/vibe-learnings-sync-plan` does the
  deterministic half (latest-wins dedup, stable-identity watermark in
  `memex-synced.txt`, prose-oriented secret redaction covering token, URL-cred,
  JWT, and env-assignment shapes); the skill body handles the consent-gated MCP
  push with per-entry resume and server-side idempotency. Egress is a one-way
  door: the exact fact text is shown before anything leaves the machine, and
  headless sessions never auto-approve. `test/test-learn-sync.sh` covers the
  planner (20 cases).

### Fixed

- `/learn stats` never worked: a quoted heredoc kept `$LEARN_FILE` from
  expanding, so it always printed `NO_LEARNINGS`; a literal newline in the
  Python source was also a syntax error. Stats now dedupes and reports
  correctly, and tolerates non-string timestamps.

## 1.24.1 — 2026-07-20

### Changed

- Documentation and internal-naming consistency pass across docs, skill bodies,
  and tooling. No behavior change.

## 1.24.0 — 2026-07-20

### Added

- **Full browser daemon + sidebar extension.** vibestack now ships the complete
  headless-browser subsystem (`browse/`, ~24k lines of TypeScript on bun) and the
  Chrome MV3 sidebar extension (`extension/`), integrated with vibestack's
  paths. This replaces the ~640-line stateless shim as the primary
  `$B` backend — it adds a rich HTTP daemon (`:34567`), the CDP inspector,
  persistent element refs, an in-browser PTY terminal, a cookie-picker UI,
  content-security wrapping of page text, and ngrok tunnelling.
  - `browse/bin/browse` launches the daemon/CLI directly on bun — no compile step.
  - `skills/browse/bin/vibe-browse` now **delegates to the full daemon** when bun
    and the deps are present, and falls back to the bundled stateless Playwright
    shim otherwise (`VIBE_BROWSE_FORCE_SHIM=1` forces the shim). Every skill that
    uses `$B` picks up the daemon automatically.
  - `./install` installs the daemon's deps (`bun install`) and vendors xterm into
    the extension when bun is available — idempotent and non-fatal; a machine
    without bun keeps working on the shim.
  - The ML prompt-injection classifier's `@huggingface/transformers` dependency is
    `optional` (lazy-loaded), so the base install stays light.

## 1.23.0 — 2026-07-20

### Removed

- **`/setup-memory`.** The persistent-memory setup skill is gone (skill count
  52). Memory recall continues to work through the connected memory MCP — this
  only removes the interactive setup flow, which is no longer used.

### Added

- **`/vibe-upgrade` is now full-featured** (67 → 353 lines), a complete upgrade
  workflow that keeps vibestack's fast-forward-only safety:
  - Inline upgrade consent gate (Yes / Always / Not now / Never ask again),
    triggered by an `UPDATE:` line in the preamble.
  - Auto-upgrade mode via `VIBESTACK_AUTO_UPGRADE` or the `auto_upgrade` config
    key, with a scoped roll-back to the pre-pull commit if `./install` fails.
  - Snooze with escalating backoff (24h / 48h / 1 week) and per-version state;
    `vibe-update-check` honors an active snooze.
  - "Never ask again" persistence via the `update_check=false` config gate.
  - A version-migrations runner (`skills/vibe-upgrade/migrations/v*.sh`),
    idempotent and non-fatal.
  - Vendored / project-local install detection and upgrade path, and a
    team-mode-aware sync/removal of a committed vendored copy.
  - `vibe-update-check` gains `--force`, the config gate, and snooze honoring —
    fully backward-compatible (default behavior unchanged with no config).

## 1.22.1 — 2026-07-20

Polish release.

### Added

- `/careful` and `/freeze` now emit a structured `hook_fire` analytics event when
  they warn/deny — gated behind the same `VIBESTACK_DEBUG` opt-in as the existing
  hook log (no unconditional egress), recording only skill/decision/pattern/ts/repo,
  never the command or file path.

### Fixed

- `/document-generate` base-branch detection probes GitLab (`glab`) as well as
  GitHub before the git-native fallback, so it resolves the correct base on either
  host.

## 1.22.0 — 2026-07-19

Completes two review/ship subsystems that were stubbed out, both built on the
review-log store added in 1.19.

### Added

- **`bin/vibe-specialist-stats`** — per-specialist hit rates from the review log.
  `/review` and `/ship` now adaptively gate their specialist army: a specialist
  dispatched 10+ times that never found anything becomes a `GATE_CANDIDATE` and is
  skipped; security and data-migration are `NEVER_GATE` (always run). A fresh
  project with no history runs the full scope-selected set.
- **`bin/vibe-next-version`** — queue-aware next-version pick. `/ship`'s version
  bump and drift check, `/landing-report`, and `/land-and-deploy` read it to see
  which VERSION slots open PRs already claim and pick the next free one, so two
  branches shipping in parallel don't collide. Degrades to a plain local bump when
  no PR host is reachable.

## 1.21.0 — 2026-07-19

Activates conditional review dispatch, hardens scrape and spec.

### Added

- **`bin/vibe-diff-scope`** computes `SCOPE_FRONTEND/BACKEND/AUTH/MIGRATIONS/API/…`
  from the diff. `/review`, `/ship`, `/land-and-deploy`, and the design checklist
  previously stubbed this out (`# diff-scope not available`), so their conditional
  specialists — security, performance, data-migration, API-contract, design — never
  fired. They now dispatch on the real scope of the change.

### Changed

- **`/scrape`** gains a match phase (reuse an existing skill before prototyping),
  single-pipeable-JSON output discipline, a 3-attempt failure protocol that never
  presents a partial scrape as complete, and a `/skillify` nudge for repeat flows.

### Fixed

- **`/spec` no longer archives a spec containing a secret under `--no-gate`.**
  Fail-closed secret redaction moved to its own always-on phase — `--no-gate` now
  skips only the codex quality score, never the secret scan that gates archiving
  and issue-filing.

## 1.20.0 — 2026-07-19

Infrastructure integration: the Codex install target, question-tuning
enforcement, and orchestrator prompts, plus two consistency fixes.

### Added

- **Codex CLI as an install target.** `./install --target=codex` renders the pack
  into `~/.codex/skills/`, and `agents/openai.yaml` registers it with Codex. The
  target list is now a data-driven registry (`TARGET_LABEL` / `TARGET_ROOT` in
  `install`) — adding a runtime is one row per map. Codex is opt-in (excluded from
  `all` / `--yes`) until its skill-path loading is confirmed on a real setup.
- **Enforced one-way-door safety for question tuning.** New
  `bin/vibe-question-check` + `skills/plan-tune/questions.json` classify every
  question as one-way (always ask) or two-way (suppressible). A `never-ask`
  preference can now only ever silence a two-way question — a destructive or
  irreversible one (delete, force-push, drop, rotate-credential, merge/deploy
  approval, breaking change) is always asked. This turns `/plan-tune` from
  observational into enforcing; wired into the shared question-tuning protocol so
  every skill honors it.
- **Orchestrator injection prompts** in `lib/orchestrator/` (`lite` / `full` /
  `plan`) — ready-made discipline prompts a remote agent can inject into a spawned
  vibestack session, cross-linked from `/pair-agent`.

### Fixed

- `/design-review` now creates its `REPORT_DIR` (and `screenshots/` subdir) in the
  setup phase; every phase writes screenshots there, but it was never initialized.
- `/retro global` stops with a clear message when no cross-tool session-discovery
  binary is present instead of running an empty query and fabricating a narrative.

## 1.19.0 — 2026-07-19

Closes real behavioral gaps found by a per-skill audit, built on vibestack's
stack (memex, Playwright, no telemetry).

### Added

- **Always-on browser anti-detection.** The browse daemon and shim now apply a
  JS-level stealth layer on every page (`skills/browse/runtime/vibe-stealth.mjs`):
  `navigator.webdriver` mask, `window.chrome.*` restoration, `Notification`/hardware
  consistency, an automation-globals sweep, and a `toString` proxy that survives the
  depth-3 `[native code]` check. Opt into the aggressive WebGL/plugins layer with
  `VIBESTACK_STEALTH=extended`; per-install hardware via `VIBESTACK_HW_CONCURRENCY` /
  `VIBESTACK_DEVICE_MEMORY`. Previously the daemon had no stealth at all.
- **Credential pre-push guard.** `vibe-redact install-prepush-hook` installs a git
  `pre-push` hook (`vibe-redact-prepush`) that scans the pushed diff for
  high-confidence credentials and blocks on a hit; it chains any existing hook and
  honors a `VIBESTACK_REDACT_PREPUSH=skip` escape valve. `/ship` offers to install it
  once (or silently installs it when you've opted in).
- **Review-log persistence.** New `vibe-review-log` / `vibe-review-read` back the
  Review Readiness Dashboard: 25 log + 9 read call sites across `/ship`, `/review`,
  `/autoplan`, the `plan-*` reviews, and the design skills now write and read real
  per-branch review state instead of no-op stubs.

### Changed

- **`/skillify` is safe by default:** a provenance guard (refuses to invent a skill
  with no working flow), a name-collision check, staged validation with
  discard-on-failure, an approval gate before install, and post-install verification.
- **`/ship` plan-completion is stricter:** UNVERIFIABLE plan items are confirmed
  per-item (never blanket-approved), and a double failure of the audit (subagent *and*
  inline fallback) surfaces an explicit gate instead of silently passing.
- **`/document-release`** scans the PR/MR body for secrets before publishing it.
- **`./install`** ends with an intent-routed first move (idea → `/office-hours` or
  `/spec`; existing code → `/qa` or `/investigate`).
- Eight browse-using skills (`/qa`, `/qa-only`, `/canary`, `/land-and-deploy`,
  `/benchmark`, `/design-consultation`, `/design-html`, `/devex-review`,
  `/office-hours`) now detect the shipped browse shim instead of hard-coding
  `BROWSE_NOT_AVAILABLE`, so their browser steps actually run.

### Fixed

- **Codex voices no longer break on stock macOS.** `/codex` and `/autoplan` resolve a
  portable timeout (`gtimeout` → `timeout` → unwrapped) instead of a bare `timeout`
  that exits 127 where coreutils isn't installed. `/codex` also surfaces a non-zero
  exit as `[codex exit N]` and treats the review as unavailable rather than a silent
  pass, and `/autoplan`'s Codex auth check is now multi-signal (`$CODEX_API_KEY` /
  `$OPENAI_API_KEY` / `~/.codex/auth.json`) instead of a `--version` probe that
  passes even when logged out.

## 1.18.2 — 2026-07-09

### Fixed

- **Multi-target install when the repo is cloned inside a target's skills
  directory** (the documented `git clone … ~/.claude/skills/vibestack`). The
  containing target's atomic swap renamed its skills root aside — moving this
  repo's `skills/` source and `bin/` renderer with it — so any target installed
  afterward found no source and landed `0/53`. Install now defers the target
  whose root contains the repo to LAST; its own render completes before the
  swap, making multi-target install order-independent. Regression test added.

## 1.18.1 — 2026-07-08

### Fixed

- `test/test-install-integration.sh` no longer risks leaving the tracked
  `bin/vibe-render-skill` replaced by its test stub. The renderer-failure
  injection restores via a trap, which a hard kill (SIGKILL) skips — an
  interrupted run could orphan a truncated stub plus a `.bak` in the working
  tree. The backup is now gitignored and swept on startup, and a stub-marker
  self-heal restores the committed renderer at the next run.

## 1.18.0 — 2026-07-08

### Added

- **First-run project scaffold.** On the first-ever skill run in a project,
  `/office-hours` now points you at one concrete next move instead of a wall of
  options. A new `vibe-first-task-detect` binary classifies the repo (greenfield,
  a language with code, a feature branch with unshipped work, uncommitted changes)
  using only local git + filesystem, and the `first-run-scaffold` snippet maps the
  bucket to a single first-skill suggestion. Fires once per project, never in
  headless/CI runs, and never interrupts a command you explicitly gave.
- **Ask-first scope gate** in `/plan-eng-review` and `/plan-design-review`: the
  first action confirms the review target (branch diff, a pasted plan, or a
  specific path) before any repo exploration or audit — no more spelunking the
  whole repo, or auditing an empty one, on a guess.
- Six more credential shapes in the secret-scan gate (`/ship`, `/cso`, `/spec`,
  `/document-generate`): GitLab (`glpat-`/`glptt-`/`gldt-`), HuggingFace, npm,
  DigitalOcean, GCP service-account JSON, and entropy-gated `Bearer` tokens.

### Changed

- `/office-hours` now offers to **launch** the next review (`/plan-eng-review` by
  default) via the Skill tool at handoff, instead of listing options you have to
  retype.

## 1.17.8 — 2026-06-21

### Changed

- Renamed `/upgrade` → **`/vibe-upgrade`** to avoid colliding with Claude Code's
  built-in `/upgrade` command (and to keep the `vibe-*`
  namespacing consistent). Behavior is unchanged; the natural triggers ("upgrade
  vibestack", "update vibestack", "pull latest skills") still auto-invoke it.

## 1.17.7 — 2026-06-21

### Fixed

- `/skillify` spelled external project names inside its own naming-check command;
  the naming rule covers skill bodies. Reworded to point at the repo's audit
  without naming the tokens. No behavior change.

## 1.17.6 — 2026-06-21

### Added

- **`/diagram`** — render a Mermaid diagram to a self-contained HTML page (Mermaid
  from a CDN) and a PNG, using the browse shim as the renderer: write the HTML,
  `$B chain "goto file://… " "wait" "screenshot …"`. No heavy diagram toolchain;
  the HTML opens in any browser even without the shim. Excalidraw/DOCX are out of
  scope.
- `docs/skills.md` now documents the five v1.17.x skills (`/scrape`, `/skillify`,
  `/diagram`, `/connect-chrome`, `/upgrade`).

Skill count 52 → 53.

## 1.17.5 — 2026-06-21

### Added

- **`/scrape`** — pull structured data from a page with the browse shim: navigate,
  extract by selector (`js`/`text`, or the daemon for interactive pages), return
  JSON. Read-only; degrades to `curl` for static pages.
- **`/skillify`** — turn a working browse/scrape flow into a reusable skill: write
  a new `skills/<name>/SKILL.md` from the captured steps, render-validate,
  brand-check, and install.

Skill count 50 → 52.

## 1.17.4 — 2026-06-21

### Added

- **`/upgrade`** — update the installed pack: locate the repo (via the `vibe-*`
  symlinks), `git pull --ff-only`, re-run `install`, and summarize the CHANGELOG
  between the old and new version. Never force-pushes or resets; a blocked pull is
  reported.
- **`/connect-chrome`** — reuse your real Chrome's logged-in cookies in the browse
  daemon: launch Chrome with `--remote-debugging-port`, then
  `$B cookies import-cdp` carries the session into automated browsing. Cookies stay
  in-session, never written to the repo.

Skill count 48 → 50.

## 1.17.3 — 2026-06-21

### Added

- **Design-mockup generation** (`bin/vibe-design`) via OpenAI's image model. `vibe-design variants --brief
  "<prompt>" --count N --output-dir <dir>` writes PNG variants; `vibe-design
  status` reports `DESIGN_AVAILABLE` when `OPENAI_API_KEY` is set, else
  `DESIGN_NOT_AVAILABLE`. The five design skills' `DESIGN SETUP` now bind `$D` to
  it (detect-and-use); the comparison-board / vision verbs degrade gracefully.

## 1.17.2 — 2026-06-21

### Added

- **Browse tunnel / pairing via ngrok**: `$B tunnel <port>` exposes a local port for a remote agent and prints
  `TUNNEL: <https url>`; `$B tunnel-stop` ends it. Detect-and-use — prints
  `TUNNEL_NOT_AVAILABLE` when ngrok isn't installed. Used by `/pair-agent`.

## 1.17.1 — 2026-06-21

### Added

- **Browse daemon gains upload, dialog capture, and full cookie ops**
  (Playwright-native): `$B upload <sel|@ref>
  <path…>`; `$B dialog` reports the last JS dialog (`$B dialog dismiss` flips the
  next one); `$B cookies get | set <json> | save <path> | load <path> |
  import-cdp <url>` — `import-cdp` copies cookies from a Chrome started with
  `--remote-debugging-port`. No browser extension needed.

## 1.17.0 — 2026-06-21

### Added

- **Persistent browse daemon** (`skills/browse/runtime/vibe-browse-daemon.mjs`).
  `$B daemon &` keeps one browser + page alive over a unix socket, so element
  refs survive across separate calls: `$B snapshot` tags interactive elements and
  returns `@e1`, `@e2`, …; a later `$B click @e1` (a different process) acts on
  the same live page. Verbs: snapshot, click, fill, type, hover, check, uncheck,
  select, press, back, forward, reload, cookies (get), goto, screenshot, text,
  eval — by ref or selector. `$B daemon-status` / `$B daemon-stop` control it, and
  the stateless shim auto-proxies these verbs to the daemon when one is up. No
  browser extension — Playwright drives Chromium over CDP directly.
- `test/test-browse-shim.sh` covers the daemon client (12/12, browser-optional).

Still needing a native browser extension (tracked in TODOS): `upload`, native
`dialog` capture, cookie *import* from a real browser, tunnel/pairing, and the
design-image daemon.

## 1.16.0 — 2026-06-21

### Added

- **`$B chain` — stateful browser interaction.** The browse shim gains a `chain`
  verb that runs a sequence of steps on **one live page** in a single call, so a
  form fill → submit → screenshot works without the full daemon's cross-call
  element refs. Step verbs: `goto click fill type press hover check uncheck
  select wait screenshot text eval is`; returns a per-step JSON log and stops on
  the first failure. Documented in `browse-setup`; covered by `test-browse-shim`
  (9/9). The persistent daemon (CDP refs, extension, tunnels/pairing) and the
  design-image daemon remain the one large vendoring item (see TODOS).

## 1.15.1 — 2026-06-21

### Fixed

- Reworded a single CHANGELOG line for naming consistency — the pack's naming
  rule covers the CHANGELOG too. No code change.

## 1.15.0 — 2026-06-21

### Added

- **`MODEL_OVERLAY`** preamble flag + a model-overlay protocol (in
  `state-protocols.md`): the skill self-adjusts to its model family (default
  `claude`, override `VIBE_MODEL_OVERLAY`). No heavy per-model registry — a
  model-level adjustment.
- **`docs/internals.md`** — documents the binaries, shared snippets, preamble
  flags, and the memex-brain / local-state architecture.

## 1.14.0 — 2026-06-21

Phase B: the preamble now derives the behavior flags the rest of the pack reads,
and the tier-2 protocol blocks that depend on the new binaries are wired in.

### Added

- **Extended session preamble** (`session-host.md`): `PROACTIVE`, `EXPLAIN_LEVEL`,
  `CHECKPOINT_MODE`, `CHECKPOINT_PUSH`, `QUESTION_TUNING` from `vibe-config`, plus a
  throttled `vibe-update-check` nag.
- **State protocols** (`lib/snippets/state-protocols.md`, 44 skills): cross-session
  decisions (via `vibe-decision-log` / `vibe-decision-search`), continuous-checkpoint
  mode, skill routing, question-tuning honoring, voice-alias handling, and opt-in
  telemetry-on-completion.

## 1.13.0 — 2026-06-21

Foundation for the session/state layer: the binaries the rich preamble needs,
built on vibestack and memex. Decisions and analytics stay **local** — memex is
the read-only semantic-recall brain; the decision log is local and the brain
optional.

### Added

- **Seven `vibe-*` binaries** (installed to `~/.vibestack/bin/`):
  - `vibe-session-kind` — classify the session (spawned / headless / interactive).
  - `vibe-repo-mode` — emit `REPO_MODE=solo|collaborative` from git history.
  - `vibe-telemetry-log` — opt-in only; writes nothing unless telemetry is enabled.
  - `vibe-timeline-log` — append a per-project timeline event.
  - `vibe-update-check` — throttled, best-effort "a newer version is available" nag.
  - `vibe-decision-log` / `vibe-decision-search` — an event-sourced **local**
    durable-decision store (`decisions.jsonl`), with `--supersede` / `--redact`
    and high-confidence-secret rejection. memex remains the semantic-recall layer.
- `test/test-vibe-bins.sh` — 11 smoke tests for the new binaries (all green).

## 1.12.0 — 2026-06-21

Consolidates the remaining generic-behavior tier-2 blocks into a single shared
snippet, wired to vibestack's own tooling (no external infra, no dead
references).

### Added

- **Working protocols** (`lib/snippets/working-protocols.md`, wired into 44
  skills): completion-status reporting (DONE / DONE_WITH_CONCERNS / BLOCKED /
  NEEDS_CONTEXT), the confusion protocol (stop and ask on high-stakes
  ambiguity), context-health (progress notes + loop detection), context-recovery
  from local `~/.vibestack/projects/` artifacts (decisions come from memory, not
  a local store), the completeness mindset, and search-before-building + repo
  ownership.
- **`REPO_MODE` detection** in `lib/snippets/session-host.md` — solo vs
  collaborative, inferred from git history. Drives the repo-ownership behavior
  and resolves the previously-undefined `REPO_MODE` reference in `/ship`'s
  test-failure triage.

## 1.11.0 — 2026-06-21

Completes the host/interaction layer — the part of the
preamble that adapts how skills ask questions to the host they run in. Built to
work without any new binary (environment + `vibe-config` only).

### Added

- **Session & host detection** (`lib/snippets/session-host.md`, wired into 44
  skills). Detects a headless (eval/CI) vs interactive session and the Conductor
  host from environment variables alone. When the host's question tool is
  unreliable (Conductor) or there is no human (headless), skills now adapt
  instead of failing: render decisions as prose, or stop/auto-pick.
- **Decision-brief format** (`lib/snippets/decision-brief.md`, wired into the 41
  skills that use AskUserQuestion). Defines the decision brief (ELI10, stakes,
  recommendation, per-option completeness, pros/cons, net), how to resolve a
  host MCP vs native question tool, the failure/unavailable fallback, the
  interactive prose fallback, and a hardened path for one-way / destructive
  confirmations.

## 1.10.2 — 2026-06-21

A two-stage deep diff of the logic-heavy review skills surfaced plan-review
guardrails that had drifted out of the local copies.

### Added

- **Anti-shortcut clause in all four plan-review skills** (`/plan-ceo-review`,
  `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`). The plan file
  is the *output* of the interactive review, not a substitute for it: if any
  review section has a non-trivial finding, the path from finding to ExitPlanMode
  must go **through** AskUserQuestion. Dumping every finding into one plan write
  and exiting plan mode without asking is now called out as the exact failure to
  avoid.
- **`/plan-eng-review` pre-emit gate lists the false-positive classes it kills**
  (field-doesn't-exist, `dict.get()` None, `save()` field loss, `update_fields`
  miss) — a concrete catalog of what quoting the motivating line catches.

### Fixed

- **Plan-review report write-flow no longer replaces in place.** The four
  plan-review skills now delete any existing `VIBESTACK REVIEW REPORT` section and
  re-append it at the end, then verify it is the last heading — preventing a stale
  report from being left mid-file when content was added after it.

## 1.10.1 — 2026-06-21

A deep, per-skill content review (not just section-level) surfaced generic
guardrails worth enforcing:

### Added

- **`/design-consultation` enforces an artifact-persistence rule.** Mockups,
  comparison boards, and `approved.json` must be saved under
  `~/.vibestack/projects/$SLUG/designs/` — never in `.context/`, `docs/designs/`,
  `/tmp/`, or any project-local / version-controlled directory. Design artifacts
  are user data that persist across branches and workspaces, not project files.
- **`/plan-tune` no longer nags.** Step 0 gained a **Consent gate** and a
  **Setup gate** with prompt-once markers (`.question-tuning-prompted`,
  `.declared-setup-prompted`): a user who declines, or who enables tuning
  directly without the wizard, is handled once and never re-prompted. A partial
  bail-out of the setup wizard is honored the same way.

### Changed

- `/plan-tune` "Inspect profile" now distinguishes the low *display* threshold
  from the much higher bar required to ship behavior-adapting defaults — so a
  visible observed profile is never mistaken for a green light to start changing
  skill behavior while tuning is observational.

## 1.10.0 — 2026-06-21

### Added

- **`/review` and `/ship` plan-completion audits now classify verification mode.**
  Before judging a plan item DONE, the audit decides *how* it can be verified —
  `DIFF-VERIFIABLE` (the repo's own `git diff` proves it), `CROSS-REPO` (a file in
  a sibling repo, checked with `[ -f ]` when reachable), `EXTERNAL-STATE` (DNS,
  managed-DB config, hosting env — invisible to the diff), or `CONTENT-SHAPE`
  (run a project validator if one exists). Both add an `UNVERIFIABLE` verdict and a
  `## Cross-Repo / External Items` output section so deliverables `git diff` cannot
  prove are surfaced for manual confirmation instead of silently marked DONE. A
  path-concreteness rule forces any concrete filesystem path to a DONE/NOT DONE
  `[ -f ]` check.
- **`/retro` now captures learnings.** It ends with the shared Capture Learnings
  step, so a non-obvious pattern or pitfall surfaced during a retrospective is
  logged for future sessions like every other workflow skill.

### Fixed

- **Secret hygiene on two more external sinks.** `/document-generate` now scans
  generated docs for high-confidence secrets before committing (doc generators
  routinely emit example credentials), and `/spec` re-scans the issue title + body
  immediately before `gh issue create` — the world-readable issue could otherwise
  carry a secret introduced after the pre-codex redaction gate. Both reuse the
  existing secret-pattern set.

### Removed

- **The iOS QA suite is gone.** The five iOS skills (`/ios-qa`, `/ios-fix`,
  `/ios-design-review`, `/ios-clean`, `/ios-sync`) and everything they carried —
  the bundled Mac-side testing daemon, the `DebugBridge` Swift/Obj-C templates,
  and the accessor codegen — were removed. On-device iOS testing is out of scope
  for this pack. Skill count drops **53 → 48**; the remaining 48 skills are
  unchanged.

### Changed

- Docs and config track the smaller surface: README skill count, `docs/skills.md`
  (iOS section dropped), and the Agent Skills compatibility audit (now 48 skills,
  4 daemon-dependent skills instead of 9). Removed `docs/howto-ios-testing.md` and
  the iOS-only `.gitignore` build-artifact entries.

## 1.9.1 — 2026-06-14

### Changed

- Rewrote the README as a short, visual landing page that reads for both
  technical and non-technical visitors: an animated workflow hero, a
  one-source-three-agents diagram, a 30-second install, and the idea→ship story
  up front. The exhaustive skill table moved to [`docs/skills.md`](docs/skills.md)
  so the front page stays scannable.

### Added

- `docs/assets/hero.svg` — a self-contained, animated diagram of the
  brainstorm → plan → review → ship loop (renders inline on GitHub, no external
  assets).

## 1.9.0 — 2026-06-13

Cross-model review, plan-approval rigor, and secret hygiene get sharper across the
review and planning skills; the safety hooks survive newer Claude Code releases.

### Added

- **Codex outside-voice is default-on.** `/plan-ceo-review`, `/plan-eng-review`, and
  `/plan-devex-review` no longer gate the independent second opinion behind a "Want an
  outside voice?" question — it runs automatically. A 4-state preflight
  (`disabled` / `not_installed` / `not_authed` / `ready`) detects install *and* auth
  separately and degrades to a Claude subagent with a one-line reason when Codex is
  missing or unauthenticated. A single `codex_reviews` switch governs it
  (`vibe-config set codex_reviews disabled` turns it off; any other value is enabled).
- **`/document-release` Codex documentation review** (new Step 8.5, default-on,
  informational). Recomputes the shipped diff via `git merge-base` and checks the docs
  you touched against what actually shipped — stale claims, undocumented new surface,
  over/under-sold CHANGELOG entries. Never auto-edits; every fix needs your approval.
- **Mandatory unresolved-decisions verdict** in the VIBESTACK REVIEW REPORT, plus a
  **blocking EXIT PLAN MODE GATE**. Every plan-review report now ends with either the
  exact `NO UNRESOLVED DECISIONS` line or a `**UNRESOLVED DECISIONS:**` block, and the
  gate refuses ExitPlanMode unless that status is the report's final line — no "if
  applicable" escape. Wired into `/plan-ceo-review`, `/plan-eng-review`,
  `/plan-design-review`, `/plan-devex-review`, `/codex`, and `/devex-review` via two new
  shared snippets.
- **Brain preflight in the planning skills.** `/plan-ceo-review`, `/plan-eng-review`,
  `/plan-design-review`, `/plan-devex-review`, and `/office-hours` now query connected
  memory (memex MCP) for product / goal / persona / prior-decision context *before* the
  first question — pre-filling or skipping what the brain already answers. Skips
  silently when no brain is connected.
- New shared snippets: `lib/snippets/unresolved-decisions-status.md`,
  `exit-plan-mode-gate.md`, `brain-preflight.md`, `secret-scan-patterns.md`.

### Changed

- **Adversarial review carries authorized-defensive-testing framing.** The Claude
  adversarial subagent in `/ship` and `/review` now states it is hardening the repo's
  own code (not attacking a third party) and reads fixture/attack-payload files in
  summary mode — so a diff that includes the project's own security fixtures no longer
  trips usage-policy denials.
- **Secret scanning before external sinks.** `/spec`'s fail-closed gate now catches
  modern OpenAI key shapes (`sk-(proj|svcacct|admin)-…`, which a contiguous-alphanumeric
  pattern silently missed), and `/ship` (PR/MR body + release text) and `/cso` (audit
  report) gained a pre-sink secret scan. All three share the new
  `secret-scan-patterns.md` so the pattern set has one source of truth.

### Fixed

- **Safety hooks survive Claude Code releases that stop populating
  `${CLAUDE_SKILL_DIR}`.** `/guard`, `/freeze`, and `/careful` hook commands (and two
  in-body references in `/ship` and `/investigate`) now fall back to
  `${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/<name>}`, so Edit/Write/Bash no longer error
  when the variable is unset.
- `/autoplan` honors `codex_reviews=disabled` in its Phase 0.5 preflight, so the switch
  is truly global.

### Notes

- Deferred (tracked in `TODOS.md` with rationale): diagram rendering / multi-format /
  `/diagram` (no in-repo make-pdf renderer to build on), cross-session decision memory
  (redundant with memex as single source of truth), and the heavy brain-cache CLI (the
  lightweight model-level preflight covers the gap).

## 1.8.4 — 2026-05-31

### Added

- **Bundled browse shim — `/design-review` works without an external daemon.**
  vibestack now ships `vibe-browse`, a stateless Playwright-backed
  implementation of the read-only `$B` verb surface (`goto`, `screenshot`,
  `responsive`, `viewport`, `console`, `network`, `perf`, `js`, `css`, `is`,
  `text`, `url`, `status`). Previously `/design-review` hard-coded
  `BROWSE_NOT_AVAILABLE` and fell back to text-only checks — which silently
  passed pages that returned HTTP 200 while rendering an error overlay. The
  shim takes real Chromium screenshots (desktop + mobile), captures console
  errors and failed requests, and extracts computed typography/color for the
  design-system audit. First capture installs Playwright + Chromium into
  `~/.vibestack/browse/` (one time); detection (`status`) stays instant and
  never triggers the download.

### Changed

- `/design-review` SETUP now detects the bundled shim via the shared
  `lib/snippets/browse-setup.md` include and binds `$B` to it. When the shim is
  unavailable, the text-only fallback no longer trusts a bare `curl` status —
  it verifies the response **body** before calling a page healthy.

### Notes

- Cross-call element refs (`@e3`) and interaction verbs (`snapshot -i/-a/-D`,
  `click`, `fill`, `hover`, `upload`, `dialog`) are intentionally not in the
  stateless shim; they print `NOT_SUPPORTED:<verb>` and the skill skips that
  pass. The interaction-heavy skills (`/browse`, `/open-browser`,
  `/pair-agent`, `/setup-browser-cookies`) still expect the full daemon — see
  [`docs/external-tools.md`](docs/external-tools.md#browse-daemon).

## 1.8.3 — 2026-05-30

### Fixed

- The v1.8.2 changelog entry inadvertently quoted a third-party author name.
  Reworded; a case-insensitive `git grep` over all tracked files now returns
  zero hits — lesson logged: never quote a banned term when documenting its
  removal.

## 1.8.2 — 2026-05-30

### Fixed

- **Naming audit hardened.** A device-name example in a daemon code comment is
  now a neutral `"Jane's iPhone"`, and the PR template's checklist points to a
  case-insensitive whole-repo audit (with the term list kept out of the repo).
  The audit is now case-insensitive and covers every tracked file — skills, docs, code, comments,
  and tests — not just the prose surface.

## 1.8.1 — 2026-05-30

### Added

- **`docs/howto-ios-testing.md`** — the end-to-end iOS QA walkthrough for
  external users: prerequisites (Xcode 16+, a paired iPhone, Bun), adding the
  `DebugBridge` package to your app, building/installing to the device, starting
  `vibe-ios-qa-daemon`, the raw HTTP endpoint reference, remote QA over Tailscale
  with `vibe-ios-qa-mint`, shipping a clean Release build, and a failure table.
  Linked from the README and `docs/skills.md`; the 5 `/ios-*` skills point to it.

## 1.8.0 — 2026-05-30

The iOS suite is real. The five `/ios-*` skills are no longer preview stubs —
vibestack now ships the whole live-device QA subsystem.

### Added

- **iOS-QA daemon** (`skills/ios-qa/daemon/`, Bun, zero external deps) — the
  Mac-side broker between an agent and a real iPhone over the USB CoreDevice
  tunnel: allowlist, audit log, capability-tiered `/auth/mint`, session tokens,
  single-instance flock, request proxy/classify, tunnel bootstrap, devicectl.
  Launched via `skills/ios-qa/bin/vibe-ios-qa-daemon`; tailnet grants via
  `vibe-ios-qa-mint`. Optional `--tailnet` exposes the device to authenticated
  remote agents over Tailscale.
- **Accessor codegen** (`skills/ios-qa/scripts/`) — generates typed `@Observable`
  state accessors from your Swift source: a `swift-syntax` SwiftPM tool with a
  TypeScript fallback.
- **`DebugBridge` Swift/Obj-C templates** (`skills/ios-qa/templates/`) — the
  embedded `StateServer`, KIF-derived synthesized-tap target, debug overlay, and
  wiring you add to the app under test (DEBUG-only).

### Changed

- The five `/ios-*` skills flip from "preview, not bundled" to real: each now
  resolves the bundled daemon launcher and gives Bun + Xcode + DebugBridge setup
  steps, still detecting the daemon and reporting `NEEDS_SETUP` (never fabricating
  device actions) until the toolchain + device + bridge are in place. Each skill
  was also trimmed of ~490 lines of non-vibestack tier-2 boilerplate to match
  house style.

**Verified:** daemon `bun test` 91/91, codegen `bun test` 20/20, Swift sources
parse clean. The on-device loop (Xcode build of `DebugBridge`, a connected
iPhone) runs on your Mac — see `skills/ios-qa/docs/`.

## 1.7.4 — 2026-05-29

### Added

- **Skill-coverage audit** — a maintainer tool that scores each skill's
  workflow-line coverage (exact or fuzzy) with a median PASS/FAIL gate. Its
  configuration lives in a local, untracked `~/.vibestack/` file, out of the
  repo. Current snapshot: median 96% coverage, PASS.

## 1.7.3 — 2026-05-29

### Changed

- **Deduped the Review Readiness Dashboard into a shared snippet.** The 50-line
  dashboard block was byte-identical across `/plan-ceo-review`,
  `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`, and
  `/devex-review`; it now lives in `lib/snippets/review-readiness-dashboard.md`
  and is pulled in via `{{include}}`. Pure internal refactor — rendered output
  is byte-identical (verified), no behavior change. `/ship` keeps its own
  richer dashboard variant.

## 1.7.2 — 2026-05-28

### Added

- **`/ship` now closes the `/spec` source issue on merge.** When the branch has
  a `/spec` archive (matched by `spec_branch`) carrying a `spec_issue_number`,
  `/ship` adds a `## Linked Spec` section to the PR body: `Closes #N` when the
  Plan Completion gate reports full delivery, or a "Linked to #N (partial —
  not auto-closing)" notice otherwise, so a partial PR never silently closes
  the issue. Completes the `/spec` → `/ship` contract from v1.7.0.

## 1.7.1 — 2026-05-28

### Fixed

- `/ios-clean`'s description was silently truncated at "…and all" in the
  agent's skill catalog: the unquoted `#` in `#if DEBUG` started a YAML comment.
  Quoted the value so the full one-line description shows.

## 1.7.0 — 2026-05-28

Six new skills and a leaner session start. `/spec` turns a vague request into a
precise, executable spec in five phases, and a new iOS preview suite brings
live-device QA workflows to the pack. Every skill now costs less at session
start, and the review/retro/deploy skills got sharper correctness guards.

### Added

- **`/spec`** — turn vague intent into a backlog-ready spec in five phases
  (why → scope → technical-with-mandatory-code-reading → draft → file). Files a
  GitHub issue, runs an optional codex quality gate (0–10, with fail-closed
  secret redaction before anything leaves your machine), archives the spec
  under `~/.vibestack/projects/<slug>/specs/`, and is plan-mode aware: files
  the issue in plan mode, or files **and** spawns a `claude -p` agent in a
  fresh worktree in execution mode. `/ship` can close the source issue on merge.
- **iOS preview suite** — `/ios-qa`, `/ios-fix`, `/ios-design-review`,
  `/ios-clean`, `/ios-sync`: live-device QA, autonomous bug-fixing, design
  audit, debug-bridge cleanup, and bridge regeneration for SwiftUI apps driven
  over a USB tunnel. **Preview:** these drive a real iPhone through a Mac-side
  iOS-QA daemon and a `DebugBridge` Swift package that vibestack does not bundle
  yet — each skill detects the daemon and reports `NEEDS_SETUP` when it is
  absent, so they serve as an architecture reference until the daemon ships.
- **"5+ options — split, never drop" rule** — a shared snippet
  (`lib/snippets/askuserquestion-split.md`) plus a deep reference
  (`docs/askuserquestion-split.md`) now teach decision-asking skills to split
  or batch a 5+ option decision instead of silently trimming one to fit the
  4-option cap. Wired into the four `plan-*` review skills and `/office-hours`.

### Changed

- **Leaner session start.** Every skill's always-loaded `description:` is
  trimmed to its lead summary sentence; the "use when / proactively suggest /
  voice triggers" routing prose moves into a new `## When to invoke` body
  section that only loads when the skill is invoked. The explicit `triggers:`
  list is unchanged, so auto-invocation is unaffected.
- **`/review`, `/cso`, `/plan-eng-review`, and `/ship`** now run a pre-emit
  verification gate: every finding must quote the `file:line` and the verbatim
  code that motivates it, or it is forced to low confidence and suppressed to
  the appendix — killing the "field doesn't exist on the model" class of
  framework false positives.
- **`/retro`** gained a Step 0.5 stale-base pre-flight guard that blocks
  fabricating a retrospective against a stale base branch or a drifted "today"
  anchor, with explicit skip paths for no-remote / detached-HEAD / offline runs.
- **`/land-and-deploy`** now reads authoritative PR state after any failed
  `gh pr merge` (MERGED / OPEN / CLOSED) instead of retrying the merge, with
  non-destructive worktree cleanup on the already-merged path.

### Fixed

- Codex detection now uses `command -v codex` instead of `which codex` across
  all ten codex-using skills, so detection works in minimal / non-interactive
  shells where `which` is unavailable.
- `/review` and `/ship` compute the review diff against
  `git merge-base origin/<base> HEAD` instead of the bare base tip, so a base
  branch that has advanced past the branch point no longer injects phantom
  deletions into the review.

## 1.6.1 — 2026-05-18

Bug fix: `/setup-memory` was hardcoded to detect a `secondbrain`-named MCP
registration, so re-running the skill on a machine where the brain is
registered under a different compliant name (most commonly `memex`, the
single-tenant brain at github.com/timurgaleev/memex) missed the existing
setup and would push the user through Path 4 a second time — creating a
duplicate `secondbrain` entry in `claude mcp list` pointing at the same URL.

### Fixed
- **Detection regex now matches any compliant brain MCP name.** Step 1 and
  Step 10 detect blocks accept lines starting with `memex:` or `secondbrain:`
  (followed by whitespace) and capture the actual name in a new
  `SBRAIN_MCP_NAME` variable. The pre-existing regex also incorrectly
  expected `field $3 == "http"` but `claude mcp list` emits `(HTTP)` with
  parentheses — corrected to `tolower($3)=="(http)"`. Both bugs hid each
  other: matching nothing meant the mode comparison never fired.
- **Step 5a now reuses the detected name.** Both Path 4 (remote-http) and
  Paths 1-3 (local-stdio) registration paths read `${SBRAIN_MCP_NAME:-secondbrain}`
  for `claude mcp remove` / `claude mcp add` / verify-grep, so re-running
  `/setup-memory` against an existing `memex` registration refreshes that
  entry instead of creating a parallel `secondbrain` one.
- **Step 2 idempotency note updated** to explicitly call out that the skip
  applies regardless of detected name, and to forbid registering a parallel
  `secondbrain` entry when one is already present under another name.
- **Step 10 verdict template** now substitutes `{SBRAIN_MCP_NAME}` in the
  status header, MCP row, and `mcp__*__*` tool-name hint — so the output
  reflects what's actually registered.

### Notes
- No skill body change in any of the other 46 skills.
- Tests green: `bash test/test-render-skill.sh` (16/16) +
  `bash test/test-install-integration.sh` (29/29).
- Naming audit clean: zero hits across `skills/`, `docs/`, `README.md`,
  `lib/snippets/`.

## 1.6.0 — 2026-05-18

Behavior sweep — 32 commits' worth of improvements across 13 existing
skills and 1 new skill. Pulls the latest review/codex/document-release/
setup-memory improvements into vibestack while staying backend-agnostic.

### Added
- **`/document-generate` (new skill).** Generate complete documentation from
  scratch using the Diataxis framework (tutorial / how-to / reference /
  explanation). Researches the full codebase surface before writing — accuracy
  over elegance. Can be invoked standalone or by `/document-release` to fill
  coverage gaps. Skill count now 47.
- **Per-phase Implementation Tasks aggregation.** New shared snippets
  `lib/snippets/tasks-section-emit.md` and `tasks-section-aggregate.md` wire
  the four `/plan-*` review skills to emit per-phase JSONL task artifacts
  scoped to branch + recent commits, which `/autoplan` Phase 4 reads, dedupes
  by `(component, files, title)`, sorts by priority, and renders as an
  `### Implementation Tasks (aggregated across phases)` block in the Final
  Approval Gate output.
- **`/browse` Headed Mode + Proxy + Anti-Bot Sites.** New section documents
  `--headed`, `--proxy socks5|http`, `download --navigate`, the
  URL-vs-env-var credential policy, daemon-startup discipline,
  `navigator.webdriver` stealth, container Xvfb auto-spawn, and the SOCKS5
  fail-fast failure modes.
- **Staff Engineer persona + HARD GATE** on `/context-save`, `/context-restore`,
  and `/learn`. Sets a clear behavioral tone before the workflow starts. The
  cross-branch default for `/context-restore` is now restated at the top.
- **CSO persona on `/cso`.** Adds the "Chief Security Officer who has led
  incident response on real breaches" framing and the "real attack surface is
  your dependencies" opening. Subtitle bumped to "(v2)".
- **`/investigate` hypothesis-keyed learnings re-search.** After naming a root
  cause hypothesis, re-pulls learnings keyed to a single keyword from the
  hypothesis with strict keyword discipline (alphanumeric/hyphen only). Mirrors
  the same pattern in `/ship`.
- **`/make-pdf` flag table.** Adds `--tagged` (accessible PDF), `--outline`
  (PDF bookmarks), and `--allow-network` (fetch external images) to the
  documented flag reference.

### Changed
- **`/codex` major rewrite (critical for Codex CLI ≥0.130.0).** New Step 0.5
  multi-signal auth probe accepting any of `$CODEX_API_KEY`, `$OPENAI_API_KEY`,
  or `~/.codex/auth.json`. Known-bad CLI version warning for `0.120.0/.1/.2`.
  Portable `$PLAN_ROOT`/`$TMP_ROOT` (no more hardcoded `/tmp`/`~/.claude/plans`).
  **Review Mode now dual-path:** bare `codex review --base` preserves the CLI's
  built-in review template; `codex exec` with `DIFF_START`/`DIFF_END` markers
  takes over when custom instructions are passed (Codex ≥0.130.0 rejects
  prompt + `--base` together — the previous single-path implementation was
  broken there). Synthesis Recommendation line is now REQUIRED in all three
  modes with a canonical format the AskUserQuestion judge can grade.
  Resume-session block added for Consult mode (`codex exec resume <session-id>`).
  Hang detection + auth-error surfacing from captured stderr.
- **`/document-release` major rewrite.** New Step 1.5 Coverage Map applies
  Diataxis as an audit lens — extracts new public-surface items from the diff
  and assesses each against reference / how-to / tutorial / explanation
  coverage. Architecture diagram drift detection cross-references entity names
  in ASCII/Mermaid blocks against the diff. Sell-test upgraded to a 0-3
  Diataxis rubric (1 point each for "What changed?" / "Why care?" / "How to
  use?"). PR body now grows a `### Documentation Debt` subsection when gaps
  are found, with a suggested `docs-debt` label. New PR/MR title sync sub-step
  rewrites titles to start with `v<VERSION>` (idempotent).
- **`/setup-memory` major rewrite (single-machine, backend-agnostic).** New
  Step 1.5 broken-engine remediation flow (Retry / Switch-to-PGLite / Switch
  mode / Quit). **Path 4 Remote MCP** (HTTP transport with bearer token) for
  users whose brain runs on another machine — registers via
  `claude mcp add --transport http --header "Authorization: Bearer …"`, with
  a verify round-trip against `tools/list` before registration. New Step 7.5
  single-machine transcript ingest gate. Step 8 now writes a `## Memory Search
  Guidance` block (HTML-delimited) into CLAUDE.md after the smoke test passes,
  teaching the agent when to prefer secondbrain over Grep. New Step 10
  GREEN/YELLOW/RED verdict block makes re-running `/setup-memory` a
  first-class doctor path. PATH-shadow validation in Step 3 catches stale
  global installs.
- **`/ship` doc surfaces.** README skill table and `docs/skills.md` entries
  for `/document-release` and `/document-generate` rewritten to reflect the
  Diataxis coverage map and the new generation workflow.

### Notes
- All changes keep vibestack's skills backend-agnostic. The `/setup-memory`
  Path 4 flow works against any compliant MCP-HTTP brain.
- Tests green: `bash test/test-render-skill.sh` (16/16),
  `bash test/test-install-integration.sh` (29/29).
- Naming audit clean: zero hits across `skills/`,
  `docs/`, `README.md`, `lib/snippets/`.

## 1.5.0 — 2026-05-10

Install UX polish (TODO #8) + per-target atomic stage-and-swap (TODO #4).
Closes the deferred UX work from v1.4.0 eng review and the atomicity work
from v1.3.0 SKILL.md composition CEO review in one release.

### Added
- **Install plan + Enter UX.** `./install` (interactive TTY) now shows a
  write plan listing each target's path and detection status, then a
  single prompt: `Press Enter to install.  a=all  e=edit  d=dry-run  q=quit`.
  The common case is one keystroke. `e` falls through to the v1.4.0
  per-target prompts with detection-flipped defaults (`[Y/n]` for detected,
  `[y/N]` for not). `d` triggers an in-prompt dry-run preview. `q`/`n`
  exits cleanly.
- **`Installation incomplete:` outcome header.** When any target fails,
  the summary changes from "complete" to "incomplete", lists successful
  targets first with `✓` then failed targets with `✗` and the failed
  skill's path, and suppresses the happy-path CTA. Hook warning still
  prints on partial success (so users see safety info even when other
  targets failed).
- **Per-target atomic stage-and-swap.** Each target's install renders to
  `~/.<target>/skills.staging.<pid>/` first, then atomically swaps via
  `mv skills{,.old}` + `mv staging skills`. On staging failure, the
  partial render is parked as `.staging.failed.<ts>` for debugging and
  the production `~/.<target>/skills/` is left untouched. Recovery pass
  on each run cleans orphaned staging dirs and restores from `.old` if
  a prior interrupted swap left `skills/` missing.
- **SIGINT/SIGTERM trap.** Ctrl-C mid-install exits 130 with
  `Installation interrupted (SIGINT); some targets may be partially
  updated.` SIGTERM exits 143 with the equivalent message. Re-run
  converges (idempotent staging cleanup).
- **PTY test harness** (`test/pty-run.py`) for exercising TTY-gated
  prompt branches in `test/test-install-integration.sh`. 15 new
  integration tests cover the prompt branches, atomic-swap behavior,
  staging-failure preservation of production, and recovery from
  orphaned `.old` / `.staging` dirs.
- **Test seam:** `VIBE_TEST_MODE=1` disables the `command -v` half of
  target detection so tests can control detection precisely via
  `$HOME/.<target>/` directory presence without picking up real
  agent binaries on the dev machine.

### Changed
- **`./install` now requires bash 4+ explicitly** (de facto since v1.4.0;
  the new outcome accumulator uses associative arrays). On stock macOS
  bash 3.2.57 the install exits 4 with a Homebrew install hint instead
  of failing later with a cryptic `declare: -A: invalid option`.
- **Failure mode pivots from fail-fast to per-target fail-fast +
  cross-target fail-soft.** A single per-skill failure within a target
  no longer aborts the whole install — remaining targets continue. The
  failed target's production `skills/` stays untouched (atomic-swap
  blocked by the failure). Exit code is non-zero on any failure, so CI
  still breaks correctly. Recovery is idempotent: re-run after fixing
  the underlying error.
- Output strings preserved verbatim where v1.4.x prints them
  (`Installation complete:` colon-form). `--target=<list>` and `--yes`
  paths are byte-identical to v1.4.x for backward compatibility.
- README "Try it in 30 seconds" copy updated to describe the new
  install plan UX.

### Behind the change
- Codex outside-voice (in `/plan-eng-review`) flagged that fail-soft
  alone leaves users in a mixed state on partial failure. Per-target
  staged-install closes that gap: production `skills/` is only ever
  modified by an atomic mv chain, so partial failures leave the prior
  install intact.
- The same outside-voice round caught: SIGTERM ≠ 130 (now correctly 143),
  hook warning shouldn't be suppressed on partial success (now prints
  whenever hook-bearing skills landed in any successful non-Claude
  target), and the test harness was unable to reach TTY-gated prompt
  code with `< /dev/null` (now uses a Python `pty` harness).

### Why a minor (1.4.2 → 1.5.0)?
Additive UX (install plan, atomic swap, recovery, SIGINT trap) plus a
flagged behavior change (fail-fast → fail-soft per-target, with CI
exit-code semantics preserved). No breaking flag changes. Same
`git pull && ./install` distribution.

## 1.4.2 — 2026-05-09

Multi-agent positioning rewrite. Docs-only patch — no code changes.
v1.4.x is the multi-agent release; the previous README still framed
vibestack as "a personal Claude Code skills pack" which under-sold what
shipped. v1.4.2 fixes the framing.

### Changed
- **README.md** rewritten with hybrid hero/measured-detail tone:
  - New tagline: "46 opinionated AI coding workflows. One install.
    Works in **Claude Code**, **Cursor**, and **Kiro**."
  - Badges row (release, license, Agent Skills standard, stars).
  - "Why vibestack" section with 5 bullets focused on multi-agent +
    no lock-in + opinionated.
  - "How vibestack compares" table vs. awesome lists, plugin
    marketplaces, and `.cursorrules` files.
  - `/reroll-buddy` row updated from "Claude Code `/buddy`" to
    "your agent's `/buddy`" since the skill is portable.
  - `/setup-memory` row updated from "Claude Code MCP tool" to
    "an MCP tool" (MCP is multi-agent).
  - Telemetry/analytics section flagged as Claude-Code-only with
    forward-looking note for Cursor/Kiro.
  - Closing call-to-action for stars + forks.
- **CONTRIBUTING.md**: dependency line now mentions all three agents,
  not "only Bash and Claude Code". Test step calls out the multi-agent
  install path. Quality bar checklist gains a hook-tier requirement
  for hook-bearing skills.
- **ETHOS.md**: "Natural language first" extended to call out
  multi-agent applicability. "Hooks with care" gets a cross-agent
  caveat warning that hook determinism degrades in Cursor/Kiro.
- The two remaining "Claude Code" mentions in `docs/skills.md` (in
  `/reroll-buddy` and `/setup-memory`) are factually scoped and stay —
  those skills genuinely target Claude-Code-specific config files.

### Why a patch, not a minor?
No behavior change. Same 46 skills, same install pipeline, same tests
pass. The release artifact (rendered SKILL.md content) is byte-identical
to v1.4.1. This is purely how we describe what shipped.

## 1.4.1 — 2026-05-09

Docs-only patch. Closes the gap between the v1.4.0 tag and the merged
state on main: the `a0e5b52` Track B verification commit landed after
v1.4.0 was tagged but before the PR merged, so `git checkout v1.4.0`
shipped the pre-verification ("pending Track B") version of the audit
doc. This patch re-tags so the v1.4.x release matches what's actually
on main.

### Changed
- No code changes. Docs only.
- v1.4.0 → v1.4.1: `git checkout v1.4.1` now matches the merged main
  state, including the Track B verification section in
  `docs/agent-skills-compatibility-audit.md`, the empirical per-target
  table in README, and the Kiro-no-sandbox warning in CHANGELOG notes.

## 1.4.0 — 2026-05-09

Multi-target install: vibestack now installs into Cursor and Kiro alongside
Claude Code, all from a single source. Same SKILL.md, three folders. Built on
the Agent Skills open standard ([agentskills.io](https://agentskills.io/specification))
which Claude Code, Cursor (`~/.cursor/skills/`), and Kiro (`~/.kiro/skills/`)
all implement. No format translation, no per-target writers — the spec already
guarantees portability at the file-shape layer.

### Added
- `./install --target=<list>` — install into one or more agents.
  Accepts `claude`, `cursor`, `kiro`, `all`, or any comma-separated subset.
- `./install` (interactive default) — TTY mode prompts per-target with Y default.
  Three separate Y/n prompts so you opt into each agent independently.
- `./install --yes` / `-y` — non-interactive shorthand for `--target=all`.
- `./install --dry-run` — preview the 138 outputs (46 skills × 3 targets) without
  writing any files. Composes with `--target=`.
- `./uninstall --target=<list>` — symmetric multi-target removal.
- `docs/agent-skills-compatibility-audit.md` — full per-skill compatibility
  matrix from Day 0 spec audit (all 46 skills are spec-compliant on file
  shape; 4 hook-bearing skills flagged for runtime verification).
- `docs/hook-verification.md` — manual procedure for verifying hooks fire
  correctly under Cursor and Kiro per (target × skill).
- `test/test-install-integration.sh` — 13 integration tests covering
  regression (Claude byte-identical), multi-target install, dry-run,
  idempotency, install/uninstall round-trip, hook warning, bin symlinks.

### Changed
- **BREAKING for CI users:** `./install` with no flags now defaults to
  installing into ALL THREE targets (claude + cursor + kiro). v1.3.x default
  was claude-only. CI scripts that want claude-only behavior must now pass
  `--target=claude` explicitly. Interactive (TTY) usage is unaffected — you
  get prompted per target.
- `./install` and `./uninstall` switched from `set -e` to `set -uo pipefail`
  with explicit error handling per critical operation. Per-target failures
  surface clearly without silent abort mid-loop.
- The per-skill install body was extracted into `install_skill_to_target()`
  (Beck refactor — make the change easy first, then make the easy change).
  Same logic, parameterized destination root.
- `bin/vibe-render-skill` is **unchanged** from v1.3.0. Multi-target reuses
  the v1.3.0 renderer 1:1.
- `lib/snippets/` is **unchanged**. Same snippets compile to identical
  SKILL.md content for all three targets.
- All 46 `skills/<n>/SKILL.md` source files are **unchanged**.

### Notes
- For hook-bearing skills (`careful`, `freeze`, `guard`, `investigate`),
  Cursor and Kiro support is **soft tier — verified empirically** against
  Cursor `2026.05.07-42ddaca` and Kiro CLI `2.2.2`. The `PreToolUse` hook
  command does NOT fire in either target (Cursor uses `${skillDir}`, Kiro
  doesn't expose a `${CLAUDE_SKILL_DIR}` equivalent at all). The install
  prints a one-line warning when these skills are installed into non-Claude
  targets.
- ⚠️ **Cursor's native shell sandbox** blocks `rm -rf` and similar dangerous
  commands independently of our hook, so Cursor users get fallback safety.
  **Kiro has no equivalent sandbox** — `rm -rf` ran without any prompt
  during Track B testing. If safety skills are load-bearing for you, use
  Claude Code (hard tier) or be aware of the gap.
- Full per-target tier matrix and Track B test results in
  `docs/agent-skills-compatibility-audit.md`. Re-verification procedure
  for future Cursor/Kiro versions in `docs/hook-verification.md`.
- v1.4.0 designed by `/office-hours` + `/plan-eng-review` + Codex outside-voice
  cross-model challenge. Track B verified end-to-end before merge.

## 1.3.0 — 2026-05-09

SKILL.md composition pipeline. Shared markdown sections now live in
`lib/snippets/` and are expanded into installed `SKILL.md` files via a
tiny `{{include lib/snippets/X.md}}` directive resolved at install time.
Designed by `/office-hours` + `/plan-ceo-review` + `/plan-eng-review`.

### Added
- `bin/vibe-render-skill` — install-time markdown renderer. Expands include
  directives, substitutes `{SKILL_NAME}` per skill, writes a sidecar
  `.vibe-render.json` metadata file, supports `--check` mode, idempotent.
  ~150 lines bash 3.2-portable; uses `set -euo pipefail`, atomic
  `mktemp`+`mv`, signal trap for cleanup. Exit codes: 0 success / 2 validation
  / 3 infrastructure.
- `lib/snippets/capture-learnings.md` — canonical "Capture Learnings"
  block. Used in 14 skills (cso, design-consultation, design-review,
  plan-ceo-review, plan-eng-review, qa, retro, ship, devex-review,
  office-hours, plan-design-review, plan-devex-review, qa-only,
  investigate). 8 other skills retained inlined variants per Day 0
  drift audit (4 short-form, 4 domain-customized).
- `lib/snippets/prior-learnings.md` — canonical "Prior Learnings"
  search block. Used in 14 skills (all skills that previously had it).
- `test/fixtures/render/` — 11 fixtures covering byte-identical
  fallback, single/multi include, missing/nested include rejection,
  fence-state tracking (codefenced and indented directives stay literal),
  no-frontmatter handling, idempotency, --check mode (drift detected /
  no drift), and arg parsing (5 invalid invocations).
- `test/test-render-skill.sh` — fixture-driven harness; 16 test cases
  pass on first run.

### Changed
- `./install` — `SKILL.md` no longer symlinked; rendered into a regular
  file via `vibe-render-skill`. `bin/` and per-skill sub-doc symlinks are
  unchanged. Renderer invoked via absolute repo path so a fresh install
  works before `$VIBE_BIN` exists.
- `./uninstall` — patched to remove regular-file `SKILL.md` and
  `.vibe-render.json` sidecar at canonical paths. Existing
  symlink-removal loop unchanged. User-placed regular files at other
  paths are still preserved.
- 28 skills migrated (14 each for capture-learnings and prior-learnings;
  13 skills got both). Total: 874 lines removed from sources;
  installed-output content unchanged for 40 of 46 skills (byte-identical
  P3 baseline). 6 skills harmonize +2 trailing blank lines as predicted
  by the Day 0 drift audit (purely whitespace, LLM-invisible).

### Architecture
- Render-at-install treats SKILL.md authoring as a build step rather
  than verbatim source. Skill authors can now keep shared logic in one
  place and reference it via include directives.
- `{SKILL_NAME}` token substitution is the v1's only renderer-side
  variable — narrowly scoped, not a general templating system.
- `.vibe-render.json` sidecar replaces an inline HTML-comment header
  (which would have leaked into LLM prompt content). Sidecars are
  LLM-invisible and tool-readable.
- Code-fence state tracking prevents directive expansion inside ```
  blocks, so skills can document the include syntax without triggering
  it.

### Verified
- `bash -n` syntax check on renderer + install + uninstall.
- 16 fixture tests pass (`bash test/test-render-skill.sh`).
- P3 baseline: 46 source skills install with the expected output diff
  pre-vs-post migration (0 unintended changes, 6 expected
  whitespace-only harmonizations).
- Round-trip: `./install` then `./uninstall` against fresh `$HOME`
  leaves zero residual files in `~/.claude/skills/<name>/`.

---

## 1.2.1 — 2026-05-03

`/ship` now auto-tags and auto-publishes a GitHub/GitLab Release. No more manual `gh release create` after every merge.

### Changed
- `skills/ship/SKILL.md` — three additions:
  - **Step 15.2** — annotated-tag the version-bump commit (`v$NEW_VERSION`). Idempotent: skips if already at HEAD, moves if at a different commit, creates if absent.
  - **Step 17** — `git push -u origin <branch> --follow-tags` so the new tag goes up with the branch (plus an explicit fallback push if the branch was already pushed).
  - **Step 19.5** — extract the CHANGELOG section for the new version and create (or update) a GitHub/GitLab Release pointing at the tag. Idempotent — re-running `/ship` updates the notes instead of erroring.
- Documents the merge-strategy tradeoff: tags placed on the feature branch survive merge-commits; squash-merges orphan the tag and need a manual re-tag against `main`.

### Notes
- This is the only `/ship` run since `/ship` was modified — the tag and release for v1.2.1 itself need to be created manually (or by re-running `/ship` once the merged change is on main, since Step 19.5 is idempotent).

---

## 1.2.0 — 2026-05-03

DX overhaul driven by `/plan-devex-review` + Codex outside-voice. Champion-tier TTHW target for an OSS contributor cloning vibestack from GitHub.

### Added
- `/tdd` — test-driven development with vertical-slice red-green-refactor loop. Tests verify behavior through public interfaces (so they survive refactors); anti-pattern callout for horizontal slicing; per-cycle checklist. Sub-docs: `deep-modules.md`, `interface-design.md`, `mocking.md`, `refactoring.md`, `tests.md`.
- `/improve-arch` — find deepening opportunities in an existing codebase: turn shallow modules into deep ones (small interface, deep implementation) for testability and AI-navigability. Precise glossary (module, interface, depth, seam, adapter, leverage, locality); deletion test; explore → present candidates → grilling loop. Optional `CONTEXT.md` and `docs/adr/` integration. Sub-docs: `DEEPENING.md`, `INTERFACE-DESIGN.md`, `LANGUAGE.md`.
- README — `Try /office-hours in 30 seconds` magical-moment section with rendered terminal output (Stripe-style inline receipt).
- README — `By workflow` navigation table mapping 6 use-cases to skill chains.
- README — `What ./install modifies on your machine` table for install-trust transparency.
- README — `Data written locally` disclosure section (no telemetry; documents `~/.vibestack/projects/`, `~/.vibestack/analytics/`, `~/.vibestack/hook.log`, `~/.vibestack/freeze-dir.txt`).
- `docs/external-tools.md` — honest disclosure that vibestack does not bundle the browse daemon or `vibe-model-benchmark`. Affected 5 SKILL.md NEEDS_SETUP blocks and 3 `docs/skills.md` descriptions rewritten to point here instead of the non-existent `./setup`.
- `bin/vibe-skill-track` — opt-in UserPromptSubmit hook that logs explicit `/skill-name` invocations to `~/.vibestack/analytics/skill-usage.jsonl`. Off by default; user wires it into `~/.claude/settings.json`. `VIBESTACK_TRACK=0` disables. Auto-invokes not captured (Claude Code does not expose a `SkillStart` event — limitation documented).
- `.github/ISSUE_TEMPLATE/bug.yml`, `.github/ISSUE_TEMPLATE/skill-proposal.yml`, `.github/pull_request_template.md` — community contribution scaffolding.

### Changed
- `install` — final-line output replaced ("Installed N skills → ~/.claude/skills. Try /office-hours first.") and the verbose 46-line skill list removed (was noise on every re-install).
- `uninstall` — now removes ALL skill symlinks (not just `SKILL.md`), removes `vibe-*` binary copies, prompts before deleting `~/.vibestack/` state, prints what stays. Added `--delete-state` flag for non-interactive runs.
- `skills/careful/bin/check-careful.sh`, `skills/freeze/bin/check-freeze.sh` — added opt-in `_vibestack_log` decision audit (controlled by `VIBESTACK_DEBUG=1`). Subshell-isolated so logging errors never propagate to hook decision flow. `flock`-guarded for concurrent writes; rotation at 1MB via atomic rename.

Skill count: 44 → 46.

---

## 1.1.0 — 2026-04-26

### Added
- `/benchmark-models` — compare AI model outputs side-by-side across OpenAI, Anthropic, Google, Mistral, Groq, Together, Ollama; optionally judge with a separate model; results saved to `~/.vibestack/benchmarks/`
- `/browse` — persistent headless Chromium browser with ~100ms per command; navigate, interact, screenshot, diff, assert element states, test uploads and dialogs, responsive layouts, local HTML rendering, CSS inspector, Puppeteer migration cheatsheet
- `/claude` — independent second opinion from a nested Claude instance; three modes: review (brutally honest diff review), challenge (adversarial failure-mode analysis), consult (read-only Q&A with session continuity)
- `/open-browser` — launch AI-controlled visible Chromium with real-time sidebar activity feed and anti-bot stealth
- `/pair-agent` — pair a remote AI agent (OpenClaw, Hermes, Codex, Cursor) with your browser session via same-machine or ngrok tunnel
- `/setup-browser-cookies` — import cookies from your real Chromium browser into the headless browse session via interactive picker or direct domain import
- `/setup-memory` — install and configure secondbrain persistent memory as a Claude Code MCP tool; supports PGLite local, Supabase existing URL, and Supabase auto-provision paths
- `/pr-summary` — read full diff across all PR commits, categorize changes, write accurate PR body preserving existing author notes
- `/reroll-buddy` — reset the Claude Code `/buddy` companion pet by removing the `companion` key from `~/.claude.json`; preserves all other config
- `/codex` — second-opinion AI reviewer via OpenAI Codex CLI; three modes: review (pass/fail gate on P1 findings), challenge (adversarial edge-case analysis), consult (session continuity)
- `/make-pdf` — generate professional PDFs from markdown, code, or HTML; cover page, TOC, watermarks, custom margins and page sizes, preview mode, per-project defaults
- `/setup-deploy` — detect deploy platform (Fly.io, Render, Vercel, Netlify, Heroku, GitHub Actions, custom), write config to `CLAUDE.md` for `/land-and-deploy`; idempotent
- `CLAUDE.md` — development guide for skill authoring, hook script conventions, and commit discipline
- `ETHOS.md` — five core principles guiding skill design
- `CONTRIBUTING.md` — step-by-step guide for adding and editing skills
- `docs/skills.md` — full skills reference with descriptions, details, and triggers for all skills
- `LICENSE` — MIT license

### Fixed
- `skills/freeze/bin/check-freeze.sh` — `_resolve_path` now resolves symlinks for the boundary itself, not just the incoming file path, so `/freeze` works correctly when the frozen directory is or contains a symlink (e.g. `/tmp` → `/private/tmp` on macOS); also eliminates `//foo` double-slash artifact in deny messages
- `skills/careful/bin/check-careful.sh` — safe exception sed regex uses POSIX `[[:space:]]` instead of `\s` (macOS BSD sed compatibility); anchored with `^` to prevent greedy match failure

### Removed
- `/commit`, `/commit-push`, `/pr-create` — git/PR flow consolidated into `/ship` and `/pr-summary`
- `/code-audit` — overlapped with `/review` and `/cso`
- `/validate` — out of scope; project-level lint/typecheck commands are owned by each repo
- `/docs-sync` — out of scope for vibestack
- `/context-init`, `/context-load` — duplicated by `/context-save` and `/context-restore`
- `/resolve-coderabbit` — review-tool-specific; out of scope

Skill count: 53 → 44.

---

## 1.0.0 — 2026-04-24

### Added
- 30 skills: planning (`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/plan-devex-review`, `/autoplan`, `/plan-tune`), code quality (`/review`, `/ship`, `/investigate`, `/cso`), QA (`/qa`, `/qa-only`, `/canary`, `/land-and-deploy`), design (`/design-consultation`, `/design-review`, `/design-html`, `/design-shotgun`), operations (`/retro`, `/learn`, `/document-release`, `/devex-review`, `/health`, `/benchmark`, `/landing-report`), session (`/context-save`, `/context-restore`), safety (`/careful`, `/freeze`, `/unfreeze`, `/guard`)
- `install` script — symlink-based install, no runtime dependencies beyond Bash
- `uninstall` script — clean removal of symlinks and empty directories
- Hook scripts for `/careful` (destructive command warnings) and `/freeze` (edit scope boundary) with full PreToolUse integration
- State management via `~/.vibestack/` flat files
