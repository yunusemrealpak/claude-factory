#!/usr/bin/env bash
# Sandbox tests: lessons that keep their shape, and rules with teeth (3.6) -
# factory-lesson add/update/check (category, retire_when, the overlap check),
# factory-retro-apply applying a rule (and what it refuses, and its caps), a
# rewording and a retirement, and the retro digest's view of both. The hooks
# module's side of the rules and the stuck check is in mod.test.ts. Never
# touches a real project.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$H/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

NOW="$(date +%s)"
newproj() {
  P="$WORK/s19-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main . 2>/dev/null; git config user.email dev@example.com; git config user.name dev; git config core.autocrlf false
  mkdir -p .factory/failures/resolved .factory/retro .factory/lessons tasks/done src/api
  : > .factory/active
  printf '.factory/\n' > .gitignore
  echo '{"retry_limit":2,"retro":{"mode":"full","min_sample":4}}' > .factory/config.json
  for t in C2-01 C2-02 C2-03; do printf -- '---\nid: %s\nmodule: orders\n---\n' "$t" > "tasks/done/$t.md"; done
  printf 'GATE test: FAIL\n' > .factory/failures/sig-abcdef123456.txt
  printf 'x\n' > src/api/routes.ts
  git add -A; git commit -qm base
  export FACTORY_ROOT="$P"
}
lesson() { bash "$H/factory-lesson.sh" "$@" 2>&1; }
prop() { printf '{"proposals":[%s]}\n' "$1" > .factory/retro/p.json; }
apply() { python3 "$H/factory-retro-apply.py" apply .factory/retro/p.json --date 2026-10-25 2>&1; }
mrun() { printf '{"ts":%s,"tasks":%s,"landed":%s,"first_try_green":%s,"stalled":0,"usd_total":1.0}\n' "$1" "$2" "$2" "$3" >> .factory/metrics.jsonl; }
past() {  # every ledger line applied a day ago, so later runs count as after
  python3 - "$NOW" <<'PY'
import json, sys
rows = [json.loads(l) for l in open('.factory/retro/ledger.jsonl')]
for r in rows:
    r['applied_at'] = int(sys.argv[1]) - 86400
open('.factory/retro/ledger.jsonl', 'w').write('\n'.join(json.dumps(r) for r in rows) + '\n')
PY
}
LF=.factory/lessons/orders.md
nl_of() { local n; n="$(grep -c '^- ' "$1" 2>/dev/null)"; echo "${n:-0}"; }
mkdir -p "$WORK"

echo "=== lessons: category and retire_when"
newproj shape
out="$(lesson add orders C2-01 'Run `dotnet test --filter Category!=Integration` unless the compose db is up.' --category test)"; rc=$?
check "a category goes inside the bracket, before added" '[ $rc -eq 0 ] && grep -q "^- Run .dotnet test --filter Category!=Integration. unless the compose db is up\. \[evidence: C2-01; category: test; added: 20[0-9-]*T[0-9:]*Z\]$" $LF' "$out $(cat $LF)"
out="$(lesson add orders C2-01 'Something about speed.' --category speed)"; rc=$?
check "a category off the list is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "category must be one of: build test tooling convention environment dependency"' "$out"
out="$(lesson add orders C2-02 'Register new handlers in src/api/routes.ts.' --category convention --retire-when src/api/routes.ts)"; rc=$?
check "retire_when is kept, before added" '[ $rc -eq 0 ] && grep -q "^- Register new handlers in src/api/routes.ts\. \[evidence: C2-02; category: convention; retire_when: src/api/routes.ts; added: [0-9TZ:-]*\]$" $LF' "$out $(cat $LF)"
out="$(lesson add orders C2-01 'Mind the old importer.' --retire-when src/nope.ts)"; rc=$?
check "a retire_when path that is not there is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no such path"' "$out"
out="$(lesson add orders C2-01 'Mind the old importer.' --retire-when ../outside)"; rc=$?
check "a retire_when outside the project is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "inside the project"' "$out"
HEAD12="$(git rev-parse HEAD | cut -c1-12)"
out="$(lesson add orders C2-03 'The fixture loader was replaced; seed with the new one.' --category test --retire-when "$HEAD12")"; rc=$?
check "a reachable sha is a retire_when" '[ $rc -eq 0 ] && grep -q "retire_when: $HEAD12; added:" $LF' "$out"
out="$(lesson add orders C2-03 'Watch the cache warmup.' --retire-when 0123456789abcdef)"; rc=$?
check "a sha HEAD does not reach is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no commit reachable"' "$out"
out="$(lesson add orders C2-01 'Use the seeded clock in tests.')"; rc=$?
check "without options a line is as it always was" '[ $rc -eq 0 ] && grep -q "^- Use the seeded clock in tests\. \[evidence: C2-01; added: [0-9TZ:-]*\]$" $LF' "$out"
out="$(lesson add orders C2-01 'one' 'two')"; rc=$?
check "a lesson in pieces is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "too many arguments"' "$out"

echo "=== lessons: the overlap check"
before="$(nl_of $LF)"
out="$(lesson add orders C2-03 'Start the compose db before `dotnet test` runs the integration suite.' --category test)"; rc=$?
check "same category and command overlap" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "overlaps lesson 1 of orders.md (same module, same category test, same command dotnet test"' "$out"
check "...and the refusal names the update" 'printf "%s" "$out" | grep -q "factory-lesson update orders 1 C2-03"' "$out"
check "...and the file is unchanged" '[ "$(nl_of $LF)" -eq "$before" ]'
out="$(lesson add orders C2-03 'Run dotnet test --filter Category!=Integration unless the compose db is up!')"; rc=$?
check "the same words, nothing else alike, overlap" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "overlaps lesson 1 .*100% the same words"' "$out"
out="$(lesson add orders C2-03 'Keep src/api/routes.ts sorted by path.' --category convention)"; rc=$?
check "same category and path overlap" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "overlaps lesson 2 .*same path src/api/routes.ts"' "$out"
out="$(lesson add orders C2-03 'Keep src/api/routes.ts sorted by path.' --category tooling)"; rc=$?
check "a path in common alone is no overlap" '[ $rc -eq 0 ]' "$out"
out="$(lesson add orders C2-03 'lesson number 2')"; rc1=$?
out2="$(lesson add orders C2-03 'lesson number 3')"; rc2=$?
check "lessons that differ in one number both go in" '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]' "$out $out2"
out="$(lesson add orders C2-01 'Use the seeded clock in tests.')"; rc=$?
check "a duplicate still says already" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "already"' "$out"
printf '# Lessons: general\n\n- Register handlers in Startup.cs. [evidence: C2-01, sig-abcdef123456; added: 2026-09-11T00:00:00Z]\n' > .factory/lessons/general.md
out="$(lesson add general C2-02 'Register the handlers in Startup.cs!')"; rc=$?
check "a line from before categories is compared too" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "overlaps lesson 1 of general.md"' "$out"

echo "=== lessons: update"
out="$(lesson update orders 1 C2-02 'Run `dotnet test --filter Category!=Integration` unless the compose database is up.')"; rc=$?
line1="$(grep '^- ' $LF | sed -n 1p)"
check "update rewords in place" '[ $rc -eq 0 ] && printf "%s" "$line1" | grep -q "^- Run .dotnet test --filter Category!=Integration. unless the compose database is up\. \["' "$out $line1"
check "...the evidence is the old and the new" 'printf "%s" "$line1" | grep -q "\[evidence: C2-01, C2-02; category: test; added: "' "$line1"
check "...it says what it was" 'printf "%s" "$out" | grep -q "^LESSON updated in .factory/lessons/orders.md: 1 was: - Run .dotnet test --filter Category!=Integration. unless the compose db is up\."' "$out"
check "...and the count is the same" '[ "$(nl_of $LF)" -eq "$((before + 3))" ]' "$(cat $LF)"
out="$(lesson update orders 1 C2-01 'Register new handlers in src/api/routes.ts!' --category convention)"; rc=$?
check "an update that overlaps another lesson is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "overlaps lesson 2"' "$out"
out="$(lesson update general 1 C2-02 'Register handlers in Startup.cs.' --category convention)"; rc=$?
check "an old line gets a category" '[ $rc -eq 0 ] && grep -q "^- Register handlers in Startup.cs\. \[evidence: C2-01, sig-abcdef123456, C2-02; category: convention; added: " .factory/lessons/general.md' "$out $(cat .factory/lessons/general.md)"
out="$(lesson update orders 99 C2-01 'x')"; rc=$?
check "an update of a lesson that is not there is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "has lessons 1\.\."' "$out"
out="$(lesson update orders 1 C9-99 'x')"; rc=$?
check "an update needs evidence on disk" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "evidence C9-99"' "$out"

echo "=== lessons: check"
out="$(lesson check)"; rc=$?
check "nothing gone, nothing to retire" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^CHECK OK: 2 lesson(s) name a retire_when, none is gone$"' "$out"
rm src/api/routes.ts
printf -- '- Keep the shim from the hotfix. [evidence: C2-01; category: build; retire_when: deadbeefdeadbeef0000; added: 2026-09-11T00:00:00Z]\n' >> .factory/lessons/general.md
out="$(lesson check)"; rc=$?
check "a path that is gone is flagged" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "^RETIRE orders 2 path:src/api/routes.ts is gone: Register new handlers in src/api/routes.ts\.$"' "$out"
check "a sha HEAD does not reach is flagged" 'printf "%s" "$out" | grep -q "^RETIRE general 2 sha:deadbeefdeadbeef0000 is gone: Keep the shim from the hotfix\.$"' "$out"
check "a sha HEAD reaches is not" '! printf "%s" "$out" | grep -q "$HEAD12"' "$out"
check "the count of what to retire" 'printf "%s" "$out" | grep -q "^CHECK: 2 lesson(s) to retire"' "$out"
out="$(lesson check general)"; rc=$?
check "check takes a module" '[ $rc -eq 1 ] && ! printf "%s" "$out" | grep -q "RETIRE orders"' "$out"
check "list still numbers every lesson" 'lesson list orders | grep -q "^ 2 - Register new handlers"'

echo "=== retro-apply: rules"
newproj rules
prop '{"id":"P1","kind":"rule","name":"pnpm-only","match":"bash","pattern":"(^|[\\s;&|])npm\\s+install","action":"warn","message":"This repo uses pnpm; npm install rewrites the lockfile.","evidence":"C2-03,sig-abcdef123456","metric":"first_pass_green"},
{"id":"P2","kind":"rule","name":"no-legacy","match":"path","pattern":"^src/legacy/","action":"block","message":"src/legacy is frozen; new code goes under src/core.","evidence":"C2-01","metric":"first_pass_green"},
{"id":"P3","kind":"rule","name":"no-console","match":"content","pattern":"console\\.log\\(","action":"warn","message":"Use the logger.","evidence":"C2-01","metric":"first_pass_green"}'
out="$(apply)"
R=.factory/rules/pnpm-only.rule
check "a rule is applied" 'printf "%s" "$out" | grep -q "RETRO APPLIED 2026-10-25/P1 rule (first_pass_green)" && [ -f $R ]' "$out"
check "...its file holds every field" 'grep -qx "match: bash" $R && grep -qxF "pattern: (^|[\s;&|])npm\s+install" $R && grep -qx "action: warn" $R && grep -qx "evidence: C2-03, sig-abcdef123456" $R && grep -qx "message: This repo uses pnpm; npm install rewrites the lockfile." $R && grep -q "^added: 20" $R' "$(cat $R 2>/dev/null)"
check "...and says who wrote it" 'grep -q "^# Factory rule, applied by factory-retro-apply (2026-10-25/P1)" $R'
check "two rules per retrospective, not three" 'printf "%s" "$out" | grep -q "RETRO APPLIED 2026-10-25/P2 rule" && printf "%s" "$out" | grep -q "RETRO REJECTED 2026-10-25/P3: at most 2 rules per retrospective" && [ ! -e .factory/rules/no-console.rule ]' "$out"
check "the ledger can take it back" 'jq -e "select(.id==\"2026-10-25/P1\" and .status==\"applied\" and .undo.kind==\"rule\" and .undo.name==\"pnpm-only\")" .factory/retro/ledger.jsonl >/dev/null'
refused() {  # <what> <proposal json> <reason text>
  prop "$2"; out="$(apply)"
  check "refused: $1" 'printf "%s" "$out" | grep -q "RETRO REJECTED" && printf "%s" "$out" | grep -qF "$3"' "$out"
}
RB='"kind":"rule","action":"warn","message":"m","evidence":"C2-01","metric":"first_pass_green"'
refused "a pattern that matches everything" "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"bash\",\"pattern\":\".*\",$RB}" "so it would match every call"
refused "a pattern that matches settling"   "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"bash\",\"pattern\":\"settle\",$RB}" "may never stand in the way of checking or settling"
refused "a pattern that matches a task file" "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"path\",\"pattern\":\"\\\\.md\$\",$RB}" "tasks/in-progress/T1.md"
refused "an inline flag"                    "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"bash\",\"pattern\":\"(?i)npm\",$RB}" "JavaScript reads otherwise"
refused "a POSIX class"                     "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"bash\",\"pattern\":\"npm[[:space:]]install\",$RB}" "JavaScript reads otherwise"
refused "a pattern that is no regex"        "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"bash\",\"pattern\":\"(npm\",$RB}" "not a regex"
refused "a match off the list"              "{\"id\":\"P1\",\"name\":\"r1\",\"match\":\"shell\",\"pattern\":\"npm\",$RB}" "match must be bash, path or content"
refused "an action off the list"            '{"id":"P1","kind":"rule","name":"r1","match":"bash","pattern":"npm","action":"halt","message":"m","evidence":"C2-01","metric":"first_pass_green"}' "action must be warn or block"
refused "a name with spaces"                "{\"id\":\"P1\",\"name\":\"Bad Name\",\"match\":\"bash\",\"pattern\":\"npm\",$RB}" "name is lower-case"
refused "evidence that is not on disk"      '{"id":"P1","kind":"rule","name":"r1","match":"bash","pattern":"npm","action":"warn","message":"m","evidence":"C9-99","metric":"first_pass_green"}' "evidence C9-99"
refused "a message that bypasses the gate"  '{"id":"P1","kind":"rule","name":"r1","match":"bash","pattern":"npm","action":"warn","message":"commit with --no-verify","evidence":"C2-01","metric":"first_pass_green"}' "bypass the gate"
refused "a rule with no metric"             '{"id":"P1","kind":"rule","name":"r1","match":"bash","pattern":"npm","action":"warn","message":"m","evidence":"C2-01"}' "metric must be one of"
refused "a name already in force"           "{\"id\":\"P1\",\"name\":\"pnpm-only\",\"match\":\"bash\",\"pattern\":\"yarn\",$RB}" "already in force"
for i in 3 4 5 6 7 8 9 10; do printf 'name: r%s\nmatch: bash\npattern: tool%s\naction: warn\nmessage: m\n' "$i" "$i" > ".factory/rules/r$i.rule"; done
refused "an eleventh rule"                  "{\"id\":\"P1\",\"name\":\"r11\",\"match\":\"bash\",\"pattern\":\"yarn\",$RB}" "holds 10 rules"

echo "=== retro-apply: a rule that did not help is taken back"
newproj rulerev
mrun "$((NOW - 5*86400))" 10 8
prop '{"id":"P1","kind":"rule","name":"pnpm-only","match":"bash","pattern":"npm\\s+install","action":"block","message":"Use pnpm.","evidence":"C2-01","metric":"first_pass_green"}'
apply >/dev/null
past
mrun "$((NOW - 3600))" 5 1
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "a worse first-pass rate deletes the rule" 'printf "%s" "$out" | grep -q "REVERTED 2026-10-25/P1" && [ ! -e .factory/rules/pnpm-only.rule ]' "$out"

echo "=== retro-apply: lessons with shape, rewording, retiring"
newproj lessons
prop '{"id":"P1","kind":"lesson","module":"orders","evidence":"C2-01","text":"Register new handlers in src/api/routes.ts.","category":"convention","retire_when":"src/api/routes.ts","metric":"first_pass_green"},
{"id":"P2","kind":"lesson","module":"orders","evidence":"C2-02","text":"Add each new handler to src/api/routes.ts in order.","category":"convention","metric":"first_pass_green"},
{"id":"P3","kind":"lesson","module":"orders","evidence":"C2-03","text":"Seed the fixture before the integration tests.","category":"cleverness","metric":"first_pass_green"}'
out="$(apply)"
check "a lesson goes in with its category and retire_when" 'printf "%s" "$out" | grep -q "RETRO APPLIED 2026-10-25/P1 lesson" && grep -q "^- Register new handlers in src/api/routes.ts\. \[evidence: C2-01; category: convention; retire_when: src/api/routes.ts; added: " $LF' "$out"
check "an overlapping lesson is refused, naming the one to reword" 'printf "%s" "$out" | grep -q "RETRO REJECTED 2026-10-25/P2: .*overlaps lesson 1 of orders.md"' "$out"
check "a category off the list is refused" 'printf "%s" "$out" | grep -q "RETRO REJECTED 2026-10-25/P3: .*category must be one of"' "$out"
prop '{"id":"P4","kind":"lesson","module":"orders","evidence":"C2-02","text":"Register every new handler in src/api/routes.ts, in order.","replaces":"Register new handlers in src/api/routes.ts.","metric":"first_pass_green"},
{"id":"P5","kind":"lesson","module":"orders","evidence":"C2-02","text":"x","replaces":"No such lesson.","metric":"first_pass_green"}'
out="$(apply)"
check "replaces rewords the lesson in force" 'printf "%s" "$out" | grep -q "RETRO APPLIED 2026-10-25/P4 lesson" && grep -q "^- Register every new handler in src/api/routes.ts, in order\. \[evidence: C2-01, C2-02; category: convention; retire_when: src/api/routes.ts; added: " $LF && [ "$(nl_of $LF)" -eq 1 ]' "$out $(cat $LF)"
check "replaces names a lesson that is there" 'printf "%s" "$out" | grep -q "RETRO REJECTED 2026-10-25/P5: no lesson of orders.md reads"' "$out"
check "the ledger keeps the old line to restore" 'jq -e "select(.id==\"2026-10-25/P4\" and (.undo.old_line | startswith(\"- Register new handlers in src/api/routes.ts. [\")))" .factory/retro/ledger.jsonl >/dev/null'
prop '{"id":"P6","kind":"lesson_retire","module":"orders","text":"Register every new handler in src/api/routes.ts, in order."}'
out="$(apply)"
check "a lesson whose path is still there is not retired" 'printf "%s" "$out" | grep -q "RETRO REJECTED 2026-10-25/P6: factory-lesson check does not flag that lesson" && [ "$(nl_of $LF)" -eq 1 ]' "$out"
rm src/api/routes.ts
out="$(apply)"
check "once the path is gone, it is retired" 'printf "%s" "$out" | grep -q "RETRO RETIRED 2026-10-25/P6 lesson of orders: path:src/api/routes.ts is gone" && [ "$(nl_of $LF)" -eq 0 ]' "$out"
check "...counted as applied, without a metric" 'printf "%s" "$out" | grep -q "RETRO DONE: 1 applied of 1 proposed" && jq -e "select(.id==\"2026-10-25/P6\" and .status==\"retired\" and (.undo.line | startswith(\"- Register every new handler\")))" .factory/retro/ledger.jsonl >/dev/null' "$out"
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "a retirement is not judged by evaluate" '! printf "%s" "$out" | grep -q "P6"' "$out"

echo "=== retro-apply: a reworded lesson that did not help gets its old line back"
newproj reword
mrun "$((NOW - 5*86400))" 10 8
lesson add orders C2-01 'Seed the fixture before the integration tests.' --category test >/dev/null
old="$(grep '^- ' $LF)"
prop '{"id":"P1","kind":"lesson","module":"orders","evidence":"C2-02","text":"Seed the fixture with the new loader before the integration tests run.","replaces":"Seed the fixture before the integration tests.","metric":"first_pass_green"}'
apply >/dev/null
past
mrun "$((NOW - 3600))" 5 1
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "the old line is restored" 'printf "%s" "$out" | grep -q "REVERTED 2026-10-25/P1" && [ "$(grep "^- " $LF)" = "$old" ]' "$out $(cat $LF)"

echo "=== the retro digest"
newproj digest
lesson add orders C2-01 'Register new handlers in src/api/routes.ts.' --category convention --retire-when src/api/routes.ts >/dev/null
rm src/api/routes.ts
mkdir -p .factory/rules
printf '# x\nname: pnpm-only\nmatch: bash\npattern: npm install\naction: warn\nmessage: Use pnpm.\nevidence: C2-01\nadded: 2026-10-20T00:00:00Z\n' > .factory/rules/pnpm-only.rule
{
  echo '{"ts":"2026-10-21T00:00:00Z","kind":"lesson_rule","task":"C2-02","rule":"pnpm-only","outcome":"warn","tool":"Bash"}'
  echo '{"ts":"2026-10-21T00:01:00Z","kind":"lesson_rule","task":"C2-02","rule":"pnpm-only","outcome":"warn","tool":"Bash"}'
  echo '{"ts":"2026-10-21T00:02:00Z","kind":"stuck","task":"C2-03","outcome":"warn","pattern":"error","what":"npm test failed the same way 3 times in a row"}'
} > .factory/events.jsonl
out="$(bash "$H/factory-retro.sh" 2>&1)"
check "the digest lists the lessons to retire" 'printf "%s" "$out" | sed -n "/## Lessons to retire/,/## Rules in force/p" | grep -q "^RETIRE orders 1 path:src/api/routes.ts is gone"' "$(printf "%s" "$out" | sed -n "/Lessons to retire/,/Decisions/p")"
check "the digest lists the rules and how often they fired" 'printf "%s" "$out" | grep -q "^- pnpm-only: warn bash /npm install/ - Use pnpm. \[evidence: C2-01; added: 2026-10-20T00:00:00Z\]" && printf "%s" "$out" | grep -q "fired: 2 warn, 0 block" && printf "%s" "$out" | grep -q "(1/10 rules)"' "$(printf "%s" "$out" | sed -n "/Rules in force/,/Decisions/p")"
check "the digest lists stuck builders" 'printf "%s" "$out" | grep -q "C2-03 warn: npm test failed the same way 3 times in a row"' "$(printf "%s" "$out" | sed -n "/Rules in force/,/Decisions/p")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
