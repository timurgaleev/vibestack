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
#     pre-gate checklist verifies them.
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
  (cd "$TMP/repo" && HOME="$TMP/home" bash "$TMP/block.sh") >/dev/null 2>&1
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

echo
echo "autoplan ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
