#!/usr/bin/env python3
"""
Claude Code Statusline Hook
Renders the terminal status line: model, project, git, context, cost.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# ============================================================================
# Configuration Loading
# ============================================================================


# Token reset window: 5h for Pro/Max, 0 to disable (Enterprise)
TOKEN_RESET_HOURS = int(os.environ.get("CLAUDE_TOKEN_RESET_HOURS", "5") or "5")
TOKEN_RESET_MS = TOKEN_RESET_HOURS * 3600 * 1000

# Lock file timeout constants
LOCK_TIMEOUT_SECONDS = 5
LOCK_RETRY_INTERVAL = 0.05

# ============================================================================
# Utility Functions
# ============================================================================


def read_input() -> str:
    """Read input from stdin."""
    return sys.stdin.read()


def parse_json(data: str) -> dict[str, Any]:
    """Parse JSON string to dictionary."""
    try:
        return json.loads(data)
    except (json.JSONDecodeError, TypeError):
        return {}


# ============================================================================
# Git Functions
# ============================================================================

# Branch emoji mapping based on branch name prefix
BRANCH_EMOJIS = {
    "main": "🌿",
    "master": "🌿",
    "develop": "🌱",
    "development": "🌱",
    "dev": "🌱",
    "feature": "✨",
    "feat": "✨",
    "fix": "🐛",
    "bugfix": "🐛",
    "hotfix": "🔥",
    "release": "📦",
    "chore": "🧹",
    "refactor": "♻️",
    "docs": "📝",
    "doc": "📝",
    "test": "🧪",
    "experiment": "🧪",
    "exp": "🧪",
}


def get_branch_emoji(branch: str) -> str:
    """Get emoji for branch based on name or prefix."""
    if not branch:
        return "🌿"

    branch_lower = branch.lower()

    # Check exact match first (main, master, develop, etc.)
    if branch_lower in BRANCH_EMOJIS:
        return BRANCH_EMOJIS[branch_lower]

    # Check prefix match (feature/xxx, fix/xxx, etc.)
    if "/" in branch_lower:
        prefix = branch_lower.split("/", 1)[0]
        if prefix in BRANCH_EMOJIS:
            return BRANCH_EMOJIS[prefix]

    # Default emoji
    return "🌿"


def get_git_root(directory: str) -> str | None:
    """Get git repository root directory."""
    if not directory:
        return None
    try:
        result = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


def get_project_name(directory: str) -> str:
    """Get project name from git root or directory basename."""
    if not directory:
        return ""

    # Try git root first (handles subdirectory cases)
    git_root = get_git_root(directory)
    if git_root:
        name = os.path.basename(git_root)
        if name:
            return name

    # Fallback to directory basename
    return os.path.basename(directory)


def get_git_info(directory: str) -> str:
    """Get git branch and status information.

    Optimized to use single git command with status --porcelain --branch
    which provides both branch name and change status in one call.
    """
    if not directory:
        return ""

    try:
        # Single git command: get branch and status in one call
        # --porcelain=v1 --branch gives: "## branch...tracking" as first line
        # followed by changed files (if any)
        result = subprocess.run(
            [
                "git",
                "--no-optional-locks",
                "-C",
                directory,
                "status",
                "--porcelain=v1",
                "--branch",
            ],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode != 0:
            return ""

        lines = result.stdout.splitlines()
        if not lines:
            return ""

        # Parse branch from first line: "## branch" or "## branch...origin/branch"
        header = lines[0]
        if not header.startswith("## "):
            return ""

        branch_part = header[3:]  # Remove "## "
        # Handle "branch...origin/branch [ahead 1]" format
        branch = branch_part.split("...")[0].split()[0]

        if not branch or branch == "HEAD":
            # Detached HEAD state
            return ""

        # Check if there are any changes (lines after the header)
        has_changes = len(lines) > 1

        if has_changes:
            return f" git:({branch} *)"
        return f" git:({branch})"

    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


# ============================================================================
# Context Window Functions
# ============================================================================


def get_context_usage(data: dict[str, Any]) -> str:
    """Calculate context window usage percentage.

    Args:
        data: Pre-parsed JSON dictionary
    """
    context_window = data.get("context_window", {})
    if not isinstance(context_window, dict):
        return ""

    # Try pre-calculated percentage first
    used_pct = context_window.get("used_percentage", 0)

    if used_pct and used_pct != "null":
        try:
            pct = float(used_pct)
            if pct > 0:
                return f"{int(pct)}%"
        except (ValueError, TypeError):
            pass

    # Fallback: calculate from current_usage
    try:
        context_size = int(context_window.get("context_window_size", 0) or 0)
        if context_size <= 0:
            return ""

        current_usage = context_window.get("current_usage", {})
        if not isinstance(current_usage, dict):
            return ""

        input_tokens = int(current_usage.get("input_tokens", 0) or 0)
        cache_creation = int(current_usage.get("cache_creation_input_tokens", 0) or 0)
        cache_read = int(current_usage.get("cache_read_input_tokens", 0) or 0)

        current_tokens = input_tokens + cache_creation + cache_read
        if current_tokens > 0:
            return f"{current_tokens * 100 // context_size}%"
    except (ValueError, TypeError):
        pass

    return ""


# ============================================================================
# ANSI Colors
# ============================================================================

C_RESET = "\033[0m"
C_DIM = "\033[2m"
C_CYAN = "\033[36m"
C_GREEN = "\033[32m"
C_YELLOW = "\033[33m"
C_RED = "\033[31m"
C_MAGENTA = "\033[35m"
C_BLUE = "\033[34m"
C_ORANGE = "\033[38;5;208m"

# ============================================================================
# Formatting Functions
# ============================================================================


def format_number(num: int | float | str | None) -> str:
    """Format number with K/M suffix."""
    if num is None or num == "null" or num == 0:
        return "0"

    try:
        num_float = float(num)
        int_num = int(num_float)

        if int_num >= 1_000_000:
            return f"{num_float / 1_000_000:.1f}M"
        if int_num >= 1_000:
            return f"{num_float / 1_000:.1f}K"
        return str(int_num)
    except (ValueError, TypeError):
        return "0"


def format_duration(ms: int | float | str | None) -> str:
    """Format duration in milliseconds to human readable format."""
    if ms is None or ms == "null" or ms == 0:
        return "0s"

    try:
        total_seconds = int(ms) // 1000
        hours, remainder = divmod(total_seconds, 3600)
        minutes, seconds = divmod(remainder, 60)

        if hours > 0:
            return f"{hours}h{minutes}m"
        if minutes > 0:
            return f"{minutes}m{seconds}s"
        return f"{seconds}s"
    except (ValueError, TypeError):
        return "0s"


def format_cost(cost: float | str | None) -> str:
    """Format cost in USD."""
    if cost is None or cost == "null":
        return "$0.00"

    try:
        return f"${float(cost):.2f}"
    except (ValueError, TypeError):
        return "$0.00"


# ============================================================================
# Token Reset Functions
# ============================================================================


def get_token_window_path() -> str:
    """Get the token window state file path."""
    state_dir = os.environ.get("CLAUDE_STATUSLINE_STATE_DIR", "~/.claude/statusline")
    return os.path.join(os.path.expanduser(state_dir), "token_window.json")


def load_window_start() -> float | None:
    """Load the token window start time from persistent file."""
    try:
        with open(get_token_window_path()) as f:
            data = json.load(f)
            return data.get("window_start")
    except (FileNotFoundError, json.JSONDecodeError, IOError):
        return None


def save_window_start(window_start: float) -> None:
    """Save the token window start time to persistent file (atomic write)."""
    window_file = get_token_window_path()
    try:
        os.makedirs(os.path.dirname(window_file), exist_ok=True)
        tmpfile = f"{window_file}.tmp.{os.getpid()}"
        with open(tmpfile, "w") as f:
            json.dump({"window_start": window_start}, f)
        os.replace(tmpfile, window_file)
    except (IOError, OSError):
        pass


def get_token_reset_info(duration_ms: int | float | str | None) -> tuple[int, str]:
    """Calculate token reset remaining time and local reset clock time.

    Tracks the 5-hour token window using a persisted start time,
    so the reset countdown stays accurate across multiple sessions.

    Returns:
        (remaining_ms, reset_time_str) e.g. (180000, "17:00")
        (0, "") if disabled or unavailable
    """
    if TOKEN_RESET_MS <= 0:
        return (0, "")

    if duration_ms is None or duration_ms == "null" or duration_ms == 0:
        return (0, "")

    try:
        now = time.time()
        token_reset_seconds = TOKEN_RESET_MS // 1000

        # Load persisted window start (survives across sessions)
        window_start = load_window_start()

        # Snap to the hour floor: Anthropic resets on the hour boundary
        if window_start is not None:
            window_start = window_start - (window_start % 3600)

        # If window expired or doesn't exist, start a new one
        if window_start is None or (now - window_start) >= token_reset_seconds:
            window_start = now - (now % 3600)
            save_window_start(window_start)

        # Calculate remaining time in window
        remaining_seconds = int(token_reset_seconds - (now - window_start))

        if remaining_seconds <= 0:
            return (0, "")

        remaining_ms = remaining_seconds * 1000

        # Calculate actual local reset time
        reset_timestamp = now + remaining_seconds
        reset_local = time.localtime(reset_timestamp)
        reset_time_str = time.strftime("%H:%M", reset_local)

        return (remaining_ms, reset_time_str)
    except (ValueError, TypeError):
        return (0, "")


def format_token_reset(remaining_ms: int, reset_time_str: str) -> str:
    """Format token reset display with color based on urgency.

    Shows remaining time until token reset (e.g. "⏳ 4h35m").
    Color indicates urgency: dim > 33%, orange 10-33%, red < 10%.
    """
    if remaining_ms <= 0:
        return ""

    # Format remaining time as hours/minutes
    total_minutes = remaining_ms // 60000
    hours = total_minutes // 60
    minutes = total_minutes % 60

    if hours > 0:
        remaining_display = f"{hours}h{minutes}m"
    else:
        remaining_display = f"{minutes}m"

    # Color based on remaining percentage of window
    if TOKEN_RESET_MS > 0:
        remaining_pct = remaining_ms * 100 // TOKEN_RESET_MS
    else:
        remaining_pct = 100

    if remaining_pct <= 10:
        color = C_RED
    elif remaining_pct <= 33:
        color = C_ORANGE
    else:
        color = C_DIM

    return f"{color}⏳ {remaining_display}{C_RESET}"


# ============================================================================
# Progress Bar Functions
# ============================================================================


def build_progress_bar(percent_str: str | int | float, width: int = 10) -> str:
    """Build a colored progress bar.

    Args:
        percent_str: Percentage value (can be "85%", "85", 85, or 85.5)
        width: Bar width in characters
    """
    # Remove % sign if present and convert to string
    cleaned = str(percent_str).rstrip("%").strip()

    if not cleaned:
        return ""

    # Parse as float first to handle "12.5", then convert to int
    try:
        percent = int(float(cleaned))
    except (ValueError, TypeError):
        return ""

    # Clamp to valid range
    percent = max(0, min(100, percent))

    filled = percent * width // 100
    empty = width - filled

    # Color based on usage level
    if percent >= 90:
        color = C_RED
    elif percent >= 75:
        color = C_YELLOW
    else:
        color = C_GREEN

    # Build the bar - filled in color, empty in dim
    filled_bar = "━" * filled
    empty_bar = "╌" * empty

    return f"{color}{filled_bar}{C_RESET}{C_DIM}{empty_bar}{C_RESET} {percent}%"


# ============================================================================
# Statusline Output
# ============================================================================


def build_statusline(
    model: str,
    dir_name: str,
    git_info: str,
    context_usage: str,
    input_tokens: int | str,
    output_tokens: int | str,
    cost: float | str,
    duration: int | str,
    lines_added: int | str,
    lines_removed: int | str,
    token_reset: str = "",
) -> str:
    """Build the status line string."""
    SEP = " │ "
    parts: list[str] = []

    # Directory (📂 icon)
    parts.append(f"{C_BLUE}📂 {dir_name}{C_RESET}")

    # Git info (emoji based on branch type)
    if git_info:
        # Extract branch and status from " git:(branch *)" format
        branch_info = git_info.replace(" git:(", "").rstrip(")")
        # Get branch name without status indicator for emoji lookup
        branch_name = branch_info.rstrip(" *")
        emoji = get_branch_emoji(branch_name)
        parts.append(f"{C_GREEN}{emoji} {branch_info}{C_RESET}")

    # Model (🤖 icon) - remove "Claude " prefix
    short_model = model.removeprefix("Claude ")
    parts.append(f"{C_MAGENTA}🤖 {short_model}{C_RESET}")

    # Token usage (📥 in / 📤 out)
    if input_tokens and str(input_tokens) != "0":
        in_fmt = format_number(input_tokens)
        out_fmt = format_number(output_tokens)
        parts.append(f"{C_CYAN}📥 {in_fmt} 📤 {out_fmt}{C_RESET}")

    # Cost (💰 icon)
    if cost and str(cost) != "0" and cost != "null":
        cost_fmt = format_cost(cost)
        parts.append(f"{C_YELLOW}💰 {cost_fmt}{C_RESET}")

    # Duration (⏱️ icon) + Token reset (⏳ icon)
    if duration and str(duration) != "0" and duration != "null":
        duration_fmt = format_duration(duration)
        duration_part = f"{C_DIM}⏱️ {duration_fmt}{C_RESET}"
        if token_reset:
            duration_part += f" {token_reset}"
        parts.append(duration_part)

    # Lines changed (+/-)
    if lines_added and str(lines_added) != "0":
        lines_part = f"{C_GREEN}+{lines_added}{C_RESET}"
        if lines_removed and str(lines_removed) != "0":
            lines_part += f" {C_RED}-{lines_removed}{C_RESET}"
        parts.append(lines_part)

    # Context usage with progress bar (🧠 icon)
    if context_usage:
        progress_bar = build_progress_bar(context_usage)
        if progress_bar:
            parts.append(f"🧠 {progress_bar}")

    return SEP.join(parts)


# ============================================================================
# Main
# ============================================================================


def main() -> None:
    """Main entry point."""
    # Disable statusline for team sub-agents spawned via Task tool
    # Task tool agents run with CLAUDE_CODE_ENTRYPOINT=local-agent
    # STATUSLINE_DISABLED=1 allows manual override
    entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "cli")
    if entrypoint == "local-agent" or os.environ.get("STATUSLINE_DISABLED") == "1":
        return

    input_raw = read_input()

    # Parse JSON once and reuse
    data = parse_json(input_raw)

    # Extract model info
    model_data = data.get("model", {})
    model_display = (
        model_data.get("display_name", "Claude")
        if isinstance(model_data, dict)
        else "Claude"
    )

    # Extract workspace info
    workspace_data = data.get("workspace", {})
    current_dir = (
        workspace_data.get("current_dir", "")
        if isinstance(workspace_data, dict)
        else ""
    )
    dir_name = get_project_name(current_dir) if current_dir else ""

    # Get additional info
    git_info = get_git_info(current_dir)
    context_usage = get_context_usage(data)

    # Extract context window data
    context_window = data.get("context_window", {})
    if isinstance(context_window, dict):
        input_tokens = context_window.get("total_input_tokens", 0)
        output_tokens = context_window.get("total_output_tokens", 0)
    else:
        input_tokens = output_tokens = 0

    # Extract cost data
    cost_data = data.get("cost", {})
    if isinstance(cost_data, dict):
        cost = cost_data.get("total_cost_usd", 0)
        duration = cost_data.get("total_duration_ms", 0)
        lines_added = cost_data.get("total_lines_added", 0)
        lines_removed = cost_data.get("total_lines_removed", 0)
    else:
        cost = duration = lines_added = lines_removed = 0

    # Calculate token reset time (local clock)
    remaining_ms, reset_time_str = get_token_reset_info(duration)
    token_reset = format_token_reset(remaining_ms, reset_time_str)


    # Output statusline
    print(
        build_statusline(
            model_display,
            dir_name,
            git_info,
            context_usage,
            input_tokens,
            output_tokens,
            cost,
            duration,
            lines_added,
            lines_removed,
            token_reset,
        ),
        end="",
    )


if __name__ == "__main__":
    main()
