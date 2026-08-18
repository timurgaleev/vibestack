# Infra-error fixture

This fixture is parameterized: the harness puts shim `mktemp` and `mv`
binaries at the front of `PATH` and drives the renderer's `exit 3`
guards. Each shim fails only when its `FAIL_*` variable is set, so every
call a case does not target still reaches the real binary.

`source.md` carries no `{{include}}` directive (nothing to resolve) but
does carry one `${CLAUDE_SKILL_DIR}` token, so the `--skill-dir`
substitution branch has real work to do.

Each case seeds the destination `SKILL.md` with a sentinel and asserts:
exit 3, the `render: infra:` message below on stderr, the sentinel left
untouched, and no `.SKILL.*` temp file left in the destination directory.

Cases:
1. mkdir_dest_dir       dest dir is a regular file  → cannot create dest dir
2. mktemp_check_tmpdir  FAIL_MKTEMP, --check        → cannot create temp dir for --check
3. mktemp_dest_temp     FAIL_MKTEMP                 → cannot create temp file in …
4. mktemp_sub_temp      FAIL_MKTEMP on .SKILL.sub.  → cannot create temp file for substitution
5. mv_final             FAIL_MV                     → cannot move into … (perms?)
6. mv_substitution      FAIL_MV, --skill-dir        → cannot replace temp file after substitution

Not covered: the `skill-dir substitution failed` guard, which needs
python3 to fail and so cannot be reached by shimming mktemp or mv.
