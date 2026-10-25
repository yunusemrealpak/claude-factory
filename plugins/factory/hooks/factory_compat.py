"""What differs on Windows, in one place, for the factory's Python scripts.

Repo-relative paths are spelled with "/" everywhere the factory compares them:
git prints them that way, task files list them that way, config.json names
units that way. os.path.normpath would turn them into "lib\\a.dart" on Windows
and every comparison against git's output would quietly miss.

A script with no extension (a #! file) cannot be started by Windows itself;
argv() runs it through bash, as Git Bash would.
"""
import os
import posixpath
import shutil
import sys

WINDOWS = os.name == "nt"
_NATIVE = (".exe", ".com", ".bat", ".cmd")


def npath(p):
    """A repo-relative path, normalised, spelled with '/'."""
    return posixpath.normpath(str(p).replace("\\", "/"))


def rel(path, root):
    """path relative to root, spelled with '/'."""
    return npath(os.path.relpath(path, root))


def _spellings(root):
    """The ways a tool may print this root: C:\\p, C:/p, /c/p (drive in either case)."""
    r = str(root).replace("\\", "/").rstrip("/")
    out = {r}
    if len(r) >= 2 and r[1] == ":":
        drive, rest = r[0], r[2:]
        for d in (drive.lower(), drive.upper()):
            out.add(d + ":" + rest)
            out.add("/" + d.lower() + rest)
    return out


def strip_root(tok, roots):
    """tok relative to the first root it starts with (any spelling), else None."""
    t = str(tok).replace("\\", "/")
    for root in roots:
        for r in _spellings(root):
            if t.startswith(r + "/"):
                return t[len(r) + 1:]
    return None


def bash():
    """The bash to run scripts with. On Windows the Git Bash one, never the WSL
    launcher in System32."""
    if not WINDOWS:
        return "bash"
    given = os.environ.get("CLAUDE_CODE_GIT_BASH_PATH")
    if given and os.path.isfile(given):
        return given
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    for guess in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
        if os.path.isfile(guess):
            return guess
    return "bash"


def argv(cmd):
    """cmd ready for subprocess. On Windows a script with a #! line and no
    native extension runs through bash; everything else is unchanged."""
    if not WINDOWS or not cmd:
        return list(cmd)
    exe = cmd[0]
    if exe == "bash":
        return [bash()] + list(cmd[1:])
    path = exe if os.path.isfile(exe) else None
    if path is None and not os.path.dirname(exe):
        # CreateProcess finds name.exe on PATH but not name.cmd (an npm shim).
        found = shutil.which(exe)
        if found and found.lower().endswith((".cmd", ".bat")):
            return [found] + list(cmd[1:])
    if path and not path.lower().endswith(_NATIVE):
        try:
            with open(path, "rb") as fh:
                if fh.read(2) == b"#!":
                    return [bash(), path] + list(cmd[1:])
        except OSError:
            pass
    return list(cmd)


def python():
    """The interpreter running this script, for a sibling script."""
    return sys.executable or "python3"


def pid_alive(pid):
    """Whether a process with this id is running. os.kill(pid, 0) is that test
    on POSIX; on Windows signal 0 is CTRL_C_EVENT and any other value kills
    the process, so the question goes to the kernel instead."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if not WINDOWS:
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True
        except OSError:
            return False
    import ctypes
    k32 = ctypes.windll.kernel32
    handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        if not k32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == 259  # STILL_ACTIVE
    finally:
        k32.CloseHandle(handle)
