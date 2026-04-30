# Interface Design

When the user is open to alternatives, generate three to five candidate interface shapes for the deepened module — not implementations, just shapes. Each shape is the **complete contract** a caller has to know: types, invariants, error modes, ordering rules, configuration.

## What to vary

Vary the things that have outsized impact on **leverage** and **locality**:

- **Granularity** — one wide interface vs. several narrow ones.
- **Statefulness** — pure functions, configured constructors, long-lived objects.
- **Error model** — exceptions, result types, error events, panic-on-violation.
- **Ordering** — required call sequences vs. commutative operations.
- **Async shape** — sync, callbacks, promises, streams, generators.
- **Identity** — value objects vs. entity objects vs. opaque handles.

Don't vary surface ergonomics that don't change the contract (parameter order, naming style). That's noise.

## What each candidate must include

For every candidate, write down:

1. The **interface** — the shape a caller depends on.
2. The **invariants** the interface promises to preserve.
3. The **failure modes** a caller has to handle.
4. The **deepest single example** — one realistic call site, end-to-end, showing the full lifecycle.
5. The **leverage**: what does a caller get for free?
6. The **locality cost**: where does change concentrate?

If you can't fill in every slot, the candidate isn't ready to evaluate yet — keep working.

## Sub-agent fan-out

For non-trivial deepenings, fan out: dispatch the candidates to multiple sub-agents in parallel, one per shape, each with a focused brief to flesh out the contract and the deepest example.

Include [LANGUAGE.md](LANGUAGE.md) vocabulary in the brief, plus the project's domain vocabulary (e.g. from `CONTEXT.md` if it exists), so each sub-agent names things consistently with the architecture language and the project's domain language.

Synthesize the returned candidates into a single comparison table for the user.

## Comparison

Put the candidates side by side. The columns matter more than the rows:

- **Interface size** — how much the caller has to know.
- **Behavioral coverage** — how much of the implementation surface is reachable.
- **Test surface** — what kinds of tests this shape makes easy / hard.
- **Migration cost** — how disruptive adopting this shape is for existing callers.
- **Invariants under stress** — what breaks first under contention, partial failure, unusual ordering.

Don't pick. Hand the comparison to the user. The user picks.
