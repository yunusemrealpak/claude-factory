#!/usr/bin/env python3
"""Factory: did the work leave behind what the goal needs? NOT a hook:
factory-finish runs it on every task the run landed, and the auditor runs it
first, as the start of its audit.

Usage (from the project root):
  factory-musthaves <Cn | task-id>... [--json]

A task file can say what must exist once it is done, under `## Must haves`:

  ## Must haves
  - truth: a user with no orders sees the empty state, not an error
  - artifact: src/orders/empty_state.tsx
  - link: src/routes.tsx: OrdersEmptyState

An `artifact` is a file that must be in the tree and not empty; a `link` is a
file that must contain a piece of text - the import, the route registration,
the subscription that wires a part in. Both are checked here, from disk, with
no model: a task can be green and its summary say "done" while the screen it
built is reachable from nowhere. A `truth` is behaviour, which only a reader
can judge: it is listed for the auditor, not checked.

What it cannot prove: an artifact that exists can still be a stub. That is the
auditor's question, and the reason it starts from "the tasks are done, the
goal is missed" rather than from the green board.

Only landed tasks (tasks/done) are checked: a must-have of unfinished work is
not missing yet. Output: `MUST-HAVE MISSING <id>: ...` per miss, `TRUTH <id>:
...` per truth, and `MUST-HAVES <n> checked, <m> missing`. Exit 1 when one is
missing.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
ROOT = os.getcwd()
DONE = os.path.join(ROOT, "tasks", "done")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def section(text, name):
    m = re.search(r"^## %s[ \t]*\n(.*?)(?=^## |\Z)" % re.escape(name), text, re.S | re.M | re.I)
    return m.group(1) if m else ""


def items(text):
    """(kind, value) for each `- kind: value` line under ## Must haves."""
    out = []
    for line in section(text, "Must haves").splitlines():
        m = re.match(r"^\s*[-*]\s*(truth|artifact|link)\s*:\s*(.+?)\s*$", line, re.I)
        if m:
            out.append((m.group(1).lower(), m.group(2).strip().strip("`")))
    return out


def inside(path):
    full = os.path.realpath(os.path.join(ROOT, path))
    return full == os.path.realpath(ROOT) or full.startswith(os.path.realpath(ROOT) + os.sep)


def check_task(tid):
    """{"id", "checked", "missing": [...], "truths": [...]} for one landed task."""
    res = {"id": tid, "checked": 0, "missing": [], "truths": []}
    text = read(os.path.join(DONE, tid + ".md"))
    for kind, value in items(text):
        if kind == "truth":
            res["truths"].append(value)
            continue
        res["checked"] += 1
        if kind == "artifact":
            path = value.lstrip("./")
            if not inside(path):
                res["missing"].append("artifact %s is outside the project" % value)
            elif not os.path.isfile(os.path.join(ROOT, path)):
                res["missing"].append("artifact %s does not exist" % path)
            elif os.path.getsize(os.path.join(ROOT, path)) == 0:
                res["missing"].append("artifact %s is empty" % path)
            continue
        path, sep, needle = value.partition(":")
        path, needle = path.strip().strip("`").lstrip("./"), needle.strip().strip("`")
        if not sep or not needle:
            res["missing"].append("link '%s' is not written as <file>: <text>" % value)
        elif not inside(path) or not os.path.isfile(os.path.join(ROOT, path)):
            res["missing"].append("link %s: the file does not exist" % path)
        elif needle not in read(os.path.join(ROOT, path)):
            res["missing"].append("link %s does not contain '%s' - nothing wires it in" % (path, needle))
    return res


def task_ids(args):
    try:
        done = sorted(n[:-3] for n in os.listdir(DONE) if n.endswith(".md"))
    except OSError:
        done = []
    ids = []
    for a in args:
        if re.match(r"^C[0-9]+$", a):
            ids += [t for t in done if t.startswith(a + "-") or (a == "C1" and not re.match(r"^C[0-9]+-", t))]
        elif a in done:
            ids.append(a)
    return list(dict.fromkeys(ids))


def check(args):
    return [r for r in (check_task(t) for t in task_ids(args)) if r["checked"] or r["truths"]]


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print("usage: factory-musthaves <Cn | task-id>... [--json]", file=sys.stderr)
        return 2
    results = check(args)
    missing = sum(len(r["missing"]) for r in results)
    if "--json" in argv:
        print(json.dumps({"tasks": results, "checked": sum(r["checked"] for r in results), "missing": missing}))
        return 1 if missing else 0
    for r in results:
        for m in r["missing"]:
            print("MUST-HAVE MISSING %s: %s" % (r["id"], m))
        for t in r["truths"]:
            print("TRUTH %s: %s" % (r["id"], t))
    print("MUST-HAVES %d checked, %d missing%s" % (
        sum(r["checked"] for r in results), missing,
        "" if results else " (no landed task of %s lists any)" % " ".join(args)))
    return 1 if missing else 0


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    sys.exit(main(sys.argv[1:]))
