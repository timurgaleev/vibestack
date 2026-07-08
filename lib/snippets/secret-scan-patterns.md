High-confidence secret patterns — scan the exact bytes about to leave for an external sink (issue body, PR/MR body, generated docs, a third-party model) and block on a match:

- `AWS access key`: `AKIA[0-9A-Z]{16}`
- `AWS secret key` style: 40-char base64 with `aws_secret_access_key` nearby
- `GitHub token`: `ghp_[A-Za-z0-9]{36}`, `gho_[A-Za-z0-9]{36}`, `ghs_[A-Za-z0-9]{36}`
- `Anthropic key`: `sk-ant-[A-Za-z0-9_\-]{20,}`
- `OpenAI key`: classic `sk-[A-Za-z0-9]{48}`, and modern prefixed keys `sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}`. Match the WHOLE token — a contiguous-alphanumeric pattern stops at the first `-`/`_` and misses the modern shapes, failing open.
- `GitLab token`: `gl(pat|ptt|dt)-[A-Za-z0-9_\-]{20,}` — the `glpat-` (personal), `glptt-` (pipeline-trigger), and `gldt-` (deploy-token) shapes.
- `HuggingFace token`: `hf_[A-Za-z0-9]{30,}`
- `npm token`: `npm_[A-Za-z0-9]{36}`
- `DigitalOcean token`: `dop_v1_[a-f0-9]{64}`
- `GCP service-account key`: a JSON blob carrying `"private_key"` with a `-----BEGIN PRIVATE KEY-----` body; the nearby `"private_key_id"` field confirms the service-account shape.
- `Bearer token`: `Bearer[ \t]+[A-Za-z0-9._~+/=\-]{20,}` in a header/auth context. Entropy-gated so docs and examples don't false-positive: only block when the token is ≥20 chars AND has at least one digit AND mixed case (or otherwise looks high-entropy). Treat all-caps/underscore placeholders (`Bearer YOUR_TOKEN_HERE`), angle-bracket stubs (`Bearer <token>`), and repeated-character runs as non-secrets.
- `.env`-style key=value: lines matching `^[A-Z_]+_(KEY|TOKEN|SECRET|PASSWORD)=.+`
- `Private key block`: `-----BEGIN.*PRIVATE KEY-----`

Calibration note: keep this list to genuinely-secret credentials so the gate does not cry wolf. Hyphenated prose (e.g. `sk-learning-rate`) must not false-positive — the modern-OpenAI shapes require one of the literal `sk-proj-` / `sk-svcacct-` / `sk-admin-` prefixes before the base64url body.
