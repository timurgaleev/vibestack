#### Shared-code rubric

Flag a shared-code opportunity only when it passes all five checks:

- **Prove the callers.** At least two verified first-party source locations, each
  named by function and file:line. Proposed callers from the plan count only when
  labelled as proposals. Similar names or formatting do not prove equivalent
  behavior. Generated and vendored copies never count; trace a generated copy to
  its authored source.
- **Reuse before extracting.** Look for an existing helper or library first.
  Compare inputs, outputs, error handling, side effects and runtime boundaries, and
  keep the differences callers depend on.
- **Keep the helper small.** Name its location, its contract, the callers to
  migrate and the smallest adoption order. No option-heavy helpers, no coupling of
  unrelated components. State the blast radius of a bug in the shared code.
- **Account for the whole change.** Estimate lines removed and added for the
  implementation, then again including tests and integration. Savings = removed −
  added; use ranges when unsure and say when the total change grows.
- **Reject incompatible contracts.** Code that looks alike but promises different
  behavior stays separate, and so does any extraction whose benefit does not pay
  for the abstraction.

Each surviving opportunity is a finding like any other: it goes to the user, and
approving the plan's scope does not approve an extraction.
