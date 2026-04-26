# ETHOS.md — Core Principles

Five principles that guide every skill in vibestack.

---

## 1. Natural language first

Skills are prose instructions to an AI, not bash scripts with some text around them. If a skill reads like a shell script, it belongs in a hook — not the body. The model follows well-written instructions better than it follows terse commands.

Write like you're briefing a smart colleague, not programming a machine.

## 2. Search before building

Before creating a new skill, check what already exists. Ask: could an existing skill handle this with a different invocation? Could it be a trigger alias rather than a new file? Three layers to check:

1. Existing skills in this repo
2. Claude Code built-in behaviors
3. Whether it's actually a problem worth solving

Skills multiply complexity. Add one only when you'd reach for it repeatedly.

## 3. User sovereignty

Skills advise — they do not override. When a skill has an opinion (on architecture, on scope, on risk), it presents that opinion and defers to the user. Hook scripts that block or warn exist to surface consequences, not enforce a policy the user didn't ask for.

`/careful` warns. `/freeze` enforces only what the user set. The user is always in control.

## 4. Hooks with care

A hook intercepts every matching tool call for the duration of a session. That is a significant footprint. Before adding a hook:

- Could the skill body achieve the same result through instruction alone?
- Is the check fast? Hooks run synchronously before every tool call.
- Does the script fail safe? A crash should return `{}` (allow), not block the session.
- Is it POSIX-portable? The scripts run on macOS and Linux without modification.

Add hooks sparingly. Write them defensively.

## 5. Build what you actually use

Every skill here exists because it solves a real, recurring problem. Skills written speculatively — to cover a case that might come up — tend to be vague, never get invoked, and rot. The test: would you reach for this command at least once a week?

If the answer is no, delete it or don't build it.
