#!/usr/bin/env bash
# Sandbox tests: the living spec ledger (3.6, specs.ledger) - a change's
# delta.md seeded at open, checked by factory-change validate, merged into
# specs/requirements.md when the change closes (all or nothing), and the drift
# report of requirements no test names. Never touches a real project.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

newproj() {  # <name> <ledger true|false> -> P, cd P
  P="$WORK/s20-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main; git config user.email t@example.invalid; git config user.name t
  mkdir -p .factory/changes tasks/backlog tasks/in-progress tasks/done tasks/blocked tasks/proposed src tests
  : > .factory/active
  printf '{"specs":{"ledger":%s}}\n' "$2" > .factory/config.json
  printf '.factory/\n' > .gitignore; echo base > src/a.txt
  git add -A; git commit -qm base
}
mktask() {  # <column> <id>
  printf -- '---\nid: %s\ntitle: task %s\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: queued\nstage_since:\n---\n\n## Goal\nx\n\n## Files touched\n\n## Attempts\n' "$2" "$2" > "tasks/$1/$2.md"
}
reqs() {  # <change> <lines...>: the change's requirements file
  local c="$1"; shift
  { echo "# $c - requirements"; echo; for l in "$@"; do echo "$l"; done; echo; echo "## Clarifications"; echo "- Q1: csv or xlsx? -> csv"; } > ".factory/changes/$c.requirements.md"
}
open_change() {  # <change> <slug>: one backlog task, opened
  mktask backlog "$1-01"
  printf 'goal of %s\n' "$1" | factory-change open "$1" "$2" feature - 2>&1
}
close_change() {  # <change>: its task done, then a sync
  mv "tasks/backlog/$1-01.md" "tasks/done/$1-01.md"
  factory-change sync "$1" 2>&1
}
cdir() { ls -d .factory/changes/"$1"-*/ 2>/dev/null | head -1 | sed 's:/$::'; }
L=specs/requirements.md

echo "=== off by default"
newproj off false
reqs C2 "- FR-001: A thing."
out="$(open_change C2 thing)"
check "ledger off: open writes no delta"            '[ ! -e "$(cdir C2)/delta.md" ] && ! printf "%s" "$out" | grep -q SPECS' "$out"
out="$(factory-change validate C2)"; rc=$?
check "ledger off: validate says so, exit 0"        '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^SPECS OFF"' "$out"
out="$(close_change C2)"
check "ledger off: closing writes no ledger"        'printf "%s" "$out" | grep -q "^CLOSED-NOW C2-" && [ ! -e "$L" ] && ! printf "%s" "$out" | grep -q SPECS' "$out"
out="$(factory-change drift)"
check "ledger off: drift says so"                   'printf "%s" "$out" | grep -q "^SPECS OFF"' "$out"

echo "=== a delta seeded at open, and validate"
newproj seed true
reqs C2 "- FR-001: An accountant downloads the month's invoices as one CSV." "- FR-002: An empty month gives a header row only."
out="$(open_change C2 csv-export)"
D="$(cdir C2)"
check "open seeds delta.md from the requirements"   'printf "%s" "$out" | grep -q "^SPECS DELTA C2: .*2 requirement" && grep -q "^- FR-001: An accountant" "$D/delta.md" && grep -q "^- FR-002:" "$D/delta.md"' "$out"
check "...under ADDED, with MODIFIED and REMOVED empty" 'awk "/^## ADDED/{a=1} /^## MODIFIED/{a=0} a && /FR-00/" "$D/delta.md" | grep -c . | grep -q "^2$" && grep -q "^## REMOVED" "$D/delta.md"'
check "...and the clarifications are not requirements" '! grep -q "Q1" "$D/delta.md"'
check "...the change still opened"                  'printf "%s" "$out" | grep -q "^OPENED C2-csv-export"' "$out"
out="$(factory-change validate C2)"; rc=$?
check "validate: the seeded delta is OK"            '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^SPECS OK C2: 2 added, 0 modified, 0 removed"' "$out"
printf 'my own delta\n## ADDED\n- FR-009: kept\n' > "$D/delta.md"
python3 "$H/factory-specs.py" seed C2 >/dev/null
check "seed never overwrites a delta"               'grep -q "FR-009: kept" "$D/delta.md"'

newproj empty true
out="$(open_change C2 no-reqs)"
D="$(cdir C2)"
check "no requirements file: an empty delta, and open says so" 'printf "%s" "$out" | grep -q "SPECS DELTA C2: .*is empty" && [ -f "$D/delta.md" ]' "$out"
out="$(factory-change validate C2)"; rc=$?
check "validate refuses an empty delta"             '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^SPECS REFUSED C2: delta.md lists no requirement"' "$out"
rm -f "$D/delta.md"
out="$(factory-change validate C2)"; rc=$?
check "validate refuses a change with no delta at all" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "no delta"' "$out"
awk 'NR==2{print "skip_specs: true"} {print}' "$D/goal.md" > "$D/g.tmp" && mv "$D/g.tmp" "$D/goal.md"
out="$(factory-change validate C2)"; rc=$?
check "skip_specs: true in goal.md is a decision, not a gap" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^SPECS SKIPPED C2"' "$out"
out="$(close_change C2)"
check "...and closing it leaves the ledger alone"   'printf "%s" "$out" | grep -q "SPECS SKIPPED C2" && [ ! -e "$L" ]' "$out"
newproj skipline true
out="$(open_change C2 chore)"; D="$(cdir C2)"
printf '<!-- nothing to add -->\nskip_specs: true\n' > "$D/delta.md"
out="$(factory-change validate C2)"; rc=$?
check "a one-line delta.md skip_specs: true skips too" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^SPECS SKIPPED C2"' "$out"

echo "=== merged into the ledger when the change closes"
newproj merge true
reqs C2 "- FR-001: Invoices download as CSV." "- FR-002: An empty month has a header row only."
open_change C2 csv-export >/dev/null
D2="$(cdir C2)"
commits="$(git rev-list --count HEAD)"
out="$(close_change C2)"
check "the closing sync merges the delta"           'printf "%s" "$out" | grep -q "^CLOSED-NOW C2-" && printf "%s" "$out" | grep -q "^SPECS MERGED C2 into specs/requirements.md: 2 added, 0 modified, 0 removed"' "$out"
check "...and prints what changed"                  'printf "%s" "$out" | grep -q "^  added C2-FR-001: Invoices download as CSV."' "$out"
check "the ledger files them under the change"      'grep -q "^- C2-FR-001: Invoices download as CSV.$" "$L" && grep -q "^- C2-FR-002: An empty month" "$L" && head -1 "$L" | grep -q "^# Requirements"'
check "...as a working-tree change, not a commit"   '[ "$(git rev-list --count HEAD)" = "$commits" ] && git status --porcelain | grep -q "specs/"'
check "...marked merged, and the event says so"     '[ -f "$D2/specs-merged" ] && [ ! -e "$D2/specs-pending" ] && grep "\"kind\":\"spec_merge\"" .factory/events.jsonl | grep -q "\"outcome\":\"merged\""'
out="$(factory-change sync)"
check "a later sync does not merge it twice"        '[ "$(grep -c "C2-FR-001" "$L")" -eq 1 ] && ! printf "%s" "$out" | grep -q "SPECS"' "$out"
git add -A; git commit -qm "ledger after C2"
printf '# the ledger\n\nA note the developer wrote.\n' > "$WORK/s20-head.md"
{ cat "$WORK/s20-head.md"; grep "^- " "$L"; } > "$L.new" && mv "$L.new" "$L"

reqs C3 "- FR-001: Exports can be filtered by customer."
open_change C3 filter >/dev/null
D3="$(cdir C3)"
cat > "$D3/delta.md" <<'MD'
## ADDED
- FR-001: Exports can be filtered by customer.
## MODIFIED
- C2-FR-001: Invoices download as CSV, one row per invoice line.
## REMOVED
- C2-FR-002
MD
out="$(factory-change validate C3)"; rc=$?
check "validate: added, modified and removed"       '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "1 added, 1 modified, 1 removed"' "$out"
out="$(close_change C3)"
check "MODIFIED replaces the text by id"            'grep -q "^- C2-FR-001: Invoices download as CSV, one row per invoice line.$" "$L" && [ "$(grep -c "C2-FR-001" "$L")" -eq 1 ]' "$out"
check "REMOVED takes it out"                        '! grep -q "C2-FR-002" "$L"'
check "ADDED is filed under the new change"         'grep -q "^- C3-FR-001: Exports can be filtered by customer.$" "$L"'
check "what is not a requirement stays where it was" 'head -1 "$L" | grep -q "^# the ledger" && grep -q "^A note the developer wrote.$" "$L"'

echo "=== a delta that does not fit the ledger"
cp "$L" "$WORK/s20-before.md"
mkdir -p tasks/backlog
reqs C4 "- FR-001: x"
open_change C4 bad >/dev/null; D4="$(cdir C4)"
printf '## MODIFIED\n- C9-FR-001: no such\n' > "$D4/delta.md"
out="$(factory-change validate C4)"; rc=$?
check "validate refuses MODIFIED of an id the ledger lacks" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "C9-FR-001 is not in the ledger"' "$out"
printf '## MODIFIED\n- FR-001: unfiled\n' > "$D4/delta.md"
out="$(factory-change validate C4)"; rc=$?
check "...MODIFIED of an unfiled FR id"             '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "name the ledger id"' "$out"
printf '## ADDED\n- C2-FR-005: not mine\n' > "$D4/delta.md"
out="$(factory-change validate C4)"; rc=$?
check "...ADDED under another change's id"          '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "under its own id"' "$out"
printf -- '- FR-001: no heading\n' > "$D4/delta.md"
out="$(factory-change validate C4)"; rc=$?
check "...a requirement under no heading"           '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "under no ADDED"' "$out"
printf '## MODIFIED\n- C9-FR-001: no such\n' > "$D4/delta.md"
out="$(close_change C4)"
check "at close: the change still closes"           'printf "%s" "$out" | grep -q "^CLOSED-NOW C4-"' "$out"
check "...the merge fails and says why"             'printf "%s" "$out" | grep -q "^SPECS MERGE FAILED C4: .*C9-FR-001 is not in the ledger - the ledger is unchanged"' "$out"
check "...the ledger is byte for byte what it was"  'cmp -s "$L" "$WORK/s20-before.md"'
check "...the failure is pending and an event"      '[ -f "$D4/specs-pending" ] && [ ! -f "$D4/specs-merged" ] && grep "\"kind\":\"spec_merge\"" .factory/events.jsonl | grep -q "\"outcome\":\"failed\""'
printf '## ADDED\n- FR-001: Fixed delta.\n' > "$D4/delta.md"
out="$(factory-change sync)"
check "the next sync retries the pending merge"     'printf "%s" "$out" | grep -q "^SPECS MERGED C4" && grep -q "^- C4-FR-001: Fixed delta.$" "$L" && [ ! -e "$D4/specs-pending" ] && [ -f "$D4/specs-merged" ]' "$out"

echo "=== all or nothing"
cp "$L" "$WORK/s20-before.md"
reqs C5 "- FR-001: y"
open_change C5 fault >/dev/null; D5="$(cdir C5)"
out="$(FACTORY_SPECS_FAULT=after-write close_change C5)"
check "a failure after the write puts the old ledger back" 'printf "%s" "$out" | grep -q "SPECS MERGE FAILED C5: .*back as it was" && cmp -s "$L" "$WORK/s20-before.md"' "$out"
check "...leaves no temp file behind"               '[ ! -e "$L.specs.tmp" ] && [ -f "$D5/specs-pending" ]'
out="$(factory-change sync C5)"
check "...and a later sync merges it"               'printf "%s" "$out" | grep -q "^SPECS MERGED C5" && grep -q "^- C5-FR-001: y$" "$L"' "$out"
newproj fault-new true
reqs C2 "- FR-001: z"
open_change C2 first >/dev/null
out="$(FACTORY_SPECS_FAULT=after-write close_change C2)"
check "with no ledger before, a failed merge leaves none" 'printf "%s" "$out" | grep -q "SPECS MERGE FAILED C2" && [ ! -e "$L" ]' "$out"

newproj opendone true
reqs C2 "- FR-001: done at open"
mktask done C2-01
out="$(printf 'g\n' | factory-change open C2 already feature - 2>&1)"
check "a change opened with its tasks done: seeded, then merged" 'grep -q "^- C2-FR-001: done at open$" "$L" && [ -f "$(cdir C2)/specs-merged" ] && ! grep -q "\"outcome\":\"failed\"" .factory/events.jsonl' "$out"

echo "=== drift: requirements no test names"
newproj drift true
reqs C2 "- FR-001: one" "- FR-002: two" "- FR-003: three"
open_change C2 drift >/dev/null; close_change C2 >/dev/null
printf 'def test_c2_fr_001_one():\n    pass\n' > tests/test_export.py
printf 'C12-FR-003 and C2-FR-0031 are other requirements\n' > tests/test_other.py
printf 'it("c2_fr_002 two", () => {})\n' > src/export.test.ts
printf 'C2-FR-003 is mentioned only outside a test\n' > src/notes.md
out="$(factory-change drift)"; rc=$?
check "drift lists a requirement no test names"     '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^DRIFT C2-FR-003: no test names it - three"' "$out"
check "...not one a test names, in any spelling"     '! printf "%s" "$out" | grep -q "^DRIFT C2-FR-001" && ! printf "%s" "$out" | grep -q "^DRIFT C2-FR-002"' "$out"
check "...and counts them"                          'printf "%s" "$out" | grep -q "^SPECS DRIFT 1 of 3 requirement"' "$out"
jq '.check = {test_files: "\\.md$"}' .factory/config.json > .factory/c.tmp && mv .factory/c.tmp .factory/config.json
out="$(factory-change drift)"
check "check.test_files decides what a test file is" '! printf "%s" "$out" | grep -q "^DRIFT C2-FR-003" && printf "%s" "$out" | grep -q "^DRIFT C2-FR-001"' "$out"
newproj drift-empty true
out="$(factory-change drift)"; rc=$?
check "an empty ledger is a line, not an error"     '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "holds no requirement yet"' "$out"
out="$(bash "$H/factory-change.sh" bogus 2>&1)"
check "the usage names validate and drift"          'printf "%s" "$out" | grep -q "validate <change-id> | drift"' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
