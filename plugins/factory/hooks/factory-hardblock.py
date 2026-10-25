#!/usr/bin/env python3
"""Factory: the hard-block judge, shell side. `factory-hardblock.sh check` runs
it; register.js holds the same algorithm in JavaScript, and both are held to one
list of cases (tests/hardblock-cases.txt).

Usage: factory-hardblock.py <rules file> <kind> < the root on one line, then the text
  kind: bash | powershell (the command) or path (one file path)
  HB_LIFTED: the rule names the project's allowed groups lift, one per line.

Prints the rule's name on a hit. Exit 0 clean; 3 a hard hit (refuse the call and
halt the run); 5 a soft hit (refuse this call only: a guess, not a ban broken);
4 the rules could not be read. Anything else is a failure, and the caller
refuses the call (fail closed).
"""
import re
import sys

HARD, SOFT = 3, 5

# What writes, moves or removes a file. The short PowerShell and cmd aliases
# count only where one of those shells runs: in bash they are words of prose
# ("copy the key into .env").
WRITE_SH = ("tee|cp|mv|install|ln|rsync|truncate|touch|chmod|chown|dd|set-content|add-content|out-file|new-item|"
            r"copy-item|move-item|rename-item|clear-content|(sed|perl)\s+([^;&|]*\s)?-[A-Za-z]*i")
WRITE_PS = "copy|move|ren|rni|cpi|mi|ni|sc|ac"
DELETE_SH = "rm|shred|unlink|remove-item|rmdir"
DELETE_PS = "ri|del|erase|rd"
WINSHELL = re.compile(r"(^|[;&|(`\"'\s/])(pwsh|powershell|cmd)(\.exe)?([\s;&|)\"']|$)", re.I)
# A program that runs code given on its command line or in a heredoc can write
# any file without a shell verb. Such a command that names a protected path and
# calls something that writes is refused - softly: it is a guess, so only the
# call is refused and the run goes on.
INTERP = re.compile(r"(^|[;&|(`\"'\s/])(python[0-9.]*|py|node|nodejs|deno|bun|perl|ruby|php|pwsh|powershell|"
                    r"osascript|cmd)(\.exe)?([\s;&|)\"']|$)", re.I)
WRITEISH = re.compile(r"write|append|open\s*\([^)]*[\"'][rwab]*[wax+]|open\s*\([^)]*[\"'][+]?>|rename|unlink|remove|"
                      r"rmtree|shutil|fileutils|copy|move|mkdir|symlink|truncate|chmod|touch|put_contents|"
                      r"createwritestream|rmsync|delete|set-content|add-content|out-file|new-item|"
                      r"(^|[^A-Za-z0-9_])(del|erase|rd|ren|mklink)([^A-Za-z0-9_]|$)", re.I)
TERM = r"([\s;&|)\"'>]|$)"

# Commands that only read or print: their quoted free text is data, not a
# command, when nothing in the line runs code (factory-block T1 'needs the key
# copied into .env', grep -rn "git push" scripts).
DATA_CMD = re.compile(r"^(([^\s;&|<>()]*/)?factory-[A-Za-z0-9_-]+(\.sh|\.py)?|echo|printf|grep|egrep|fgrep|rg|ag|ack|"
                      r"head|tail|wc|cut|cat|sort|true|false|:|test|\[)$", re.I)
HEREDOC_DATA = ("cat", "tee")

# Every way a command names the project root without spelling it.
ROOT_VARS = re.compile(r"(\$\{PWD\}|\$PWD|\$\(pwd\)|`pwd`|~\+|\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR|"
                       r"\$\{env:CLAUDE_PROJECT_DIR\}|\$env:CLAUDE_PROJECT_DIR|\$\(get-location\)|\(get-location\))/", re.I)
# A backslash before a quote, $ or ` escapes it; it is never a folder separator.
ESCAPED = re.compile(r"\\(?=[\"'$`])")
NOT_SEG = "/\\s;&|\"'<>=(),`"
DOTDOT = re.compile("(^|[" + NOT_SEG + "])(?!\\.\\.?/)[^" + NOT_SEG + "]+/\\.\\./")
LITERAL_SEG = re.compile(r"^([A-Za-z0-9_-]|\\\.)+$")


def posix(x):
    """hard-blocks.txt writes [:space:] and [:alnum:]; Python and JavaScript
    know neither."""
    return x.replace("[:space:]", r"\s").replace("[:alnum:]", "A-Za-z0-9")


def rx(x):
    return re.compile(posix(x), re.I)


class PathRule:
    def __init__(self, name, anchor, x, create_only):
        self.name, self.anchor, self.create_only = name, anchor, create_only
        self.x = x
        X = posix(x)
        root = anchor == "root"
        up = r"(\./|(\.\./)+)?"
        self.lead = up if root else r"([^\s;&|\"']*/)?"
        self.pre = r"[\s\"'=<>]" if root else r"[\s/\"'=<>]"
        self.vlead = up if root else ""
        self.X = X
        self.file = re.compile((r"^(\./)?(" if root else r"(^|/)(") + X + ")$", re.I)
        self.redirect = re.compile(r">>?[|]?\s*[\"']?" + self.lead + "(" + X + ")" + TERM, re.I)
        self.mention = re.compile(
            (r"(^|[^A-Za-z0-9_./-])" + up + "(" + X + r")([^A-Za-z0-9_./-]|$)") if root else
            (r"(^|[^A-Za-z0-9_.-])([^\s;&|\"'()]*/)?(" + X + r")([^A-Za-z0-9_.-]|$)"), re.I)
        self._verb = {}

    def verb(self, verbs):
        if verbs not in self._verb:
            self._verb[verbs] = re.compile(r"(^|[^A-Za-z0-9_.-])(" + verbs + r")\s+([^;&|]*" + self.pre + ")?" +
                                           self.vlead + "(" + self.X + ")" + TERM, re.I)
        return self._verb[verbs]


class DirRule(PathRule):
    """A directory that holds protected files: writing into it, moving it or
    removing it reaches them without naming one."""

    def __init__(self, anchor, x, full):
        PathRule.__init__(self, "protected-dir", anchor, x, not full)
        root = anchor == "root"
        up = r"(\./|(\.\./)+)?"
        self.mention = re.compile(
            (r"(^|[^A-Za-z0-9_./-])" + up + "(" + self.X + r")/?([^A-Za-z0-9_./-]|$)") if root else
            (r"(^|[^A-Za-z0-9_.-])([^\s;&|\"'()]*/)?(" + self.X + r")/?([^A-Za-z0-9_.-]|$)"), re.I)

    def verb(self, verbs):
        if verbs not in self._verb:
            self._verb[verbs] = re.compile(r"(^|[^A-Za-z0-9_.-])(" + verbs + r")\s+([^;&|]*" + self.pre + ")?" +
                                           self.vlead + "(" + self.X + r")(/(\.|\*)?)?" + TERM, re.I)
        return self._verb[verbs]


def load(path):
    bash, paths = [], []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for line in text.splitlines():
        f = line.split(" ## ")
        if f[0] == "bash" and len(f) == 3:
            bash.append((f[1], rx(f[2])))
        if f[0] == "path" and len(f) in (4, 5):
            paths.append(PathRule(f[1], f[2], f[3], len(f) == 5 and f[4] == "create-only"))
    if not bash or not paths:
        raise ValueError("hard-blocks.txt holds no rules")
    return bash, paths


def dirs_of(paths):
    """The directories named by the literal start of the path rules:
    \\.factory/verified/.* gives .factory and .factory/verified. A directory
    only create-only rules name is protected against writes, not removal."""
    out = {}
    for p in paths:
        segs = p.x.split("/")
        for k in range(1, len(segs)):
            if not all(LITERAL_SEG.match(s) for s in segs[:k]):
                break
            key = (p.anchor, "/".join(segs[:k]))
            out[key] = out.get(key, False) or not p.create_only
    return [DirRule(a, d, full) for (a, d), full in out.items()]


# --- one file, one spelling ---------------------------------------------------

def spellings(root):
    """The ways Windows and its shells write one root: C:\\p, C:/p, /c/p,
    /cygdrive/c/p."""
    r = str(root or "").replace("\\", "/").rstrip("/")
    if not r:
        return []
    m = re.match(r"^([A-Za-z]):(/.*)?$", r) or re.match(r"^/cygdrive/([A-Za-z])(/.*)?$", r) or \
        re.match(r"^/([A-Za-z])(/.*)?$", r)
    if not m:
        return [r]
    rest = m.group(2) or ""
    return [r, m.group(1) + ":" + rest, "/" + m.group(1) + rest, "/cygdrive/" + m.group(1) + rest]


def strip_all(t, prefix):
    lp = prefix.lower()
    out, low = [], t.lower()
    i = low.find(lp)
    while i >= 0:
        out.append(t[:i])
        t, low = t[i + len(prefix):], low[i + len(prefix):]
        i = low.find(lp)
    return "".join(out) + t


def collapse(t):
    t = re.sub(r"//+", "/", t)
    while "/./" in t:
        t = t.replace("/./", "/")
    while True:
        t2 = DOTDOT.sub(r"\1", t)
        if t2 == t:
            return t
        t = t2


def normalise(text, root):
    """\\" is ", \\ reads as / (Windows takes either), $PWD and its kin are the root,
    dir/../ is nothing, and the root is removed in every spelling - so no
    spelling of a protected path stays outside a root-relative rule."""
    t = ROOT_VARS.sub("", ESCAPED.sub("", text).replace("\\", "/"))
    t = collapse(t)
    for r in spellings(root):
        t = strip_all(t, r + "/")
    return collapse(t)


# --- what in a bash command is data ---------------------------------------------

def lex(t):
    """Words, commands, quoted spans, heredoc bodies and comments of a bash
    command, or None when its quoting does not close (bash would not run it)."""
    n = len(t)
    words, spans, heredocs, comments = [], [], [], []
    cmds, pipes = [[]], [0]
    flags = {"active": False, "complex": False}
    st = {"cur": None, "target": False, "pid": 0}
    pending = []

    def start(at):
        if st["cur"] is None:
            st["cur"] = [at, at, "", st["target"]]
            st["target"] = False

    def end(at):
        if st["cur"] is not None:
            st["cur"][1] = at
            words.append(st["cur"])
            cmds[-1].append(len(words) - 1)
            st["cur"] = None

    def sep(kind):
        if kind == "list":
            st["pid"] += 1
        cmds.append([])
        pipes.append(st["pid"])

    i = 0
    while i < n:
        c = t[i]
        if c == "\\":
            start(i)
            st["cur"][2] += t[i + 1:i + 2]
            i += 2
            continue
        if c == "'":
            start(i)
            j = t.find("'", i + 1)
            if j < 0:
                return None
            spans.append((i, j + 1, "sq", t[i + 1:j], len(words)))
            st["cur"][2] += t[i + 1:j]
            i = j + 1
            continue
        if c == "$" and t[i + 1:i + 2] == "'":
            start(i)
            j = i + 2
            while j < n and t[j] != "'":
                j += 2 if t[j] == "\\" else 1
            if j >= n:
                return None
            spans.append((i, j + 1, "ansi", t[i + 2:j], len(words)))
            st["cur"][2] += t[i + 2:j]
            i = j + 1
            continue
        if c == '"':
            start(i)
            j = i + 1
            while j < n and t[j] != '"':
                if t[j] == "\\":
                    j += 2
                    continue
                if t[j] == "`" or t.startswith("$(", j):
                    flags["active"] = True
                j += 1
            if j >= n:
                return None
            spans.append((i, j + 1, "dq", t[i + 1:j], len(words)))
            st["cur"][2] += re.sub(r"\\([\"\\$`])", r"\1", t[i + 1:j])
            i = j + 1
            continue
        if c == "`" or t.startswith("$(", i):
            flags["active"] = True
            start(i)
            st["cur"][2] += c
            i += 1
            continue
        if c in " \t\r":
            end(i)
            i += 1
            continue
        if c == "#" and st["cur"] is None:
            j = t.find("\n", i)
            j = n if j < 0 else j
            comments.append((i, j))
            i = j
            continue
        if c == "\n":
            end(i)
            i += 1
            for h in pending:
                h["s"] = i
                while True:
                    e = t.find("\n", i)
                    le = n if e < 0 else e
                    line = t[i:le]
                    if (line.lstrip("\t") if h["strip"] else line) == h["delim"]:
                        h["e"] = i
                        i = min(le + 1, n)
                        break
                    if e < 0:
                        h["e"] = n
                        i = n
                        break
                    i = e + 1
                if not h["quoted"] and re.search(r"\$\(|`", t[h["s"]:h["e"]]):
                    flags["active"] = True
                heredocs.append(h)
            pending = []
            sep("list")
            continue
        if c in ";&|":
            end(i)
            two = t[i:i + 2]
            if two in ("&&", "||", ";;"):
                i += 2
                sep("list")
                continue
            if two == "|&":
                i += 2
                sep("pipe")
                continue
            if two == "&>":
                i += 3 if t[i + 2:i + 3] == ">" else 2
                st["target"] = True
                continue
            i += 1
            sep("pipe" if c == "|" else "list")
            continue
        if c in "()":
            end(i)
            flags["complex"] = True
            i += 1
            sep("list")
            continue
        if c in "<>":
            cur = st["cur"]
            if cur is not None and re.fullmatch(r"[0-9]+", t[cur[0]:i]):
                st["cur"] = None
            else:
                end(i)
            if t.startswith("<<", i) and not t.startswith("<<<", i):
                j = i + 2
                strip = t[j:j + 1] == "-"
                j += 1 if strip else 0
                while j < n and t[j] in " \t":
                    j += 1
                k, delim, quoted = j, "", False
                while k < n and t[k] not in " \t\n;&|<>()":
                    if t[k] in "'\"":
                        e = t.find(t[k], k + 1)
                        if e < 0:
                            return None
                        delim += t[k + 1:e]
                        quoted = True
                        k = e + 1
                    elif t[k] == "\\":
                        delim += t[k + 1:k + 2]
                        quoted = True
                        k += 2
                    else:
                        delim += t[k]
                        k += 1
                pending.append({"cmd": len(cmds) - 1, "delim": delim, "quoted": quoted, "strip": strip, "s": n, "e": n})
                i = k
                continue
            if t.startswith("<(", i) or t.startswith(">(", i):
                flags["active"] = flags["complex"] = True
                i += 1
                continue
            j = i + 1
            while j < n and t[j] in "<>&|":
                j += 1
            i = j
            if t[j - 1] == "&":
                m = re.match(r"[0-9]+|-", t[j:])
                if m:
                    i = j + len(m.group())
                    continue
            st["target"] = True
            continue
        start(i)
        st["cur"][2] += c
        i += 1
    end(n)
    for h in pending:
        heredocs.append(h)
    return {"words": words, "spans": spans, "heredocs": heredocs, "comments": comments,
            "cmds": cmds, "pipes": pipes, "active": flags["active"], "complex": flags["complex"]}


def names_of(lx, ws):
    return [lx["words"][w][2] for w in ws if not lx["words"][w][3]]


def is_data(names):
    if not names:
        return True
    first = names[0].lower()
    if DATA_CMD.match(names[0]):
        if first == "sort" and any(re.match(r"(-[A-Za-z]*o|--output)", x) for x in names[1:]):
            return False
        return True
    if first == "git" and len(names) > 1 and names[1].lower() in ("grep", "log"):
        return not any(x.startswith("-O") or x.lower().startswith("--open-files") for x in names[2:])
    return False


def apply_edits(t, edits):
    out, at = [], 0
    for s, e, rep in sorted(edits):
        if s < at:
            continue
        out.append(t[at:s])
        out.append(rep)
        at = e
    out.append(t[at:])
    return "".join(out)


def variants(t):
    """The command as it is, with what is only data taken out, and the same
    with the quotes of single words dropped (g''it "push" is git push). A rule
    that matches either is hit."""
    lx = lex(t)
    if lx is None:
        return [t]
    edits = []
    if not lx["active"]:
        edits += [(s, e, "") for s, e in lx["comments"]]
    kept_bodies = 0
    for h in lx["heredocs"]:
        ci = h["cmd"]
        alone = lx["pipes"].count(lx["pipes"][ci]) == 1
        names = names_of(lx, lx["cmds"][ci])
        if not lx["active"] and alone and names and names[0].lower() in HEREDOC_DATA:
            edits.append((h["s"], h["e"], ""))
        else:
            kept_bodies += 1
    if not lx["active"] and not lx["complex"] and not kept_bodies:
        allnames = [x for ws in lx["cmds"] for x in names_of(lx, ws)]
        if all(is_data(names_of(lx, ws)) for ws in lx["cmds"]) and \
                not any(x.lower().startswith(("--pre", "--output")) for x in allnames):
            for s, e, kind, inner, wi in lx["spans"]:
                if re.search(r"\s", inner) and not lx["words"][wi][3]:
                    edits.append((s, e, "''"))
    a = apply_edits(t, edits)
    taken = [(s, e) for s, e, _ in edits]
    deq = list(edits)
    for s, e, kind, inner, wi in lx["spans"]:
        if kind != "ansi" and not re.search(r"\s", inner) and not any(s < te and ts < e for ts, te in taken):
            deq.append((s, e, inner))
    b = apply_edits(t, deq)
    return [a] if b == a else [a, b]


# --- the judge -------------------------------------------------------------------

def judge(kind, text, root, bash, paths, lifted):
    bash = [(n, r) for n, r in bash if n not in lifted]
    paths = [p for p in paths if p.name not in lifted]
    if kind in ("bash", "powershell"):
        t = text.replace("\\\n", "")
        vs = variants(t) if kind == "bash" else [t]
        vs = [normalise(v, root).replace("\n", ";") for v in vs]
        winsh = kind == "powershell" or any(WINSHELL.search(v) for v in vs)
        wv = WRITE_SH + ("|" + WRITE_PS if winsh else "")
        dv = DELETE_SH + ("|" + DELETE_PS if winsh else "")
        for name, r in bash:
            if any(r.search(v) for v in vs):
                return name, HARD
        dirs = dirs_of(paths)
        for p in paths + dirs:
            verb = p.verb(wv if p.create_only else wv + "|" + dv)
            if any(p.redirect.search(v) or verb.search(v) for v in vs):
                return p.name, HARD
        inline = (kind == "powershell" or any(INTERP.search(v) for v in vs)) and any(WRITEISH.search(v) for v in vs)
        if inline:
            for p in paths + dirs:
                if any(p.mention.search(v) for v in vs):
                    return p.name, SOFT
        return None
    if kind == "path":
        f = normalise(text, root)
        for p in paths:
            if p.file.search(f):
                return p.name, HARD
        return None
    raise ValueError("unknown kind: " + kind)


def main(argv):
    import os
    if len(argv) != 3:
        sys.stderr.write("usage: factory-hardblock.py <rules> <kind> < root line, then the text\n")
        return 2
    try:
        bash, paths = load(argv[1])
    except (OSError, ValueError) as e:
        sys.stderr.write("hard-blocks.txt unreadable: %s\n" % e)
        return 4
    root, _, text = sys.stdin.buffer.read().decode("utf-8", "replace").partition("\n")
    kind = argv[2]
    if kind == "path":
        text = text.rstrip("\r\n")
    lifted = {x.strip() for x in os.environ.get("HB_LIFTED", "").splitlines() if x.strip()}
    hit = judge(kind, text, root.rstrip("\r"), bash, paths, lifted)
    if not hit:
        return 0
    sys.stdout.buffer.write((hit[0] + "\n").encode("utf-8"))
    return hit[1]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
