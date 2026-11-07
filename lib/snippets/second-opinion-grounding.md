## Date Grounding

A second-opinion model knows nothing past its training cutoff, so a model,
tool, library, API or version released after it reads as made up, and the
reviewer reports real code as hallucinated. Once the prompt file is written and
before its run block, append today's date and the rule for unrecognised names to
it. Substitute the prompt file's full path, as printed when it was created, for
`<prompt-file-path>`:

```bash
_GF='<prompt-file-path>'
[ -s "$_GF" ] || { echo "Not run: $_GF is missing or empty; write the prompt first." >&2; exit 1; }
_GD="Current date (UTC): $(date -u +%F)"
printf '\n%s\n%s\n' "$_GD" "Do not call a model, tool, library, API or version hallucinated only because you do not recognize it; mark the claim [unverified]." >> "$_GF"
echo "$_GD"
```

The block prints the date line it wrote. If it stops, the prompt was never
written: write it, then run the block again. Never send a prompt this block has
not grounded.
