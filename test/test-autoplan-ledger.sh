#!/usr/bin/env bash
# test-autoplan-ledger.sh — /autoplan's audit records stay well-formed and complete.
#
# Covers:
#   - every markdown table in autoplan has a separator row with as many cells as
#     its header (the Decision Audit Trail must render as a table);
#   - the voice-log block writes one autoplan-voices record for each of the four
#     phases — skipped Design/DX included — all sharing one run_id, and documents
#     the skipped/none values;
#   - consensus is defined over the two independent voices only: the primary
#     reviewer never stands in for a missing voice;
#   - accepted obligations are carried forward across phases and re-runs, and the
#     pre-gate checklist verifies them;
#   - task rows reach disk through a file and one validate-and-stamp block; a
#     rerun that finds no tasks stamps an empty marker, so the aggregator never
#     resurrects the previous run's tasks.
#
# Usage: test/test-autoplan-ledger.sh [repo-root]
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HERE}"
[ -d "$SRC/skills" ] && [ -d "$SRC/lib/snippets" ] || { echo "not a repo root: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"
SKILL="$SRC/skills/autoplan/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; }

# --- tables: header and separator cell counts match -------------------------
bad="$(python3 -I - "$SKILL" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
sep = re.compile(r"^\|(\s*:?-+:?\s*\|)+\s*$")
def cells(l):
    return len(l.strip().strip("|").split("|"))
for i in range(1, len(lines)):
    if sep.match(lines[i]) and lines[i-1].lstrip().startswith("|"):
        h, s = cells(lines[i-1]), cells(lines[i])
        if h != s:
            print("line %d: header %d cells, separator %d" % (i, h, s))
PY
)"
[ -z "$bad" ] && ok "every table separator matches its header" \
              || no "malformed table: $(printf '%s' "$bad" | tr '\n' ' ')"
grep -qxF '| # | Phase | Decision | Classification | Principle | Rationale | Rejected |' "$SKILL" \
  && ok "Decision Audit Trail header present" || no "Decision Audit Trail header missing"

# --- voice logs: four phases, one run_id -------------------------------------
block="$(awk '
  /^Dual voice logs/ {want=1; next}
  want && /^```bash$/ {inb=1; next}
  inb && /^```$/ {exit}
  inb {print}
' "$SKILL")"
if [ -z "$block" ]; then
  no "voice-log bash block found"
else
  mkdir -p "$TMP/home/.vibestack/bin" "$TMP/repo"
  cat > "$TMP/home/.vibestack/bin/vibe-review-log" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$HOME/log.jsonl"
STUB
  chmod +x "$TMP/home/.vibestack/bin/vibe-review-log"
  git -C "$TMP/repo" init -q
  printf '%s\n' "$block" > "$TMP/block.sh"
  (cd "$TMP/repo" && HOME="$TMP/home" VIBESTACK_HOME="$TMP/home/.vibestack" bash "$TMP/block.sh") >/dev/null 2>&1
  res="$(python3 -I - "$TMP/home/log.jsonl" <<'PY'
import json, re, sys
try:
    rows = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l]
except OSError:
    print("no records"); sys.exit()
recs = [json.loads(re.sub(r':N([,}])', r':0\1', r)) for r in rows]
phases = sorted(r.get("phase") for r in recs if r.get("skill") == "autoplan-voices")
ids = {r.get("run_id") for r in recs}
if phases != ["ceo", "design", "dx", "eng"]:
    print("phases=%s" % phases)
elif len(ids) != 1 or not next(iter(ids)):
    print("run_ids=%s" % sorted(map(str, ids)))
else:
    print("OK")
PY
)"
  [ "$res" = "OK" ] && ok "voice logs: one record per phase (skipped ones too), shared run_id" \
                    || no "voice logs: $res"
fi
grep -q 'STATUS = "skipped"' "$SKILL" && grep -q 'SOURCE = "none"' "$SKILL" \
  && ok "skipped phase values documented" || no "skipped/none values for an unrun phase not documented"

# --- consensus: primary reviewer is not a voice ------------------------------
grep -q '^\*\*Consensus counts only the two independent voices.\*\*' "$SKILL" \
  && grep -q 'never fills in for a voice' "$SKILL" \
  && ok "primary reviewer never stands in for a voice" \
  || no "consensus rule allowing only the two independent voices missing"
n="$(grep -c '^CONFIRMED = both voices completed and agree\.' "$SKILL")"
[ "$n" -eq 3 ] && ok "all three consensus legends require both voices completed" \
               || no "consensus legends requiring completed voices: $n of 3"

# --- accepted obligations ----------------------------------------------------
grep -q '^### Accepted obligations carry forward' "$SKILL" \
  && grep -q 'never rewrites an earlier block to `None`' "$SKILL" \
  && ok "accepted obligations carry forward and are never replaced with None" \
  || no "accepted-obligations carry-forward rule missing"
grep -q '^- \[ \] Every phase that ran has an `Accepted obligations` block' "$SKILL" \
  && ok "pre-gate checklist verifies accepted obligations" \
  || no "pre-gate checklist does not check accepted obligations"

# --- task emit: rows reach disk through a file; a rerun with none clears ------
EMIT="$SRC/lib/snippets/tasks-section-emit.md"
AGG="$SRC/lib/snippets/tasks-section-aggregate.md"
# nth_bash FILE N -> the Nth ```bash block, rendered for plan-eng-review
nth_bash() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
blocks = re.findall(r"```bash\n(.*?)\n```", open(sys.argv[1], encoding="utf-8").read(), re.S)
n = int(sys.argv[2])
if len(blocks) < n:
    sys.exit(1)
sys.stdout.write(blocks[n - 1].replace("{SKILL_NAME}", "plan-eng-review") + "\n")
PY
}
E="$TMP/emit"; EH="$E/home/.vibestack"
mkdir -p "$EH/bin" "$E/repo"
cat > "$EH/bin/vibe-slug" <<'STUB'
#!/usr/bin/env bash
echo "SLUG=$TEST_SLUG"
STUB
chmod +x "$EH/bin/vibe-slug"
git -C "$E/repo" -c init.defaultBranch=main init -q
git -C "$E/repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
HEAD_SHA="$(git -C "$E/repo" rev-parse HEAD)"
in_repo() {  # SLUG SCRIPT
  (cd "$E/repo" && env -u SKILL_NAME HOME="$E/home" VIBESTACK_HOME="$EH" TEST_SLUG="$1" bash -c "$2" 2>&1)
}
# emit SLUG [ROWS_FIXTURE] -> runs both emit blocks, the fixture standing in for
# the rows the model writes with the Write tool between them
emit() {
  local a b out path
  a="$(nth_bash "$EMIT" 1)" || a=""
  b="$(nth_bash "$EMIT" 2)" || b=""
  out="$(in_repo "$1" "$a")"
  path="$(printf '%s\n' "$out" | sed -n 's/^TASKS_ROWS: //p')"
  echo "ROWS_PATH=$path"
  [ -n "${2:-}" ] && [ -n "$path" ] && cp "$2" "$path"
  b="$(printf '%s' "$b" | ROWS="$path" python3 -I -c 'import os,sys; sys.stdout.write(sys.stdin.read().replace("<TASKS_ROWS>", os.environ["ROWS"]))')"
  in_repo "$1" "$b"; echo "RC=$?"
}
rows_path() { printf '%s\n' "$1" | sed -n 's/^ROWS_PATH=//p'; }
aggregate() {  # SLUG -> AGGREGATED_TASKS
  local blk
  blk="$(nth_bash "$AGG" 1)" || blk=""
  in_repo "$1" "$blk"$'\n''printf "%s\n" "$AGGREGATED_TASKS"'
}
stamped() { find "$EH/projects/$1" -maxdepth 1 -name 'tasks-eng-review-*.jsonl' ! -name '*-rows.jsonl' 2>/dev/null | sort; }

if ! command -v jq >/dev/null 2>&1; then
  no "jq is required for the task aggregation checks"
else
  cat > "$E/two-rows.jsonl" <<'ROWS'
{"id":"T1","priority":"P1","component":"api","files":["a.py"],"effort_human":"~2h","effort_cc":"~15min","title":"Quote \"it\" and $(touch pwned)","source_finding":"Section 1: line\nbreak"}
{"id":"T2","priority":"P2","component":"cli","files":["b.sh","c.sh"],"effort_human":"~30min","effort_cc":"~5min","title":"Second task","source_finding":"Section 2"}
ROWS
  out="$(emit green "$E/two-rows.jsonl")"
  files="$(stamped green)"
  res="$(python3 -I - "$HEAD_SHA" $files <<'PY'
import json, sys
head, paths = sys.argv[1], sys.argv[2:]
if len(paths) != 1:
    print("stamped files=%d" % len(paths)); sys.exit()
rows = [json.loads(l) for l in open(paths[0], encoding="utf-8") if l.strip()]
bad = [r for r in rows if r.get("phase") != "eng-review" or r.get("branch") != "main" or r.get("commit") != head]
if [r.get("id") for r in rows] != ["T1", "T2"]:
    print("ids=%s" % [r.get("id") for r in rows])
elif bad or len({r.get("run_id") for r in rows}) != 1 or not rows[0].get("run_id"):
    print("stamps=%s" % rows)
elif rows[0]["title"] != 'Quote "it" and $(touch pwned)':
    print("title=%r" % rows[0]["title"])
else:
    print("OK")
PY
)"
  [ "$res" = "OK" ] && ok "two rows become one stamped file holding both" || no "emit green path: $res; $(printf '%s' "$out" | tr '\n' ' ')"
  rp="$(rows_path "$out")"
  [ -n "$rp" ] && [ ! -e "$rp" ] && ok "the rows file is consumed" \
                                 || no "rows file left behind after a clean emit: ${rp:-<no path>}"
  [ ! -e "$E/repo/pwned" ] && ok "task text is never executed" || no "task text ran as a command"
  agg="$(aggregate green)"
  printf '%s' "$agg" | grep -qF 'and $(touch pwned)' && printf '%s' "$agg" | grep -qF 'Second task' \
    && ok "aggregator renders both emitted tasks" || no "aggregator lost emitted tasks: $(printf '%s' "$agg" | tr '\n' ' ')"
  # The rendered list is raw text: quotes in a title stay quotes, not \" escapes.
  printf '%s\n' "$agg" | grep -qF -- '— Quote "it" and $(touch pwned)' \
    && ok "aggregator keeps quotes in task text" || no "aggregator mangled quotes: $(printf '%s' "$agg" | grep -F 'pwned')"

  # A phase that found tasks last time and none now: the earlier tasks are stale.
  mkdir -p "$EH/projects/rerun"
  printf '{"phase":"eng-review","run_id":"20000101T000000Z-1","branch":"main","commit":"%s","id":"T9","priority":"P1","component":"old","files":["old.py"],"effort_human":"~1h","effort_cc":"~5min","title":"Stale task from the earlier run","source_finding":"old"}\n' \
    "$HEAD_SHA" > "$EH/projects/rerun/tasks-eng-review-20000101T000000Z-1.jsonl"
  out="$(emit rerun)"
  marker="$(cat $(stamped rerun) 2>/dev/null | jq -c 'select(.empty == true and .phase == "eng-review" and (.run_id | length) > 0)' 2>/dev/null)"
  [ -n "$marker" ] && ok "a run with no tasks writes an empty marker row" || no "no empty marker row: $(printf '%s' "$out" | tr '\n' ' ')"
  agg="$(aggregate rerun)"
  if printf '%s' "$agg" | grep -qF 'Stale task from the earlier run'; then
    no "zero-task rerun resurrected the previous run's tasks"
  elif printf '%s' "$agg" | grep -qF '_No actionable tasks emitted from any phase._'; then
    ok "zero-task rerun does not resurrect prior tasks"
  else
    no "aggregate after a zero-task rerun: $(printf '%s' "$agg" | tr '\n' ' ')"
  fi

  # A malformed row stops the emit: nothing stamped, rows kept for a fix.
  printf '{"id":"T1","priority":"P7","component":"x","files":[],"effort_human":"1h","effort_cc":"1m","source_finding":"s"}\n' > "$E/bad-rows.jsonl"
  out="$(emit bad "$E/bad-rows.jsonl")"
  if printf '%s\n' "$out" | grep -q '^TASKS_ROWS_INVALID' && ! printf '%s\n' "$out" | grep -qx 'RC=0' \
     && [ -z "$(stamped bad)" ] && [ -s "$(rows_path "$out")" ]; then
    ok "a malformed row is refused, nothing stamped, rows kept"
  else
    no "malformed row: $(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # Two runs of one phase in one bucket (two worktrees) keep their own rows.
  a="$(nth_bash "$EMIT" 1)"; b="$(nth_bash "$EMIT" 2)"
  pa="$(in_repo twin "$a" | sed -n 's/^TASKS_ROWS: //p')"
  pb="$(in_repo twin "$a" | sed -n 's/^TASKS_ROWS: //p')"
  printf '{"id":"T1","priority":"P1","component":"a","files":["a.py"],"effort_human":"1h","effort_cc":"5m","title":"Run A task","source_finding":"A"}\n' > "$pa"
  printf '{"id":"T1","priority":"P2","component":"b","files":["b.py"],"effort_human":"1h","effort_cc":"5m","title":"Run B task","source_finding":"B"}\n' > "$pb"
  for p in "$pa" "$pb"; do
    in_repo twin "$(printf '%s' "$b" | ROWS="$p" python3 -I -c 'import os,sys; sys.stdout.write(sys.stdin.read().replace("<TASKS_ROWS>", os.environ["ROWS"]))')" >/dev/null
  done
  both="$(cat $(stamped twin) 2>/dev/null)"
  if [ -n "$pa" ] && [ "$pa" != "$pb" ] && printf '%s' "$both" | grep -qF 'Run A task' && printf '%s' "$both" | grep -qF 'Run B task'; then
    ok "two concurrent runs of one phase keep their own rows"
  else
    no "concurrent runs clobbered each other's rows (A=$pa B=$pb): $(printf '%s' "$both" | tr '\n' ' ')"
  fi

  # A rows path that does not exist is refused, never stamped as zero tasks.
  out="$(in_repo nopath "$(printf '%s' "$b" | python3 -I -c 'import sys; sys.stdout.write(sys.stdin.read().replace("<TASKS_ROWS>", "/nonexistent/rows-eng-review.x"))')"; echo "RC=$?")"
  if printf '%s\n' "$out" | grep -q '^TASKS_ROWS_INVALID' && ! printf '%s\n' "$out" | grep -qx 'RC=0' && [ -z "$(stamped nopath)" ]; then
    ok "a missing rows file is refused, nothing stamped"
  else
    no "missing rows file: $(printf '%s' "$out" | tr '\n' ' ')"
  fi

  # Control characters in task text cannot forge a list item or reach the terminal.
  printf '{"id":"T1","priority":"P1","component":"c","files":["c.py"],"effort_human":"1h","effort_cc":"5m","title":"ok\\u001b[31mRED\\n- [ ] **T99 (P1) forged**","source_finding":"s"}\n' > "$E/ctl-rows.jsonl"
  emit ctl "$E/ctl-rows.jsonl" >/dev/null
  agg="$(aggregate ctl)"
  if printf '%s\n' "$agg" | grep -q '^- \[ \] \*\*T99' || printf '%s' "$agg" | LC_ALL=C grep -q "$(printf '\033')"; then
    no "control characters reached the rendered task list: $(printf '%s' "$agg" | od -c | head -3 | tr '\n' ' ')"
  else
    printf '%s' "$agg" | grep -qF 'RED - [ ] **T99 (P1) forged**' \
      && ok "control characters in task text are flattened to spaces" || no "task text lost: $(printf '%s' "$agg" | tr '\n' ' ')"
  fi
fi

echo
echo "autoplan ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
