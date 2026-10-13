#!/usr/bin/env python3
"""Build codex/AGENTS.md (or copilot/copilot-instructions.md) from
claude/CLAUDE.md + claude/rules/.

Claude Code loads CLAUDE.md *and* every rules/*.md file, so the hub can stay
thin and point at spokes. Codex loads a single AGENTS.md, and Copilot CLI a
single personal copilot-instructions.md; neither has a rules directory, so the
same content has to arrive inlined. Rather than maintain copies by hand, expand
the hub's pointers into the rule bodies.

    ./scripts/gen-codex-agents.py                    # write codex/AGENTS.md
    ./scripts/gen-codex-agents.py --check            # exit 1 if it is out of date
    ./scripts/gen-codex-agents.py --target copilot   # copilot/copilot-instructions.md

A rule referenced from more than one section is inlined once, at its first
mention; later mentions become a cross-reference.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HUB = ROOT / "config" / "claude" / "CLAUDE.md"
RULES = ROOT / "config" / "claude" / "rules"
OUT = ROOT / "config" / "codex" / "AGENTS.md"
SECTIONS = Path(__file__).resolve().parent / "codex-sections"

# Sections whose content has no Claude equivalent worth reusing. The hub section
# is dropped and replaced wholesale by the named file under codex-sections/.
OVERRIDES = {
    "Claude Code Usage": ("Codex Usage", "codex-usage.md"),
}

# Hub sections that make no sense for Codex and carry no replacement.
DROP = {
    # "Skills" is folded into Codex Usage: Codex resolves skills from
    # ~/.agents/skills, and has no rules/skills.md to point at.
    "Skills",
}

# Rules the hub never points at, appended as their own sections so Codex still
# receives them. perf.md is deliberately absent — it is about picking a Claude
# model tier.
APPEND = ["patterns.md"]

# Rules whose body is Claude-Code-specific (EnterPlanMode, subagents, the Skill
# tool). Codex gets the hub's summary plus the Codex Usage section instead of
# instructions for tools it does not have.
NO_INLINE = {"claude-code-usage"}

# One filename grammar, shared by every rule-reference pattern here and by the
# G2/G4 checks in test/test_codex_agents.sh. Narrower classes let a rule such as
# `foo_bar.md` slip past expansion while still looking accounted for.
RULE_NAME = r"[A-Za-z0-9._-]+"

# References to sibling rule files read as dangling links in a single-file
# document. Point them at the section that now carries the content.
DANGLING = [
    (re.compile(r"See `rules/skills\.md` for the\ntask → skill map\."),
     "See **Codex Usage** for how skills are resolved."),
    (re.compile(r" \(see `rules/authorship\.md`\)"), " (see **Authorship**)"),
    (re.compile(r"`git\.md`"), "**Git Safety**"),
    (re.compile(rf"`rules/({RULE_NAME})\.md`"), r"the **\1** rules"),
]

# Per-target output. Codex is the default and its output is unchanged by the
# copilot entry; everything a target does differently is declared here.
TARGETS = {
    "codex": {
        "out": OUT,
        "sections": SECTIONS,
        "overrides": OVERRIDES,
        "title": "# AGENTS.md",
        "runtime": "Codex",
        "structure": (
            "This is the *only* global instruction file Codex loads automatically, so\n"
            "every rule is written out in full below. An `AGENTS.md` in the project root\n"
            "takes precedence — the deeper file wins.\n\n"
        ),
        "dangling": DANGLING,
    },
    "copilot": {
        "out": ROOT / "config" / "copilot" / "copilot-instructions.md",
        "sections": Path(__file__).resolve().parent / "copilot-sections",
        "overrides": {"Claude Code Usage": ("Copilot Usage", "copilot-usage.md")},
        "title": "# copilot-instructions.md",
        "runtime": "Copilot CLI",
        "structure": (
            "Copilot CLI loads this file from `~/.copilot` every session and has no\n"
            "rules directory to point at, so every rule is written out in full below.\n"
            "Repository instructions (`.github/copilot-instructions.md`, `AGENTS.md`,\n"
            "`CLAUDE.md`) load alongside it; where they conflict, the repository wins.\n\n"
        ),
        "dangling": [
            (re.compile(r"See `rules/skills\.md` for the\ntask → skill map\."),
             "See **Copilot Usage** for how skills are resolved."),
            # Copilot does have a setting for this, and the pack ships it.
            (re.compile(r"- The Claude configuration sets the `attribution` setting.*?what holds\.",
                        re.DOTALL),
             "- The configuration ships `~/.copilot/settings.json` with\n"
             "  `includeCoAuthoredBy` set to `false`, so Copilot itself adds no\n"
             "  co-author trailer. Never add one by hand either."),
        ] + DANGLING[1:],
    },
}

# A line that hands off to a rule file, e.g. "Full rule: `rules/git.md`".
POINTER = re.compile(rf"^(?:Full rule|Details and examples):\s*`rules/({RULE_NAME})\.md`\s*$")
# The Priority list points at rule files too; Codex has none to open.
PRIORITY_REF = re.compile(rf"\s*→\s*`rules/{RULE_NAME}\.md`")

HEADER = """<!-- Generated by scripts/gen-codex-agents.py from claude/CLAUDE.md and
     claude/rules/. Do not edit directly — edit the source and regenerate. -->

"""


FENCE = re.compile(r"^\s*(```|~~~)")

# Rules the last build() actually inlined or appended. --report-rules prints
# this so the tests assert on real consumption rather than on a hub grep, which
# also matches fenced examples and prose.
RULES_USED: set[str] = set()


def outside_fences(lines: list[str]):
    """Yield (line, in_fence) so heading logic never fires inside a code block."""
    in_fence = False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            yield line, True
            continue
        yield line, in_fence


def rewrite_outside_fences(text: str, patterns) -> str:
    """Apply patterns to unfenced regions only, fenced blocks passed through.

    Runs on whole unfenced runs rather than single lines, so a pattern spanning
    two lines still matches while a fenced example keeps its literal text.
    """
    out: list[str] = []
    buf: list[str] = []
    in_fence = False

    def flush() -> None:
        if not buf:
            return
        chunk = "\n".join(buf)
        for pattern, replacement in patterns:
            chunk = pattern.sub(replacement, chunk)
        out.append(chunk)
        buf.clear()

    for line in text.splitlines():
        if FENCE.match(line):
            if not in_fence:
                flush()
            out.append(line)
            in_fence = not in_fence
            continue
        if in_fence:
            out.append(line)
        else:
            buf.append(line)
    flush()
    return "\n".join(out)


def rule_body(name: str) -> str:
    """Rule text without its H1, with headings pushed one level down."""
    lines = (RULES / f"{name}.md").read_text().splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    while lines and not lines[0].strip():
        lines.pop(0)
    out = [
        "#" + line if line.startswith("##") and not fenced else line
        for line, fenced in outside_fences(lines)
    ]
    return "\n".join(out).rstrip()


def split_sections(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Return (preamble, [(title, body)]) split on H2 headings outside fences."""
    preamble: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    for line, fenced in outside_fences(text.splitlines()):
        if not fenced and line.startswith("## "):
            sections.append((line[3:].strip(), []))
        elif sections:
            sections[-1][1].append(line)
        else:
            preamble.append(line)
    return "\n".join(preamble), [(t, "\n".join(b)) for t, b in sections]


def build(target: str = "codex") -> str:
    cfg = TARGETS[target]
    preamble, sections = split_sections(HUB.read_text())

    preamble = preamble.replace("# CLAUDE.md", cfg["title"], 1)
    preamble = preamble.replace(
        "Global instructions for Claude Code.",
        f"Global instructions for {cfg['runtime']}.",
    )
    # The hub explains its own index/spoke split; the output has no spokes.
    preamble = re.sub(
        r"\*\*Structure\*\*.*?(?=\n## |\Z)",
        lambda _: cfg["structure"],
        preamble,
        flags=re.DOTALL,
    )

    expanded_in: dict[str, str] = {}  # rule name -> section title it landed in
    RULES_USED.clear()
    out: list[str] = []

    for title, body in sections:
        if title in DROP:
            continue

        if title in cfg["overrides"]:
            new_title, filename = cfg["overrides"][title]
            out.append(f"## {new_title}\n\n{(cfg['sections'] / filename).read_text().rstrip()}\n")
            continue

        rendered = []
        for line, fenced in outside_fences(body.splitlines()):
            # A pointer inside a fenced example is illustration, not a directive.
            if fenced:
                rendered.append(line)
                continue
            match = POINTER.match(line)
            if not match:
                rendered.append(PRIORITY_REF.sub("", line))
                continue
            rule = match.group(1)
            if rule in NO_INLINE:
                continue
            if rule in expanded_in:
                rendered.append(f"Covered under **{expanded_in[rule]}**.")
            else:
                expanded_in[rule] = title
                RULES_USED.add(rule)
                rendered.append(rule_body(rule))
        section = "\n".join(rendered).strip()
        out.append(f"## {title}\n\n{section}\n")

    for filename in APPEND:
        name = filename[: -len(".md")]
        if name in expanded_in:
            continue
        first = (RULES / filename).read_text().splitlines()[0]
        heading = first.lstrip("# ").strip() if first.startswith("# ") else name
        RULES_USED.add(name)
        out.append(f"## {heading}\n\n{rule_body(name)}\n")

    document = HEADER + preamble.rstrip() + "\n\n" + "\n".join(out)

    # Rewrite dangling links outside fenced blocks only, so a fenced example
    # that quotes a rules/ path keeps its literal text.
    return rewrite_outside_fences(document, cfg["dangling"]) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(TARGETS), default="codex",
                        help="which runtime's file to build (default: codex)")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if the target file differs from the generated output")
    parser.add_argument("--report-rules", action="store_true",
                        help="print the rules actually inlined or appended, one per line")
    args = parser.parse_args()

    out = TARGETS[args.target]["out"]
    rel = out.relative_to(ROOT / "config")
    generated = build(args.target)

    if args.report_rules:
        print("\n".join(sorted(RULES_USED)))
        return 0

    if args.check:
        current = out.read_text() if out.exists() else ""
        if current == generated:
            print(f"{rel} is up to date")
            return 0
        flag = "" if args.target == "codex" else f" --target {args.target}"
        print(f"{rel} is out of date — run scripts/gen-codex-agents.py{flag}",
              file=sys.stderr)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(generated)
    print(f"wrote {out.relative_to(ROOT)} ({len(generated.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
