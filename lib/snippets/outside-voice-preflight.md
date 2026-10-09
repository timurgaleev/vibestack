**Preflight — decide whether and how the outside voice runs:**
```bash
_CODEX_CFG=$(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-config get codex_reviews 2>/dev/null || echo enabled)
OUTSIDE_VOICE=""
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
  # Under Codex the cross-model voice is Claude Code. A subagent here is Codex
  # again, so it is only the fallback when the claude CLI is absent.
  if command -v claude >/dev/null 2>&1; then
    OUTSIDE_VOICE="claude_cli"
  else
    OUTSIDE_VOICE="same_model_subagent"
  fi
elif ! command -v codex >/dev/null 2>&1; then
  CODEX_MODE="not_installed"
else
  # An installed binary says nothing about a usable one: `codex --version`
  # succeeds while logged out. The probe makes one cached round trip and names
  # what it found; a missing probe is an unverified Codex, never a ready one.
  _PROBE_OUT=$(${VIBESTACK_HOME:-$HOME/.vibestack}/bin/vibe-codex-probe 2>/dev/null || true)
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
if [ -n "${OUTSIDE_VOICE:-}" ]; then echo "OUTSIDE_VOICE: $OUTSIDE_VOICE"; fi
```
Branch on `CODEX_MODE`:
- **`disabled`** — skip this section entirely; do NOT fall back to a Claude subagent. Print: "Outside voice skipped (codex_reviews disabled). Re-enable: `vibe-config set codex_reviews enabled`." Continue to the next section.
- **`under_codex`** — the host is already Codex, so a nested `codex exec` would be the same model reviewing itself at multiplied cost (force it with `VIBE_FORCE_CODEX_REVIEW=1`). The outside voice is Claude Code instead, and this replaces the subagent path below for this mode:
  - **`OUTSIDE_VOICE: claude_cli`** — print "Outside voice: Claude Code via `claude -p` (this session runs under Codex)." Build the prompt exactly as below, write it to a private prompt file the way the Codex path does (`umask 077; mktemp`, then the Write tool — never interpolate it into shell), and run it from the repo root with a 5-minute timeout: `claude -p --output-format json --disable-slash-commands --tools "" < '<prompt-file>'`. Present the JSON's `result` field verbatim under an `OUTSIDE VOICE (Claude Code via claude -p):` header, then remove the prompt file. A non-zero exit, a timeout, an auth error or an empty `result` means the pass did not complete — say which, then fall through to the subagent below with the same-model label.
  - **`OUTSIDE_VOICE: same_model_subagent`** (or the `claude -p` pass failed) — print "No Claude Code pass (<`claude` not installed, or why `claude -p` failed>) — the subagent below is Codex reviewing Codex, not a cross-model opinion. Install or log in to Claude Code for one." Run the subagent path below, but present its findings under `OUTSIDE VOICE (same-model subagent — not cross-model):` instead of the Claude-subagent header.
- **`not_installed`** — Print: "Codex not installed — using a Claude subagent for the outside voice. Install for true cross-model coverage." Then run the outside voice via the Claude-subagent path below.
- **`not_authed`** — Print: "Codex installed but not authenticated — using a Claude subagent. Run `codex login` or set `$CODEX_API_KEY`; a login is picked up on the next run, and `vibe-codex-probe --refresh` re-checks at once." Then run the Claude-subagent path below.
- **`quota_exhausted`** — Codex refused the call for the account's usage limit. Print: "Codex usage limit reached — using a Claude subagent." followed by the `DETAIL:` line(s) above verbatim (they name when the limit resets), and "Codex is skipped for 15 minutes; retry sooner with `vibe-codex-probe --refresh`." Then run the Claude-subagent path below, exactly as for `not_authed`.
- **`unavailable`** — the probe could not confirm Codex (no answer in time, an unclassified failure, or the probe itself is missing). Print: "Codex unavailable (<the `CODEX:` line above, or `probe missing`>) — using a Claude subagent. Codex is skipped for 15 minutes; retry sooner with `vibe-codex-probe --refresh`." Then run the Claude-subagent path below, exactly as for `not_authed`.
- **`ready`** — run the Codex pass below. If a `CODEX_NOTE: rate_limited` line was printed, say so in one line; the pass still runs, and if it fails, the Codex-error fallback below applies.
