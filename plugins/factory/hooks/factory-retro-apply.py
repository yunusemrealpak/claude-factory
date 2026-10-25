#!/usr/bin/env python3
"""Factory: the retrospective's validator, applier and judge. NOT a hook.

Usage (from the project root):
  factory-retro-apply apply <proposals.json> [--date YYYY-MM-DD]
  factory-retro-apply evaluate
  factory-retro-apply ledger
  factory-retro-apply due            (is a retrospective due? exit 0 = yes)

The retro agent proposes; this script is the only thing that writes. A proposal
is a JSON object with a kind and the metric it should move:

  {"id":"P1","kind":"lesson","module":"api","evidence":"C2-03,sig-4f1a...",
   "text":"...","metric":"sig_recurrence","signature":"4f1a..."}
  {"id":"P2","kind":"config","patch":{"gate_isolation":true},"metric":"first_pass_green"}
  {"id":"P3","kind":"claude_md","text":"...","metric":"stage_red_rate","stage":"build"}
  {"id":"P4","kind":"plugin","surface":"agents/builder.md","change":"...","metric":"cost_per_task"}
  {"id":"P5","kind":"rule","name":"pnpm-only","match":"bash","pattern":"(^|[\\\\s;&|])npm\\\\s+install",
   "action":"warn","message":"...","evidence":"C2-03,sig-4f1a...","metric":"sig_recurrence","signature":"4f1a..."}
  {"id":"P6","kind":"lesson_retire","module":"api","text":"<the lesson, as factory-lesson check printed it>"}

What it will apply, and nothing else:
  - a lesson, through factory-lesson (which checks the evidence on disk and
    refuses one that overlaps a lesson already there); with "replaces": "<the
    old lesson's text>" it rewords that lesson instead (factory-lesson update),
    and "category" / "retire_when" go along;
  - a rule, .factory/rules/<name>.rule: a lesson the hooks module enforces on
    builders' calls (match bash|path|content, a regex, action warn|block, a
    message, evidence on disk). At most RULES_PER_RETRO per retrospective and
    MAX_RULES in all; a pattern that matches everything, or the way a builder
    checks and settles, is refused. A rule is taken back by deleting its file;
  - a lesson's retirement, only when `factory-lesson check` says what it names
    is gone. No metric: it is a fact on disk, not a bet;
  - a config patch that does not loosen the gate: gate_isolation false->true,
    isolation_links added, risk_paths only widened, min_tests only raised,
    retry_limit only lowered, fast.risk_review after->before, fast.audit
    false->true. Every other key is refused;
  - at most one CLAUDE.md protocol rule per retrospective, one line, under the
    size guard.
A "plugin" proposal (the harness itself) is never applied: it is written to
.factory/retro/c-class.md for the developer, like a class C change.

Each applied change is one commit of its own file with the trailer
`Factory-Retro: <date>/P<n>` (where the file is tracked) and one line in
.factory/retro/ledger.jsonl, with the metric's baseline and how to undo it.
`evaluate` measures what happened after, once enough tasks have run, and undoes
what did not help.
"""
import calendar
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK_DIR)
from factory_compat import bash, rel  # noqa: E402
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
F = os.path.join(ROOT, ".factory")
RETRO = os.path.join(F, "retro")
LEDGER = os.path.join(RETRO, "ledger.jsonl")
CONFIG = os.path.join(F, "config.json")

METRICS = {  # name -> True when a higher number is the improvement
    "sig_recurrence": False,
    "stage_red_rate": False,
    "first_pass_green": True,
    "no_progress_rate": False,
    "cost_per_task": False,
}
DEFAULT_SAMPLE = 10
DUE_SIGS = 30
DUE_DAYS = 7
CLAUDE_MD_MAX = 200
BAD_RULE = re.compile(
    r"--no-verify|skip(ping)?\s+(the\s+)?(gate|verify|review|tests?)|ignore\s+(the\s+)?(gate|failing|failures)|"
    r"disable\s+(the\s+)?(gate|hook|review)|git\s+push|force[- ]push|gates/|verify\.sh|\.factory/(config|autonomy|STOP)",
    re.I)
MAX_RULE = 240
RULES = os.path.join(F, "rules")
MAX_RULES = 10          # register.js reads no more than this either
RULES_PER_RETRO = 2
RULE_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,40}")
# How a builder checks, settles, blocks and asks, and the files it settles
# with. register.js never applies a rule to them; a pattern that matches one
# is refused here as well, so the mistake is caught where it is made.
WAY_OUT = {
    "bash": ['factory-settle T1 "no_progress: npm test failed"', "factory-block T1 'needs a decision'",
             'factory-ask T1 "which one?"', "factory-check T1", "factory-start T1 builder"],
    "path": ["tasks/in-progress/T1.md", "tasks/backlog/T1.md", "decisions.md"],
    "content": [],
}
# What JavaScript reads otherwise than Python, or not at all: named groups the
# Python way, comments, atomic groups, inline flags, \A \Z, possessive
# quantifiers, POSIX classes ([[:space:]]: write \s). Letter case is ignored
# by both readers anyway.
NOT_PORTABLE = re.compile(r"\(\?(P|#|>|[aiLmsux-]+[:)])|\\[AZz]|[*+?}]\+|\[\[?:[a-z]+:\]")
LESSON_CATEGORIES = ("build", "test", "tooling", "convention", "environment", "dependency")


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def jload(path, default):
    try:
        return json.loads(read(path))
    except ValueError:
        return default


def config():
    c = jload(CONFIG, {})
    return c if isinstance(c, dict) else {}


def sample_size():
    try:
        return max(1, int((config().get("retro") or {}).get("min_sample", DEFAULT_SAMPLE)))
    except (TypeError, ValueError):
        return DEFAULT_SAMPLE


def sh(cmd, **kw):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, errors="replace", **kw)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return 0


# --- the measuring ------------------------------------------------------------

def run_records():
    out = []
    for l in read(os.path.join(F, "metrics.jsonl")).splitlines():
        try:
            r = json.loads(l)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("ts"):
            out.append(r)
    return out


def red_runs():
    """[(epoch, task, signature)] from the failure logs, open and resolved."""
    rows = []
    fdir = os.path.join(F, "failures")
    for d in (fdir, os.path.join(fdir, "resolved")):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not n.endswith(".log"):
                continue
            for l in read(os.path.join(d, n)).splitlines():
                p = l.split()
                if len(p) >= 2:
                    rows.append((epoch(p[0]), n[:-4], p[1]))
    return rows


def measure(metric, since, until, signature=None, stage=None):
    """(value, tasks) for the runs with since < ts <= until; value is None when
    no task ran in the window."""
    recs = [r for r in run_records() if since < r["ts"] <= until]
    tasks = sum(int(r.get("tasks") or 0) for r in recs)
    if not tasks:
        return None, 0
    if metric == "first_pass_green":
        return round(sum(int(r.get("first_try_green") or 0) for r in recs) / tasks, 4), tasks
    if metric == "no_progress_rate":
        return round(sum(int(r.get("stalled") or 0) for r in recs) / tasks, 4), tasks
    if metric == "cost_per_task":
        landed = sum(int(r.get("landed") or 0) for r in recs)
        usd = [r.get("usd_total") for r in recs if r.get("usd_total") is not None]
        return (round(sum(usd) / landed, 4) if landed and usd else None), tasks
    reds = [x for x in red_runs() if since < x[0] <= until]
    if metric == "sig_recurrence":
        return round(sum(1 for x in reds if x[2] == signature) / tasks, 4), tasks
    if metric == "stage_red_rate":
        hit = 0
        for _, _, sig in reds:
            if ("GATE %s: FAIL" % stage) in read(os.path.join(F, "failures", "sig-%s.txt" % sig)):
                hit += 1
        return round(hit / tasks, 4), tasks
    return None, tasks


# --- the ledger ---------------------------------------------------------------

def ledger():
    rows = []
    for l in read(LEDGER).splitlines():
        try:
            rows.append(json.loads(l))
        except ValueError:
            pass
    return rows


def ledger_add(rec):
    os.makedirs(RETRO, exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


def pending_applied():
    rows = ledger()
    decided = {r["id"] for r in rows if r.get("outcome")}
    return [r for r in rows if r.get("status") == "applied" and r["id"] not in decided]


# --- git ------------------------------------------------------------------------

def tracked_and_clean(rel):
    rc, _ = sh(["git", "rev-parse", "--is-inside-work-tree"])
    if rc != 0:
        return False, "not a git work tree"
    rc, _ = sh(["git", "check-ignore", "-q", "--", rel])
    if rc == 0:
        return False, "ignored"
    rc, out = sh(["git", "status", "--porcelain", "--", rel])
    if out.strip() and not out.startswith("??"):
        return None, "%s has uncommitted changes; commit or stash them and apply again (factory-retro-apply)" % rel
    return True, ""


def commit_file(rel, message, trailer):
    rc, _ = sh(["git", "add", "--", rel])
    if rc != 0:
        return None
    rc, out = sh(["git", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message, "-m", trailer, "--", rel])
    if rc != 0:
        return None
    return sh(["git", "rev-parse", "--short", "HEAD"])[1].strip()


# --- the applying ---------------------------------------------------------------

def check_metric(p):
    m = p.get("metric")
    if m not in METRICS:
        return "metric must be one of %s" % ", ".join(sorted(METRICS))
    if m == "sig_recurrence":
        sig = str(p.get("signature") or "")
        if not re.fullmatch(r"[0-9a-f]{6,64}", sig) or not os.path.isfile(os.path.join(F, "failures", "sig-%s.txt" % sig)):
            return "sig_recurrence needs a signature that exists in .factory/failures"
    if m == "stage_red_rate" and not re.fullmatch(r"[a-z][a-z0-9_-]{0,20}", str(p.get("stage") or "")):
        return "stage_red_rate needs a stage name"
    return None


def get_in(d, dotted):
    for k in dotted.split("."):
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def set_in(d, dotted, value):
    ks = dotted.split(".")
    for k in ks[:-1]:
        d = d.setdefault(k, {})
    d[ks[-1]] = value


def del_in(d, dotted):
    ks = dotted.split(".")
    for k in ks[:-1]:
        d = d.get(k) or {}
    d.pop(ks[-1], None)


def judge_config_key(key, old, new):
    """None when the change may be applied, else the reason it may not."""
    if key == "gate_isolation":
        return None if (old in (False, None) and new is True) else "gate_isolation may only be turned on"
    if key == "isolation_links":
        if not isinstance(new, list) or not all(isinstance(x, str) for x in new):
            return "isolation_links must be a list of paths"
        old = old or []
        if any(x not in new for x in old):
            return "isolation_links may only gain entries"
        if any(x.startswith(("/", "~")) or ".." in x.split("/") for x in new):
            return "isolation_links must stay inside the project"
        return None
    if key == "risk_paths":
        if not isinstance(new, list) or not all(isinstance(x, str) for x in new):
            return "risk_paths must be a list of globs"
        if any(x not in new for x in (old or [])):
            return "risk_paths may only be widened, never narrowed"
        return None
    if key == "min_tests":
        ok = isinstance(new, int) and not isinstance(new, bool) and isinstance(old, int) and new >= old
        return None if ok else "min_tests may only be raised"
    if key == "retry_limit":
        ok = isinstance(new, int) and not isinstance(new, bool) and isinstance(old, int) and 1 <= new <= old
        return None if ok else "retry_limit may only be lowered (loosening is refused)"
    if key == "fast.risk_review":
        ok = new == "before" and old in ("after", "before", None)
        return None if ok else "fast.risk_review may only be set to before"
    if key == "fast.audit":
        return None if (new is True and old in (False, True, None)) else "fast.audit may only be turned on"
    return "%s is not a key a retrospective may change" % key


def undo_for_config(cfg_keys):
    return {"kind": "config", "keys": cfg_keys}


LESSON_SH = os.path.join(HOOK_DIR, "factory-lesson.sh")
MODULE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def lesson_lines(module):
    return [l for l in read(os.path.join(F, "lessons", module + ".md")).splitlines() if l.startswith("- ")]


def lesson_text(line):
    return " ".join(line[2:].split(" [evidence: ")[0].split())


def lesson_number(module, text):
    """(n, line) of the lesson of <module> that reads <text>, or (None, None)."""
    want = " ".join(str(text).split())
    for i, l in enumerate(lesson_lines(module), 1):
        if lesson_text(l) == want:
            return i, l
    return None, None


def evidence_on_disk(ev):
    """(the evidence comma-joined, None), or (None, why not): every task id and
    sig-<hash> must exist, as factory-lesson asks of a lesson."""
    toks = [t for t in re.split(r"[,\s]+", str(ev or "")) if t]
    if not toks:
        return None, "a rule needs evidence: at least one task id or sig-<hash>"
    for t in toks:
        if t.startswith("sig-"):
            if not re.fullmatch(r"sig-[0-9a-f]{6,64}", t) or not os.path.isfile(os.path.join(F, "failures", t + ".txt")):
                return None, "evidence %s: no .factory/failures/%s.txt" % (t, t)
        elif not MODULE.fullmatch(t) or not glob.glob(os.path.join(ROOT, "tasks", "*", t + ".md")):
            return None, "evidence %s: no task file tasks/*/%s.md" % (t, t)
    return ", ".join(toks), None


def rule_files():
    try:
        return sorted(n for n in os.listdir(RULES) if re.fullmatch(r"[a-z0-9][a-z0-9-]*\.rule", n))
    except OSError:
        return []


def check_rule(p):
    """None when the rule may be written, else why not."""
    if not RULE_NAME.fullmatch(str(p.get("name") or "")):
        return "a rule's name is lower-case letters, digits and dashes, at most 41"
    match, action = p.get("match"), p.get("action")
    if match not in ("bash", "path", "content"):
        return "match must be bash, path or content"
    if action not in ("warn", "block"):
        return "action must be warn or block"
    pat = p.get("pattern")
    if not isinstance(pat, str) or not pat or len(pat) > 200 or "\n" in pat or "\r" in pat:
        return "the pattern is one line of at most 200 characters"
    if NOT_PORTABLE.search(pat):
        return ("the pattern uses a form JavaScript reads otherwise ((?P...), inline flags, \\A, \\Z, "
                "possessive quantifiers, [[:class:]]); write it plainly, \\s for a space")
    try:
        rx = re.compile(pat, re.I)
    except re.error as e:
        return "the pattern is not a regex: %s" % e
    if rx.search(""):
        return "the pattern matches an empty %s, so it would match every call" % match
    for s in WAY_OUT[match]:
        if rx.search(s):
            return "the pattern matches %r: a rule may never stand in the way of checking or settling" % s
    msg = " ".join(str(p.get("message") or "").split())
    if not msg or len(msg) > MAX_RULE:
        return "the message is one line of at most %d characters" % MAX_RULE
    if BAD_RULE.search(msg):
        return "a rule's message may not tell an agent to bypass the gate"
    return None


def apply_rule(p, date, pid, applied_before, base):
    why = check_rule(p)
    if why:
        return {"status": "rejected", "reason": why}
    ev, why = evidence_on_disk(p.get("evidence"))
    if why:
        return {"status": "rejected", "reason": why}
    name = p["name"]
    path = os.path.join(RULES, name + ".rule")
    if os.path.exists(path):
        return {"status": "rejected", "reason": "a rule named %s is already in force" % name}
    if sum(1 for r in applied_before if r.get("kind") == "rule") >= RULES_PER_RETRO:
        return {"status": "rejected", "reason": "at most %d rules per retrospective" % RULES_PER_RETRO}
    if len(rule_files()) >= MAX_RULES:
        return {"status": "rejected", "reason": "the project holds %d rules, the most there may be; retire one first "
                "(delete its .factory/rules/<name>.rule)" % MAX_RULES}
    body = [
        "# Factory rule, applied by factory-retro-apply (%s/%s). The hooks module applies it to every" % (date, pid),
        "# factory builder's call; delete this file to take it back.",
        "name: %s" % name,
        "match: %s" % p["match"],
        "pattern: %s" % p["pattern"],
        "action: %s" % p["action"],
        "message: %s" % " ".join(str(p["message"]).split()),
        "evidence: %s" % ev,
        "metric: %s" % p.get("metric"),
        "added: %s" % now_iso(),
    ]
    os.makedirs(RULES, exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(body) + "\n")
    os.replace(tmp, path)
    base.update({"status": "applied", "undo": {"kind": "rule", "name": name}, "commit": None})
    return base


def retire_lesson(p):
    """A lesson out, only once factory-lesson check says what it names is gone."""
    module, text = str(p.get("module") or ""), " ".join(str(p.get("text") or "").split())
    if not MODULE.fullmatch(module) or not text:
        return {"status": "rejected", "reason": "a retirement names the module and the lesson's text"}
    _, out = sh([bash(), LESSON_SH, "check", module])
    hit = None
    for l in out.splitlines():
        m = re.match(r"RETIRE (\S+) (\d+) ((path|sha):.*?) is gone: (.*)$", l)
        if m and m.group(1) == module and " ".join(m.group(5).split()) == text:
            hit = (int(m.group(2)), m.group(3))
            break
    if not hit:
        return {"status": "rejected", "reason": "factory-lesson check does not flag that lesson; a lesson is retired "
                "here only once what its retire_when names is gone"}
    n, gone = hit
    lines = lesson_lines(module)
    line = lines[n - 1] if n <= len(lines) else ""
    rc, out = sh([bash(), LESSON_SH, "remove", module, str(n)])
    if rc != 0:
        return {"status": "rejected", "reason": out.strip().splitlines()[-1] if out.strip() else "factory-lesson refused"}
    return {"status": "retired", "reason": "%s is gone" % gone,
            "undo": {"kind": "lesson_retire", "module": module, "line": line}, "commit": None}


def apply_one(p, date, applied_before):
    pid = str(p.get("id") or "")
    if not re.fullmatch(r"P[0-9]{1,3}", pid):
        return {"status": "rejected", "reason": "id must look like P1"}
    kind = p.get("kind")
    if kind == "plugin":
        os.makedirs(RETRO, exist_ok=True)
        with open(os.path.join(RETRO, "c-class.md"), "a", encoding="utf-8") as fh:
            fh.write("- %s/%s %s: %s\n" % (date, pid, p.get("surface", "?"), str(p.get("change", ""))[:400]))
        return {"status": "c_class", "reason": "touches the plugin surface; left for the developer"}
    if kind == "lesson_retire":
        return retire_lesson(p)
    why = check_metric(p)
    if why:
        return {"status": "rejected", "reason": why}
    metric = p["metric"]
    baseline, n = measure(metric, 0, int(time.time()), p.get("signature"), p.get("stage"))
    base = {"metric": metric, "signature": p.get("signature"), "stage": p.get("stage"),
            "baseline": baseline, "baseline_tasks": n, "applied_at": int(time.time())}
    trailer = "Factory-Retro: %s/%s" % (date, pid)

    if kind == "lesson":
        module, text, ev = str(p.get("module") or ""), str(p.get("text") or ""), str(p.get("evidence") or "")
        if BAD_RULE.search(text):
            return {"status": "rejected", "reason": "a lesson may not tell an agent to bypass the gate"}
        extra = []
        if p.get("category"):
            extra += ["--category", str(p["category"])]
        if p.get("retire_when"):
            extra += ["--retire-when", str(p["retire_when"])]
        undo_rec = {"kind": "lesson", "module": module, "text": text}
        if p.get("replaces"):
            if not MODULE.fullmatch(module):
                return {"status": "rejected", "reason": "module must be letters, digits, dot, dash or underscore"}
            n, old_line = lesson_number(module, p["replaces"])
            if not n:
                return {"status": "rejected", "reason": "no lesson of %s.md reads %r" % (module, str(p["replaces"])[:80])}
            cmd = [bash(), LESSON_SH, "update", module, str(n), ev, text] + extra
            undo_rec["old_line"] = old_line
        else:
            cmd = [bash(), LESSON_SH, "add", module, ev, text] + extra
        rc, out = sh(cmd)
        if rc != 0:
            return {"status": "rejected", "reason": out.strip().splitlines()[-1] if out.strip() else "factory-lesson refused"}
        base.update({"status": "applied", "undo": undo_rec, "commit": None})
        return base

    if kind == "rule":
        return apply_rule(p, date, pid, applied_before, base)

    if kind == "config":
        patch = p.get("patch")
        if not isinstance(patch, dict) or not patch:
            return {"status": "rejected", "reason": "a config proposal carries a patch object"}
        cfg = config()
        keys = {}
        flat = {}
        for k, v in patch.items():
            if isinstance(v, dict) and k in ("fast",):
                for k2, v2 in v.items():
                    flat["%s.%s" % (k, k2)] = v2
            else:
                flat[k] = v
        for k, v in flat.items():
            old = get_in(cfg, k)
            why = judge_config_key(k, old, v)
            if why:
                return {"status": "rejected", "reason": why}
            keys[k] = {"before": old, "had": old is not None}
        ok, note = tracked_and_clean(rel(CONFIG, ROOT))
        if ok is None:
            return {"status": "rejected", "reason": note}
        for k, v in flat.items():
            set_in(cfg, k, v)
        tmp = CONFIG + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, CONFIG)
        sha = commit_file(rel(CONFIG, ROOT), "retro: %s" % ", ".join(sorted(flat)), trailer) if ok else None
        base.update({"status": "applied", "undo": undo_for_config(keys), "commit": sha})
        return base

    if kind == "claude_md":
        text = " ".join(str(p.get("text") or "").split())
        if any(r.get("kind") == "claude_md" for r in applied_before):
            return {"status": "rejected", "reason": "one CLAUDE.md rule per retrospective"}
        if not text or len(text) > MAX_RULE:
            return {"status": "rejected", "reason": "the rule is one line of at most %d characters" % MAX_RULE}
        if BAD_RULE.search(text):
            return {"status": "rejected", "reason": "a protocol rule may not loosen the gate or touch protected files"}
        path = os.path.join(ROOT, "CLAUDE.md")
        body = read(path)
        try:
            limit = int((config().get("check") or {}).get("claude_md_max_lines", CLAUDE_MD_MAX))
        except (TypeError, ValueError):
            limit = CLAUDE_MD_MAX
        header = "## Protocol (added by retro)"
        add = ([] if header in body else ["", header, ""]) + ["- " + text]
        if len(body.splitlines()) + len(add) > limit:
            return {"status": "rejected", "reason": "CLAUDE.md would pass its %d-line guard" % limit}
        ok, note = tracked_and_clean("CLAUDE.md")
        if ok is None:
            return {"status": "rejected", "reason": note}
        if "- " + text in body:
            return {"status": "rejected", "reason": "that rule is already there"}
        if header in body:
            head, _, tail = body.partition(header)
            m = re.search(r"\n#{1,2} ", tail)
            cut = m.start() if m else len(tail)
            tail = tail[:cut].rstrip("\n") + "\n- " + text + "\n" + tail[cut:]
            new = head + header + tail
        else:
            new = body.rstrip("\n") + "\n" + "\n".join(add) + "\n"
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
        sha = commit_file("CLAUDE.md", "retro: protocol rule", trailer) if ok else None
        base.update({"status": "applied", "undo": {"kind": "claude_md", "text": text}, "commit": sha})
        return base

    return {"status": "rejected", "reason": "kind must be lesson, lesson_retire, rule, config, claude_md or plugin"}


def undo(rec):
    """Take an applied change back. Targeted, not a blind git revert: it removes
    exactly what was added and leaves later edits of the same file alone."""
    u = rec.get("undo") or {}
    kind = u.get("kind")
    trailer = "Factory-Retro-Revert: %s" % rec["id"]
    if kind == "lesson":
        path = os.path.join(F, "lessons", u["module"] + ".md")
        lines = read(path).splitlines()
        # A reworded lesson gets its old line back; an added one goes.
        mine = "- %s [" % u["text"]
        if u.get("old_line"):
            keep = [u["old_line"] if l.startswith(mine) else l for l in lines]
            if keep == lines:
                return False
        else:
            keep = [l for l in lines if not l.startswith(mine)]
            if len(keep) == len(lines):
                return False
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keep) + "\n")
        return True
    if kind == "rule":
        try:
            os.remove(os.path.join(RULES, u["name"] + ".rule"))
            return True
        except OSError:
            return False
    if kind == "config":
        cfg = config()
        for k, v in (u.get("keys") or {}).items():
            if v.get("had"):
                set_in(cfg, k, v.get("before"))
            else:
                del_in(cfg, k)
        with open(CONFIG, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
            fh.write("\n")
        if rec.get("commit"):
            commit_file(rel(CONFIG, ROOT), "retro: revert %s" % rec["id"], trailer)
        return True
    if kind == "claude_md":
        path = os.path.join(ROOT, "CLAUDE.md")
        lines = read(path).splitlines()
        keep = [l for l in lines if l != "- " + u["text"]]
        if len(keep) == len(lines):
            return False
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keep) + "\n")
        if rec.get("commit"):
            commit_file("CLAUDE.md", "retro: revert %s" % rec["id"], trailer)
        return True
    return False


# --- commands ---------------------------------------------------------------------

def cmd_apply(argv):
    if not argv:
        print("usage: factory-retro-apply apply <proposals.json> [--date YYYY-MM-DD]")
        return 2
    date = time.strftime("%Y-%m-%d", time.gmtime())
    if "--date" in argv and argv.index("--date") + 1 < len(argv):
        date = argv[argv.index("--date") + 1]
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
        print("RETRO REFUSED: --date must be YYYY-MM-DD")
        return 2
    doc = jload(argv[0], None)
    props = doc.get("proposals") if isinstance(doc, dict) else doc
    if not isinstance(props, list):
        print("RETRO REFUSED: %s holds no proposals list" % argv[0])
        return 2
    applied = []
    for p in props:
        if not isinstance(p, dict):
            continue
        r = apply_one(p, date, applied)
        pid = "%s/%s" % (date, p.get("id", "?"))
        rec = dict(r)
        rec.update({"id": pid, "ts": int(time.time()), "kind": p.get("kind"), "metric": p.get("metric")})
        rec.setdefault("applied_at", rec["ts"])
        ledger_add(rec)
        if r["status"] == "applied":
            applied.append(rec)
            print("RETRO APPLIED %s %s (%s%s)" % (pid, p.get("kind"), p.get("metric"),
                  ", commit %s" % r["commit"] if r.get("commit") else ""))
        elif r["status"] == "retired":
            applied.append(rec)
            print("RETRO RETIRED %s lesson of %s: %s" % (pid, p.get("module"), r.get("reason", "")))
        else:
            print("RETRO %s %s: %s" % (r["status"].upper(), pid, r.get("reason", "")))
    os.makedirs(RETRO, exist_ok=True)
    with open(os.path.join(RETRO, "last.json"), "w", encoding="utf-8") as fh:
        json.dump({"ts": int(time.time()), "date": date, "applied": len(applied)}, fh)
    try:
        os.remove(os.path.join(F, "retro-due"))
    except OSError:
        pass
    print("RETRO DONE: %d applied of %d proposed" % (len(applied), len(props)))
    return 0


def cmd_evaluate(_argv):
    need = sample_size()
    now = int(time.time())
    pend = pending_applied()
    if not pend:
        print("RETRO EVALUATE: nothing waiting for a result")
        return 0
    for rec in pend:
        after, n = measure(rec["metric"], rec["applied_at"], now, rec.get("signature"), rec.get("stage"))
        if n < need:
            print("RETRO PENDING %s: %d/%d tasks since it was applied" % (rec["id"], n, need))
            continue
        before = rec.get("baseline")
        if before is None or after is None:
            ledger_add({"id": rec["id"], "outcome": "kept", "reason": "no baseline to compare with",
                        "after": after, "tasks": n, "ts": now})
            print("RETRO KEPT %s: %s could not be compared (no baseline)" % (rec["id"], rec["metric"]))
            continue
        better = after > before if METRICS[rec["metric"]] else after < before
        if better:
            ledger_add({"id": rec["id"], "outcome": "kept", "before": before, "after": after, "tasks": n, "ts": now})
            print("RETRO KEPT %s: %s %s -> %s over %d tasks" % (rec["id"], rec["metric"], before, after, n))
        else:
            ok = undo(rec)
            ledger_add({"id": rec["id"], "outcome": "reverted" if ok else "revert_failed", "before": before,
                        "after": after, "tasks": n, "ts": now})
            print("RETRO %s %s: %s %s -> %s over %d tasks" % ("REVERTED" if ok else "REVERT-FAILED", rec["id"],
                                                               rec["metric"], before, after, n))
    return 0


def cmd_ledger(_argv):
    rows = ledger()
    if not rows:
        print("(no retrospective has applied anything yet)")
        return 0
    for r in rows:
        if r.get("outcome"):
            print("%s  outcome=%s  %s -> %s" % (r["id"], r["outcome"], r.get("before"), r.get("after")))
        else:
            print("%s  %s  %s  %s" % (r["id"], r.get("status"), r.get("kind"), r.get("metric") or ""))
    return 0


def due_state():
    """(due, reason). New signatures since the last retrospective, or a week with
    runs in it; an idle project is never due."""
    last = jload(os.path.join(RETRO, "last.json"), {})
    since = int(last.get("ts") or 0) if isinstance(last, dict) else 0
    sigs = 0
    fdir = os.path.join(F, "failures")
    try:
        for n in os.listdir(fdir):
            if n.startswith("sig-") and n.endswith(".txt") and os.path.getmtime(os.path.join(fdir, n)) > since:
                sigs += 1
    except OSError:
        pass
    if sigs >= DUE_SIGS:
        return True, "%d new failure signatures since the last retrospective" % sigs
    recs = [r for r in run_records() if r["ts"] > since]
    if recs:
        ref = since or min(r["ts"] for r in recs)
        if time.time() - ref >= DUE_DAYS * 86400:
            return True, "%d days since the last retrospective, with %d run(s) since" % (DUE_DAYS, len(recs))
    return False, ""


def cmd_due(_argv):
    due, why = due_state()
    if due:
        os.makedirs(F, exist_ok=True)
        with open(os.path.join(F, "retro-due"), "w", encoding="utf-8") as fh:
            fh.write("%s\n" % why)
        print("RETRO DUE: %s" % why)
        return 0
    print("RETRO NOT DUE")
    return 1


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "apply":
        return cmd_apply(argv[1:])
    if cmd == "evaluate":
        return cmd_evaluate(argv[1:])
    if cmd == "ledger":
        return cmd_ledger(argv[1:])
    if cmd == "due":
        return cmd_due(argv[1:])
    print("usage: factory-retro-apply apply <file> | evaluate | ledger | due")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
