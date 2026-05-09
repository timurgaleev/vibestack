## Prior Learnings

Search for relevant learnings from previous sessions:

```bash
_CROSS_PROJ=$(~/.vibestack/bin/vibe-config get cross_project_learnings 2>/dev/null || echo "unset")
echo "CROSS_PROJECT: $_CROSS_PROJ"
if [ "$_CROSS_PROJ" = "true" ]; then
  ~/.vibestack/bin/vibe-learnings-search --limit 10 --cross-project 2>/dev/null || true
else
  ~/.vibestack/bin/vibe-learnings-search --limit 10 2>/dev/null || true
fi
```

If `CROSS_PROJECT` is `unset` (first time): Use AskUserQuestion:

> vibestack can search learnings from your other projects on this machine to find
> patterns that might apply here. This stays local (no data leaves your machine).
> Recommended for solo developers. Skip if you work on multiple client codebases
> where cross-contamination would be a concern.

Options:
- A) Enable cross-project learnings (recommended)
- B) Keep learnings project-scoped only

If A: run `~/.vibestack/bin/vibe-config set cross_project_learnings true`
If B: run `~/.vibestack/bin/vibe-config set cross_project_learnings false`

Then re-run the search with the appropriate flag.

If learnings are found, incorporate them into your analysis. When a review finding
matches a past learning, display:

**"Prior learning applied: [key] (confidence N/10, from [date])"**

This makes the compounding visible. The user should see that vibestack is getting
smarter on their codebase over time.

