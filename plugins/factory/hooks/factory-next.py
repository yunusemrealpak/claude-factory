#!/usr/bin/env python3
"""Factory: the outer loop. Starts the next approved change on its own - only
when everything that makes unattended work safe holds. NOT a hook.

Usage (from the project root):
  factory-next check                 NEXT GO <Cn> (<n> task(s)) | NEXT WAIT <why>
  factory-next launch [--dry-run]    check, then run /factory:fast for that change
                                     in a worktree of its own
  factory-next launchd [--hour H]    print the LaunchAgent plist for a nightly
                                     run (nothing is installed or loaded)

It goes only when, all together:
  - the autonomy level is merge (the developer typed "auto devam et"; a
    breaker's cap or "auto dur" lowers it, and then this waits);
  - nothing stopped the factory (.factory/STOP);
  - the quota file has a fresh reading and it is under the even-spend line
    (factory-quota check) - no reading is "wait", never "go";
  - no publish is still in flight or held, so one change is never stacked on
    another that has not landed;
  - no run is active in this project;
  - an approved change (tasks in the backlog) is ready to start.

The run happens in a git worktree under .factory/worktrees/, not in the
developer's working tree, so a night run never touches uncommitted work. The
consent file travels with it: factory-autonomy re-checks it against the
transcript it names, which still exists, so the run's level is the one the
developer typed and not a new one.

The command is `claude -p "/factory:fast" --permission-mode auto
--strict-mcp-config`: no --bare, so hooks and the module load and the run
writes its own quota file, which makes it subject to the same breaker.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import argv as runnable, bash, npath, rel  # noqa: E402
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
F = os.path.join(ROOT, ".factory")
CLAUDE = os.environ.get("FACTORY_CLAUDE", "claude")
TERMINAL = ("done", "pr_only", "reverted", "abandoned")


def sh(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd or ROOT, capture_output=True, text=True, errors="replace")
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def jread(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def decide():
    """(go: bool, text, change)"""
    if not os.path.isfile(os.path.join(F, "active")):
        return False, "not a factory project", None
    if os.path.exists(os.path.join(F, "STOP")):
        return False, "STOP is set", None
    env = dict(os.environ, FACTORY_ROOT=ROOT)
    r = subprocess.run([bash(), os.path.join(HOOK_DIR, "factory-autonomy.sh")], cwd=ROOT, env=env,
                       capture_output=True, text=True, errors="replace")
    level = (r.stdout or "").strip().splitlines()[-1:] or ["local"]
    if level[0] != "merge":
        return False, "autonomy level is %s, not merge" % level[0], None
    rc, out = sh([bash(), os.path.join(HOOK_DIR, "factory-quota.sh"), "check"])
    if rc != 0:
        return False, out.splitlines()[-1] if out else "no quota reading", None
    for p in glob.glob(os.path.join(F, "publish", "*.json")):
        st = jread(p, {})
        if st.get("state") not in TERMINAL:
            return False, "publish %s is %s%s" % (st.get("change", os.path.basename(p)), st.get("state"),
                                                  " (held)" if st.get("held") else ""), None
    if glob.glob(os.path.join(F, "inflight", "*")) or glob.glob(os.path.join(ROOT, "tasks", "in-progress", "*.md")):
        return False, "a run is active", None
    rc, out = sh([sys.executable, os.path.join(HOOK_DIR, "factory-plan.py"), "--json"])
    try:
        plan = json.loads(out[out.index("{"):])
    except (ValueError, ImportError):
        return False, "the plan could not be read", None
    tasks = plan.get("tasks") or []
    if not tasks:
        return False, "no approved task is ready", None
    by = {}
    for t in tasks:
        m = re.match(r"(C[0-9]+)-", t.get("id", ""))
        by.setdefault(m.group(1) if m else "C1", []).append(t["id"])
    cid = sorted(by, key=lambda c: int(c[1:]))[0]
    return True, "%s (%d task(s))" % (cid, len(by[cid])), cid


def cmd_check():
    go, text, _ = decide()
    print(("NEXT GO " if go else "NEXT WAIT ") + text)
    return 0 if go else 1


def worktree(cid):
    stamp = time.strftime("%Y%m%d-%H%M", time.gmtime())
    path = os.path.join(F, "worktrees", "%s-%s" % (cid, stamp))
    branch = "factory/next-%s-%s" % (cid, stamp)
    base = (jread(os.path.join(F, "config.json"), {}).get("delivery") or {}).get("base", "main")
    rc, _ = sh(["git", "fetch", "-q", "origin", base])
    start = "origin/" + base if rc == 0 else "HEAD"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rc, out = sh(["git", "worktree", "add", "-q", "-b", branch, path, start])
    if rc != 0:
        return None, out
    # Runtime state a run needs and git does not carry: the consent (which
    # factory-autonomy re-checks against its transcript) and the quota breaker.
    os.makedirs(os.path.join(path, ".factory"), exist_ok=True)
    # Approved tasks and project config may be uncommitted or ignored: they go
    # along as copies, so the worktree plans exactly what the main tree holds.
    tdir = os.path.join(ROOT, "tasks")
    if os.path.isdir(tdir):
        shutil.copytree(tdir, os.path.join(path, "tasks"), dirs_exist_ok=True)
    for name in ("active", "config.json", "changes"):
        src = os.path.join(F, name)
        dst = os.path.join(path, ".factory", name)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        elif os.path.isfile(src) and not os.path.exists(dst):
            shutil.copyfile(src, dst)
    for name in ("autonomy.json", "autonomy-cap", "autonomy-off"):
        src = os.path.join(F, name)
        if os.path.isfile(src):
            with open(src, "rb") as a, open(os.path.join(path, ".factory", name), "wb") as b:
                b.write(a.read())
    return path, branch


def cmd_launch(argv):
    go, text, cid = decide()
    if not go:
        print("NEXT WAIT " + text)
        return 1
    argv_cmd = [CLAUDE, "-p", "/factory:fast", "--permission-mode", "auto", "--strict-mcp-config"]
    if "--dry-run" in argv:
        print("NEXT GO %s\nWOULD RUN %s (in a new worktree under .factory/worktrees/)" % (text, " ".join(argv_cmd)))
        return 0
    path, info = worktree(cid)
    if not path:
        print("NEXT WAIT the worktree could not be made: %s" % info)
        return 1
    logdir = os.path.join(F, "logs")
    os.makedirs(logdir, exist_ok=True)
    log = os.path.join(logdir, "next-%s.log" % time.strftime("%Y%m%d-%H%M", time.gmtime()))
    # Forward slashes: bash compares and strips this root as text.
    env = dict(os.environ, FACTORY_ROOT=npath(path), FACTORY_NEXT="1")
    env.pop("CLAUDE_PROJECT_DIR", None)
    with open(log, "w", encoding="utf-8") as fh:
        r = subprocess.run(runnable(argv_cmd), cwd=path, env=env, stdout=fh, stderr=subprocess.STDOUT)
    print("NEXT RAN %s in %s (exit %d, log %s)" % (text, rel(path, ROOT), r.returncode, rel(log, ROOT)))
    return 0 if r.returncode == 0 else 1


def cmd_launchd(argv):
    hour = 3
    if "--hour" in argv and argv.index("--hour") + 1 < len(argv):
        try:
            hour = max(0, min(23, int(argv[argv.index("--hour") + 1])))
        except ValueError:
            pass
    slug = re.sub(r"[^a-z0-9]+", "-", os.path.basename(ROOT).lower()).strip("-") or "project"
    label = "com.factory.next.%s" % slug
    plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%(label)s</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/env</string><string>python3</string>
    <string>%(script)s</string><string>launch</string>
  </array>
  <key>WorkingDirectory</key><string>%(root)s</string>
  <key>EnvironmentVariables</key><dict><key>FACTORY_ROOT</key><string>%(root)s</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string></dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>%(hour)d</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>%(root)s/.factory/logs/next-launchd.out</string>
  <key>StandardErrorPath</key><string>%(root)s/.factory/logs/next-launchd.err</string>
</dict></plist>
""" % {"label": label, "script": os.path.abspath(__file__), "root": ROOT, "hour": hour}
    print(plist)
    print("<!-- Save as ~/Library/LaunchAgents/%s.plist, then: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/%s.plist\n"
          "     Remove with: launchctl bootout gui/$(id -u)/%s -->" % (label, label, label))
    return 0


def main(argv):
    cmd = argv[0] if argv else "check"
    if cmd == "check":
        return cmd_check()
    if cmd == "launch":
        return cmd_launch(argv[1:])
    if cmd == "launchd":
        return cmd_launchd(argv[1:])
    print("usage: factory-next check | launch [--dry-run] | launchd [--hour H]")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
