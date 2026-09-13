#!/usr/bin/env python3
"""Preserve the lead's working state across a compaction.

Registered on PreCompact and PostCompact.

PreCompact writes <project>/.factory/lead-state.md before the conversation is
summarized. The file holds two things the summary cannot be trusted to keep:
  1. the exact board state, rebuilt from the task files on disk
  2. the tail of the lead's own reasoning, so intent survives the summary
factory-brief.sh reads that file back on the SessionStart that fires with
source "compact", which is how the state re-enters the compacted context.

PostCompact appends the generated summary to <project>/.factory/compact-log.md
as an audit trail.

Neither mode ever blocks compaction: a failure here must not wedge the run.

Verified against https://code.claude.com/docs/en/hooks:
  PreCompact  input: trigger, custom_instructions, transcript_path
  PostCompact input: trigger, compact_summary
"""
import json
import os
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
MAX_MSGS = 4           # how many trailing assistant messages to keep
MAX_CHARS = 700        # per message
MAX_TOOL_LINES = 12    # trailing tool calls to list


STAGES = ["queued", "implementing", "verifying", "review", "integrating"]


def read_frontmatter(path):
    """Parses the leading --- block of a task file into a dict of raw strings."""
    data = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            if fh.readline().strip() != "---":
                return data
            for line in fh:
                if line.strip() == "---":
                    break
                key, sep, value = line.partition(":")
                if sep:
                    data[key.strip()] = value.strip()
    except OSError:
        pass
    return data


def scan_board(project):
    """Rebuilds the board from disk. Small and self-contained on purpose: the
    memo is the only thing standing between a compaction and a lost run."""
    lanes = ("backlog", "in-progress", "done", "blocked")
    tasks, done_ids = [], set()
    for lane in lanes:
        d = os.path.join(project, "tasks", lane)
        try:
            names = sorted(n for n in os.listdir(d) if n.endswith(".md"))
        except OSError:
            continue
        for name in names:
            tid = name[:-3]
            if lane == "done":
                done_ids.add(tid)
            fm = read_frontmatter(os.path.join(d, name))
            deps = [x.strip().strip("\"'") for x in fm.get("depends_on", "").strip("[]").split(",") if x.strip()]
            tasks.append({"id": tid, "lane": lane, "title": fm.get("title") or tid,
                          "deps": deps, "owner": fm.get("owner", ""), "stage": fm.get("stage", ""),
                          "retries": fm.get("retries", "0"),
                          "needs_human": fm.get("needs_human", "").lower() == "true",
                          "stage_since": fm.get("stage_since", "")})
    counts = {l: sum(1 for t in tasks if t["lane"] == l) for l in lanes}
    for t in tasks:
        t["ready"] = (t["lane"] == "backlog" and not t["needs_human"]
                      and all(d in done_ids for d in t["deps"]))
    return tasks, counts


def text_of(message):
    """Flattens an assistant message's content blocks into plain text."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            out.append(block.get("text", ""))
    return "\n".join(out).strip()


def tail_of_transcript(path):
    """Returns the last assistant messages and tool calls, newest last."""
    msgs, tools = [], []
    try:
        with open(path, errors="replace") as fh:
            lines = fh.readlines()[-1500:]
    except OSError:
        return msgs, tools
    for line in lines:
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("isSidechain"):
            continue
        msg = row.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        body = text_of(msg)
        if body:
            msgs.append(body)
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    name = block.get("name", "?")
                    inp = block.get("input") or {}
                    hint = inp.get("file_path") or inp.get("command") or inp.get("subagent_type") or ""
                    tools.append(f"{name}: {str(hint)[:90]}")
    return msgs[-MAX_MSGS:], tools[-MAX_TOOL_LINES:]


def write_memo(project, data):
    tasks, counts = scan_board(project)
    msgs, tools = tail_of_transcript(data.get("transcript_path", ""))
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    total = sum(counts.values())
    ready = [t for t in tasks if t["ready"]]
    human = sum(1 for t in tasks if t["needs_human"])

    out = [
        "# Lead state at compaction",
        "",
        f"Written {now} by the PreCompact hook, trigger `{data.get('trigger', '?')}`.",
        "This is the state the summary must not lose. The board below is rebuilt",
        "from disk and is authoritative; the reasoning tail below it is what the",
        "lead was in the middle of.",
        "",
        "## Board",
        "",
        f"- backlog {counts.get('backlog', 0)} · in-progress {counts.get('in-progress', 0)} "
        f"· done {counts.get('done', 0)} · blocked {counts.get('blocked', 0)} "
        f"· ready {len(ready)} · needs-human {human} (total {total})",
        "",
    ]

    inflight = [t for t in tasks if t["lane"] == "in-progress"]
    if inflight:
        out += ["## Dispatched right now", ""]
        for t in inflight:
            out.append(f"- `{t['id']}` {t['title']} — owner `{t['owner'] or 'NONE'}`, "
                       f"stage `{t['stage'] or 'NONE'}`, retries {t['retries']}")
        out.append("")

    if ready:
        out += ["## Ready to dispatch next", ""]
        out += [f"- `{t['id']}` {t['title']}" for t in ready[:12]]
        out.append("")

    blocked = [t for t in tasks if t["lane"] == "blocked"]
    if blocked:
        out += ["## Blocked", ""]
        out += [f"- `{t['id']}` {t['title']} (retries {t['retries']})" for t in blocked]
        out.append("")

    decisions = []
    try:
        with open(os.path.join(project, "decisions.md"), encoding="utf-8", errors="replace") as fh:
            decisions = [l.strip() for l in fh if l.strip() and not l.startswith("#")][-6:]
    except OSError:
        pass
    if decisions:
        out += ["## Recent decisions", ""] + [d if d.startswith("-") else "- " + d
                                              for d in reversed(decisions)] + [""]

    if tools:
        out += ["## Last actions taken", ""] + [f"- {t}" for t in tools] + [""]

    if msgs:
        out += ["## Lead's reasoning tail (verbatim, truncated)", ""]
        for m in msgs:
            body = m if len(m) <= MAX_CHARS else m[:MAX_CHARS] + " …"
            out.append("> " + body.replace("\n", "\n> "))
            out.append("")

    out += ["## On resuming", "",
            "Re-read this file's board section before dispatching anything. If it",
            "disagrees with your memory of the run, the file is right: it was",
            "rebuilt from disk. Continue the loop from 'Ready to dispatch next'.", ""]

    with open(os.path.join(project, ".factory", "lead-state.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))


def log_summary(project, data):
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary = (data.get("compact_summary") or "").strip()
    path = os.path.join(project, ".factory", "compact-log.md")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"\n## {now} · trigger {data.get('trigger', '?')}\n\n{summary}\n")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    project = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if not os.path.isfile(os.path.join(project, ".factory", "active")):
        return 0
    try:
        if data.get("hook_event_name") == "PostCompact":
            log_summary(project, data)
        else:
            write_memo(project, data)
    except Exception as err:
        # Never block or fail a compaction because the memo could not be written.
        print(f"factory-compact: {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
