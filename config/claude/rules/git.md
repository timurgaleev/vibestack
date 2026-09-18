# Git Workflow

## CRITICAL: Commit & Push Policy

**NEVER commit or push without explicit user permission.**
- Only run `git commit` when explicitly requested by the user
- Only run `git push` when explicitly requested by the user
- Do not auto-commit after code changes
- Only proceed when there is a clear instruction such as "commit"

### Never, unless the user explicitly asks

- Committing secrets (`.env`, API keys, tokens), binaries, or generated files
- Bypassing hooks or signing (`--no-verify`, `--no-gpg-sign`, `--no-signoff`)
- Reverting unrelated changes in the working tree

## Destructive & Irreversible Operations

Run these only when the user clearly asks. State the blast radius first and wait
for confirmation:

- `git reset --hard`, `git checkout -- <path>`, `git restore --`
- `git push --force`, `git push --force-with-lease`
- Branch deletion (`git branch -D`, deleting a remote branch)
- Amending or rebasing published commits
- `git clean -f`

## Commit Message Format

```
<type>: <description>

<optional body>
```

Types: feat, fix, refactor, docs, test, chore, perf, ci

## Pull Request Workflow

When creating PRs:
1. Analyze full commit history (not just latest commit)
2. Use `git diff [base-branch]...HEAD` to see all changes
3. Draft comprehensive PR summary
4. Include test plan with TODOs
5. Push with `-u` flag if new branch

## Feature Implementation Workflow

1. **Plan First**
   - Use **task-planner** agent to create implementation plan
   - Identify dependencies and risks
   - Break down into phases

2. **Implementation**
   - Write tests for new functionality
   - Implement functionality
   - Run tests to verify correctness
   - Verify 80%+ test coverage

3. **Code Review**
   - Use **quality-guard** agent for quality and security review
   - Address CRITICAL and HIGH issues
   - Fix MEDIUM issues when possible

4. **Commit & Push**
   - Detailed commit messages
   - Follow conventional commits format
