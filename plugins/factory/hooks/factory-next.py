#!/usr/bin/env python3
"""Factory: the outer loop. Starts the next approved change on its own - only
when everything that makes unattended work safe holds. NOT a hook.

Usage (from the project root):
  factory-next check                 NEXT GO <Cn> (<n> task(s)) | NEXT WAIT <why>
  factory-next launch [--dry-run]    check, then run /factory:run <change> in a
                                     worktree of its own
  factory-next launchd [--hour H]    print the LaunchAgent plist for a nightly
                                     run (nothing is installed or loaded)
  factory-next schtasks [--hour H] [--timeout-min M]
                                     Windows: write .factory/schedule/next.ps1
                                     and print the Task Scheduler line that runs
                                     it (nothing is registered)

It goes only when, all together:
  - the autonomy level is merge (the developer typed "auto devam et"; a
    breaker's cap or "auto dur" lowers it, and then this waits);
  - nothing stopped the factory (.factory/STOP);
  - the quota file has a fresh reading and it is under the even-spend line
    (factory-quota check) - no reading is "wait", never "go";
  - no publish is still in flight or held, so one change is never stacked on
    another that has not landed;
  - no run is active in this project (.factory/run.lock, fresh and not
    marked halted);
  - an approved change (tasks in the backlog) is ready to start.

The run happens in a git worktree under .factory/worktrees/, not in the
developer's working tree, so a night run never touches uncommitted work. The
consent file travels with it: factory-autonomy re-checks it against the
transcript it names, which still exists, so the run's level is the one the
developer typed and not a new one.

The command is `claude -p "/factory:run <Cn>" --permission-mode auto
--permission-prompts none --allowedTools "Workflow(factory:loop)"
--strict-mcp-config`: the change it picked is the change it builds (on its own
branch when delivery.branch is per-change); nobody is there to answer a
permission prompt, so anything that would ask is refused and the agent is told
so, instead of the run waiting all night on a prompt nobody sees (the rules a
run needs are written by factory-allow); the loop workflow is allowed up front;
and there is no --bare, so hooks and the module load and the run writes its own
quota file, which makes it subject to the same breaker.

On Windows the scheduler is Task Scheduler, through a PowerShell wrapper
(`schtasks`): the desktop app's scheduled tasks are not used - they have been
reported to hang mid tool call and to leave claude.exe processes behind, while
`claude -p` started from Task Scheduler exits when its work is done. The
wrapper honours .factory/STOP, takes a lock so two starts never overlap, stops
a run that outlives its wall-clock timeout together with every process it
started, and logs to .factory/logs/.
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


def native(p):
    """A path from a POSIX shell, as this Python opens it. Git Bash hands a
    native program /c/x or /tmp/x as it is when it skips its conversion (a
    quote in the value is enough), and on Windows abspath reads /tmp/x as
    C:\\tmp\\x. Elsewhere, and for a path that is already native, a no-op."""
    if os.name != "nt" or not p or not p.startswith("/") or p.startswith("//"):
        return p
    m = re.match(r"^/([a-zA-Z])(/.*)?$", p)
    if m:
        return m.group(1).upper() + ":" + (m.group(2) or "/")
    try:
        # On stdin: an MSYS program parses its command line like a shell and
        # would take an apostrophe in the path for a quote.
        r = subprocess.run(["cygpath", "-w", "-f", "-"], input=p + "\n", capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return p


ROOT = os.path.abspath(native(os.environ.get("FACTORY_ROOT") or "") or os.getcwd())
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


def run_active():
    """A run holds .factory/run.lock from its preflight to its finish, and its
    checks keep the file fresh. One marked halted, or untouched for two hours,
    is not running: the next run takes over its base."""
    lock = os.path.join(F, "run.lock")
    try:
        age = time.time() - os.path.getmtime(lock)
    except OSError:
        return False
    return age < 2 * 3600 and jread(lock, {}).get("state") != "halted"


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
    if run_active():
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
    # The lessons (gitignored, approved on this machine) and the criteria (in
    # case they are not committed yet) go too: a builder in the worktree reads
    # them at factory-start like one in the main tree.
    for name in ("active", "config.json", "changes", "lessons", "criteria"):
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
    argv_cmd = [CLAUDE, "-p", "/factory:run %s" % cid, "--permission-mode", "auto", "--permission-prompts", "none",
                "--allowedTools", "Workflow(factory:loop)", "--strict-mcp-config"]
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
    env = dict(os.environ, FACTORY_ROOT=npath(path), FACTORY_NEXT="1", FACTORY_HEADLESS="1")
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


def opt_int(argv, name, default, low, high):
    if name in argv and argv.index(name) + 1 < len(argv):
        try:
            return max(low, min(high, int(argv[argv.index(name) + 1])))
        except ValueError:
            pass
    return default


def win(path):
    """A path as Windows writes it: Task Scheduler and PowerShell read these."""
    return os.path.abspath(native(path)).replace("/", "\\")


def find_claude():
    """The absolute path of the claude executable, or None. A scheduled task
    starts with a bare PATH, so a name is not enough."""
    named = native(os.environ.get("FACTORY_CLAUDE") or "claude")
    if os.path.isabs(named):
        return named if os.path.isfile(named) else None
    return shutil.which(named)


def cmd_schtasks(argv):
    hour = opt_int(argv, "--hour", 3, 0, 23)
    timeout = opt_int(argv, "--timeout-min", 240, 10, 24 * 60)
    claude = find_claude()
    if not claude:
        print("SCHTASKS REFUSED: no claude executable found (PATH or FACTORY_CLAUDE) - a scheduled task needs its "
              "absolute path. Install Claude Code, or set FACTORY_CLAUDE to the full path of claude.exe.")
        return 1
    tpl_path = os.path.join(HOOK_DIR, "factory-next-task.ps1")
    try:
        with open(tpl_path, encoding="utf-8") as fh:
            tpl = fh.read()
    except OSError:
        print("SCHTASKS REFUSED: the wrapper template %s is missing" % tpl_path)
        return 1
    ps_quote = lambda s: s.replace("'", "''")  # noqa: E731 - inside a single-quoted PowerShell string
    script = (tpl.replace("__ROOT__", ps_quote(win(ROOT)))
                 .replace("__PYTHON__", ps_quote(win(sys.executable)))
                 .replace("__SCRIPT__", ps_quote(win(os.path.abspath(__file__))))
                 .replace("__CLAUDE__", ps_quote(win(claude)))
                 .replace("__TIMEOUT__", str(timeout)))
    left = sorted(set(re.findall(r"__[A-Z]+__", script)))
    if left:
        print("SCHTASKS REFUSED: the wrapper template still has %s after filling it" % ", ".join(left))
        return 1
    out_dir = os.path.join(F, "schedule")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "next.ps1")
    # PowerShell 5.1 reads a file without a BOM in the ANSI code page: the BOM
    # keeps a non-ASCII path intact.
    with open(out, "w", encoding="utf-8-sig", newline="\r\n") as fh:
        fh.write(script)
    slug = re.sub(r"[^a-z0-9]+", "-", os.path.basename(ROOT).lower()).strip("-") or "project"
    name = "Factory\\next-%s" % slug
    print("SCHTASKS WROTE %s (wall-clock timeout %d min, claude at %s)" % (rel(out, ROOT), timeout, win(claude)))
    print("Register it (as yourself, once):")
    print('  schtasks /Create /TN "%s" /SC DAILY /ST %02d:00 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass '
          '-File \\"%s\\"" /F' % (name, hour, win(out)))
    print("Remove it with:")
    print('  schtasks /Delete /TN "%s" /F' % name)
    print("Each start logs to .factory/logs/next-schtasks-<time>.log; .factory/STOP keeps it from starting a run.")
    return 0


def main(argv):
    cmd = argv[0] if argv else "check"
    if cmd == "check":
        return cmd_check()
    if cmd == "launch":
        return cmd_launch(argv[1:])
    if cmd == "launchd":
        return cmd_launchd(argv[1:])
    if cmd == "schtasks":
        return cmd_schtasks(argv[1:])
    print("usage: factory-next check | launch [--dry-run] | launchd [--hour H] | schtasks [--hour H] [--timeout-min M]")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
