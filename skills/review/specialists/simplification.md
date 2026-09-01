# Simplification Specialist Review Checklist

Scope: When DIFF_LINES > 100
Output: JSON objects, one finding per line. Schema:
{"severity":"INFORMATIONAL","confidence":N,"path":"file","line":N,"category":"simplification","summary":"...","fix":"...","fingerprint":"path:line:simplification","specialist":"simplification"}
Optional: line, fix, fingerprint, evidence, test_stub.
If no findings: output `NO FINDINGS` and nothing else.

---

This lens hunts structure nobody asked for. Every finding is **advisory** — always
`INFORMATIONAL`, never `CRITICAL`, and never auto-fixed. A defect breaks something;
over-engineering only costs the next reader. Confusing the two turns a taste call
into a blocking gate, so keep the severity honest even when the finding is obvious.

Judge the diff against what the branch set out to do, not against an ideal design.
Do NOT report missing coverage, missing tests, or missing error handling here —
those belong to the testing and maintainability lenses, and duplicating them
inflates the finding count without adding information.

---

## Categories

### Hand-Rolled Standard Library
- Custom implementations of things the language or runtime already ships (date math, deep clone, debounce, retry, path joining, UUID generation, argument parsing)
- Reimplemented collection helpers that the standard library provides
- A bespoke cache, queue, or pool where the framework already has one
- String or date formatting written by hand instead of the platform formatter

### One-Implementation Abstractions
- An interface, protocol, or abstract base class with exactly one implementer and no second one in sight
- A factory, registry, or strategy dispatch that resolves to a single branch
- A configuration option, feature flag, or parameter with exactly one caller passing exactly one value
- Wrapper layers that forward every call unchanged to the thing they wrap
- Generic type parameters instantiated at exactly one type

### Dependencies Duplicating Platform Features
- A new dependency for behavior the platform, framework, or standard library already covers
- A second library added for a job an existing dependency already does
- A heavyweight package pulled in for one small function

### Speculative Generality
- Extension points, hooks, or plugin surfaces with no current consumer
- Data model fields, enum members, or API parameters that nothing reads
- Code paths guarded by conditions that cannot be true yet ("when we add tenants…")
- Versioned or pluggable formats where exactly one format exists

### Indirection Without Payoff
- A helper called once whose body is shorter than its call site's setup
- Chains of thin modules where each layer only renames arguments
- State threaded through several layers to reach one consumer that could own it
- Configuration read in one place, passed through five, used in one

---

## Reporting

Name what the simpler version would be and what it costs to keep the current shape.
"Could be simpler" without a concrete alternative is noise — either state the
replacement (the stdlib call, the collapsed layer, the deleted flag) or drop the
finding. When the extra structure is load-bearing for something already in the diff,
that is not a finding at all.
