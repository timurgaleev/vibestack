#!/usr/bin/env bash
# test-office-hours-contract.sh — /office-hours contracts the rendered skill must
# keep: one outside-voice preflight, prompts sent on stdin, the shared base-branch
# detection, the inline variant pick, the saved sketch and the gated handoff.
#
# Covers:
#   - Phase 3.5 and the sketch voices decide through the shared preflight, and
#     every `codex exec` reads its prompt from stdin with skill instructions off;
#   - Phase 1 finds the diff base with the shared base-branch block, verbatim;
#   - the dead comparison-board flow is gone and the inline pick is documented;
#   - the sketch lives in a private temp dir and its save block copies it into
#     the project dir under the design-doc naming scheme (run for real);
#   - both design-doc templates carry a Wireframe line;
#   - builder-mode question discipline and decision ownership tags;
#   - the next-skill launch is gated on PROACTIVE and SESSION_KIND.
#
# Usage: test/test-office-hours-contract.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset VIBESTACK_HOME

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

OH_SRC="$SRC/skills/office-hours/SKILL.md"
OH="$TMP/r/office-hours/SKILL.md"
VIBESTACK_REPO_ROOT="$SRC" "$HERE/bin/vibe-render-skill" "$OH_SRC" "$OH" >/dev/null 2>&1 \
  || { no "office-hours renders"; echo "office-hours-contract: $pass passed, $fail failed"; exit 1; }

has()    { grep -Fq -- "$1" "$OH"; }
present() { has "$2" && ok "$1" || no "$1 (missing: $2)"; }
absent()  { has "$2" && no "$1 (still present: $2)" || ok "$1"; }
# section "<heading>" -> rendered text from the heading to the next heading of its level or higher
section() {
  python3 -I - "$OH" "$1" <<'PY'
import re, sys
text, head = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
at = text.find(head)
if at < 0:
    sys.exit("no heading: " + head)
level = len(head) - len(head.lstrip("#"))
rest = text[at + len(head):]
m = re.search(r"^#{1,%d} " % level, rest, re.M)
sys.stdout.write(rest[:m.start()] if m else rest)
PY
}
# block_with NEEDLE -> the one fenced bash block in the rendered skill containing NEEDLE
block_with() {
  python3 -I - "$OH" "$1" <<'PY'
import re, sys, textwrap
text, needle = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
blocks = [textwrap.dedent(m.group(2)) for m in re.finditer(r"^([ \t]*)```bash\n(.*?)\n\1```", text, re.S | re.M)]
hits = [b for b in blocks if needle in b]
if len(hits) != 1:
    sys.exit("expected one bash block containing %r, found %d" % (needle, len(hits)))
sys.stdout.write(hits[0] + "\n")
PY
}

echo "outside voices"
# Value: protects=Phase 3.5 and the sketch voices honour codex_reviews=disabled and the under-Codex guard; fails_when=the skill goes back to a bare `command -v codex` check; why_new=test-render-skill.sh only checks the three plan-review skills; seam=none
grep -qx '{{include lib/snippets/outside-voice-preflight.md}}' "$OH_SRC" \
  && ok "office-hours includes the shared preflight" || no "office-hours does not include the shared preflight"
grep -q '^_CODEX_CFG=' "$OH_SRC" && no "office-hours re-inlines its own preflight" || ok "no re-inlined preflight"
absent "no bare CODEX_AVAILABLE binary check" 'echo "CODEX_AVAILABLE"'
# Value: protects=every Codex call reads a Write-tool prompt file on stdin with skill instructions off; fails_when=a voice passes its prompt as an argv string again; why_new=no suite covered office-hours' codex calls; seam=none
# Prose names the command in backticks; only shell lines are checked.
cx="$(grep -n 'codex exec' "$OH" | grep -vF '`codex exec' || true)"
if [ -z "$cx" ]; then
  no "no codex exec call found"
else
  bad="$(printf '%s\n' "$cx" | grep -v 'codex exec - ' || true)"
  [ -z "$bad" ] && ok "every codex exec reads its prompt from stdin" || no "codex exec with an argv prompt: $bad"
  bad="$(printf '%s\n' "$cx" | grep 'codex exec - ' | grep -v 'skills.include_instructions=false' || true)"
  [ -z "$bad" ] && ok "every codex exec turns skill instructions off" || no "codex exec without skills.include_instructions=false: $bad"
fi
present "the sketch voices re-run the preflight" 'run the Phase 3.5 preflight block again'
# Value: protects=a prompt that fails the scan under under_codex does not linger in TMPDIR; fails_when=the claude -p gate stops naming the removal; why_new=the ready block's EXIT trap covers only the Codex path; seam=none
present "the under_codex gate removes the prompt file either way" 'remove the prompt file in either case'

echo "diff base"
# Value: protects=Phase 1 diffs against the detected base, not a hard-coded origin/main; fails_when=the include is dropped or the copy drifts from the snippet; why_new=test-base-branch-detect.sh tests the snippet, not its consumers; seam=none
SNIP_BLOCK="$TMP/bb.sh"
awk '/^```bash$/ {on=1; next} on && /^```$/ {exit} on' "$SRC/lib/snippets/base-branch-detect.md" > "$SNIP_BLOCK"
if [ -s "$SNIP_BLOCK" ] && python3 -I -c 'import sys
sys.exit(open(sys.argv[1]).read() not in open(sys.argv[2]).read())' "$SNIP_BLOCK" "$OH"; then
  ok "rendered office-hours carries the base-branch block verbatim"
else
  no "rendered office-hours lacks the base-branch block"
fi
absent "no hard-coded origin/main diff" 'git diff origin/main'

echo "variant pick"
# Value: protects=the documented flow is the inline pick, not a board vibe-design cannot serve; fails_when=board, feedback-file or reload prose returns; why_new=test-design-html.sh checks only approved_path; seam=none
for dead in 'feedback.json' 'feedback-pending' 'api/reload' 'compare --images' 'design-board'; do
  absent "no comparison-board prose ($dead)" "$dead"
done
present "variants are read inline from saved: paths" 'Read each `saved:` PNG'
present "one question picks and confirms" 'one AskUserQuestion that both picks and confirms'

echo "visual sketch"
absent "no fixed /tmp sketch path" '/tmp/vibestack-sketch'
present "sketch dir is a private mktemp dir" 'mktemp -d "${TMPDIR:-/tmp}/vibe-sketch.XXXXXX"'
# Value: protects=the approved sketch survives the session under the project dir with the design-doc naming scheme; fails_when=the save block copies to a fixed or temp path, or keeps the branch's slash; why_new=nothing ran the sketch blocks before; seam=none
if block_with 'SKETCH_SAVED' > "$TMP/save.sh" 2>"$TMP/err"; then
  W="$TMP/work"; mkdir -p "$W"
  git -C "$W" init -q -b feat/sketchy 2>/dev/null || { git -C "$W" init -q && git -C "$W" checkout -q -b feat/sketchy; }
  SD="$(mktemp -d "$TMP/vibe-sketch.XXXXXX")"
  echo '<html>sketch</html>' > "$SD/sketch.html"; echo png > "$SD/sketch.png"
  python3 -I - "$TMP/save.sh" "$SD/sketch.html" <<'PY'
import sys
p, f = sys.argv[1:3]
s = open(p).read()
assert "<SKETCH_FILE>" in s, "no <SKETCH_FILE> placeholder"
open(p, "w").write(s.replace("<SKETCH_FILE>", f))
PY
  VH="$TMP/vh"; mkdir -p "$VH"
  (cd "$W" && VIBESTACK_HOME="$VH" bash "$TMP/save.sh") > "$TMP/save.out" 2>&1
  PD="$VH/projects/unknown"
  html="$(ls "$PD"/*-feat-sketchy-sketch-*.html 2>/dev/null | head -1)"
  png="$(ls "$PD"/*-feat-sketchy-sketch-*.png 2>/dev/null | head -1)"
  if [ -n "$html" ] && [ -n "$png" ] && [ "$(cat "$html")" = '<html>sketch</html>' ] \
     && printf '%s' "$(basename "$html")" | grep -Eq "^$(whoami)-feat-sketchy-sketch-[0-9]{8}-[0-9]{6}\.html$"; then
    ok "save block copies sketch.html and .png to <PROJECT_DIR>/{user}-{branch}-sketch-{datetime}.*"
  else
    no "save block output: $(tr '\n' '|' < "$TMP/save.out"); files: $(ls -R "$VH" | tr '\n' ' ')"
  fi
  [ ! -e "$SD" ] && ok "save block removes the private sketch dir" || no "save block left the sketch dir behind"
  # Value: protects=the only copy of an approved sketch survives a failed save; fails_when=the block removes the temp dir after cp failed; why_new=the run above only covers a writable project dir; seam=none
  SD2="$(mktemp -d "$TMP/vibe-sketch.XXXXXX")"
  echo '<html>keep</html>' > "$SD2/sketch.html"
  sed "s|$SD/sketch.html|$SD2/sketch.html|" "$TMP/save.sh" > "$TMP/save2.sh"
  VH2="$TMP/vh2"; mkdir -p "$VH2"; : > "$VH2/projects"
  (cd "$W" && VIBESTACK_HOME="$VH2" bash "$TMP/save2.sh") > "$TMP/save2.out" 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ -s "$SD2/sketch.html" ] \
    && ok "a failed save keeps the sketch and exits non-zero" \
    || no "failed save: exit $rc, sketch dir $( [ -e "$SD2" ] && echo kept || echo deleted ); $(tr '\n' '|' < "$TMP/save2.out")"
else
  no "sketch save block: $(cat "$TMP/err")"
fi
# fence_after "<heading>" -> the first fenced block after the heading (the template itself)
fence_after() {
  python3 -I - "$OH" "$1" <<'PY'
import re, sys
text, head = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
at = text.find(head)
m = re.search(r"^```[a-z]*\n(.*?)^```$", text[at:], re.S | re.M) if at >= 0 else None
if not m:
    sys.exit("no template after: " + head)
sys.stdout.write(m.group(1))
PY
}
for t in '### Startup mode design doc template:' '### Builder mode design doc template:'; do
  sec="$(fence_after "$t" 2>&1)"
  printf '%s\n' "$sec" | grep -q '^Wireframe: ' && printf '%s\n' "$sec" | grep -Fq 'none (<reason>)' \
    && ok "${t#\#\#\# } has a Wireframe line with the none form" || no "${t#\#\#\# } lacks a Wireframe line"
done
present "the sketch voice prompt carries the approved approach and the sketch HTML" 'the approved approach and the full sketch HTML'

echo "builder discipline"
B="$(section '## Phase 2B: Builder Mode — Design Partner' 2>&1)"
for phrase in 'beyond the task in front of them' 'Ask why first' 'no options' 'changes what gets built' 'as a proposal'; do
  printf '%s\n' "$B" | grep -Fq -- "$phrase" && ok "builder mode: $phrase" || no "builder mode lacks: $phrase"
done
present "decision bullets name their owner" '`(yours)`'
present "decision bullets name the proposer's reason" '`(my call — <reason>)`'

echo "next-skill handoff"
N="$(section '### Next-skill handoff' 2>&1)"
for phrase in 'PROACTIVE' 'SESSION_KIND: interactive' 'Next: /<skill>' 'EXPANSION' '/plan-ceo-review' '/plan-eng-review' '/plan-design-review'; do
  printf '%s\n' "$N" | grep -Fq -- "$phrase" && ok "handoff: $phrase" || no "handoff lacks: $phrase"
done

echo "builder profile"
absent "no hand-built JSON echoed into the profile" "echo '{\"date\""
# Value: protects=the Phase 6 reader survives legacy or hand-edited profile lines; fails_when=a non-object line or a non-list signals/resources_shown crashes the reader and every count falls back to an introduction; why_new=the append validator only guards new entries; seam=none
if block_with 'RESOURCES_SHOWN_COUNT' > "$TMP/prof.sh" 2>"$TMP/err"; then
  VH3="$TMP/vh3"; mkdir -p "$VH3/bin"
  printf '#!/bin/sh\necho SLUG=demo\n' > "$VH3/bin/vibe-slug"; chmod +x "$VH3/bin/vibe-slug"
  {
    echo '{"mode":"builder","project_slug":"demo","signals":["taste"],"assignment":"first","resources_shown":["u1"]}'
    echo '[1, 2]'
    echo '"just a string"'
    echo '{"mode":"builder","project_slug":"demo","signals":"taste","resources_shown":5,"design_doc":7,"assignment":"second"}'
    echo '{"mode":"resources","resources_shown":{"u":1}}'
    echo '{"mode":"builder","project_slug":"demo","signals":[["x"], "taste"],"assignment":"third"}'
  } > "$VH3/builder-profile.jsonl"
  out="$(cd "$TMP" && VIBESTACK_HOME="$VH3" bash "$TMP/prof.sh" 2>&1)"
  printf '%s\n' "$out" | grep -qx 'SESSION_COUNT: 3' \
    && printf '%s\n' "$out" | grep -qx 'LAST_ASSIGNMENT: second' \
    && printf '%s\n' "$out" | grep -qx 'ACCUMULATED_SIGNALS: taste=2' \
    && printf '%s\n' "$out" | grep -qx 'RESOURCES_SHOWN_COUNT: 1' \
    && ok "profile reader skips non-object lines and non-list fields" \
    || no "profile reader on legacy lines: $(printf '%s' "$out" | tr '\n' '|')"
else
  no "profile reader block: $(cat "$TMP/err")"
fi

echo
echo "office-hours-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
