#!/usr/bin/env bash
# Sandbox tests: the speed package - skipping the integrator's duplicate gate
# run, the pre-dispatch task lint, the deterministic ready set.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
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

echo "=== tree fingerprint"
S="$WORK/skip"; rm -rf "$S"; mkdir -p "$S"; cd "$S" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p src .factory/verified tasks/in-progress tasks/done
printf 'one\n' > src/a.txt; printf 'x\n' > decisions.md
git add -A; git commit -qm base
h1="$(bash "$H/factory-gate-skip.sh" hash)"
check "a fingerprint is a hash" 'printf "%s" "$h1" | grep -qE "^[0-9a-f]{40}$"' "$h1"
check "it is stable when nothing changes" '[ "$(bash "$H/factory-gate-skip.sh" hash)" = "$h1" ]'
printf 'two\n' > src/a.txt
h2="$(bash "$H/factory-gate-skip.sh" hash)"
check "a product edit changes it" '[ "$h2" != "$h1" ]'
printf 'one\n' > src/a.txt
check "putting the bytes back restores it" '[ "$(bash "$H/factory-gate-skip.sh" hash)" = "$h1" ]'
mktask "$S" in-progress C2-01 src/a.txt
printf 'a decision\n' >> decisions.md
printf 'junk\n' > .factory/scratch
check "task files, decisions.md and .factory do not change it" '[ "$(bash "$H/factory-gate-skip.sh" hash)" = "$h1" ]' "$(bash "$H/factory-gate-skip.sh" hash) vs $h1"
printf 'new\n' > src/b.txt
h3="$(bash "$H/factory-gate-skip.sh" hash)"
check "an untracked product file changes it" '[ "$h3" != "$h1" ]'
printf 'new2\n' > src/b.txt
check "editing that untracked file changes it again" '[ "$(bash "$H/factory-gate-skip.sh" hash)" != "$h3" ]'
rm src/b.txt
git add -A -- src decisions.md >/dev/null 2>&1; git commit -qm second >/dev/null 2>&1
check "a commit changes it, even with the same working tree" '[ "$(bash "$H/factory-gate-skip.sh" hash)" != "$h1" ]'
mkdir -p "$WORK/nogit-skip" && check "outside a git repo it answers unknown" '[ "$(cd "$WORK/nogit-skip" && bash "$H/factory-gate-skip.sh" hash)" = "unknown" ]'

echo "=== is the second gate run needed"
cd "$S" || exit 1
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "no marker: run it" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^GATE RUN C2-01: no green marker"' "$out"
mk_marker() {  # <tree> [isolated]
  { date -u +"%Y-%m-%dT%H:%M:%SZ"; echo "test_files=1"; echo "skipped=0"
    echo "isolated=${2:-no}"; echo "commit=abc1234"; echo "tree=$1"; } > .factory/verified/C2-01
}
mk_marker "$(bash "$H/factory-gate-skip.sh" hash)"
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "unchanged tree: skip the duplicate run" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^GATE SKIP C2-01"' "$out"
printf 'appended\n' >> decisions.md
mktask "$S" in-progress C2-01 src/a.txt src/c.txt
printf '\n### Attempt 1 - red\n- tried something\n' >> tasks/in-progress/C2-01.md
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "bookkeeping written after the gate still skips" '[ $rc -eq 0 ]' "$out"
printf 'changed by a neighbour\n' >> src/a.txt
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "a neighbour touching the tree forces the run" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "tree changed"' "$out"
git checkout -q -- src/a.txt
mk_marker "$(bash "$H/factory-gate-skip.sh" hash)" yes
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "an isolated green never skips the shared-tree run" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "isolated"' "$out"
mk_marker ""
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "an old marker with no fingerprint runs the gate" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no tree fingerprint"' "$out"
mk_marker unknown
check "tree=unknown runs the gate" '! bash "$H/factory-gate-skip.sh" check C2-01 >/dev/null'
out="$(bash "$H/factory-gate-skip.sh" check 2>&1)"; rc=$?
check "check with no task id is a usage error" '[ $rc -eq 2 ]' "$out"

echo "=== the gate writes the fingerprint itself"
G="$WORK/skipgate"; rm -rf "$G"; mkdir -p "$G"; cd "$G" || exit 1
git init -q -b main; git config user.email t@example.invalid; git config user.name t
mkdir -p src gates .factory/verified tasks/in-progress
printf 'base\n' > src/a.txt
python3 "$EXTRACT" gates/verify.sh >/dev/null
git add -A; git commit -qm base
jq -n '{gate_mode:"full", min_tests:1, gate_isolation:false, isolation_links:[],
        commands:{build:"true", test:"echo \"1 passed\"", arch:"", lint:"true"}}' > .factory/config.json
printf 'work\n' >> src/a.txt
mktask "$G" in-progress C2-01 src/a.txt
bash gates/verify.sh C2-01 > "$WORK/skipgate.out" 2>&1; rc=$?
check "the gate goes green" '[ $rc -eq 0 ]' "$(tail -3 "$WORK/skipgate.out")"
check "the marker carries a real fingerprint" 'grep -qE "^tree=[0-9a-f]{40}$" .factory/verified/C2-01' "$(cat .factory/verified/C2-01)"
out="$(bash "$H/factory-gate-skip.sh" check C2-01)"; rc=$?
check "straight after a green gate, the second run is skipped" '[ $rc -eq 0 ]' "$out"
printf '\n## Attempts\n- note\n' >> tasks/in-progress/C2-01.md
printf 'C2-01: did the thing\n' >> decisions.md
check "the implementer's own bookkeeping does not undo it" 'bash "$H/factory-gate-skip.sh" check C2-01 >/dev/null'
printf 'someone else\n' >> src/a.txt
check "another change to the code does" '! bash "$H/factory-gate-skip.sh" check C2-01 >/dev/null'
git checkout -q -- src/a.txt 2>/dev/null; printf 'work\n' > /dev/null
# gate_isolation on: the marker must say so, and the skip must refuse
rm -f .factory/verified/C2-01
jq '.gate_isolation = true' .factory/config.json > c.tmp && mv c.tmp .factory/config.json
printf 'base\nwork\n' > src/a.txt
bash gates/verify.sh C2-01 > "$WORK/skipgate.out" 2>&1
check "isolated gate still writes a fingerprint of the shared tree" 'grep -q "^isolated=yes" .factory/verified/C2-01 && grep -qE "^tree=[0-9a-f]{40}$" .factory/verified/C2-01' "$(cat .factory/verified/C2-01)"
check "but the integrator still runs the gate" '! bash "$H/factory-gate-skip.sh" check C2-01 >/dev/null'

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
out="$(bash "$H/factory-ready.sh")"
check "a task with no dependencies is ready" 'printf "%s\n" "$out" | grep -q "^READY C2-01 m t C2-01$"' "$out"
check "a dependency already done does not hold it back" 'printf "%s\n" "$out" | grep -q "^READY C2-02 "' "$out"
check "an unfinished dependency is named" 'printf "%s\n" "$out" | grep -q "^WAIT  C2-03 needs C2-01$"' "$out"
check "needs_human is held, not dispatched" 'printf "%s\n" "$out" | grep -q "^HOLD C2-04 needs_human"' "$out"
check "a stalled task is not offered again" 'printf "%s\n" "$out" | grep -q "^STALL C2-05"' "$out"
check "the summary counts every column" 'printf "%s\n" "$out" | grep -q "^SUMMARY ready=2 wait=1 hold=1 stall=1 in-progress=1$"' "$out"
out="$(bash "$H/factory-ready.sh" --ids)"
check "--ids is a bare list for a loop" '[ "$(printf "%s\n" "$out")" = "$(printf "C2-01\nC2-02")" ]' "$out"
mv tasks/backlog/C2-01.md tasks/done/
out="$(bash "$H/factory-ready.sh")"
check "finishing a dependency releases the task waiting on it" 'printf "%s\n" "$out" | grep -q "^READY C2-03 "' "$out"
E="$WORK/ready-empty"; rm -rf "$E"; mkdir -p "$E/tasks/backlog"; cd "$E" || exit 1
out="$(bash "$H/factory-ready.sh")"
check "an empty backlog says so rather than failing" '[ "$out" = "SUMMARY ready=0 wait=0 hold=0 stall=0 in-progress=0" ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
