#!/usr/bin/env python3
"""Convert opencode debug log (out.log) to scenario.txt for replay testing.

Extracts:
  - SSE raw events  → :sse directives
  - API calls       → # comment annotations (>>> request, <<< response)
  - Chat handlers   → # comment annotations (on-*, refresh, refreshing)

Usage:
    python3 convert_log_to_scenario.py [input.log] [output.txt] [--session SES_ID]
    python3 convert_log_to_scenario.py input.log output.txt --session ses_abc123

Options:
    --session SES_ID   Only include events for this session ID.
                       Events without a session (heartbeat, etc.) are excluded
                       when this flag is set.

Defaults:
    input:  ../../out.log  (relative to this script)
    output: fixtures/scenario-output.txt  (same dir as this script)
"""
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
DEFAULT_INPUT = SCRIPT_DIR / ".." / ".." / ".." / "out.log"
DEFAULT_OUTPUT = SCRIPT_DIR / "fixtures" / "scenario-output.txt"

# SSE event types to skip (not useful for scenario replay)
SKIP_EVENT_TYPES = {
    "server.heartbeat",
    "server.connected",
    "tui.toast.show",
    "file.watcher.updated",
    "file.edited",
    "vcs.branch.updated",
    "lsp.updated",
    "mcp.tools.changed",
    "session.created",  # handled by sidebar, not chat
    "pty.output",
    "pty.exit",
    "worktree.updated",
    "project.updated",
    "command.executed",
}

# Patterns
RE_TIMESTAMP = re.compile(r"^\[(\d{2}:\d{2}:\d{2}\.\d{3})\]\s+")
RE_RAW_EVENT = re.compile(r"raw event: type=\S+ data=(\{.*\})\s*$")
RE_API_OUT = re.compile(r"opencode-api: >>>\s+(.*)")
RE_API_IN = re.compile(r"opencode-api: <<<\s+(.*)")
RE_CHAT_HANDLER = re.compile(r"opencode-chat: (on-\S+.*|refresh .*|refreshing .*)")
RE_SSE_DISPATCH = re.compile(r"opencode-sse: \[([^\]]+)\]")


def extract_session_id(ev: dict) -> str | None:
    payload = ev.get("payload", {})
    props = payload.get("properties", {})
    if not isinstance(props, dict):
        return None
    for key in ("info", "part"):
        sub = props.get(key)
        if isinstance(sub, dict) and sub.get("sessionID"):
            return sub["sessionID"]
    return props.get("sessionID")


def event_type_label(ev: dict) -> str:
    return ev.get("payload", {}).get("type", "?")


def parse_args():
    """Parse positional and --session arguments."""
    args = sys.argv[1:]
    session_filter = None
    positional = []

    i = 0
    while i < len(args):
        if args[i] == "--session" and i + 1 < len(args):
            session_filter = args[i + 1]
            i += 2
        elif args[i].startswith("--session="):
            session_filter = args[i].split("=", 1)[1]
            i += 1
        else:
            positional.append(args[i])
            i += 1

    input_path = Path(positional[0]) if len(positional) > 0 else DEFAULT_INPUT
    output_path = Path(positional[1]) if len(positional) > 1 else DEFAULT_OUTPUT

    return input_path, output_path, session_filter


def main():
    input_path, output_path, session_filter = parse_args()

    input_path = input_path.resolve()
    if not input_path.exists():
        sys.exit(f"Input not found: {input_path}")

    lines = input_path.read_text(encoding="utf-8").splitlines()

    out: list[str] = []
    session_id: str | None = session_filter
    directory: str | None = None
    sse_count = 0
    api_count = 0
    chat_count = 0
    prev_was_sse = False

    for line in lines:
        # Strip timestamp for matching
        ts_match = RE_TIMESTAMP.match(line)
        if not ts_match:
            continue
        ts = ts_match.group(1)
        rest = line[ts_match.end():]

        # --- SSE raw event ---
        m = RE_RAW_EVENT.search(rest)
        if m:
            try:
                ev = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            if "payload" not in ev:
                continue

            evt = event_type_label(ev)

            # Skip irrelevant event types
            if evt in SKIP_EVENT_TYPES:
                continue

            # Session filtering
            ev_session = extract_session_id(ev)
            if session_filter:
                # Skip events for other sessions
                if ev_session and ev_session != session_filter:
                    continue
                # Skip session-less events when filtering (except critical ones)
                if not ev_session and evt not in (
                    "server.instance.disposed",
                    "global.disposed",
                    "installation.update-available",
                ):
                    continue

            # Extract metadata from first matching event
            if not session_id and ev_session:
                session_id = ev_session
            if not directory and ev.get("directory"):
                directory = ev["directory"]

            compact = json.dumps(ev, separators=(",", ":"), ensure_ascii=False)

            # Add blank line before SSE if previous wasn't SSE (visual grouping)
            if not prev_was_sse and out and not out[-1].startswith("#"):
                out.append("")

            out.append(f"# [{ts}] {evt}")
            out.append(f":sse {compact}")
            sse_count += 1
            prev_was_sse = True
            continue

        prev_was_sse = False

        # --- API request (>>>) ---
        m = RE_API_OUT.search(rest)
        if m:
            api_line = m.group(1)
            # If filtering by session, skip API calls for other sessions
            if session_filter and session_filter not in api_line:
                # But keep session-less API calls (like /question, /permission, /agent)
                if "/session/" in api_line:
                    continue
            out.append(f"# [{ts}] API >>> {api_line}")
            api_count += 1
            continue

        # --- API response (<<<) ---
        m = RE_API_IN.search(rest)
        if m:
            api_line = m.group(1)
            if session_filter and session_filter not in api_line:
                if "/session/" in api_line:
                    continue
            out.append(f"# [{ts}] API <<< {api_line}")
            api_count += 1
            continue

        # --- Chat handler ---
        m = RE_CHAT_HANDLER.search(rest)
        if m:
            out.append(f"# [{ts}] chat: {m.group(1)}")
            chat_count += 1
            continue

    # Build header
    session_id = session_id or "ses_unknown"
    directory = directory or "/Users/bytedance/Documents/opencode.el"

    header = [
        f"# Scenario: auto-generated from {input_path.name}",
        f"# Source: {input_path.name}",
        f"# Stats: {sse_count} SSE events, {api_count} API calls, {chat_count} chat actions",
    ]
    if session_filter:
        header.append(f"# Session filter: {session_filter}")
    header += [
        "",
        f":session {session_id}",
        f":directory {directory}",
        "",
    ]

    # Build footer with assertions
    footer = [
        "",
        "# --- Assertions ---",
        ":assert-busy",
    ]

    final = header + out + footer
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(final) + "\n", encoding="utf-8")
    print(f"Wrote {output_path} ({len(final)} lines)")
    print(f"  SSE events: {sse_count}")
    print(f"  API calls:  {api_count}")
    print(f"  Chat lines: {chat_count}")


if __name__ == "__main__":
    main()
