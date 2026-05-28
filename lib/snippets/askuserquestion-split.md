## Handling 5+ options — split, never drop

AskUserQuestion caps every call at **4 options**. With 5+ real options, NEVER
drop, merge, or silently defer one to fit. Pick a compliant shape:

- **Batch into ≤4-groups** — for coherent alternatives (e.g. version bumps,
  layout variants). One call; surface the 5th only if the first 4 don't fit.
- **Split per-option** — for independent scope items (e.g. "ship E1..E6?").
  Fire N sequential calls, one per option. Default to this when unsure.

Per-option call shape: `D<N>.k` header (e.g. D3.1..D3.5), ELI10 per option,
Recommendation, kind-note (no completeness score — Include/Defer/Cut/Hold are
decision actions), and 4 buckets:
**A) Include**, **B) Defer**, **C) Cut**, **D) Hold** (stop chain, discuss).

When the user picks **Hold**, stop the chain immediately — do not queue later
options behind it. Resume when the user says "continue".

After the chain, fire `D<N>.final` to validate the assembled set (reprompt
dependency conflicts) and confirm shipping it. Use `D<N>.revise-<k>` to
revise one option without re-running the chain.

For N>6, fire a `D<N>.0` meta-AskUserQuestion first (proceed / narrow / batch).

question_ids for split chains: `{SKILL_NAME}-split-<option-slug>` (kebab-case
ASCII, ≤64 chars, `-2`/`-3` suffix on collision). **Split-chain per-option
calls are NEVER auto-decided** — even if a question preference would otherwise
auto-pick, ask normally. The user's option set is sacred; restoring their
sovereignty over the decision space is the entire point of splitting.

**Full rule + worked examples + Hold/dependency/final-summary semantics:** see
`docs/askuserquestion-split.md`. Read on demand when N>4.
