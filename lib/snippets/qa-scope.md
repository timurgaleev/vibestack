## Choosing the surface

Decide what you are testing before you look for a running app. A surface is the
thing a user of this change touches:

- **browser** — the change reaches pages: a URL was given, or the diff maps to
  routes, views, components or styles that render in a page.
- **functional** — the change is behavior with no page of its own: a CLI, a
  library or SDK, an API-only endpoint, a worker or scheduled job, a webhook
  handler, a migration or data script. It is tested by running it and checking
  what it did.
- **mixed** — both: a diff that changes a backend behavior and the pages built
  on it. Each part is tested on its own surface and reported separately.

No URL does not imply a web server. A repo with no URL and no listening port
may be a CLI or a library; do not start or hunt for a server to manufacture a
browser surface. Choose from the request and the diff (entry points, `bin/`,
package `bin`/`main` fields, route and handler files, job definitions), then
print one line before going further:

```
SURFACE: browser|functional|mixed — <the evidence that decided it>
```

On a functional surface, skip the browser setup and the port scan, and follow
"Functional surface" below. On a browser or mixed surface, the browser workflow
runs as written; on mixed, the functional part follows "Functional surface" too.

**Isolation and ownership come before the first functional probe.** Name what
each probe will read and write — files, a database, a queue, a remote API —
and make sure every write lands on state this run owns: a scratch directory
from `mktemp -d`, a test database or local instance you started, or one the
user named for this run. A probe never writes to a shared, staging or
production resource, and a remote host follows the LOCAL / NON-LOCAL rules in
"Rules for probing the target". When no isolated target exists, ask with AskUserQuestion
before probing; never fall back to the real one. Stop what you started when the
run ends, and never delete data the run did not create.
