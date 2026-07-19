```bash
# vibestack ships a Playwright-backed browse shim (vibe-browse). Detect it and
# bind $B; fall back to text-only tools only when it is genuinely absent.
B="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/{SKILL_NAME}}/../browse/bin/vibe-browse"
[ -x "$B" ] || B="$(command -v vibe-browse || true)"

if [ -n "$B" ] && [ -x "$B" ] && [ "$("$B" status 2>/dev/null)" != "BROWSE_NOT_AVAILABLE" ]; then
  echo "BROWSE_AVAILABLE via $B"
else
  echo "BROWSE_NOT_AVAILABLE"
fi
```

If `BROWSE_AVAILABLE`: use `$B` for the browse commands in this skill. The shim
is stateless — `goto <url>` records the target and each capture verb
re-navigates; use `$B chain "goto …" "click …" "screenshot …"` for a
multi-step flow on one live page, or `$B daemon &` + `$B snapshot` for a
persistent session with `@e1`-style element refs across calls.

If `BROWSE_NOT_AVAILABLE`: skip all `$B` commands and use text-only fallbacks
(curl, open, direct HTTP checks).
