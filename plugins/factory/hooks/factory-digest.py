#!/usr/bin/env python3
"""Factory: the day's delivery digest - what merged, what is held, what was
reverted, which pull requests wait for a person, and what tripped a breaker.

NOT a hook. The publisher writes it after every run; the session brief prints
its one-line form. Written to .factory/digest/<date>.md (overwritten through
the day), and `--line` prints just the line the brief shows.

Notifications are the publisher's job and only for a ban, a revert or a
breaker; this file is the quiet record of everything else.
"""
import json
import os
import sys
import time

ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
F = os.path.join(ROOT, ".factory")
P = os.path.join(F, "publish")


def states():
    out = []
    try:
        names = sorted(os.listdir(P))
    except OSError:
        return out
    for n in names:
        if n.endswith(".json"):
            try:
                out.append(json.load(open(os.path.join(P, n), encoding="utf-8")))
            except (OSError, ValueError):
                pass
    return out


def events(kind, since):
    rows = []
    try:
        for l in open(os.path.join(F, "events.jsonl"), encoding="utf-8"):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if r.get("kind") == kind and r.get("epoch", 0) >= since:
                rows.append(r)
    except OSError:
        pass
    return rows


def summarize():
    sts = states()
    open_ = [s for s in sts if s.get("state") not in ("done", "pr_only", "reverted", "abandoned")]
    return {
        "merged": [s for s in sts if s.get("state") == "done" and s.get("pr")],
        "waiting": [s for s in sts if s.get("state") == "pr_only"],
        "reverted": [s for s in sts if s.get("state") == "reverted"],
        "held": [s for s in open_ if s.get("held")],
        "running": [s for s in open_ if not s.get("held")],
    }


def line():
    d = summarize()
    parts = []
    if d["merged"]:
        parts.append("%d delivered" % len(d["merged"]))
    if d["waiting"]:
        parts.append("%d PR(s) wait for you (%s)" % (len(d["waiting"]), ", ".join("#%s" % s["pr"] for s in d["waiting"] if s.get("pr"))))
    if d["held"]:
        parts.append("%d held (%s)" % (len(d["held"]), ", ".join(s["change"] for s in d["held"])))
    if d["reverted"]:
        parts.append("%d reverted (%s)" % (len(d["reverted"]), ", ".join(s["change"] for s in d["reverted"])))
    cap = os.path.join(F, "autonomy-cap")
    if os.path.exists(cap):
        try:
            parts.append("BREAKER: " + open(cap, encoding="utf-8").read().splitlines()[1])
        except (OSError, IndexError):
            parts.append("BREAKER: level capped")
    return "; ".join(parts)


def write():
    d = summarize()
    day = time.strftime("%Y-%m-%d")
    os.makedirs(os.path.join(F, "digest"), exist_ok=True)
    L = ["# Delivery digest %s" % day, ""]

    def sect(title, rows, fmt):
        if rows:
            L.extend(["## " + title, ""] + ["- " + fmt(r) for r in rows] + [""])

    sect("Delivered", d["merged"], lambda s: "%s #%s (class %s, %s)" % (s["change"], s.get("pr"), s.get("class", "?"), s.get("method", "?")))
    sect("Waiting for you (class C or autonomy level pr)", d["waiting"],
         lambda s: "%s #%s class %s%s" % (s["change"], s.get("pr"), s.get("class", "?"), " - " + "; ".join(s.get("reasons", [])) if s.get("reasons") else ""))
    sect("Held", d["held"], lambda s: "%s at %s: %s" % (s["change"], s.get("state"), s.get("held")))
    sect("Reverted", d["reverted"], lambda s: "%s #%s - revert %s" % (s["change"], s.get("pr"), s.get("revert") or "not opened"))
    sect("In flight", d["running"], lambda s: "%s %s" % (s["change"], s.get("state")))
    since = time.time() - 86400
    bans = events("hard_block", since)
    sect("Hard blocks hit (last 24 h)", bans, lambda r: "%s by %s (%s)" % (r.get("rule"), r.get("agent_id") or "an agent", r.get("tool")))
    sect("Breakers (last 24 h)", events("breaker", since), lambda r: r.get("reason", "?"))
    if len(L) == 2:
        L.append("Nothing to report.")
    with open(os.path.join(F, "digest", day + ".md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")
    return os.path.join(F, "digest", day + ".md")


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if not os.path.isfile(os.path.join(F, "active")):
        sys.exit(0)
    if "--line" in sys.argv:
        print(line())
    else:
        print(write())
