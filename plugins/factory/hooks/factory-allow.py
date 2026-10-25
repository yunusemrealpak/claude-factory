#!/usr/bin/env python3
"""Factory: the permission rules an unattended run needs, merged into the
project's .claude/settings.json. NOT a hook: /factory:init and
/factory:upgrade run it with --apply; factory-preflight reports what is
missing when the run is headless.

Usage (from the project root, or with FACTORY_ROOT set):
  factory-allow            report how many rules the project lacks (exit 1 if any)
  factory-allow --apply    add them
  factory-allow --list     print the rules, one per line

A night run is started with --permission-prompts none: nobody is there to
answer a prompt, so anything that would ask is refused, and the agent is told
so. That is the right failure - a run that waits on a prompt nobody sees burns
the night - but only if what the run is supposed to do never asks. These
rules are that list: the loop workflow, the factory commands a run calls, the
project's build, test and lint commands from .factory/config.json, and the
read-only git commands the reviewer and the auditor read diffs with.

A configured command becomes a rule for each of its parts (`cd app && npm
test` is two commands to the permission check, so it is two rules), and a
{placeholder} - with anything after it - becomes a wildcard. A command run
through a shell or another launcher (`bash -c ...`, `env ...`, `sudo ...`) is
never given a wildcard: `Bash(bash -c *)` would allow anything at all. Such a
command is allowed exactly as written, or not at all when it has a
placeholder; the report names it, and a rule for it is the developer's call.

A union, like factory-deny: rules already there - the developer's own
included - stay and keep their order, missing ones are appended, a second run
changes nothing, and everything else in the file is left as it is. The hard
bans stay in permissions.deny, and a deny rule wins over an allow rule.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
FILE = os.path.join(ROOT, ".claude", "settings.json")
SHOWN = ".claude/settings.json"

# What a run calls, from workflows/loop.js, the agents and commands/run.md. A
# command a run calls only in one form is allowed only in that form.
COMMANDS = ("factory-preflight", "factory-plan", "factory-ids check", "factory-start", "factory-check",
            "factory-settle", "factory-block", "factory-ask", "factory-risk", "factory-lint", "factory-criteria",
            "factory-musthaves",
            "factory-review-submit", "factory-deliver", "factory-finish", "factory-accept", "factory-retro-apply",
            "factory-lesson list", "factory-change sync")
READ_ONLY_GIT = ("git diff", "git log", "git show", "git status", "git rev-parse", "git ls-files")
# Launchers: whatever follows them is another command, so a wildcard after one
# allows everything.
RUNNERS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "pwsh", "powershell", "powershell.exe", "cmd", "cmd.exe",
           "env", "eval", "exec", "sudo", "doas", "xargs", "nohup", "time", "timeout", "nice", "watch", "command",
           "builtin", "source", "."}


def settings_file(root=None):
    return FILE if root is None else os.path.join(os.path.abspath(root), ".claude", "settings.json")


def config(root=None):
    try:
        with open(os.path.join(root or ROOT, ".factory", "config.json"), encoding="utf-8-sig") as fh:
            cfg = json.load(fh)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def as_rules(cmd):
    """One configured command as allow rules, and the parts that could not be
    made one: ([rules], [skipped parts])."""
    cmd = (cmd or "").strip() if isinstance(cmd, str) else ""
    if not cmd or "\n" in cmd:
        return [], ([cmd] if cmd else [])
    rules, skipped = [], []
    for part in re.split(r"\s*(?:&&|\|\||;|\|)\s*", cmd):
        part = part.strip()
        if not part:
            continue
        if re.search(r"[()`]|\$\(", part):
            skipped.append(part)  # a rule cannot hold it: Bash( ... ) ends at the first ")"
            continue
        runner = part.split()[0] in RUNNERS
        if "{" in part:
            head = part[:part.index("{")].rstrip()
            if head and not runner:
                rules.append("Bash(%s *)" % head)
            else:
                skipped.append(part)
            continue
        rules.append("Bash(%s)" % part)
        if not runner:
            rules.append("Bash(%s *)" % part)
    return rules, skipped


def configured(root=None):
    """The project's own commands from .factory/config.json, in a fixed order."""
    cfg = config(root)
    out = []
    cmds = cfg.get("commands") if isinstance(cfg.get("commands"), dict) else {}
    for key in ("build", "test", "arch", "lint"):
        out.append(cmds.get(key))
    chk = cfg.get("check") if isinstance(cfg.get("check"), dict) else {}
    for key in ("format", "unit_test"):
        out.append(chk.get(key))
    for unit in chk.get("units") or []:
        if isinstance(unit, dict):
            out.append(unit.get("test"))
    return [c for c in out if isinstance(c, str) and c.strip()]


def plan(root=None):
    """(the rules a run needs, the configured parts left to the developer)."""
    rules = ["Workflow(factory:loop)"]
    for c in COMMANDS + READ_ONLY_GIT:
        rules += ["Bash(%s)" % c, "Bash(%s *)" % c]
    skipped = []
    for c in configured(root):
        r, s = as_rules(c)
        rules += r
        skipped += [x for x in s if x not in skipped]
    out = []
    for r in rules:
        if r not in out:
            out.append(r)
    return out, skipped


def wanted(root=None):
    return plan(root)[0]


def current(root=None):
    """The settings as a dict; ValueError when the file is not a JSON object
    whose permissions.allow is a list."""
    path = settings_file(root)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8-sig") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
    perms = data.get("permissions")
    if perms is not None and (not isinstance(perms, dict) or not isinstance(perms.get("allow", []), list)):
        raise ValueError("permissions.allow is not a list")
    return data


def missing(settings=None, root=None):
    """The rules the settings lack, in order. Never raises: settings that
    cannot be read lack every rule."""
    if settings is None:
        try:
            settings = current(root)
        except (OSError, ValueError):
            return wanted(root)
    have = ((settings.get("permissions") or {}).get("allow") or []) if isinstance(settings, dict) else []
    return [r for r in wanted(root) if r not in have]


def main(argv):
    rules, skipped = plan()
    if "--list" in argv:
        print("\n".join(rules))
        return 0
    try:
        settings = current()
    except (OSError, ValueError) as exc:
        print("ALLOW ERROR: %s cannot be read (%s); fix it by hand first" % (SHOWN, exc))
        return 2
    gap = missing(settings)
    note = ["ALLOW NOTE: not allowed automatically, a rule for it is your call: %s" % s for s in skipped]
    if "--apply" not in argv:
        if not gap:
            print("ALLOW OK: every rule an unattended run needs is in %s" % SHOWN)
        else:
            print("ALLOW %d rule(s) missing from %s (e.g. %s); 'factory-allow --apply' adds them."
                  % (len(gap), SHOWN, ", ".join(gap[:3])))
        if note:
            print("\n".join(note))
        return 1 if gap else 0
    if gap:
        perms = settings.setdefault("permissions", {})
        perms["allow"] = list(perms.get("allow") or []) + gap
        os.makedirs(os.path.dirname(FILE), exist_ok=True)
        tmp = FILE + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(settings, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, FILE)
    print("ALLOW APPLIED: %d rule(s) added to %s" % (len(gap), SHOWN))
    if note:
        print("\n".join(note))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
