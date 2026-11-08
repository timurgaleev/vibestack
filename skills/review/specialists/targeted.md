# Targeted Specialist Review Checklist

Scope: Any size of diff, when SCOPE_AUTH=true or the diff touches paid-API clients, caps/limits/budgets, or tokens/secrets/redaction
Output: JSON objects, one finding per line. Schema:
{"severity":"CRITICAL|INFORMATIONAL","confidence":N,"path":"file","line":N,"category":"targeted","summary":"...","fix":"...","fingerprint":"path:line:targeted","specialist":"targeted"}
Optional: line, fix, fingerprint, evidence, test_stub, cause.
If no findings: output `NO FINDINGS` and nothing else.

---

A small diff is where money, gates and secrets break quietly: one deleted check, one widened
default. Read every hunk that touches them — **deleted lines as closely as added ones**. A line the
diff removes is a guard that no longer runs.

## Categories

### Money and spend
- A paid call (LLM, cloud API, SMS, email, payment) reachable without a cap, budget check or
  per-user limit, or a loop/retry around one with no bound
- A cap, limit or budget raised, defaulted to unlimited, or read from input without a ceiling
- Cost or quota accounting moved after the call it is meant to gate

### Gates and authorization
- An auth, permission, ownership or feature check deleted, moved behind a cache, or turned
  into a warning
- A default flipped from deny to allow; an `if` inverted; an early return removed
- A new route, command or job that skips the middleware its siblings use

### Secrets and redaction
- A token, key or secret newly logged, echoed, put in a URL, written to a file or sent to a
  third party
- A redaction, masking or scrubbing step removed, narrowed, or applied after the write it
  protects
- A secret compared with `==` instead of a constant-time comparison

When a finding's root cause sits elsewhere (the cap is read in one file and bypassed in
another), put it in `cause` as `{"path":"file","line":N}`.
