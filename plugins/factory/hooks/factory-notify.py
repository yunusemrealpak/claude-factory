#!/usr/bin/env python3
"""Factory: tell the developer, wherever they are. NOT a hook: factory-ask,
factory-finish, the hard-block breaker, the unpushed breaker, the autonomy
consent and the publisher call it.

Usage (from the project root, or with FACTORY_ROOT set):
  factory-notify "<title>" "<body>" [--tag question|finish|stop|delivery|autonomy] [--bg]

--bg returns at once and leaves the sending to a detached copy of itself:
what hooks and scripts use, so nothing they do waits on a toast or a network.
The test log line below is still written before it returns.

Two channels, both best effort and never fatal:

  - the desktop: Notification Center on macOS, notify-send on Linux, a toast
    on Windows (Windows PowerShell, nothing to install);
  - ntfy, when the project says where: "notify": {"ntfy":
    "https://ntfy.sh/<a topic only you know>"} in .factory/config.json, or
    FACTORY_NTFY_URL in the environment (which wins, and keeps the topic out
    of a committed file). FACTORY_NTFY_TOKEN, when set, is sent as a bearer
    token for a server that wants one. ntfy is the channel that reaches a
    phone while the laptop runs a night build with nobody at it.

FACTORY_NO_NOTIFY=1 or ~/.claude/.factory-no-notify mutes both (the test
suites set the first). FACTORY_NOTIFY_LOG=<file> takes the desktop's place on
every platform: one line "title | body | tag" is appended there instead of a
popup - with " | muted" at the end when muting held the rest back - so a test
can see what would have been shown. ntfy is still sent when one is configured
and nothing mutes it. Each send has a few seconds; the script exits 0 whatever
happened.
"""
import json
import os
import platform
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())

# PowerShell's own AppUserModelID: a toast needs a registered app to show
# under, and this one is on every Windows that has PowerShell.
PS_APP = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"
TOAST = r"""
$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $x.GetElementsByTagName('text')
$t.Item(0).AppendChild($x.CreateTextNode($env:FACTORY_NOTIFY_TITLE)) | Out-Null
$t.Item(1).AppendChild($x.CreateTextNode($env:FACTORY_NOTIFY_BODY)) | Out-Null
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($env:FACTORY_NOTIFY_APP).Show([Windows.UI.Notifications.ToastNotification]::new($x))
"""
URGENT = ("stop", "question")
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW: no console flashing up for the toast


def muted():
    if os.environ.get("FACTORY_NO_NOTIFY") == "1":
        return True
    homes = {os.path.expanduser("~"), os.environ.get("HOME") or ""}
    return any(h and os.path.exists(os.path.join(h, ".claude", ".factory-no-notify")) for h in homes)


def config():
    try:
        with open(os.path.join(ROOT, ".factory", "config.json"), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def windows():
    return platform.system() == "Windows" or os.environ.get("OS") == "Windows_NT"


def record(log, title, body, tag, quiet):
    try:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write("%s | %s | %s%s\n" % (title, " ".join(body.split()), tag, " | muted" if quiet else ""))
    except OSError:
        pass


def desktop(title, body):
    env = dict(os.environ, FACTORY_NOTIFY_TITLE=title, FACTORY_NOTIFY_BODY=body, FACTORY_NOTIFY_APP=PS_APP)
    flags = 0
    if shutil.which("osascript"):
        safe = lambda s: s.replace("\\", "").replace('"', "'")  # noqa: E731
        cmd = ["osascript", "-e", 'display notification "%s" with title "%s" sound name "Glass"' % (safe(body), safe(title))]
    elif windows():
        ps = shutil.which("powershell") or shutil.which("powershell.exe") or shutil.which("pwsh")
        if not ps:
            return False
        cmd, flags = [ps, "-NoProfile", "-NonInteractive", "-Command", TOAST], NO_WINDOW
    elif shutil.which("notify-send"):
        cmd = ["notify-send", title, body]
    else:
        return False
    try:
        subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=15, creationflags=flags)
        return True
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def ntfy(title, body, tag):
    url = (os.environ.get("FACTORY_NTFY_URL") or str((config().get("notify") or {}).get("ntfy") or "")).strip()
    if not url.startswith(("https://", "http://")):
        return False
    # Title and tags as query parameters, not headers: a header has to be
    # Latin-1, and a title names a Turkish task as often as not.
    query = {"title": title, "tags": tag or "factory"}
    if tag in URGENT:
        query["priority"] = "high"
    full = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
    headers = {"Content-Type": "text/plain; charset=utf-8"}
    if os.environ.get("FACTORY_NTFY_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["FACTORY_NTFY_TOKEN"]
    req = urllib.request.Request(full, data=body.encode("utf-8"), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8):
            return True
    except Exception:  # noqa: BLE001 - a notification never fails the caller
        return False


def detach(argv, log):
    """This script again, without --bg, and not waited for: a hook that tells
    the developer something must not sit through a toast or a slow network.
    The test log is already written; the copy gets the null device for one,
    so it sends ntfy and never shows a popup in a test."""
    env = dict(os.environ, FACTORY_ROOT=ROOT)
    if log:
        env["FACTORY_NOTIFY_LOG"] = os.devnull
    kw = dict(cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    cmd = [sys.executable, os.path.abspath(__file__)] + argv
    if not windows():
        subprocess.Popen(cmd, start_new_session=True, **kw)
        return
    # Out of the caller's job when the job allows it, so closing the hook's
    # process tree does not take the toast with it.
    for flags in (NO_WINDOW | 0x00000200 | 0x01000000, NO_WINDOW | 0x00000200):
        try:
            subprocess.Popen(cmd, creationflags=flags, **kw)
            return
        except OSError:
            continue


def main(argv):
    tag, bg = "", "--bg" in argv
    argv = [a for a in argv if a != "--bg"]
    if "--tag" in argv:
        i = argv.index("--tag")
        tag = argv[i + 1] if i + 1 < len(argv) else ""
        argv = argv[:i] + argv[i + 2:]
    if len(argv) < 2:
        print('usage: factory-notify "<title>" "<body>" [--tag <tag>] [--bg]', file=sys.stderr)
        return 2
    title, body = " ".join(argv[0].split())[:120], argv[1].strip()[:600]
    quiet, log = muted(), os.environ.get("FACTORY_NOTIFY_LOG")
    if log:
        record(log, title, body, tag, quiet)
    if quiet:
        return 0
    if bg:
        detach([title, body, "--tag", tag], log)
        return 0
    if not log:
        desktop(title, body)
    ntfy(title, body, tag)
    return 0


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:  # noqa: BLE001 - never fatal, whatever happened
        sys.exit(0)
