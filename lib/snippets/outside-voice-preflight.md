**Preflight — decide whether and how the outside voice runs:**
```bash
_CODEX_CFG=$(~/.vibestack/bin/vibe-config get codex_reviews 2>/dev/null || echo enabled)
# Master switch: only the literal `disabled` turns the outside voice off. vibestack
# has no validating config binary, so treat any other value as enabled.
if [ "$_CODEX_CFG" = "disabled" ]; then
  CODEX_MODE="disabled"
# Running-under-Codex probe. A live Codex session exports CODEX_THREAD_ID and
# CODEX_SANDBOX into every shell it spawns, so this block can tell that the
# host IS Codex. vibestack ships Codex as a first-class runtime, which makes
# that the normal case, not an exotic one — and spawning `codex exec` from
# inside it means the same model reviewing itself at multiplied token cost,
# with no cross-model value at all. Set VIBE_FORCE_CODEX_REVIEW=1 to spawn the
# nested pass anyway.
elif [ "${VIBE_FORCE_CODEX_REVIEW:-0}" != "1" ] && { [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SANDBOX:-}" ]; }; then
  CODEX_MODE="under_codex"
elif ! command -v codex >/dev/null 2>&1; then
  CODEX_MODE="not_installed"
elif ! codex --version >/dev/null 2>&1; then
  CODEX_MODE="not_authed"
else
  CODEX_MODE="ready"
fi
echo "CODEX_MODE: $CODEX_MODE"
```
Branch on `CODEX_MODE`:
- **`disabled`** — skip this section entirely; do NOT fall back to a Claude subagent. Print: "Outside voice skipped (codex_reviews disabled). Re-enable: `vibe-config set codex_reviews enabled`." Continue to the next section.
- **`under_codex`** — the host is already Codex. Print: "Outside voice skipped — this session is running under Codex, so a nested `codex exec` would be the same model reviewing itself at multiplied cost. Force it with `VIBE_FORCE_CODEX_REVIEW=1`." Then run the outside voice via the Claude-subagent path below, which is a genuinely different model here.
- **`not_installed`** — Print: "Codex not installed — using a Claude subagent for the outside voice. Install for true cross-model coverage." Then run the outside voice via the Claude-subagent path below.
- **`not_authed`** — Print: "Codex installed but not authenticated — using a Claude subagent. Run `codex login` or set `$CODEX_API_KEY`." Then run the Claude-subagent path below.
- **`ready`** — run the Codex pass below.
