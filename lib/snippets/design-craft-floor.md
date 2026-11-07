**Craft floor.** A page that misses any line below is not finished, however good it
looks. Build to it; when auditing, a miss is a finding.

**Proof belongs to the user.** A testimonial, customer logo, usage number, rating,
award, certification, price, guarantee or quote appears only when the user supplied
it (or it is on the live page they asked you to work from). Where one is missing,
write `[Needs proof: <what would go here>]` in its place. Never put a believable
stand-in there: invented proof ships as if it were true.

**Illustrative content stays honest.** No placeholder people (Jane Doe, stock
headshots), no invented company names or logos, no suspiciously round numbers
("10,000+ teams", "99.9% uptime"), and no filler words ("seamless", "powerful",
"next-generation", "unlock"). Copy names what this user's visitor gets.

**Ship floor**, on every page:
- a specific `<title>` and a meta description
- a favicon
- a skip link to `<main>` as the first focusable element
- landmarks: `<header>`, `<nav>`, `<main>`, `<footer>`
- alt text on every meaningful image, `alt=""` on decorative ones
- no `href="#"`: a link goes somewhere, an action is a `<button>`
- `aria-current="page"` on the nav item for the current page
- form errors shown inline beside the field, not in an alert or only after submit

**Values come from the scale.** Every spacing step, font size, radius and color is a
token from the design system (DESIGN.md, `:root` custom properties or the Tailwind
theme). An off-scale one-off such as `13px` or `#3b82f7` is either promoted to a
token or replaced by the nearest one.

**Line breaks are set.** `text-wrap: balance` on headings, `text-wrap: pretty` on
body paragraphs.

**Motion never hides content.** Every element renders in its final, visible state
from CSS alone; script only enhances. An entrance starts from an
IntersectionObserver, never from a scroll handler revealing a block that sat at
opacity 0, and it never animates from `scale(0)`. A full-height section uses
`100dvh` (after a `100vh` fallback line) so mobile browser bars do not crop it.
Under `prefers-reduced-motion: reduce` there is no entrance at all.

**Before this can ship.** End with this list for the user, one line per open item:
every `[Needs proof: …]` marker, each placeholder legal link (privacy, terms,
imprint), each form without a real endpoint, missing assets (favicon, social
image), and the index or noindex decision. When nothing is open, say so in one line.
