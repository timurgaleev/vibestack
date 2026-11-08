#!/usr/bin/env bash
# test-unslop-gate.sh — /unslop cannot hand back a rewrite that changed code,
# inline code, headings or link targets, and its contract keeps the author
# questions, the reader test, the light-edit exit and the secret-file refusal.
#
# The Step 4 preservation block and the Step 1 input check are extracted from
# the rendered skill and run against fixtures, so a regression in the skill
# text itself turns this red.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/skills/unslop/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

SKILL="$TMP/SKILL.md"
"$ROOT/bin/vibe-render-skill" "$SRC" "$SKILL" >/dev/null

# fenced FILE START_REGEX -> body of the first ```bash block whose first line
# matches START_REGEX
fenced() {
  awk -v re="$2" '
    /^```bash$/ { inb=1; first=1; buf=""; next }
    /^```$/ && inb { if (hit) { printf "%s", buf; exit } inb=0; next }
    inb { if (first && $0 ~ re) hit=1; first=0; buf = buf $0 "\n" }
  ' "$1"
}

echo "preservation gate"
GATE=$(fenced "$SKILL" '^# Preservation:')
if [ -z "$GATE" ]; then
  no "Step 4 preservation block missing"
else
  ok "Step 4 preservation block found"
  RUN="$TMP/run"; mkdir -p "$RUN"
  cat > "$TMP/orig.md" <<'EOF'
# Getting Started With The Tool

Furthermore, the tool is a powerful way to sync files. Run `vibe sync --dry-run` first.

```bash
vibe sync --force --target=prod
```

See the [install guide](https://example.com/install) and [notes][n].

## Options

[n]: https://example.com/notes
EOF
  # gate_run REWRITE -> the block's output with its placeholders filled in
  gate_run() {
    cp "$1" "$RUN/rewrite.md"
    printf '%s' "$GATE" \
      | sed -e "s#<input>#$TMP/orig.md#g" -e "s#<run>#$RUN#g" > "$TMP/gate.sh"
    bash "$TMP/gate.sh" 2>&1
  }

  # green: prose and heading case change, every mark kept
  sed -e 's/^# Getting Started With The Tool$/# Getting started with the tool/' \
      -e 's/^Furthermore, the tool is a powerful way to sync files\./The tool syncs files./' \
      "$TMP/orig.md" > "$TMP/prose.md"
  out=$(gate_run "$TMP/prose.md")
  printf '%s\n' "$out" | grep -qx 'CODE: identical' && ok "prose-only rewrite keeps code" || no "prose-only rewrite flagged code: $out"
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && ok "prose-only rewrite keeps marks" || no "prose-only rewrite flagged marks: $out"

  sed 's/--force --target=prod/--target=prod/' "$TMP/orig.md" > "$TMP/flag.md"
  out=$(gate_run "$TMP/flag.md")
  printf '%s\n' "$out" | grep -qx 'CODE: CHANGED' && ok "a flag dropped inside a fence fails" || no "fence change passed: $out"

  sed '/^```bash$/,/^```$/s/vibe sync/vibe  sync/' "$TMP/orig.md" > "$TMP/space.md"
  out=$(gate_run "$TMP/space.md")
  printf '%s\n' "$out" | grep -qx 'CODE: CHANGED' && ok "whitespace inside a fence fails" || no "fence whitespace passed: $out"

  sed 's/`vibe sync --dry-run`/`vibe sync`/' "$TMP/orig.md" > "$TMP/span.md"
  out=$(gate_run "$TMP/span.md")
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && no "inline-code change passed" || ok "an edited inline code span is reported"
  printf '%s\n' "$out" | grep -q 'CODE: identical' && ok "inline-code change leaves the fence check clean" || no "inline-code change tripped the fence check"

  sed 's#(https://example.com/install)#(https://example.com/setup)#' "$TMP/orig.md" > "$TMP/link.md"
  out=$(gate_run "$TMP/link.md")
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && no "changed link target passed" || ok "a changed link target is reported"

  sed '/^\[n\]: /d' "$TMP/orig.md" > "$TMP/ref.md"
  out=$(gate_run "$TMP/ref.md")
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && no "dropped reference link passed" || ok "a dropped reference definition is reported"

  sed '/^## Options$/d' "$TMP/orig.md" > "$TMP/head.md"
  out=$(gate_run "$TMP/head.md")
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && no "dropped heading passed" || ok "a dropped heading is reported"

  # A fence closes only on the same character, at least as long as the one
  # that opened it. Docs about markdown nest a ``` block inside a ```` block,
  # and a ~~~ line is ordinary content inside a ``` block.
  # gate_on ORIG REWRITE -> the block's output for that pair
  gate_on() {
    cp "$2" "$RUN/rewrite.md"
    printf '%s' "$GATE" \
      | sed -e "s#<input>#$1#g" -e "s#<run>#$RUN#g" > "$TMP/gate.sh"
    bash "$TMP/gate.sh" 2>&1
  }
  printf '%s\n' 'Write the block like this:' '' '````markdown' '```bash' 'echo real-command --flag' '```' '````' '' 'Done.' > "$TMP/nest.md"
  sed 's/echo real-command --flag/echo tampered/' "$TMP/nest.md" > "$TMP/nest-new.md"
  out=$(gate_on "$TMP/nest.md" "$TMP/nest-new.md")
  printf '%s\n' "$out" | grep -qx 'CODE: CHANGED' && ok "a change inside a nested fence fails" || no "nested fence change passed: $out"
  printf '%s\n' 'Text.' '' '```text' '~~~' 'keep this line' '```' '' 'More.' > "$TMP/tilde.md"
  sed 's/keep this line/changed line/' "$TMP/tilde.md" > "$TMP/tilde-new.md"
  out=$(gate_on "$TMP/tilde.md" "$TMP/tilde-new.md")
  printf '%s\n' "$out" | grep -qx 'CODE: CHANGED' && ok "a ~~~ line inside a backtick fence does not close it" || no "tilde-in-backtick change passed: $out"
  out=$(gate_on "$TMP/nest.md" "$TMP/nest.md")
  printf '%s\n' "$out" | grep -qx 'CODE: identical' && ok "an untouched nested fence passes" || no "untouched nested fence flagged: $out"
  # Value: protects=a line of four spaces plus ``` stays code inside a fence; fails_when=fence recognition accepts 4+ leading spaces; why_new=new case; seam=none
  printf '%s\n' 'Text.' '' '```text' '    ```' 'keep this line' '```' '' 'More.' > "$TMP/indent.md"
  sed 's/keep this line/changed line/' "$TMP/indent.md" > "$TMP/indent-new.md"
  out=$(gate_on "$TMP/indent.md" "$TMP/indent-new.md")
  printf '%s\n' "$out" | grep -qx 'CODE: CHANGED' && ok "an indented fence line does not close a fence" || no "indented fence line closed the fence: $out"
  # Value: protects=swapping the destinations of two links is caught; fails_when=link targets are compared as a bag without their text; why_new=new case; seam=none
  printf '%s\n' 'See [docs](https://a.example) and [api](https://b.example).' > "$TMP/swap.md"
  printf '%s\n' 'See [docs](https://b.example) and [api](https://a.example).' > "$TMP/swap-new.md"
  out=$(gate_on "$TMP/swap.md" "$TMP/swap-new.md")
  printf '%s\n' "$out" | grep -qx 'MARKS: identical' && no "swapped link destinations passed" || ok "swapped link destinations are reported"
fi

echo "input check"
CHECK=$(fenced "$SKILL" '^# Input check:')
if [ -z "$CHECK" ]; then
  no "Step 1 input check missing"
else
  ok "Step 1 input check found"
  check_run() {
    printf '%s' "$CHECK" | sed "s#<path>#$1#g" > "$TMP/check.sh"
    bash "$TMP/check.sh" 2>/dev/null
  }
  mkdir -p "$TMP/in/.ssh" "$TMP/in/.aws"
  for f in .env .env.local .envrc .env_local .envs server.pem tls.key ID.PEM .ssh/id_ed25519 .aws/config \
           credentials .git-credentials credentials.json aws-credentials; do
    printf 'SECRET=1\n' > "$TMP/in/$f"
    out=$(check_run "$TMP/in/$f")
    case "$out" in "INPUT: REFUSE"*) ok "refuses $f" ;; *) no "did not refuse $f: $out" ;; esac
  done
  # a prose-named link into a secret store is judged by where it points
  ln -s "$TMP/in/.ssh/id_ed25519" "$TMP/in/intro.md"
  out=$(check_run "$TMP/in/intro.md")
  case "$out" in "INPUT: REFUSE"*) ok "refuses a prose-named symlink to a key" ;; *) no "symlink to a key not refused: $out" ;; esac
  ln -s "$TMP/in/.ssh" "$TMP/in/docs"
  printf 'Host x\n' > "$TMP/in/.ssh/notes.md"
  out=$(check_run "$TMP/in/docs/notes.md")
  case "$out" in "INPUT: REFUSE"*) ok "refuses a path through a symlinked directory" ;; *) no "symlinked dir not refused: $out" ;; esac
  for f in managing-credentials.md aws-credentials.txt; do
    printf '# Rotating keys\n' > "$TMP/in/$f"
    out=$(check_run "$TMP/in/$f")
    case "$out" in "INPUT: WARN"*) ok "warns, not refuses, on prose named $f" ;; *) no "$f not a warning: $out" ;; esac
  done
  out=$(check_run "$TMP/in/missing.md")
  case "$out" in "INPUT: STOP"*) ok "a missing file stops" ;; *) no "missing file did not stop: $out" ;; esac
  mkdir -p "$TMP/in/folder.md"
  out=$(check_run "$TMP/in/folder.md")
  case "$out" in "INPUT: STOP"*) ok "a directory stops" ;; *) no "directory did not stop: $out" ;; esac
  printf '# Notes\n' > "$TMP/in/NOTES.MD"
  out=$(check_run "$TMP/in/NOTES.MD")
  [ "$out" = "INPUT: OK" ] && ok "an uppercase prose extension passes" || no "NOTES.MD not OK: $out"
  out=$(check_run '~/.ssh/config')
  case "$out" in "INPUT: REFUSE"*) ok "refuses an unexpanded ~/.ssh path" ;; *) no "did not refuse ~/.ssh/config: $out" ;; esac
  # Value: protects=the input check refuses common secret files and never runs text from the path; fails_when=key copies with a prose extension, .netrc/.npmrc/.htpasswd/*.p12 or .kube/.gnupg pass, or a $(...) in the path executes; why_new=new cases; seam=none
  mkdir -p "$TMP/in/.kube" "$TMP/in/.gnupg"
  for f in id_rsa.txt id_ed25519.md .netrc .npmrc .htpasswd cert.p12 .kube/config .gnupg/notes.txt; do
    printf 'SECRET=1\n' > "$TMP/in/$f"
    out=$(check_run "$TMP/in/$f")
    case "$out" in "INPUT: REFUSE"*) ok "refuses $f" ;; *) no "did not refuse $f: $out" ;; esac
  done
  out=$(check_run "$TMP/in/x\$(touch $TMP/pwned).md")
  [ ! -e "$TMP/pwned" ] && ok "a \$(...) in the path is never run" || no "the path's \$(...) ran"
  mkdir -p "$TMP/home"; printf '# Notes\n' > "$TMP/home/notes.md"
  out=$(printf '%s' "$CHECK" | sed "s#<path>#~/notes.md#g" > "$TMP/check.sh"; HOME="$TMP/home" bash "$TMP/check.sh" 2>/dev/null)
  [ "$out" = "INPUT: OK" ] && ok "a ~/ path is expanded" || no "~/notes.md not expanded: $out"
  # Value: protects=hosts without readlink -f (macOS before 12.3) still check files, and still refuse a final symlink; fails_when=a failed readlink -f stops every path or lets a link through; why_new=new case; seam=a readlink shim that rejects -f
  mkdir -p "$TMP/oldrl"; printf '#!/bin/sh\n[ "$1" = -f ] && exit 1\nexec /usr/bin/readlink "$@"\n' > "$TMP/oldrl/readlink"; chmod +x "$TMP/oldrl/readlink"
  printf '# Plain\n' > "$TMP/in/plain.md"; ln -s "$TMP/in/plain.md" "$TMP/in/alias.md"
  printf '%s' "$CHECK" | sed "s#<path>#$TMP/in/plain.md#g" > "$TMP/check.sh"
  out=$(PATH="$TMP/oldrl:$PATH" bash "$TMP/check.sh" 2>/dev/null)
  [ "$out" = "INPUT: OK" ] && ok "without readlink -f a regular file still passes" || no "no readlink -f: regular file got $out"
  printf '%s' "$CHECK" | sed "s#<path>#$TMP/in/alias.md#g" > "$TMP/check.sh"
  out=$(PATH="$TMP/oldrl:$PATH" bash "$TMP/check.sh" 2>/dev/null)
  case "$out" in "INPUT: OK") no "without readlink -f a symlink passed" ;; *) ok "without readlink -f a final symlink is not followed ($out)" ;; esac
  printf '# Title\n\nSome prose.\n' > "$TMP/in/README.md"
  out=$(check_run "$TMP/in/README.md")
  [ "$out" = "INPUT: OK" ] && ok "a README passes" || no "README not OK: $out"
  printf 'x = 1\n' > "$TMP/in/main.py"
  out=$(check_run "$TMP/in/main.py")
  case "$out" in "INPUT: WARN"*) ok "a non-prose extension warns" ;; *) no "main.py did not warn: $out" ;; esac
  awk 'BEGIN { for (i = 0; i < 10000; i++) print "a line of prose that pads the file out to well past the cap" }' > "$TMP/in/big.md"
  out=$(check_run "$TMP/in/big.md")
  case "$out" in "INPUT: STOP"*) ok "a file over 500 KB stops" ;; *) no "big file did not stop: $out" ;; esac
fi

echo "contract"
for s in 'Questions for the author' 'Voice:    draft only (fidelity unchecked)' \
         'Unstated first-person experience or credential stacking' \
         'Step 2b' 'light edit' 'code-orig.txt' 'code-new.txt' \
         'Transition-tic openers' 'Signposting' 'Authority tropes' \
         'Negative-parallelism triples' 'Staged run-ups' 'Same caveat repeated' \
         'security warnings' 'legal or compliance wording' 'numbered destructive procedures'; do
  grep -qF -- "$s" "$SKILL" && ok "skill names: $s" || no "skill lacks: $s"
done
grep -qF -- '--voice' "$SKILL" && no "a --voice flag is offered" || ok "no --voice flag"
grep -qF 'checks fenced blocks only' "$SKILL" && ok "the gate says it checks fenced blocks only" || no "the gate does not say indented and quoted code are unchecked"
grep -qF 'make a light edit instead' "$SKILL" && ok "the light-edit rule reads in order" || no "light-edit paragraph out of order"
for n in 31 32 33 34 35 36 37; do
  grep -qE "^$n\. \*\*" "$SKILL" && ok "catalogue entry $n present" || no "catalogue entry $n missing"
done
dups=$(sed -n '/^## Step 2:/,/^### Mechanical first pass/p' "$SKILL" | grep -oE '^[0-9]+\.' | sort | uniq -d)
[ -z "$dups" ] && ok "catalogue numbers are unique" || no "duplicate catalogue numbers: $dups"
sed -n '/^## Important Rules/,$p' "$SKILL" | grep -E '^1\. ' | grep -qF 'preservation' \
  && ok "Important Rule 1 names the preservation check" || no "Important Rule 1 does not name the preservation check"
grep -qF "^(Furthermore|Moreover|Additionally|Fundamentally)" "$SKILL" && ok "mechanical pass greps transition tics" || no "no transition-tic grep"
grep -qF "let's dive|without further ado|here's the thing|sound familiar" "$SKILL" && ok "mechanical pass greps signposting" || no "no signposting grep"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
