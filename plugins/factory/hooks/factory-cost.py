#!/usr/bin/env python3
"""Factory: where a run's tokens went, from the transcripts. NOT a hook.

Usage (from the project root):
  factory-cost                 the most recent session in this project
  factory-cost <session-id>    one session
  factory-cost --all           every session of this project
  add --json for one JSON object instead of the table

Claude Code writes every request of a session to disk: the main conversation in
~/.claude/projects/<project>/<session>.jsonl, each subagent and each workflow
agent in a file of its own under <session>/subagents/, with the agent's type in
a .meta.json beside it. Each assistant message carries its usage. This adds it
up per role - the lead, each agent type, each workflow step - so "which part of
the factory costs the most" is a measurement, not an estimate. No model turn is
spent on it.

Dollar figures are estimates from list prices per million tokens (the table
below); the requests, token counts and durations are exact. Output tokens
include thinking, which is billed as output.
"""
import glob
import json
import os
import re
import sys
from datetime import datetime

sys.dont_write_bytecode = True

# $ per million tokens: input, output, cache read, cache write 5m, cache write 1h.
PRICES = {
    "claude-opus-5-5": (4.0, 20.0, 0.20, 5.0, 8.0),
    "claude-opus-5": (5.0, 25.0, 0.50, 6.25, 10.0),
    "claude-sonnet-5": (2.0, 10.0, 0.20, 2.5, 4.0),
    "claude-sonnet-4-6": (3.0, 15.0, 0.30, 3.75, 6.0),
    "claude-haiku-4-5": (1.0, 5.0, 0.10, 1.25, 2.0),
    "claude-fable-5-1": (10.0, 50.0, 0.25, 12.5, 20.0),
}


def price(model):
    for key in sorted(PRICES, key=len, reverse=True):
        if model and model.startswith(key):
            return PRICES[key]
    return None


def project_dir(root):
    return os.path.join(os.path.expanduser("~"), ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", root))


def ts(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def read_messages(path):
    """Assistant messages of one transcript, one entry per API request. A
    streamed message is written several times; its last copy has the totals."""
    msgs, first, last = {}, None, None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                t = ts(row.get("timestamp"))
                if t:
                    first = t if first is None else min(first, t)
                    last = t if last is None else max(last, t)
                if row.get("type") != "assistant":
                    continue
                msg = row.get("message") or {}
                mid, usage = msg.get("id"), msg.get("usage")
                if not mid or not usage:
                    continue
                prev = msgs.get(mid)
                if prev is None or (usage.get("output_tokens") or 0) >= (prev[1].get("output_tokens") or 0):
                    msgs[mid] = (msg.get("model") or "", usage, row.get("perTurnEffort"))
    except OSError:
        pass
    return msgs, first, last


def role_of(path, main):
    if path == main:
        return "lead (main session)"
    meta = {}
    try:
        with open(path[:-len(".jsonl")] + ".meta.json", encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        pass
    kind = meta.get("agentType") or "subagent"
    if kind == "workflow-subagent":
        label = re.sub(r"^[A-Za-z]+-\d+\s*", "", meta.get("description") or "").strip()
        return "workflow step: " + (label or meta.get("description") or "?")
    return kind


def session_report(pdir, sid):
    main = os.path.join(pdir, sid + ".jsonl")
    files = [main] + sorted(glob.glob(os.path.join(pdir, sid, "subagents", "**", "agent-*.jsonl"), recursive=True))
    roles, first, last = {}, None, None
    for path in files:
        msgs, f0, f1 = read_messages(path)
        if f0:
            first = f0 if first is None else min(first, f0)
            last = f1 if last is None else max(last, f1)
        role = role_of(path, main)
        r = roles.setdefault(role, {"agents": 0, "requests": 0, "input": 0, "output": 0, "thinking": 0,
                                    "cache_read": 0, "cache_write": 0, "usd": 0.0, "models": set(), "efforts": set()})
        if path != main:
            r["agents"] += 1
        for model, u, effort in msgs.values():
            cc = u.get("cache_creation") or {}
            w5 = cc.get("ephemeral_5m_input_tokens")
            w1 = cc.get("ephemeral_1h_input_tokens")
            write = u.get("cache_creation_input_tokens") or 0
            if w5 is None and w1 is None:
                w5, w1 = write, 0
            r["requests"] += 1
            r["input"] += u.get("input_tokens") or 0
            r["output"] += u.get("output_tokens") or 0
            r["thinking"] += (u.get("output_tokens_details") or {}).get("thinking_tokens") or 0
            r["cache_read"] += u.get("cache_read_input_tokens") or 0
            r["cache_write"] += write
            r["models"].add(model)
            if effort:
                r["efforts"].add(str(effort))
            p = price(model)
            if p:
                r["usd"] += ((u.get("input_tokens") or 0) * p[0] + (u.get("output_tokens") or 0) * p[1]
                             + (u.get("cache_read_input_tokens") or 0) * p[2] + (w5 or 0) * p[3] + (w1 or 0) * p[4]) / 1e6
    for r in roles.values():
        r["models"] = sorted(m for m in r["models"] if m)
        r["efforts"] = sorted(r["efforts"])
    return {"session": sid, "wall_seconds": int(last - first) if first and last else None, "roles": roles}


def main(argv):
    as_json = "--json" in argv
    args = [a for a in argv if a != "--json"]
    pdir = project_dir(os.getcwd())
    sessions = sorted(glob.glob(os.path.join(pdir, "*.jsonl")), key=os.path.getmtime)
    if not sessions:
        print("factory-cost: no transcripts for this directory under %s" % pdir)
        return 2
    if args and args[0] == "--all":
        sids = [os.path.basename(p)[:-6] for p in sessions]
    elif args:
        sids = [args[0]]
    else:
        sids = [os.path.basename(sessions[-1])[:-6]]
    reports = [session_report(pdir, s) for s in sids]
    if as_json:
        print(json.dumps(reports if len(reports) > 1 else reports[0], indent=1))
        return 0
    for rep in reports:
        total = sum(r["usd"] for r in rep["roles"].values()) or 1
        wall = rep["wall_seconds"]
        print("session %s   wall %s" % (rep["session"], "%dm%02ds" % divmod(wall, 60) if wall is not None else "?"))
        print("%-34s %6s %8s %10s %10s %12s %9s %6s" % ("role", "agents", "requests", "output", "thinking",
                                                      "cache read", "est. $", "share"))
        for role, r in sorted(rep["roles"].items(), key=lambda kv: -kv[1]["usd"]):
            if not r["requests"]:
                continue
            print("%-34s %6s %8d %10d %10d %12d %9.2f %5.0f%%" % (role[:34], r["agents"] or "-", r["requests"], r["output"],
                                                               r["thinking"], r["cache_read"], r["usd"], 100 * r["usd"] / total))
        tot = {k: sum(r[k] for r in rep["roles"].values()) for k in ("requests", "output", "thinking", "cache_read", "usd")}
        print("%-34s %6s %8d %10d %10d %12d %9.2f" % ("total", "", tot["requests"], tot["output"], tot["thinking"],
                                                     tot["cache_read"], tot["usd"]))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
