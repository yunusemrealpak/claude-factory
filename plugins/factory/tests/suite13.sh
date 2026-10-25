#!/usr/bin/env bash
# Sandbox tests: the one loop (3.4) - the loop workflow's schedule under a fake
# agent() (tests/loop-cases.mjs), and the scripts that decide on disk what it
# only times: factory-preflight, factory-settle, factory-review-submit and
# factory-deliver, against a real git project.
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

echo "=== the loop workflow's schedule"
if command -v node >/dev/null 2>&1; then
  out="$(node "${PLUGIN}/tests/loop-cases.mjs" 2>&1)"
  while IFS= read -r l; do
    case "$l" in
      "ok   "*) ok "loop: ${l#ok   }" ;;
      "FAIL "*) bad "loop: ${l#FAIL }" ;;
      "     "*) printf '%s\n' "$l" ;;
    esac
  done <<< "$out"
  check "the loop cases ran to the end" 'printf "%s" "$out" | grep -q "^loop: passed=[0-9]* failed=0$"' "$(printf '%s' "$out" | tail -5)"
else
  echo "SKIP the loop cases: no node on PATH"
fi

# --- a project: one unit, tests are *.t files, risk on */auth/* --------------
mktask() {  # <column> <id> <depends> <review> [files-touched...]
  local col="$1" id="$2" deps="$3" review="$4"; shift 4
  mkdir -p "$P/tasks/$col"
  {
    echo "---"; echo "id: $id"; echo "title: task $id"; echo "module: core"
    echo "depends_on: [$deps]"; echo "acceptance: bash runner.sh core"
    echo "needs_human: false"; echo "review: $review"; echo "retries: 0"
    echo "owner:"; echo "stage: queued"; echo "stage_since:"; echo "---"
    echo; echo "## Goal"; echo "Do the thing."; echo
    echo "## Acceptance criteria"; echo "- [ ] it works"; echo
    echo "## Files touched"
    for f in "$@"; do echo "- $f"; done
    echo; echo "## Attempts"
  } > "$P/tasks/$col/$id.md"
}
newproj() {  # <name>  -> P, cd P; tasks C1-01 (plain), C1-02 (review: always), C1-03 (auth)
  P="$WORK/s13-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main; git config user.email t@example.invalid; git config user.name t
  mkdir -p .factory/verified core/src core/tests core/auth tasks/backlog tasks/in-progress tasks/done tasks/blocked
  : > .factory/active
  printf 'base\n' > core/src/base.src; printf 'exit 0\n' > core/tests/base.t
  cat > runner.sh <<'SH'
n=0; bad=0
for t in $(find "$1" -name '*.t' | sort); do
  n=$((n + 1)); bash "$t" || { bad=$((bad + 1)); echo "FAILED $t: expected <1>, actual <2>"; }
done
[ "$bad" -gt 0 ] && { echo "$((n - bad)) passed, $bad failed"; exit 1; }
echo "$n passed"
SH
  cat > .factory/config.json <<'JSON'
{ "gate_mode": "full", "min_tests": 1, "retry_limit": 2,
  "commands": { "build": "true", "test": "bash runner.sh core", "arch": "", "lint": "true" },
  "check": { "unit_test": "bash runner.sh {path}", "test_files": "\\.t$",
             "units": [ {"name": "core", "path": "core", "deps": []} ] },
  "risk_paths": ["*/auth/*"], "risk_builtin": false,
  "fast": { "workers": 2, "risk_review": "after" } }
JSON
  printf '.factory/\n' > .gitignore
  mktask backlog C1-01 "" on-red core/src/a.src core/tests/a.t
  mktask backlog C1-02 "" always core/src/b.src core/tests/b.t
  mktask backlog C1-03 "" on-red core/auth/c.src core/tests/c.t
  git add -A; git commit -qm base
}
build() {  # <id> <file>... : start the task and write green work into its files
  local id="$1"; shift
  factory-start "$id" builder >/dev/null 2>&1
  for f in "$@"; do
    case "$f" in *.t) printf 'exit 0\n' > "$f" ;; *) printf 'new code for %s\nsecond line\n' "$id" > "$f" ;; esac
  done
}
settle() { factory-settle "$@" 2>&1 | tail -1; }
lane() { ls "$P"/tasks/*/"$1".md 2>/dev/null | sed 's#.*/tasks/\([^/]*\)/.*#\1#'; }

echo "=== factory-settle: green lands, from disk"
newproj settle
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
out="$(settle C1-01 "CHECK RESULT: GREEN")"
check "a green task lands" 'printf "%s" "$out" | grep -qE "^SETTLED C1-01 LANDED [0-9a-f]{7,}$" && [ "$(lane C1-01)" = done ]' "$out"
check "...as one commit that names it" 'git log -1 --format=%B | grep -q "^Factory-Task: C1-01$"'
out="$(settle C1-01 "again")"
check "settling a landed task again says so" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 LANDED (already in tasks/done)"' "$out"

echo "=== factory-settle: review always waits, uncommitted"
build C1-02 core/src/b.src core/tests/b.t
factory-check C1-02 >/dev/null 2>&1
head_before="$(git rev-parse HEAD)"
out="$(factory-settle C1-02 "CHECK RESULT: GREEN" 2>&1)"
check "review: always is not landed" 'printf "%s" "$out" | tail -1 | grep -q "^SETTLED C1-02 REVIEW$" && [ "$(lane C1-02)" = in-progress ] && [ "$(git rev-parse HEAD)" = "$head_before" ]' "$out"
check "...and says why" 'printf "%s" "$out" | grep -q "marked review: always"' "$out"
sed -i.bak 's/^review: always/review: on-red/' tasks/in-progress/C1-02.md && rm -f tasks/in-progress/C1-02.md.bak
out="$(settle C1-02 "CHECK RESULT: GREEN")"
check "a builder that edits review: always out of its task file still waits for review (HEAD's copy counts)" 'printf "%s" "$out" | grep -q "^SETTLED C1-02 REVIEW$"' "$out"

echo "=== factory-settle: a risk path lands first and owes its review"
build C1-03 core/auth/c.src core/tests/c.t
factory-check C1-03 >/dev/null 2>&1
out="$(factory-settle C1-03 "CHECK RESULT: GREEN" 2>&1)"
check "risk_review after: landed, review after" 'printf "%s" "$out" | tail -1 | grep -qE "^SETTLED C1-03 LANDED [0-9a-f]+ REVIEW-AFTER$" && [ "$(lane C1-03)" = done ]' "$out"
check "...the review is owed on disk" '[ "$(jq -r .verdict .factory/reviews/C1-03.json)" = owed ] && [ "$(jq -r .mode .factory/reviews/C1-03.json)" = after ]'
check "...and the RISK lines are printed" 'printf "%s" "$out" | grep -q "^RISK"' "$out"

newproj before
jq '.fast.risk_review = "before"' .factory/config.json > c && mv c .factory/config.json
build C1-03 core/auth/c.src core/tests/c.t
factory-check C1-03 >/dev/null 2>&1
out="$(settle C1-03 "CHECK RESULT: GREEN")"
check "risk_review before: a risk path waits for review" 'printf "%s" "$out" | grep -q "^SETTLED C1-03 REVIEW$" && [ "$(lane C1-03)" = in-progress ]' "$out"

echo "=== factory-settle: the files must be what the check saw"
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
echo "edited after the check" >> core/src/a.src
out="$(factory-settle C1-01 "CHECK RESULT: GREEN" 2>&1)"; rc=$?
check "a file changed after the green check is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | tail -1 | grep -q "^SETTLE REFUSED C1-01" && [ "$(lane C1-01)" = in-progress ]' "$out"

echo "=== factory-settle: red is an attempt, the limit blocks"
newproj red
build C1-01 core/src/a.src core/tests/a.t
printf 'exit 1\n' > core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
out="$(settle C1-01 "CHECK RESULT: RED")"
check "the first red is retried" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 RETRY 1/2: red" && [ "$(lane C1-01)" = in-progress ]' "$out"
check "...and the attempt is on disk" '[ "$(grep -c . .factory/attempts/C1-01)" = 1 ]'
printf 'echo a different failure; exit 3\n' > core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
out="$(settle C1-01 "CHECK RESULT: RED")"
check "at retry_limit attempts the task is blocked" 'printf "%s" "$out" | grep -qE "^SETTLED C1-01 BLOCKED: (red|no_progress) after 2" && [ "$(lane C1-01)" = blocked ]' "$out"

echo "=== factory-settle: waiting, STOP, a conflict, a refusal"
newproj wait
build C1-01 core/src/a.src core/tests/a.t
mkdir -p .factory/waiting; printf 'at=1\nfiles=core/src/other.src\ntasks=C1-09\n' > .factory/waiting/C1-01
out="$(settle C1-01 "CHECK RESULT: WAITING")"
check "a waiting check waits, named" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 WAITING on C1-09" && [ ! -s .factory/attempts/C1-01 ]' "$out"
out="$(settle C1-01 --no-wait "re-checked after a wait")"
check "with nothing else building, the wait is an attempt" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 RETRY 1/2" && [ ! -f .factory/waiting/C1-01 ]' "$out"
echo "x" > .factory/STOP
out="$(settle C1-01 "CHECK RESULT: RED")"
check "STOP halts, and counts nothing" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 HALTED" && [ "$(grep -c . .factory/attempts/C1-01)" = 1 ]' "$out"
rm -f .factory/STOP
out="$(settle C1-01 --conflict "criteria 1 and 2 cannot both hold")"
check "a spec conflict is blocked and asked" 'printf "%s" "$out" | grep -q "^SETTLED C1-01 BLOCKED: spec conflict, asked Q" && [ "$(lane C1-01)" = blocked ] && factory-ask list 2>/dev/null | grep -q "criteria 1 and 2"' "$out"
out="$(settle C1-02 --refused "START REFUSED for C1-02: a dependency has not landed")"
check "a refusal leaves the board as it is" 'printf "%s" "$out" | grep -q "^SETTLED C1-02 REFUSED: START REFUSED" && [ "$(lane C1-02)" = backlog ]' "$out"

echo "=== factory-review-submit: the filter"
newproj review
build C1-02 core/src/b.src core/tests/b.t
factory-check C1-02 >/dev/null 2>&1
settle C1-02 "CHECK RESULT: GREEN" >/dev/null
q="new code for C1-02"
cat > "$WORK/s13-drop.json" <<JSON
{"findings": [
 {"severity": "P1", "confidence": 60, "file": "core/src/b.src", "line": 1, "quote": "$q", "category": "correctness", "what": "low confidence", "fix": "x"},
 {"severity": "P1", "confidence": 95, "file": "core/src/b.src", "line": 1, "quote": "$q", "category": "lint", "what": "a lint finding", "fix": "x"},
 {"severity": "P1", "confidence": 95, "file": "core/src/base.src", "line": 1, "quote": "base", "category": "correctness", "what": "not in the diff", "fix": "x"},
 {"severity": "P1", "confidence": 95, "file": "core/src/b.src", "line": 1, "quote": "rows = db.query(Item).all()", "category": "correctness", "what": "a quote the diff does not have", "fix": "x"},
 {"severity": "P1", "confidence": 95, "file": "core/src/b.src", "line": 40, "quote": "$q", "category": "correctness", "what": "outside the hunks", "fix": "x"},
 {"severity": "P1", "confidence": 95, "file": "core/src/b.src", "line": 1, "quote": "$q", "category": "correctness", "what": "was there before", "fix": "x", "pre_existing": true},
 {"severity": "P2", "confidence": 95, "file": "core/src/b.src", "line": 2, "quote": "second line", "category": "correctness", "what": "worth changing", "fix": "x"}
]}
JSON
out="$(factory-review-submit C1-02 < "$WORK/s13-drop.json" 2>&1)"
check "findings the filter drops do not block, and a P2 does not either: the task lands" 'printf "%s" "$out" | tail -1 | grep -q "^REVIEW PASS C1-02: LANDED C1-02 " && [ "$(lane C1-02)" = done ]' "$out"
check "...the review is written into the task, with what was dropped" 'grep -q "^dropped by the filter: 6" tasks/done/C1-02.md && grep -q "worth changing" tasks/done/C1-02.md'
check "...and recorded" '[ "$(jq -r .verdict .factory/reviews/C1-02.json)" = pass ] && [ "$(jq -r ".rounds | length" .factory/reviews/C1-02.json)" = 1 ]'

newproj review2
build C1-02 core/src/b.src core/tests/b.t
factory-check C1-02 >/dev/null 2>&1
settle C1-02 "CHECK RESULT: GREEN" >/dev/null
cat > "$WORK/s13-p1.json" <<JSON
{"findings": [{"severity": "high", "confidence": 90, "file": "core/src/b.src", "line": 1, "quote": "new code for C1-02",
  "category": "authorization", "what": "every tenant sees it", "fix": "filter by tenant"}]}
JSON
out="$(factory-review-submit C1-02 < "$WORK/s13-p1.json" 2>&1)"
check "a blocking finding fails round 1 and the task waits for a fixer" 'printf "%s" "$out" | tail -1 | grep -q "^REVIEW FAIL C1-02 round 1" && [ "$(lane C1-02)" = in-progress ] && [ ! -f .factory/verified/C1-02 ]' "$out"
check "...a severity word maps to P0-P3" 'grep -q "\[P1\]" tasks/in-progress/C1-02.md'
out="$(factory-review-submit C1-02 < "$WORK/s13-p1.json" 2>&1)"; rc=$?
check "a review with no green check under it is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^REVIEW REFUSED C1-02: no green check"' "$out"
factory-check C1-02 >/dev/null 2>&1
out="$(factory-review-submit C1-02 < "$WORK/s13-p1.json" 2>&1)"
check "a second failed round blocks the task and asks" 'printf "%s" "$out" | tail -1 | grep -q "^REVIEW FAIL C1-02 BLOCKED" && [ "$(lane C1-02)" = blocked ] && [ "$(jq -r ".rounds | length" .factory/reviews/C1-02.json)" = 2 ]' "$out"
out="$(printf 'not json' | factory-review-submit C1-01 2>&1)"; rc=$?
check "input that is not JSON is refused" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^REVIEW REFUSED C1-01: the findings are not JSON"' "$out"

echo "=== factory-review-submit --landed"
newproj after
build C1-03 core/auth/c.src core/tests/c.t
factory-check C1-03 >/dev/null 2>&1
settle C1-03 "CHECK RESULT: GREEN" >/dev/null
cat > "$WORK/s13-after.json" <<JSON
{"findings": [{"severity": "P0", "confidence": 99, "file": "core/auth/c.src", "line": 1, "quote": "new code for C1-03",
  "category": "security", "what": "the secret is logged", "fix": "drop the log line"}]}
JSON
out="$(factory-review-submit C1-03 --landed < "$WORK/s13-after.json" 2>&1)"
check "after landing, a blocking finding fails the review and holds the change" 'printf "%s" "$out" | tail -1 | grep -q "^REVIEW FAIL C1-03 (landed):.*delivery of C1 is held" && [ "$(jq -r .verdict .factory/reviews/C1-03.json)" = fail ] && [ "$(lane C1-03)" = done ]' "$out"

echo "=== factory-deliver: full check, reviews, audit"
newproj deliver
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
settle C1-01 "CHECK RESULT: GREEN" >/dev/null
echo '{"started": 1}' > .factory/run-start.json
out="$(factory-deliver --if-ready C1 2>&1)"
check "no full check yet: wait" 'printf "%s" "$out" | grep -q "^DELIVER WAIT C1: the full check" && [ -f .factory/publish/C1.wait ]' "$out"
factory-check --full >/dev/null 2>&1
out="$(factory-deliver --if-ready C1 --audit 2>&1)"
check "the full check is green, the audit is expected: wait for it" 'printf "%s" "$out" | grep -q "^DELIVER WAIT C1: the audit" && grep -q "^audit=1" .factory/publish/C1.wait' "$out"
mkdir -p .factory/audit; printf '# Audit\n\n## high - the two tasks disagree on the field name\nWhere: a\n' > .factory/audit/C1.md
out="$(factory-deliver --if-ready 2>&1)"
check "a high audit finding holds the change (the wait remembered the audit)" 'printf "%s" "$out" | grep -q "^DELIVER HELD C1: the audit found 1 high" && [ ! -f .factory/publish/C1.wait ]' "$out"
: > .factory/publish/C1.ack
out="$(factory-deliver --if-ready C1 2>&1)"
check "accepted, it is handed to the publisher" 'printf "%s" "$out" | grep -q "^DELIVER C1: handed to the publisher"' "$out"
out="$(factory-deliver --if-ready C1 2>&1)"
check "...once" 'printf "%s" "$out" | grep -q "^DELIVER SKIPPED C1"' "$out"

newproj deliver2
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
settle C1-01 "CHECK RESULT: GREEN" >/dev/null
echo '{"started": 1}' > .factory/run-start.json
factory-check --full >/dev/null 2>&1
echo "later" > core/src/late.src; git add core/src/late.src; git commit -qm "a later commit"
out="$(factory-deliver --if-ready C1 2>&1)"
check "a full check of an older HEAD holds the change" 'printf "%s" "$out" | grep -q "^DELIVER HELD C1: the full check ran on"' "$out"
factory-check --full >/dev/null 2>&1
mkdir -p .factory/reviews; echo '{"task":"C1-01","verdict":"owed","mode":"after","rounds":[]}' > .factory/reviews/C1-01.json
out="$(factory-deliver --if-ready C1 2>&1)"
check "an owed review makes it wait" 'printf "%s" "$out" | grep -q "^DELIVER WAIT C1: the review of C1-01"' "$out"
echo '{"task":"C1-01","verdict":"fail","mode":"after","rounds":[]}' > .factory/reviews/C1-01.json
out="$(factory-deliver --if-ready C1 2>&1)"
check "a failed review holds it" 'printf "%s" "$out" | grep -q "^DELIVER HELD C1: a review failed: C1-01"' "$out"

echo "=== factory-preflight"
newproj pre
out="$(factory-preflight --json 2>&1)"; rc=$?
check "a clean board: ok, the tasks in the plan" '[ $rc -eq 0 ] && printf "%s" "$out" | jq -e ".ok and (.tasks | map(.id) | sort == [\"C1-01\",\"C1-02\",\"C1-03\"])" >/dev/null' "$out"
check "...C1-02 is planned for review" 'printf "%s" "$out" | jq -e "(.tasks[] | select(.id == \"C1-02\") | .review) == true" >/dev/null' "$out"
check "...the attempt limit and the workers come from the config" 'printf "%s" "$out" | jq -e ".attempts == 2 and .workers == 2" >/dev/null' "$out"
check "...and the run is open" '[ -f .factory/run.lock ] && git rev-parse HEAD | grep -q "^$(jq -r .start_head .factory/run.lock)" && [ "$(printf "%s" "$out" | jq -r .base)" = new ]' "$out"
base="$(jq -r .start_head .factory/run.lock)"
echo "work" > core/src/w.src; git add core/src/w.src; git commit -qm "a task landed before the run stopped"
out="$(factory-preflight --json 2>&1)"
check "a second preflight of the same run keeps its base (kill -9, then /factory:run again)" '[ "$(printf "%s" "$out" | jq -r .base)" = kept ] && [ "$(jq -r .start_head .factory/run.lock)" = "$base" ] && [ "$(jq -r .restarts .factory/run.lock)" = 1 ]' "$out"
rm -f .factory/run.lock
out="$(factory-preflight --json 2>&1)"
check "once the run closed, the next one starts from HEAD" '[ "$(printf "%s" "$out" | jq -r .base)" = new ] && [ "$(jq -r .start_head .factory/run.lock)" != "$base" ] && git rev-parse HEAD | grep -q "^$(jq -r .start_head .factory/run.lock)"' "$out"

echo "x" > .factory/STOP
out="$(factory-preflight --json 2>&1)"; rc=$?
check "STOP: not ok, nothing to start" '[ $rc -eq 1 ] && printf "%s" "$out" | jq -e ".ok == false and (.problems | join(\" \") | test(\"HALTED\"))" >/dev/null' "$out"
rm -f .factory/STOP

newproj route
sed -i.bak 's/^needs_human: false/needs_human: true/' tasks/backlog/C1-01.md && rm -f tasks/backlog/C1-01.md.bak
printf -- '---\nid: C1-04\ntitle: broken\n---\nno sections\n' > tasks/backlog/C1-04.md
git add -A; git commit -qm "approved"
out="$(factory-preflight --json 2>&1)"
check "a needs_human task is blocked and asked, not planned" '[ "$(lane C1-01)" = blocked ] && ! printf "%s" "$out" | jq -e ".tasks[] | select(.id == \"C1-01\")" >/dev/null && factory-ask list 2>/dev/null | grep -q "C1-01"' "$out"
check "a task that does not lint is blocked and asked" '[ "$(lane C1-04)" = blocked ] && factory-ask list 2>/dev/null | grep -q "C1-04"' "$out"
q="$(factory-ask list 2>/dev/null | grep "C1-01" | grep -o "Q[0-9]*" | head -1)"
factory-ask answer "$q" "use the tenant id from the session" >/dev/null 2>&1
rm -f .factory/run.lock
out="$(factory-preflight --json 2>&1)"
check "an answered question puts the task back, with the answer in its file" '[ "$(lane C1-01)" = backlog ] && grep -q "^## Developer answer ($q)" tasks/backlog/C1-01.md && grep -q "^needs_human: false" tasks/backlog/C1-01.md && printf "%s" "$out" | jq -e ".tasks[] | select(.id == \"C1-01\")" >/dev/null' "$out"
out2="$(factory-preflight --json 2>&1)"
check "...once: the question is consumed" '[ "$(grep -c "^## Developer answer" tasks/backlog/C1-01.md)" = 1 ]' "$out2"

echo "=== factory-preflight: headless needs the workflow allowed"
newproj headless
mkdir -p "$WORK/s13-home"
out="$(HOME="$WORK/s13-home" USERPROFILE="$WORK/s13-home" FACTORY_HEADLESS=1 factory-preflight --json 2>&1)"
check "a headless run without the allow rule is warned" 'printf "%s" "$out" | jq -e ".warnings | join(\" \") | test(\"Workflow\\\\(factory:loop\\\\)\")" >/dev/null' "$out"
rm -f .factory/run.lock
mkdir -p .claude; echo '{"permissions":{"allow":["Workflow(factory:loop)"]}}' > .claude/settings.json
out="$(HOME="$WORK/s13-home" USERPROFILE="$WORK/s13-home" FACTORY_HEADLESS=1 factory-preflight --json 2>&1)"
check "...and not once the project allows it" '! printf "%s" "$out" | jq -e ".warnings | join(\" \") | test(\"Workflow\")" >/dev/null' "$out"

echo "=== factory-finish: one line, or the JSON"
newproj finish
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
factory-preflight --json >/dev/null 2>&1
settle C1-01 "CHECK RESULT: GREEN" >/dev/null
out="$(factory-finish --tasks C1-01 2>&1 | tail -1)"
check "finish prints one line" 'printf "%s" "$out" | grep -q "^FINISH 1/1 landed;.*full check green.*report .factory/last-run.md$"' "$out"
check "...and closes the run" '[ ! -f .factory/run.lock ]'
factory-preflight --json >/dev/null 2>&1
out="$(factory-finish --tasks C1-01,C1-02 --no-full --halted "infra: two agents returned nothing" --json 2>&1)"
check "--json prints the object" 'printf "%s" "$out" | jq -e ".halted" >/dev/null' "$out"
check "a halted run keeps its lock, marked halted" '[ "$(jq -r .state .factory/run.lock)" = halted ]'

echo "=== letters that are not ASCII"
# Windows decodes text in its ANSI code page unless told otherwise: cp1254 on a
# Turkish system cannot decode Ş or Ğ written as UTF-8, and preflight died
# reading the task file back from git. Á and ō fail cp1252 the same way.
newproj tr
TR='Şirket ödemesi: Ğğ Şş İı çöü — Á ō → ✓'
sed -i.bak "s/^title: task C1-01\$/title: ${TR}/" tasks/backlog/C1-01.md && rm -f tasks/backlog/C1-01.md.bak
printf '\n## Notes\n%s\n' "$TR" >> tasks/backlog/C1-01.md
git add -A; git commit -qm "$TR"
out="$(factory-preflight --json 2>&1)"; rc=$?
check "preflight reads a committed task written in Turkish" '[ $rc -eq 0 ] && printf "%s" "$out" | jq -e ".ok" >/dev/null' "$out"
build C1-01 core/src/a.src core/tests/a.t
factory-check C1-01 >/dev/null 2>&1
out="$(settle C1-01 "CHECK RESULT: GREEN - ${TR}")"
check "...it checks and lands" 'printf "%s" "$out" | grep -qE "^SETTLED C1-01 LANDED [0-9a-f]{7,}$"' "$out"
check "...with its title intact in the commit" '[ "$(git log -1 --format=%s)" = "C1-01: ${TR}" ]' "$(git log -1 --format=%s)"
out="$(factory-finish --tasks C1-01 --json 2>&1)"
check "...and the run finishes, its JSON intact" 'printf "%s" "$out" | jq -e ".done | index(\"C1-01\")" >/dev/null 2>&1 || printf "%s" "$out" | jq -e . >/dev/null' "$(printf "%s" "$out" | tail -5)"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
