## Date Grounding

A second-opinion model knows nothing past its training cutoff, so a model,
tool, library, API or version released after it reads as made up, and the
reviewer reports real code as hallucinated. Once the prompt file is written and
before its run block, append today's date and the rule for unrecognised names to
it. The block rebuilds the path from the prompt file's printed name (the
`name:` part of its `PROMPT_FILE:` line), so no full path, which may hold a
quote, is pasted into shell source. Substitute that name for
`<prompt-file-name>`:

```bash
_GN='<prompt-file-name>'
case "$_GN" in ''|/*|*..*|*[!A-Za-z0-9._/-]*) echo "Not run: <prompt-file-name> was not substituted with the printed name." >&2; exit 1 ;; esac
_GF="$(git rev-parse --show-toplevel 2>/dev/null)/.vibestack/tmp/$_GN"
[ -s "$_GF" ] || _GF="${TMPDIR:-/tmp}/$_GN"
[ -s "$_GF" ] || { echo "Not run: prompt file $_GN is missing or empty; write the prompt first." >&2; exit 1; }
_GD="Current date (UTC): $(date -u +%F)"
printf '\n%s\n%s\n' "$_GD" "Do not call a model, tool, library, API or version hallucinated only because you do not recognize it; mark the claim [unverified]." >> "$_GF"
echo "$_GD"
```

The block prints the date line it wrote. If it stops, the prompt was never
written: write it, then run the block again. Never send a prompt this block has
not grounded.
