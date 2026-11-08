#!/usr/bin/env bash
# test-plan-tune-profile.sh — the profile-writing blocks of skills/plan-tune/SKILL.md.
#
# Runs the setup block (one dimension per answer) and the edit block with an
# isolated HOME and VIBESTACK_HOME, from an empty working directory. The profile
# must land under VIBESTACK_HOME with numbers, not strings; nothing may appear in
# the working directory (a quoted heredoc once wrote a file literally named
# `$_PROFILE` there); an unknown dimension or a non-numeric value must fail
# without writing; and an edit must keep the dimensions it did not touch.
#
# Usage: test/test-plan-tune-profile.sh [path/to/plan-tune/SKILL.md]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${1:-$ROOT/skills/plan-tune/SKILL.md}"
[ -f "$SKILL" ] || { echo "no such file: $SKILL" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# block "<text that precedes the block>" DIM VALUE -> the first ```bash block
# after that text, with the placeholders filled in as the skill tells the model to.
block() {
  python3 -I - "$SKILL" "$1" "$2" "$3" <<'PY'
import re, sys
text, anchor, dim, value = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2], sys.argv[3], sys.argv[4]
at = text.find(anchor)
if at < 0:
    sys.exit("anchor not found: " + anchor)
m = re.search(r"```bash\n(.*?)\n[ \t]*```", text[at:], re.S)
if not m:
    sys.exit("no bash block after: " + anchor)
body = m.group(1).replace("<DIM>", dim).replace("<VALUE>", value).replace("<NEW_VALUE>", value)
# An older form took all five answers at once.
for n in range(1, 6):
    body = body.replace("<Q%d_VALUE>" % n, value)
sys.stdout.write(body + "\n")
PY
}

SETUP_ANCHOR="**Q5 — architecture_care:**"
EDIT_ANCHOR="## Edit declared profile"

# run ANCHOR DIM VALUE -> runs the block in a fresh empty cwd; sets CWD.
run() {
  local script
  script="$(block "$1" "$2" "$3")" || { echo "extract failed" >&2; return 99; }
  CWD="$(mktemp -d "$TMP/cwd.XXXXXX")"
  (cd "$CWD" && HOME="$TMP/home" VIBESTACK_HOME="$TMP/home/.vibestack" bash -c "$script") >/dev/null 2>&1
}
PROFILE="$TMP/home/.vibestack/developer-profile.json"
declared() {  # DIM -> "<type> <value>" of declared.DIM, or "missing"
  python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1])).get("declared", {})
except Exception:
    print("missing"); sys.exit()
v = d.get(sys.argv[2])
print("missing" if v is None else "%s %s" % (type(v).__name__, v))' "$PROFILE" "$1"
}
mkdir -p "$TMP/home"

echo "setup block"
run "$SETUP_ANCHOR" scope_appetite 0.85; rc=$?
[ "$rc" -eq 0 ] && ok "saving one answer exits 0" || no "saving one answer exited $rc"
[ "$(declared scope_appetite)" = "float 0.85" ] && ok "declared.scope_appetite is the number 0.85" \
                                               || no "declared.scope_appetite is $(declared scope_appetite)"
[ -z "$(ls -A "$CWD")" ] && ok "nothing written to the working directory" \
                         || no "working directory got: $(ls -A "$CWD" | tr '\n' ' ')"
run "$SETUP_ANCHOR" risk_tolerance 0.25
[ "$(declared scope_appetite)" = "float 0.85" ] && [ "$(declared risk_tolerance)" = "float 0.25" ] \
  && ok "a second answer keeps the first" || no "after Q2: scope=$(declared scope_appetite) risk=$(declared risk_tolerance)"

cp "$PROFILE" "$TMP/before.json" 2>/dev/null
run "$SETUP_ANCHOR" not_a_dimension 0.5; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$PROFILE" "$TMP/before.json" && ok "an unknown dimension fails and writes nothing" \
                                                       || no "unknown dimension: rc=$rc"
run "$SETUP_ANCHOR" autonomy 'high$(touch pwned)'; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$PROFILE" "$TMP/before.json" && ok "a non-numeric value fails and writes nothing" \
                                                       || no "non-numeric value: rc=$rc"
[ ! -e "$CWD/pwned" ] && ok "the value is never executed" || no "the value ran as a command"

echo "edit block"
run "$EDIT_ANCHOR" autonomy 0.4; rc=$?
[ "$rc" -eq 0 ] && [ "$(declared autonomy)" = "float 0.4" ] && ok "edit writes the number" \
                                                          || no "edit: rc=$rc autonomy=$(declared autonomy)"
[ "$(declared scope_appetite)" = "float 0.85" ] && [ "$(declared risk_tolerance)" = "float 0.25" ] \
  && ok "edit keeps the untouched dimensions" || no "edit dropped other dimensions"
[ -z "$(ls -A "$CWD")" ] && ok "edit writes nothing to the working directory" \
                         || no "edit wrote: $(ls -A "$CWD" | tr '\n' ' ')"
cp "$PROFILE" "$TMP/before.json" 2>/dev/null
run "$EDIT_ANCHOR" bogus 0.4; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$PROFILE" "$TMP/before.json" && ok "edit rejects an unknown dimension" \
                                                       || no "edit unknown dimension: rc=$rc"

echo "wording"
# The profile is advisory: only an explicit never-ask preference skips a
# question. Shared text that promises otherwise contradicts plan-tune's consent copy.
hits="$(grep -rln 'profile already settles' "$ROOT/lib/snippets" "$ROOT/skills" 2>/dev/null || true)"
[ -z "$hits" ] && ok "no skill text says the profile skips questions" \
               || no "profile-skips-questions wording in: $hits"

echo "no fabricated observed profile"
# Nothing in vibestack derives an observed profile from the question log, so the
# skill must not show one, compare against one, or call a log "calibrated".
section() { awk -v s="$1" -v e="$2" '$0 ~ s {on=1; print; next} on && $0 ~ e {on=0} on' "$SKILL"; }
NOT_AVAILABLE='not available: vibestack does not derive an observed profile'
for sec in '## Inspect profile' '## Show gap'; do
  section "^$sec" '^## ' | tr '\n' ' ' | tr -s ' ' | grep -qF "$NOT_AVAILABLE" \
    && ok "$sec says the observed profile is not available" \
    || no "$sec does not print: $NOT_AVAILABLE"
done
for pat in 'inferred column' '↔ observed' 'inferred\.diversity' 'both declared and inferred exist'; do
  grep -q -- "$pat" "$SKILL" && no "skill still describes an observed profile: $pat" \
                             || ok "no observed-profile display: $pat"
done
placeholders="$(python3 -I - "$SKILL" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for body in re.findall(r"```bash\n(.*?)\n[ \t]*```", text, re.S):
    if all(not l.strip() or l.strip().startswith("#") for l in body.splitlines()):
        print(body.strip().splitlines()[0] if body.strip() else "(empty)")
PY
)"
[ -z "$placeholders" ] && ok "no comment-only placeholder bash blocks" \
                       || no "placeholder bash blocks: $placeholders"

# Run the Stats block against a log that clears every diversity threshold: it
# must report enough events to start deriving, and still say not calibrated.
SLUG="$(cd "$TMP" && VIBESTACK_SLUG_NO_MIGRATE=1 HOME="$TMP/home" VIBESTACK_HOME="$TMP/home/.vibestack" \
  "$ROOT/bin/vibe-slug" 2>/dev/null | sed -n 's/^SLUG=//p')"
SLUG="${SLUG:-unknown}"
mkdir -p "$TMP/home/.vibestack/projects/$SLUG"
python3 -I - "$TMP/home/.vibestack/projects/$SLUG/question-log.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in range(24):
        fh.write(json.dumps({"skill": ["ship", "review", "plan-ceo-review"][i % 3],
                             "question_id": "q%d" % (i % 9),
                             "ts": "2026-01-%02dT00:00:00Z" % (1 + i % 10),
                             "followed_recommendation": i % 2 == 0}) + "\n")
PY
STATS_SCRIPT="$(block "## Stats" x 0)" || STATS_SCRIPT=""
STATS_SCRIPT="$(printf '%s\n' "$STATS_SCRIPT" | sed "s|\${VIBESTACK_HOME:-\$HOME/.vibestack}/bin/|$ROOT/bin/|g")"
STATS="$(cd "$TMP" && VIBESTACK_SLUG_NO_MIGRATE=1 HOME="$TMP/home" VIBESTACK_HOME="$TMP/home/.vibestack" bash -c "$STATS_SCRIPT" 2>&1)"
printf '%s\n' "$STATS" | grep -q '^TOTAL_LOGGED: 24$' && ok "stats block reads the fixture log" \
                                                       || no "stats block output: $(printf '%s' "$STATS" | head -3)"
printf '%s\n' "$STATS" | grep -q '^ENOUGH_EVENTS_TO_START_DERIVING: True$' \
  && ok "a diverse log reports enough events to start deriving" || no "no ENOUGH_EVENTS_TO_START_DERIVING: True line"
printf '%s\n' "$STATS" | grep -q '^CALIBRATION: not calibrated: no derivation$' \
  && ok "stats always says not calibrated: no derivation" || no "no CALIBRATION: not calibrated line"
printf '%s\n' "$STATS" | grep -q '^CALIBRATED:' && no "stats still prints CALIBRATED" || ok "no CALIBRATED line"

echo
echo "plan-tune profile: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
