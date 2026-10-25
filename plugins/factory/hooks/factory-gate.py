#!/usr/bin/env python3
"""The project's gate entry point, gates/verify.sh: what it is, and making it
the shim that runs factory-check.

Usage (from the project root):
  factory-gate.py classify   absent | shim | template <versions> | custom
  factory-gate.py install    no gate: write the shim. A template /factory:init
                             wrote, byte for byte (legacy/templates.sha256): put
                             the shim in its place and keep the old file in
                             .factory/gate-legacy/verify.sh. The shim, or a gate
                             of the project's own: leave it alone.
                             Prints GATE WRITTEN | GATE REPLACED <versions> |
                             GATE CURRENT | GATE KEPT.

The gate logic lives in the plugin (factory-check), so it upgrades with the
plugin. What a project adds of its own goes in gates/extra.sh, which every
check runs last. A gate somebody changed is theirs: it is never replaced.
"""
import hashlib
import os
import re
import shutil
import sys

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.getcwd()
GATE = os.path.join(ROOT, "gates", "verify.sh")
SHIM = os.path.join(HOOK_DIR, "gate-shim.sh")
KNOWN = os.path.join(HOOK_DIR, "legacy", "templates.sha256")
KEEP = os.path.join(ROOT, ".factory", "gate-legacy", "verify.sh")


def normalised(text):
    text = re.sub(r"\\\$([1-9])", r"$\1", text.replace("\r\n", "\n"))
    return "\n".join(line.rstrip() for line in text.split("\n")).strip("\n") + "\n"


def digest(text):
    return hashlib.sha256(normalised(text).encode("utf-8")).hexdigest()


def known():
    out = {}
    with open(KNOWN, encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2 and not line.startswith("#"):
                out[parts[0]] = parts[1]
    return out


def read(path):
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        return fh.read()


def classify():
    if not os.path.isfile(GATE):
        return "absent", ""
    text = read(GATE)
    # The shim, or a gate of the project's own that hands its arguments over to
    # the engine ("factory-check count ..." inside a gate is not that).
    if re.search(r"^\s*(exec\s+)?factory-check\s+\"?\$(\{?[@1]\}?)\"?", text, re.M):
        return "shim", ""
    versions = known().get(digest(text))
    if versions:
        return "template", versions
    return "custom", ""


def write_shim():
    os.makedirs(os.path.dirname(GATE), exist_ok=True)
    with open(GATE, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(read(SHIM).replace("\r\n", "\n"))
    os.chmod(GATE, 0o755)


def main(argv):
    if not argv or argv[0] not in ("classify", "install"):
        print(__doc__.split("\n\n")[1])
        return 2
    kind, versions = classify()
    if argv[0] == "classify":
        print(("%s %s" % (kind, versions)).strip())
        return 0
    if kind == "absent":
        write_shim()
        print("GATE WRITTEN: gates/verify.sh is the shim that runs factory-check")
    elif kind == "template":
        os.makedirs(os.path.dirname(KEEP), exist_ok=True)
        shutil.copy2(GATE, KEEP)
        write_shim()
        print("GATE REPLACED %s: gates/verify.sh was the template factory %s wrote; it is now the shim that runs "
              "factory-check (the old file is in .factory/gate-legacy/verify.sh)" % (versions, versions))
    elif kind == "shim":
        print("GATE CURRENT: gates/verify.sh runs factory-check")
    else:
        print("GATE KEPT: gates/verify.sh is the project's own, so it is not replaced. The gate engine is "
              "factory-check: to use it, make gates/verify.sh the shim (exec factory-check \"$@\") and move what "
              "the gate does of its own into gates/extra.sh, which every check runs last.")
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
