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
else
  # An installed binary says nothing about a usable one: `codex --version`
  # succeeds while logged out. The probe makes one cached round trip and names
  # what it found; a missing probe is an unverified Codex, never a ready one.
  _PROBE_OUT=$(~/.vibestack/bin/vibe-codex-probe 2>/dev/null || true)
  [ -n "$_PROBE_OUT" ] && printf '%s\n' "$_PROBE_OUT"
  case "$(printf '%s\n' "$_PROBE_OUT" | sed -n '1s/^CODEX: //p')" in
    usable)          CODEX_MODE="ready" ;;
    rate_limited)    CODEX_MODE="ready"; echo "CODEX_NOTE: rate_limited — running anyway; the pass's own result decides" ;;
    missing)         CODEX_MODE="not_installed" ;;
    unauthenticated) CODEX_MODE="not_authed" ;;
    quota_exhausted) CODEX_MODE="quota_exhausted" ;;
    *)               CODEX_MODE="unavailable" ;;
  esac
fi
echo "CODEX_MODE: $CODEX_MODE"
```
Branch on `CODEX_MODE`:
- **`disabled`** — skip this section entirely; do NOT fall back to a Claude subagent. Print: "Outside voice skipped (codex_reviews disabled). Re-enable: `vibe-config set codex_reviews enabled`." Continue to the next section.
- **`under_codex`** — the host is already Codex. Print: "Outside voice skipped — this session is running under Codex, so a nested `codex exec` would be the same model reviewing itself at multiplied cost. Force it with `VIBE_FORCE_CODEX_REVIEW=1`." Then run the outside voice via the Claude-subagent path below, which is a genuinely different model here.
- **`not_installed`** — Print: "Codex not installed — using a Claude subagent for the outside voice. Install for true cross-model coverage." Then run the outside voice via the Claude-subagent path below.
- **`not_authed`** — Print: "Codex installed but not authenticated — using a Claude subagent. Run `codex login` or set `$CODEX_API_KEY`; a login is picked up on the next run, and `vibe-codex-probe --refresh` re-checks at once." Then run the Claude-subagent path below.
- **`quota_exhausted`** — Codex refused the call for the account's usage limit. Print: "Codex usage limit reached — using a Claude subagent." followed by the `DETAIL:` line(s) above verbatim (they name when the limit resets), and "Codex is skipped for 15 minutes; retry sooner with `vibe-codex-probe --refresh`." Then run the Claude-subagent path below, exactly as for `not_authed`.
- **`unavailable`** — the probe could not confirm Codex (no answer in time, an unclassified failure, or the probe itself is missing). Print: "Codex unavailable (<the `CODEX:` line above, or `probe missing`>) — using a Claude subagent. Codex is skipped for 15 minutes; retry sooner with `vibe-codex-probe --refresh`." Then run the Claude-subagent path below, exactly as for `not_authed`.
- **`ready`** — run the Codex pass below. If a `CODEX_NOTE: rate_limited` line was printed, say so in one line; the pass still runs, and if it fails, the Codex-error fallback below applies.
