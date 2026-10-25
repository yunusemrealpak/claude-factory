#!/usr/bin/env python3
"""Factory: the project's standards that apply to one task. NOT a hook:
factory-start prints them to the builder, and the reviewer runs it.

Usage (from the project root):
  factory-criteria <task-id> [--names]

A standard that every agent reads on every turn is a tax: CLAUDE.md is in
every context, all of it, whether the task touches the API or the build
script. A criteria file is read only by the task it is about.

  .factory/criteria/<area>.md
  ---
  applies_to: ["src/api/**", "migrations/*.sql"]
  modules: [api]
  ---
  - Every handler reads the tenant from the session, never from the request.

A file applies when one of its globs matches a path the task names - under
`## Files touched`, `## Constraints` or `## Context`, or a file its commit
changed once it has landed - or when `modules:` lists the task's module. A
file with neither key applies to every task. --names prints only the paths.
"""
import fnmatch
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = os.getcwd()
C = os.path.join(ROOT, ".factory", "criteria")
T = os.path.join(ROOT, "tasks")
LANES = ("in-progress", "backlog", "done", "blocked", "proposed")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def frontmatter(text):
    m = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*\n?", text, re.S)
    out = {}
    for line in (m.group(1).splitlines() if m else []):
        k, sep, v = line.partition(":")
        if sep and k.strip() not in out:
            out[k.strip()] = v.strip()
    return out, (text[m.end():] if m else text)


def listed(value):
    return [x.strip().strip("'\"") for x in value.strip().strip("[]").split(",") if x.strip().strip("'\"")]


def section(text, name):
    m = re.search(r"^## %s[ \t]*\n(.*?)(?=^## |\Z)" % re.escape(name), text, re.S | re.M)
    return m.group(1) if m else ""


def task_paths(tid, text):
    paths = set()
    for sec in ("Files touched", "Constraints", "Context"):
        for m in re.finditer(r"(?<![\w/.-])((?:[\w.-]+/)+[\w.*-]+|[\w-]+\.[a-zA-Z0-9]{1,6})(?![\w/])", section(text, sec)):
            paths.add(m.group(1).lstrip("./"))
    r = subprocess.run(["git", "log", "--format=%H", "--grep", "^Factory-Task: %s$" % tid, "-n", "5"], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    for sha in (r.stdout or "").split():
        s = subprocess.run(["git", "show", "--name-only", "--format=", sha], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        paths.update(p.strip() for p in (s.stdout or "").splitlines() if p.strip())
    return paths


def applies(meta, paths, module):
    globs = listed(meta.get("applies_to", ""))
    modules = listed(meta.get("modules", ""))
    if not globs and not modules:
        return True
    if module and module in modules:
        return True
    return any(fnmatch.fnmatch(p, g) or fnmatch.fnmatch(p, g.rstrip("/*") + "/*") for p in paths for g in globs)


def main(argv):
    ids = [a for a in argv if not a.startswith("--")]
    if not ids:
        print("usage: factory-criteria <task-id> [--names]", file=sys.stderr)
        return 2
    tid = ids[0]
    text = next((read(os.path.join(T, lane, tid + ".md")) for lane in LANES
                 if os.path.isfile(os.path.join(T, lane, tid + ".md"))), "")
    if not text:
        print("CRITERIA %s: no task file under tasks/" % tid)
        return 1
    module = frontmatter(text)[0].get("module", "")
    paths = task_paths(tid, text)
    try:
        names = sorted(n for n in os.listdir(C) if n.endswith(".md"))
    except OSError:
        names = []
    hits = []
    for n in names:
        meta, body = frontmatter(read(os.path.join(C, n)))
        if applies(meta, paths, module):
            hits.append((n, body.strip()))
    if "--names" in argv:
        for n, _ in hits:
            print(".factory/criteria/" + n)
        return 0
    if not hits:
        print("CRITERIA %s: none of the project's criteria files (.factory/criteria/) applies to it." % tid)
        return 0
    for n, body in hits:
        print("### Criteria: .factory/criteria/%s\n%s\n" % (n, body))
    return 0


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    sys.exit(main(sys.argv[1:]))
