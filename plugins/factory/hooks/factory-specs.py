#!/usr/bin/env python3
"""Factory: the living spec ledger (opt-in: "specs": {"ledger": true}). NOT a
hook: factory-change runs it - validate on demand, merge when a change
closes, drift on demand.

Usage (from the project root):
  factory-change validate <Cn>     does the change carry a delta (or say it needs none)?
  factory-change drift             which ledger requirements does no test name?
  factory-specs.py seed <Cn>       what factory-change open runs: a first delta.md
  factory-specs.py merge <Cn>      what factory-change sync runs when <Cn> closes

A change says what it does to the project's requirements, OpenSpec's way, in
.factory/changes/<Cn>-<slug>/delta.md:

  ## ADDED
  - FR-001: An accountant can download the month's invoices as one CSV file.
  ## MODIFIED
  - C1-FR-004: Amounts are shown in the invoice's own currency.
  ## REMOVED
  - C1-FR-007

When the change is opened, delta.md is seeded from the change's requirements
(.factory/changes/<Cn>.requirements.md): every FR line under ADDED. Moving the
ones that change an earlier requirement to MODIFIED, and listing what the
change takes out, is the planner's job before approval.

The change's own requirements are numbered from FR-001 in every change, so in
the ledger an ADDED requirement is filed under its change: FR-001 of C2 is
C2-FR-001. MODIFIED and REMOVED name a ledger id - one an earlier change
filed. A change with nothing to add to the ledger (a chore, a rename) says so
with `skip_specs: true` in its goal.md frontmatter, or as the only line of its
delta.md. A change with neither is refused: nobody decided it needs no spec.

When the change closes - after its acceptance, if it has one - the delta is
merged into the ledger (specs.file, specs/requirements.md by default): ADDED
appended, MODIFIED replaced by id, REMOVED taken out. One step that is either
whole or not there: the new ledger is written beside the old and put in place
in one rename, then checked; on any failure the old one is put back, byte for
byte. The ledger is left as a
working-tree change for the developer to read and commit - specs/ is the
factory's own path, so it never stops a run or a delivery. A change is merged
once (.factory/changes/<dir>/specs-merged); a merge that failed leaves
specs-pending there, and every later sync tries again.

Drift: every ledger id is looked for in the test files (check.test_files, or
factory-check's own list of test-file names) as C2-FR-001, C2_FR_001 or
C2FR001, in any case. An id no test names is listed - a report, never red.

Exit: validate 0 ok / skipped / ledger off, 1 refused; merge 0 merged /
nothing to do, 1 failed; seed and drift always 0; 2 usage.
"""
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = os.path.abspath(os.environ.get("FACTORY_ROOT") or os.getcwd())
F = os.path.join(ROOT, ".factory")
CH = os.path.join(F, "changes")
SECTIONS = ("ADDED", "MODIFIED", "REMOVED")
LEDGER_ID = re.compile(r"^(C[0-9]+)-FR-([0-9]+)$")
# factory-check.py's TEST_FILES: the same files are tests to the census and here.
DEFAULT_TESTS = (r"(Tests?\.cs|_test\.go|(^|/)test_[^/]*\.py|_test\.py|_test\.dart|\.test\.[jt]sx?|\.spec\.[jt]sx?|"
                 r"_spec\.rb|Tests?\.java|Tests?\.kt|_test\.rs|Tests?\.swift|Test\.php)$")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def config():
    try:
        return json.loads(read(os.path.join(F, "config.json")) or "{}")
    except ValueError:
        return {}


def specs_cfg():
    s = config().get("specs") or {}
    return s if isinstance(s, dict) else {}


def ledger_on():
    return specs_cfg().get("ledger") is True


def ledger_path():
    rel = str(specs_cfg().get("file") or "specs/requirements.md").replace("\\", "/").lstrip("/")
    return os.path.join(ROOT, rel), rel


def event(kind, **kw):
    try:
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()), "kind": kind}
        row.update(kw)
        with open(os.path.join(F, "events.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    except OSError:
        pass


def change_dir(cid):
    try:
        for n in sorted(os.listdir(CH)):
            if n.startswith(cid + "-") and os.path.isdir(os.path.join(CH, n)):
                return os.path.join(CH, n)
    except OSError:
        pass
    return None


def frontmatter(text):
    m = re.match(r"^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(\r?\n|$)", text, re.S)
    out = {}
    for line in (m.group(1).splitlines() if m else []):
        k, sep, v = line.partition(":")
        if sep and k.strip() not in out:
            out[k.strip()] = v.strip()
    return out


def is_true(v):
    return str(v or "").strip().strip("'\"").lower() in ("true", "yes", "1")


def parse_delta(cid, text):
    """{"ADDED": [(id, text)], "MODIFIED": [(id, text)], "REMOVED": [(id, "")]},
    problems. ADDED ids are filed under the change (FR-001 -> C2-FR-001)."""
    delta = {s: [] for s in SECTIONS}
    problems = []
    cur = None
    for raw in text.splitlines():
        line = raw.rstrip()
        h = re.match(r"^#{1,6}\s*(ADDED|MODIFIED|REMOVED)\b", line, re.I)
        if h:
            cur = h.group(1).upper()
            continue
        if re.match(r"^#{1,6}\s", line):
            cur = None
            continue
        m = re.match(r"^\s*[-*]\s*`?((?:C[0-9]+-)?FR-[0-9]+)`?\s*(?::\s*(.*))?$", line)
        if not m:
            continue
        if cur is None:
            problems.append("%s is under no ADDED, MODIFIED or REMOVED heading" % m.group(1))
            continue
        rid, body = m.group(1), (m.group(2) or "").strip()
        if cur == "ADDED":
            if rid.startswith("FR-"):
                rid = "%s-%s" % (cid, rid)
            elif not rid.startswith(cid + "-"):
                problems.append("ADDED %s: a change adds requirements under its own id (%s-FR-...)" % (rid, cid))
                continue
        elif not LEDGER_ID.match(rid):
            problems.append("%s %s: name the ledger id it changes, filed under its change (C1-%s)" % (cur, rid, rid))
            continue
        if cur in ("ADDED", "MODIFIED") and not body:
            problems.append("%s %s has no text" % (cur, rid))
            continue
        delta[cur].append((rid, body))
    return delta, problems


def ledger_entries(text):
    """[(id, text)] in ledger order."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^\s*-\s*(C[0-9]+-FR-[0-9]+)\s*:\s*(.*?)\s*$", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def load(cid):
    """(delta | None, problems, skipped) for one change."""
    d = change_dir(cid)
    if not d:
        return None, ["no change %s under .factory/changes" % cid], False
    goal = frontmatter(read(os.path.join(d, "goal.md")))
    text = read(os.path.join(d, "delta.md"))
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("<!--")]
    if is_true(goal.get("skip_specs")) or (len(lines) == 1 and re.match(r"^skip_specs\s*:\s*true$", lines[0], re.I)):
        return None, [], True
    if not text.strip():
        return None, ["no delta (.factory/changes/%s/delta.md) and no skip_specs: true in its goal.md" %
                      os.path.basename(d)], False
    delta, problems = parse_delta(cid, text)
    if not problems and not any(delta[s] for s in SECTIONS):
        problems.append("delta.md lists no requirement under ADDED, MODIFIED or REMOVED - write them, or "
                        "say skip_specs: true")
    return delta, problems, False


def check_against(delta, entries):
    have = dict(entries)
    problems = []
    seen = set()
    for sec in SECTIONS:
        for rid, _ in delta[sec]:
            if rid in seen:
                problems.append("%s is named twice in the delta" % rid)
            seen.add(rid)
            if sec == "ADDED" and rid in have:
                problems.append("ADDED %s is in the ledger already - MODIFIED, if it changes" % rid)
            if sec != "ADDED" and rid not in have:
                problems.append("%s %s is not in the ledger" % (sec, rid))
    return problems


def cmd_seed(cid):
    if not ledger_on():
        return 0
    d = change_dir(cid)
    if not d or os.path.exists(os.path.join(d, "delta.md")):
        return 0
    if is_true(frontmatter(read(os.path.join(d, "goal.md"))).get("skip_specs")):
        return 0
    req = os.path.join(CH, cid + ".requirements.md")
    added = []
    for line in read(req).splitlines():
        m = re.match(r"^\s*[-*]\s*`?(FR-[0-9]+)`?\s*:\s*(.+?)\s*$", line)
        if m:
            added.append("- %s: %s" % (m.group(1), m.group(2)))
    head = ["<!-- What %s does to the project's requirements (%s). factory-change merges it into the ledger when "
            "the change closes. A requirement that changes or replaces one already in the ledger goes under "
            "MODIFIED by its ledger id (- C1-FR-004: the new text); one the change takes out, under REMOVED "
            "(- C1-FR-007). A change that adds nothing to the ledger: replace all of this with skip_specs: true. "
            "-->" % (cid, ledger_path()[1]), ""]
    body = ["## ADDED"] + added + ["", "## MODIFIED", "", "## REMOVED", ""]
    with open(os.path.join(d, "delta.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(head + body))
    rel = ".factory/changes/%s/delta.md" % os.path.basename(d)
    if added:
        print("SPECS DELTA %s: %s lists %d requirement(s) from %s.requirements.md under ADDED - move any that "
              "change a ledger requirement to MODIFIED" % (cid, rel, len(added), cid))
    else:
        print("SPECS DELTA %s: %s is empty (no %s.requirements.md) - write it, or skip_specs: true; "
              "factory-change validate %s refuses it as it is" % (cid, rel, cid, cid))
    return 0


def cmd_validate(cid):
    if not ledger_on():
        print("SPECS OFF: specs.ledger is not on in .factory/config.json")
        return 0
    delta, problems, skipped = load(cid)
    if skipped:
        print("SPECS SKIPPED %s: skip_specs - the change declares it adds nothing to the ledger" % cid)
        return 0
    if not problems:
        path, _ = ledger_path()
        problems = check_against(delta, ledger_entries(read(path)))
    if problems:
        for p in problems:
            print("SPECS REFUSED %s: %s" % (cid, p))
        return 1
    print("SPECS OK %s: %d added, %d modified, %d removed" % (
        cid, len(delta["ADDED"]), len(delta["MODIFIED"]), len(delta["REMOVED"])))
    return 0


def render(old_text, delta, cid):
    """The ledger text with the delta applied. Lines that are not requirements
    (the title, notes) stay where they are."""
    mod = dict(delta["MODIFIED"])
    rem = set(r for r, _ in delta["REMOVED"])
    out = []
    for line in (old_text.splitlines() if old_text.strip() else
                 ["# Requirements", "",
                  "<!-- The project's requirements, one per line, filed under the change that added them. "
                  "factory-change merges each closed change's delta here; edit by hand only in a change of "
                  "your own. -->", ""]):
        m = re.match(r"^(\s*-\s*)(C[0-9]+-FR-[0-9]+)(\s*:\s*)(.*?)\s*$", line)
        if m and m.group(2) in rem:
            continue
        if m and m.group(2) in mod:
            line = "%s%s: %s" % (m.group(1), m.group(2), mod[m.group(2)])
        out.append(line)
    while out and not out[-1].strip():
        out.pop()
    if delta["ADDED"]:
        out.append("")
        out += ["- %s: %s" % (rid, body) for rid, body in delta["ADDED"]]
    return "\n".join(out) + "\n"


def verify(text, delta):
    have = dict(ledger_entries(text))
    for rid, body in delta["ADDED"] + delta["MODIFIED"]:
        if have.get(rid) != body:
            return "%s is not in the written ledger as the delta says" % rid
    for rid, _ in delta["REMOVED"]:
        if rid in have:
            return "%s is still in the written ledger" % rid
    return None


def pending(d, why):
    try:
        with open(os.path.join(d, "specs-pending"), "w", encoding="utf-8") as fh:
            fh.write("at=%s\nwhy=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), why[:300]))
    except OSError:
        pass


def cmd_merge(cid):
    if not ledger_on():
        return 0
    d = change_dir(cid)
    if not d:
        print("SPECS MERGE FAILED %s: no change directory" % cid)
        return 1
    marker = os.path.join(d, "specs-merged")
    if os.path.exists(marker):
        print("SPECS %s: merged into the ledger already" % cid)
        return 0
    delta, problems, skipped = load(cid)
    if skipped:
        print("SPECS SKIPPED %s: skip_specs - nothing merged" % cid)
        return 0
    path, rel = ledger_path()
    old = read(path)
    existed = os.path.isfile(path)
    if not problems:
        problems = check_against(delta, ledger_entries(old))
    if problems:
        for p in problems:
            print("SPECS MERGE FAILED %s: %s - the ledger is unchanged; fix delta.md and the next factory-change "
                  "sync merges it" % (cid, p))
        event("spec_merge", change=cid, outcome="failed", reason=problems[0][:200])
        pending(d, problems[0])
        return 1
    new = render(old, delta, cid)
    # The old ledger, byte for byte, to put back; and its line endings, kept.
    orig = None
    if existed:
        with open(path, "rb") as fh:
            orig = fh.read()
    eol = "\r\n" if orig and b"\r\n" in orig else "\n"
    tmp = path + ".specs.tmp"
    written = False
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8", newline=eol) as fh:
            fh.write(new)
        os.replace(tmp, path)
        written = True
        if os.environ.get("FACTORY_SPECS_FAULT") == "after-write":  # tests only: a failure past the write
            raise OSError("injected fault after the write")
        why = verify(read(path), delta)
        if why:
            raise OSError(why)
    except OSError as e:
        if written:
            try:
                if orig is None:
                    os.remove(path)
                else:
                    with open(tmp, "wb") as fh:
                        fh.write(orig)
                    os.replace(tmp, path)
            except OSError:
                pass
        try:
            os.remove(tmp)
        except OSError:
            pass
        print("SPECS MERGE FAILED %s: %s - the ledger is back as it was" % (cid, e))
        event("spec_merge", change=cid, outcome="failed", reason=str(e)[:200])
        pending(d, str(e))
        return 1
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write("at=%s\nfile=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), rel))
    try:
        os.remove(os.path.join(d, "specs-pending"))
    except OSError:
        pass
    print("SPECS MERGED %s into %s: %d added, %d modified, %d removed - a working-tree change for you to read and "
          "commit" % (cid, rel, len(delta["ADDED"]), len(delta["MODIFIED"]), len(delta["REMOVED"])))
    for sec in SECTIONS:
        for rid, body in delta[sec]:
            print("  %s %s%s" % (sec.lower(), rid, (": " + body[:100]) if body else ""))
    event("spec_merge", change=cid, outcome="merged", added=len(delta["ADDED"]), modified=len(delta["MODIFIED"]),
          removed=len(delta["REMOVED"]))
    return 0


def test_files(ledger_rel):
    rx = (config().get("check") or {}).get("test_files") or DEFAULT_TESTS
    try:
        pat = re.compile(rx)
    except re.error:
        pat = re.compile(DEFAULT_TESTS)
    r = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if r.returncode == 0:
        names = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    else:
        names = []
        for dp, dn, fn in os.walk(ROOT):
            dn[:] = [x for x in dn if not x.startswith(".")]
            names += [os.path.relpath(os.path.join(dp, f), ROOT).replace(os.sep, "/") for f in fn]
    return [n for n in names if pat.search(n) and n != ledger_rel and not n.startswith(".factory/")]


def cmd_drift():
    if not ledger_on():
        print("SPECS OFF: specs.ledger is not on in .factory/config.json")
        return 0
    path, rel = ledger_path()
    entries = ledger_entries(read(path))
    if not entries:
        print("SPECS DRIFT: the ledger (%s) holds no requirement yet" % rel)
        return 0
    blob = "\n".join(read(os.path.join(ROOT, n)) for n in test_files(rel))
    missing = []
    for rid, body in entries:
        c, n = LEDGER_ID.match(rid).groups()
        # Not inside a longer name or number: test_c2_fr_001 counts, C12-FR-001 and C2-FR-0011 do not.
        if not re.search(r"(?i)(?<![A-Za-z0-9])%s[-_ ]?FR[-_ ]?%s(?![0-9])" % (c, n), blob):
            missing.append((rid, body))
    for rid, body in missing:
        print("DRIFT %s: no test names it - %s" % (rid, body[:100]))
    print("SPECS DRIFT %d of %d requirement(s) in %s have no test naming them" % (len(missing), len(entries), rel))
    return 0


def main(argv):
    if not os.path.isfile(os.path.join(F, "active")):
        print("SPECS: no .factory/active here - not a factory project, or not its root")
        return 2
    if argv[:1] == ["drift"]:
        return cmd_drift()
    if len(argv) >= 2 and argv[0] in ("validate", "merge", "seed") and re.match(r"^C[0-9]+$", argv[1]):
        return {"validate": cmd_validate, "merge": cmd_merge, "seed": cmd_seed}[argv[0]](argv[1])
    print("usage: factory-specs.py validate <Cn> | merge <Cn> | seed <Cn> | drift", file=sys.stderr)
    return 2


if __name__ == "__main__":
    # Text in and out is UTF-8 whatever the system's code page (cp1254 on a
    # Turkish Windows cannot decode every letter a task file holds).
    for _stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    sys.exit(main(sys.argv[1:]))
