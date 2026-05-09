# Arg parsing fixture

This fixture is parameterized: the harness invokes the renderer with the
following invalid argument lists and asserts each exits non-zero (2) with
a usage-line on stderr.

Cases:
1. No arguments:                vibe-render-skill
2. One argument:                vibe-render-skill foo
3. Three arguments:             vibe-render-skill a b c
4. Unknown flag (not --check):  vibe-render-skill --bogus a b
5. --check with one argument:   vibe-render-skill --check foo
