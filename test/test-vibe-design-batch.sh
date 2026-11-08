#!/usr/bin/env bash
# test-vibe-design-batch.sh — `vibe-design variants --briefs-file` generates one
# image per brief in a single call, against a stub image endpoint on localhost.
#
# Value: protects=the batch contract /design-shotgun Step 3c relies on — one
# file per brief under its own letter, never overwriting, Retry-After honored
# with a capped retry count, one regeneration of an empty image, a deadline, the
# Gemini provider when only GEMINI_API_KEY is set, and a DESIGN_ERROR that names
# VIBE_DESIGN_MODEL when the API rejects the model; fails_when=any of those
# regress; why_new=the batch mode and the second provider are new; seam=the
# endpoint URL env vars (a real HTTP server, the real bin)
#
# Usage: test/test-vibe-design-batch.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VD="$ROOT/bin/vibe-design"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# ── stub image endpoint ──────────────────────────────────────────────────────
# The image bytes are the prompt itself, so a test can tell which brief landed
# in which file. Directives inside a prompt pick the behaviour:
#   RATE1 first request 429 + Retry-After: 1     RATE_ALWAYS every request 429
#   EMPTY1 first response has an empty image     EMPTY_ALWAYS always empty
#   BADMODEL 404 model_not_found                 SLOW sleeps 5 s
cat > "$TMP/server.py" <<'PY'
import base64, json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path, port_path = sys.argv[1], sys.argv[2]
seen, lock = {}, threading.Lock()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, headers=()):
        raw = json.dumps(body).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        gemini = ":generateContent" in self.path
        prompt = body["contents"][0]["parts"][0]["text"] if gemini else body["prompt"]
        with lock:
            n = seen[prompt] = seen.get(prompt, 0) + 1
            with open(log_path, "a") as f:
                f.write(json.dumps({"t": time.time(), "path": self.path, "prompt": prompt, "n": n,
                                    "auth": self.headers.get("Authorization", ""),
                                    "goog": self.headers.get("x-goog-api-key", ""),
                                    "modalities": (body.get("generationConfig") or {}).get("responseModalities"),
                                    "aspect": ((body.get("generationConfig") or {}).get("imageConfig") or {}).get("aspectRatio"),
                                    "model": body.get("model")}) + "\n")
        if "SLOW" in prompt:
            time.sleep(5)
        if "RATE_ALWAYS" in prompt or ("RATE1" in prompt and n == 1):
            return self.reply(429, {"error": {"message": "Rate limit reached"}}, [("Retry-After", "1")])
        if "BADMODEL" in prompt:
            return self.reply(404, {"error": {"message": "The model 'nope' does not exist", "code": "model_not_found"}})
        img = b"" if ("EMPTY_ALWAYS" in prompt or ("EMPTY1" in prompt and n == 1)) else prompt.encode()
        b64 = base64.b64encode(img).decode()
        if gemini:
            return self.reply(200, {"candidates": [{"content": {"parts": [{"inlineData": {"mimeType": "image/png", "data": b64}}]}}]})
        return self.reply(200, {"data": [{"b64_json": b64}]})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_path, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 -I "$TMP/server.py" "$TMP/requests.jsonl" "$TMP/port" & SERVER_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "stub server did not start" >&2; exit 1; }
PORT="$(cat "$TMP/port")"
export VIBE_DESIGN_OPENAI_URL="http://127.0.0.1:$PORT/v1/images/generations"
export VIBE_DESIGN_GEMINI_URL="http://127.0.0.1:$PORT/v1beta"

briefs() {  # briefs FILE BRIEF... — a briefs.json with one entry per argument
  local f="$1"; shift
  python3 -I -c 'import json,sys; json.dump([{"brief": b} for b in sys.argv[2:]], open(sys.argv[1], "w"))' "$f" "$@"
}
run() {  # run OUTDIR ARGS... — output in $OUT, exit code in $RC
  RC=0; OUT="$(env -u GEMINI_API_KEY OPENAI_API_KEY=test-key "$VD" variants --output-dir "$1" "${@:2}" 2>&1)" || RC=$?
}
reqs() { grep -c "\"prompt\": \"$1\"" "$TMP/requests.jsonl" 2>/dev/null || echo 0; }

echo "batch: one image per brief"
D1="$TMP/round"; briefs "$TMP/b3.json" "alpha hero" "beta story" "gamma minimal"
run "$D1" --briefs-file "$TMP/b3.json"
{ [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^saved: ')" = 3 ] \
  && printf '%s\n' "$OUT" | grep -qx 'requested: 3' && printf '%s\n' "$OUT" | grep -qx 'failures: 0'; } \
  && ok "3 briefs save 3 images and exit 0" || no "3 briefs: rc=$RC $OUT"
{ [ "$(cat "$D1/variant-A.png" 2>/dev/null)" = "alpha hero" ] && [ "$(cat "$D1/variant-B.png" 2>/dev/null)" = "beta story" ] \
  && [ "$(cat "$D1/variant-C.png" 2>/dev/null)" = "gamma minimal" ]; } \
  && ok "each brief lands under its own letter" || no "brief-to-letter mapping: $(ls "$D1")"
GAPS="$(python3 -I -c '
import json, sys
t = sorted(json.loads(l)["t"] for l in open(sys.argv[1]) if json.loads(l)["prompt"] in ("alpha hero", "beta story", "gamma minimal"))
print(min(b - a for a, b in zip(t, t[1:])) >= 1.3)' "$TMP/requests.jsonl")"
[ "$GAPS" = True ] && ok "requests start at least ~1.5 s apart" || no "requests not staggered"
grep -q '"auth": "Bearer test-key"' "$TMP/requests.jsonl" && ok "OpenAI requests carry the bearer key" || no "no bearer key sent"

run "$D1" --briefs-file "$TMP/b3.json"
{ [ "$RC" -eq 0 ] && [ -f "$D1/variant-A-2.png" ] && [ -f "$D1/variant-C-2.png" ] \
  && printf '%s\n' "$OUT" | grep -qx "saved: $D1/variant-B-2.png" && [ "$(cat "$D1/variant-A.png")" = "alpha hero" ]; } \
  && ok "a second run into the same dir never overwrites" || no "second run: rc=$RC $OUT"

python3 -I -c 'import json,sys; json.dump([{"brief": "retry C", "label": "C"}], open(sys.argv[1], "w"))' "$TMP/label.json"
run "$TMP/lab" --briefs-file "$TMP/label.json"
{ [ "$RC" -eq 0 ] && [ "$(cat "$TMP/lab/variant-C.png" 2>/dev/null)" = "retry C" ] && [ ! -e "$TMP/lab/variant-A.png" ]; } \
  && ok "a \"label\" retries one letter under its own name" || no "label: rc=$RC $OUT"
python3 -I -c 'import json,sys; json.dump([{"brief": "x", "label": "B"}, {"brief": "y", "label": "B"}], open(sys.argv[1], "w"))' "$TMP/dup.json"
run "$TMP/lab" --briefs-file "$TMP/dup.json"
[ "$RC" -eq 1 ] && ok "duplicate labels are a usage error" || no "duplicate labels: rc=$RC $OUT"

echo "batch: retries"
D2="$TMP/retry"; briefs "$TMP/rate.json" "RATE1 hero"
run "$D2" --briefs-file "$TMP/rate.json"
RGAP="$(python3 -I -c '
import json, sys
t = [json.loads(l)["t"] for l in open(sys.argv[1]) if json.loads(l)["prompt"] == "RATE1 hero"]
print(len(t), t[1] - t[0] >= 0.9 if len(t) > 1 else False)' "$TMP/requests.jsonl")"
{ [ "$RC" -eq 0 ] && [ "$RGAP" = "2 True" ]; } && ok "a 429 waits Retry-After and retries" || no "Retry-After: rc=$RC reqs=$RGAP $OUT"
briefs "$TMP/rate2.json" "RATE_ALWAYS hero"
run "$D2" --briefs-file "$TMP/rate2.json"
{ [ "$RC" -eq 2 ] && [ "$(reqs 'RATE_ALWAYS hero')" = 3 ] && printf '%s\n' "$OUT" | grep -q '^failed: variant-A: .*429'; } \
  && ok "a rate limit stops after 3 tries" || no "rate cap: rc=$RC reqs=$(reqs 'RATE_ALWAYS hero') $OUT"
briefs "$TMP/empty.json" "EMPTY1 hero" "EMPTY_ALWAYS hero"
run "$D2/e" --briefs-file "$TMP/empty.json"
{ [ "$RC" -eq 3 ] && [ "$(reqs 'EMPTY1 hero')" = 2 ] && [ "$(reqs 'EMPTY_ALWAYS hero')" = 2 ] \
  && [ -f "$D2/e/variant-A.png" ] && printf '%s\n' "$OUT" | grep -q '^failed: variant-B: .*empty image'; } \
  && ok "an empty image is regenerated once, then reported" || no "empty image: rc=$RC $OUT"
briefs "$TMP/slow.json" "SLOW hero"
RC=0; OUT="$(env -u GEMINI_API_KEY OPENAI_API_KEY=test-key VIBE_DESIGN_DEADLINE=2 "$VD" variants --output-dir "$D2/s" --briefs-file "$TMP/slow.json" 2>&1)" || RC=$?
{ [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q '^failed: variant-A: .*deadline'; } \
  && ok "the batch deadline stops a slow request" || no "deadline: rc=$RC $OUT"

echo "model rejection"
briefs "$TMP/bad.json" "BADMODEL hero"
run "$TMP/bad" --briefs-file "$TMP/bad.json"
{ [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q '^DESIGN_ERROR: .*VIBE_DESIGN_MODEL'; } \
  && ok "a rejected model names VIBE_DESIGN_MODEL (batch)" || no "batch model hint: rc=$RC $OUT"
run "$TMP/bad1" --brief "BADMODEL hero"
{ [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q '^DESIGN_ERROR: .*VIBE_DESIGN_MODEL'; } \
  && ok "a rejected model names VIBE_DESIGN_MODEL (single brief)" || no "single model hint: rc=$RC $OUT"

echo "gemini provider"
ST="$(env -u OPENAI_API_KEY GEMINI_API_KEY=g-key "$VD" status 2>"$TMP/st.err")"
{ [ "$ST" = DESIGN_AVAILABLE ] && grep -q 'gemini' "$TMP/st.err"; } \
  && ok "status is available and names the gemini provider" || no "gemini status: $ST / $(cat "$TMP/st.err")"
env -u GEMINI_API_KEY OPENAI_API_KEY=k "$VD" status 2>"$TMP/st2.err" >/dev/null
grep -q 'openai' "$TMP/st2.err" && ok "status names the openai provider" || no "openai status: $(cat "$TMP/st2.err")"
briefs "$TMP/g.json" "gemini one" "gemini two"
RC=0; OUT="$(env -u OPENAI_API_KEY GEMINI_API_KEY=g-key "$VD" variants --output-dir "$TMP/g" --briefs-file "$TMP/g.json" 2>&1)" || RC=$?
{ [ "$RC" -eq 0 ] && [ "$(cat "$TMP/g/variant-B.png" 2>/dev/null)" = "gemini two" ]; } \
  && ok "gemini saves one image per brief" || no "gemini batch: rc=$RC $OUT"
GREQ="$(grep '"prompt": "gemini one"' "$TMP/requests.jsonl" | head -1)"
{ printf '%s' "$GREQ" | grep -q ':generateContent' && printf '%s' "$GREQ" | grep -q '"goog": "g-key"' \
  && ! printf '%s' "$GREQ" | grep -q 'key=' && printf '%s' "$GREQ" | grep -q '"modalities": \["IMAGE"\]'; } \
  && ok "gemini sends the key in x-goog-api-key and asks for IMAGE" || no "gemini request: $GREQ"
RC=0; OUT="$(env -u OPENAI_API_KEY GEMINI_API_KEY=g-key "$VD" variants --output-dir "$TMP/g1" --brief "gemini single" --count 2 2>&1)" || RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$TMP/g1/variant-B.png" ]; } && ok "gemini serves --brief --count too" || no "gemini single: rc=$RC $OUT"
RC=0; OUT="$(env -u OPENAI_API_KEY GEMINI_API_KEY=g-key "$VD" variants --output-dir "$TMP/g2" --brief "gemini wide" --size 1792x1024 2>&1)" || RC=$?
{ [ "$RC" -eq 0 ] && grep '"prompt": "gemini wide"' "$TMP/requests.jsonl" | grep -q '"aspect": "16:9"'; } \
  && ok "gemini maps --size to the nearest aspect ratio" || no "gemini size: rc=$RC $(grep '"prompt": "gemini wide"' "$TMP/requests.jsonl")"

echo "usage"
run "$TMP/u" --briefs-file "$TMP/b3.json" --brief x
[ "$RC" -eq 1 ] && ok "--briefs-file with --brief is a usage error" || no "briefs-file + brief: rc=$RC"
printf 'not json' > "$TMP/bad-json"; run "$TMP/u" --briefs-file "$TMP/bad-json"
[ "$RC" -eq 1 ] && ok "a malformed briefs file is a usage error" || no "malformed briefs: rc=$RC $OUT"
python3 -I -c 'import json,sys; json.dump([{"brief": "b%d" % i} for i in range(11)], open(sys.argv[1], "w"))' "$TMP/eleven.json"
run "$TMP/u" --briefs-file "$TMP/eleven.json"
[ "$RC" -eq 1 ] && ok "more than 10 briefs is a usage error" || no "11 briefs: rc=$RC"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
