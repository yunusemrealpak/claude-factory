#!/usr/bin/env bash
# Sandbox tests: the speed package - the pre-dispatch task lint and the
# deterministic ready set (factory-plan --ready).
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
BASE="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$BASE/extract.py"
# Sandboxes are built under here, never beside the suite itself.
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
# Inside a Claude Code session the plugin's bin/ is on PATH; the toolkit is
# called by name, so the suites run under the same condition.
export PATH="$(cd "$(dirname "$0")/../bin" && pwd):$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

mktask() {  # <dir> <column> <id> [files...]
  local d="$1" col="$2" id="$3"; shift 3
  mkdir -p "$d/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: t $id"; echo "module: m"
    echo "depends_on: []"; echo "acceptance: bash gates/verify.sh $id"
    echo "needs_human: false"; echo "review: on-red"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"; echo
    echo "## Goal"; echo "g"; echo
    echo "## Acceptance criteria"; echo "- [ ] it works"; echo
    echo "## Files touched"
    for f in "$@"; do echo "- \`$f\`"; done
    echo; echo "## Attempts"
  } > "$d/tasks/$col/$id.md"
}

echo "=== task lint"
L="$WORK/lint"; rm -rf "$L"; mkdir -p "$L/.factory"; cd "$L" || exit 1
mktask "$L" backlog C2-01
mktask "$L" done C2-00
out="$(bash "$H/factory-lint.sh" C2-01)"; rc=$?
check "a well-formed task passes" '[ $rc -eq 0 ] && [ "$out" = "LINT OK C2-01" ]' "$out"
f=tasks/backlog/C2-01.md
lint() { bash "$H/factory-lint.sh" C2-01 2>&1; }
cp "$f" "$f.good"
sed -i.b 's/^module: m$//' "$f" && rm -f "$f.b"
out="$(lint)"; rc=$?
check "a missing key is named" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no module:"' "$out"
cp "$f.good" "$f"; printf '%s\n' "$(sed '1a\
title: second copy' "$f")" > "$f"
out="$(lint)"
check "a duplicated key is caught" 'printf "%s" "$out" | grep -q "repeats: title"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^id: C2-01$/id: C2-99/' "$f" && rm -f "$f.b"
out="$(lint)"
check "an id that disagrees with the filename is caught" 'printf "%s" "$out" | grep -q "does not match the filename"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^depends_on: \[\]$/depends_on: [C2-77]/' "$f" && rm -f "$f.b"
out="$(lint)"
check "a dependency that is not on the board is caught" 'printf "%s" "$out" | grep -q "C2-77, which is not a task"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^depends_on: \[\]$/depends_on: [C2-00]/' "$f" && rm -f "$f.b"
check "a dependency that exists passes" 'bash "$H/factory-lint.sh" C2-01 >/dev/null'
cp "$f.good" "$f"; sed -i.b 's/^depends_on: \[\]$/depends_on: [C2-01]/' "$f" && rm -f "$f.b"
out="$(lint)"
check "a task that depends on itself is caught" 'printf "%s" "$out" | grep -q "lists itself"' "$out"
cp "$f.good" "$f"; sed -i.b 's|^acceptance:.*|acceptance:|' "$f" && rm -f "$f.b"
out="$(lint)"
check "an empty acceptance command is caught" 'printf "%s" "$out" | grep -q "acceptance: is empty"' "$out"
cp "$f.good" "$f"; sed -i.b 's|^acceptance:.*|acceptance: grep -q done decisions.md|' "$f" && rm -f "$f.b"
out="$(lint)"
check "an acceptance that only reads markdown is caught" 'printf "%s" "$out" | grep -q "only evidence is a markdown file"' "$out"
cp "$f.good" "$f"; sed -i.b 's|^acceptance:.*|acceptance: cat notes.md|' "$f" && rm -f "$f.b"
out="$(lint)"
check "...any markdown file: the rule is the check's own" 'printf "%s" "$out" | grep -q "only evidence is a markdown file"' "$out"
cp "$f.good" "$f"; sed -i.b 's|^acceptance:.*|acceptance: pytest \&\& grep -q x decisions.md|' "$f" && rm -f "$f.b"
out="$(lint)"
check "...but not a command that also runs something" '! printf "%s" "$out" | grep -q "only evidence is a markdown file"' "$out"
cp "$f.good" "$f"; sed -i.b 's|^acceptance:.*|acceptance: <command that checks it>|' "$f" && rm -f "$f.b"
out="$(lint)"
check "a template placeholder in acceptance is caught" 'printf "%s" "$out" | grep -q "template placeholder"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^needs_human: false$/needs_human: maybe/' "$f" && rm -f "$f.b"
out="$(lint)"
check "needs_human has to be true or false" 'printf "%s" "$out" | grep -q "must be true or false"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^review: on-red$/review: sometimes/' "$f" && rm -f "$f.b"
out="$(lint)"
check "review has to be on-red or always" 'printf "%s" "$out" | grep -q "on-red or always"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^retries: 0$/retries: none/' "$f" && rm -f "$f.b"
out="$(lint)"
check "retries has to be a number" 'printf "%s" "$out" | grep -q "must be a number"' "$out"
cp "$f.good" "$f"; sed -i.b '/^## Files touched$/d' "$f" && rm -f "$f.b"
out="$(lint)"
check "a missing section is named" 'printf "%s" "$out" | grep -q "## Files touched section is missing"' "$out"
cp "$f.good" "$f"; sed -i.b 's/^- \[ \] it works$/some prose/' "$f" && rm -f "$f.b"
out="$(lint)"
check "acceptance criteria with no checkbox is caught" 'printf "%s" "$out" | grep -q "no checkable criterion"' "$out"
cp "$f.good" "$f"; printf '<what must be true when this is done>\n' >> "$f"
out="$(lint)"
check "template body text left behind is caught" 'printf "%s" "$out" | grep -q "template placeholder text"' "$out"
cp "$f.good" "$f"; rm -f "$f.good"
mktask "$L" in-progress C2-02
sed -i.b 's/^title: t C2-02$/title:/' tasks/in-progress/C2-02.md && rm -f tasks/in-progress/C2-02.md.b
out="$(bash "$H/factory-lint.sh" --all 2>&1)"; rc=$?
check "--all covers every column that can be dispatched" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "LINT OK C2-01" && printf "%s" "$out" | grep -q "LINT C2-02: title: is empty"' "$out"
check "--all does not lint finished work" '! printf "%s" "$out" | grep -q "C2-00"' "$out"
out="$(bash "$H/factory-lint.sh" C9-99 2>&1)"; rc=$?
check "an unknown id is a usage error" '[ $rc -eq 2 ]' "$out"

echo "=== ready set"
R="$WORK/ready"; rm -rf "$R"; mkdir -p "$R/.factory/no-progress"; cd "$R" || exit 1
: > .factory/active
mktask "$R" done C2-00
mktask "$R" backlog C2-01
mktask "$R" backlog C2-02
sed -i.b 's/^depends_on: \[\]$/depends_on: [C2-00]/' tasks/backlog/C2-02.md && rm -f tasks/backlog/C2-02.md.b
mktask "$R" backlog C2-03
sed -i.b 's/^depends_on: \[\]$/depends_on: [C2-01, C2-00]/' tasks/backlog/C2-03.md && rm -f tasks/backlog/C2-03.md.b
mktask "$R" backlog C2-04
sed -i.b 's/^needs_human: false$/needs_human: true/' tasks/backlog/C2-04.md && rm -f tasks/backlog/C2-04.md.b
mktask "$R" backlog C2-05
: > .factory/no-progress/C2-05
mktask "$R" in-progress C2-06
out="$(factory-plan --ready)"
check "a task with no dependencies is ready" 'printf "%s\n" "$out" | grep -q "^READY C2-01 m t C2-01$"' "$out"
check "a dependency already done does not hold it back" 'printf "%s\n" "$out" | grep -q "^READY C2-02 "' "$out"
check "an unfinished dependency is named" 'printf "%s\n" "$out" | grep -q "^WAIT  C2-03 needs C2-01$"' "$out"
check "needs_human is held, not dispatched" 'printf "%s\n" "$out" | grep -q "^HOLD C2-04 needs_human - a decision for the developer; factory-preflight blocks it and asks$"' "$out"
check "a stalled task is not offered again" 'printf "%s\n" "$out" | grep -q "^STALL C2-05 .*not another builder$"' "$out"
check "the summary counts every column" 'printf "%s\n" "$out" | grep -q "^SUMMARY ready=2 wait=1 hold=1 stall=1 in-progress=1$"' "$out"
mv tasks/backlog/C2-01.md tasks/done/
out="$(factory-plan --ready)"
check "finishing a dependency releases the task waiting on it" 'printf "%s\n" "$out" | grep -q "^READY C2-03 "' "$out"
E="$WORK/ready-empty"; rm -rf "$E"; mkdir -p "$E/tasks/backlog" "$E/.factory"; cd "$E" || exit 1
: > .factory/active
out="$(factory-plan --ready)"
check "an empty backlog says so rather than failing" '[ "$out" = "SUMMARY ready=0 wait=0 hold=0 stall=0 in-progress=0" ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
