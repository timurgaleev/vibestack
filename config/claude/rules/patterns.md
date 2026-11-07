# Common Patterns

## Shapes Worth Reusing

Express these in the project's own language and idioms; the shape matters, not
the syntax.

- **API responses** — one envelope across endpoints: a success flag, the data,
  an error message, and paging metadata (total, page, limit) for lists.
- **Data access** — storage sits behind a small interface (find with filters,
  find by id, create, update, delete), so callers and tests never touch the
  driver directly.
- **Timers and subscriptions** — keep the logic in one reusable unit that cleans
  up after itself instead of repeating it at every call site.

## Skeleton Projects

When implementing new functionality:
1. Search for battle-tested skeleton projects
2. Use parallel agents to evaluate options:
   - Security assessment
   - Extensibility analysis
   - Relevance scoring
   - Implementation planning
3. Clone best match as foundation
4. Iterate within proven structure
