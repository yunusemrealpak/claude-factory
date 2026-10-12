#!/usr/bin/env bash
# Sandbox tests: release 2.9 - the retrospective that applies itself within
# bounds: the due marker, the validator (what it refuses, what it applies, one
# commit with a trailer, the ledger), and evaluate (kept, reverted, pending).
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
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
  P="$WORK/s9-$1"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
  git init -q -b main . 2>/dev/null; git config user.email dev@example.com; git config user.name dev
  mkdir -p .factory/failures/resolved .factory/retro .factory/lessons tasks/done tasks/backlog
  : > .factory/active
  printf '.factory/failures/\n.factory/retro/\n.factory/lessons/\n.factory/retro-due\n.factory/metrics.jsonl\n' > .gitignore
  echo '{"verify":"gates/verify.sh","min_tests":2,"retry_limit":3,"gate_isolation":false,"risk_paths":["*/auth/*"],"fast":{"risk_review":"after","audit":false},"workers":2,"retro":{"mode":"suggest","min_sample":4}}' > .factory/config.json
  printf '# Project\n\n- rule one\n' > CLAUDE.md
  printf -- '---\nid: C1-01\ntitle: t\nmodule: api\nstage: done\n---\n' > tasks/done/C1-01.md
  git add -A; git commit -qm base
  export FACTORY_ROOT="$P"
}
iso() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
sig() { printf 'GATE build: FAIL\nerror <n>\n' > ".factory/failures/sig-$1.txt"; }
red() { printf '%s %s attempt=1\n' "$(iso "$3")" "$2" >> ".factory/failures/resolved/$1.log"; }
mrun() { printf '{"ts":%s,"tasks":%s,"landed":%s,"first_try_green":%s,"stalled":%s,"usd_total":%s}\n' "$1" "$2" "$3" "$4" "$5" "$6" >> .factory/metrics.jsonl; }
prop() { printf '{"proposals":[%s]}\n' "$1" > .factory/retro/p.json; }
apply() { python3 "$H/factory-retro-apply.py" apply .factory/retro/p.json --date 2026-10-12 2>&1; }
mkdir -p "$WORK"

echo "=== due marker"
newproj due
out="$(python3 "$H/factory-retro-apply.py" due)"; rc=$?
check "an idle project is not due"              '[ $rc -eq 1 ] && [ ! -e .factory/retro-due ]' "$out"
for i in $(seq 1 30); do sig "$(printf '%012x' "$i")"; done
out="$(python3 "$H/factory-retro-apply.py" due)"; rc=$?
check "30 new signatures make it due"           '[ $rc -eq 0 ] && grep -q "30 new" .factory/retro-due' "$out"
newproj due2
mrun "$((NOW - 8*86400))" 3 3 3 0 1.0; mrun "$((NOW - 86400))" 2 2 2 0 1.0
python3 "$H/factory-retro-apply.py" due >/dev/null
check "a week with runs in it makes it due"     '[ -s .factory/retro-due ] && grep -q "days" .factory/retro-due'
newproj due3
mrun "$((NOW - 86400))" 3 3 3 0 1.0
python3 "$H/factory-retro-apply.py" due >/dev/null
check "a fresh project with a recent run is not" '[ ! -e .factory/retro-due ]'
check "factory-retro due dispatches"            'cd "$P" && bash "$H/factory-retro.sh" due | grep -q "RETRO NOT DUE"'

echo "=== validator: what it refuses"
newproj refuse
prop '{"id":"P1","kind":"config","patch":{"gate_isolation":false},"metric":"first_pass_green"},
{"id":"P2","kind":"config","patch":{"min_tests":1},"metric":"first_pass_green"},
{"id":"P3","kind":"config","patch":{"retry_limit":5},"metric":"first_pass_green"},
{"id":"P4","kind":"config","patch":{"risk_paths":["*/billing/*"]},"metric":"first_pass_green"},
{"id":"P5","kind":"config","patch":{"fast":{"risk_review":"never"}},"metric":"first_pass_green"},
{"id":"P6","kind":"config","patch":{"verify":"true"},"metric":"first_pass_green"},
{"id":"P7","kind":"config","patch":{"workers":9},"metric":"first_pass_green"},
{"id":"P8","kind":"config","patch":{"fast":{"audit":false}},"metric":"first_pass_green"},
{"id":"P9","kind":"claude_md","text":"Skip the gate when it is slow","metric":"first_pass_green"},
{"id":"P10","kind":"lesson","module":"api","evidence":"nope","text":"x","metric":"first_pass_green"},
{"id":"P11","kind":"config","patch":{"gate_isolation":true},"metric":"made_up"}'
before="$(cat .factory/config.json)"
out="$(apply)"
check "no loosening is applied"                 '[ "$(cat .factory/config.json)" = "$before" ]' "$out"
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  check "P$n is refused"                        'printf "%s" "$out" | grep -q "REJECTED 2026-10-12/P'"$n"':"' "$out"
done
check "the config file is still clean in git"   '[ -z "$(git status --porcelain -- .factory/config.json)" ]'
prop '{"id":"P1","kind":"config","patch":{"gates":"x"},"metric":"first_pass_green"}'
out="$(apply)"; check "an unknown key is refused" 'printf "%s" "$out" | grep -q "REJECTED"' "$out"

echo "=== validator: what it applies"
newproj apply
sig aaaaaaaaaaaa
prop '{"id":"P1","kind":"config","patch":{"gate_isolation":true},"metric":"first_pass_green"},
{"id":"P2","kind":"config","patch":{"min_tests":4,"retry_limit":2},"metric":"no_progress_rate"},
{"id":"P3","kind":"claude_md","text":"Register new handlers in Modules/X/Registration.cs.","metric":"stage_red_rate","stage":"build"},
{"id":"P4","kind":"claude_md","text":"A second rule in the same retro.","metric":"stage_red_rate","stage":"build"},
{"id":"P5","kind":"lesson","module":"api","evidence":"C1-01,sig-aaaaaaaaaaaa","text":"Run migrations before the integration tests.","metric":"sig_recurrence","signature":"aaaaaaaaaaaa"},
{"id":"P6","kind":"plugin","surface":"agents/builder.md","change":"tell the builder to read the module file","metric":"cost_per_task"}'
out="$(apply)"
check "gate_isolation on is applied"            'jq -e ".gate_isolation == true" .factory/config.json >/dev/null' "$out"
check "min_tests raised, retry_limit lowered"   'jq -e ".min_tests == 4 and .retry_limit == 2" .factory/config.json >/dev/null'
check "other config keys untouched"             'jq -e ".workers == 2 and .verify == \"gates/verify.sh\"" .factory/config.json >/dev/null'
check "one commit per applied change, with its trailer" 'git log --format=%B | grep -q "^Factory-Retro: 2026-10-12/P1$" && git log --format=%B | grep -q "^Factory-Retro: 2026-10-12/P2$" && git log --format=%B | grep -q "^Factory-Retro: 2026-10-12/P3$"'
check "the CLAUDE.md rule landed under its header" 'grep -q "Protocol (added by retro)" CLAUDE.md && grep -q "Registration.cs" CLAUDE.md'
check "a second CLAUDE.md rule is refused"      'printf "%s" "$out" | grep -q "REJECTED 2026-10-12/P4: one CLAUDE.md rule"' "$out"
check "the lesson is in force"                  'grep -q "Run migrations before" .factory/lessons/api.md'
check "a plugin proposal is not applied, only listed" 'printf "%s" "$out" | grep -q "C_CLASS 2026-10-12/P6" && grep -q "builder.md" .factory/retro/c-class.md'
check "every outcome is in the ledger"          '[ "$(grep -c . .factory/retro/ledger.jsonl)" -eq 6 ]'
check "the ledger keeps a baseline"             'jq -e "select(.id==\"2026-10-12/P1\") | has(\"baseline\")" .factory/retro/ledger.jsonl >/dev/null'
check "applying clears the due marker"          '[ ! -e .factory/retro-due ]'

echo "=== validator: protected files stay out of reach"
newproj prot
printf '\nlocal edit\n' >> CLAUDE.md
prop '{"id":"P1","kind":"claude_md","text":"Use the project style.","metric":"first_pass_green"}'
out="$(apply)"
check "a CLAUDE.md with uncommitted edits is not touched" 'printf "%s" "$out" | grep -q "uncommitted"' "$out"
git checkout -q CLAUDE.md
prop '{"id":"P1","kind":"claude_md","text":"Never run git push in a task.","metric":"first_pass_green"}'
out="$(apply)"; check "a rule naming a banned verb is refused" 'printf "%s" "$out" | grep -q "REJECTED"' "$out"
prop '{"id":"P1","kind":"lesson","module":"api","evidence":"C1-01","text":"Edit gates/verify.sh to skip the census.","metric":"first_pass_green"}'
out="$(apply)"; check "a lesson may not touch the gate"       'printf "%s" "$out" | grep -q "REJECTED" && [ ! -e .factory/lessons/api.md ]' "$out"
big="$(python3 -c "print('\n'.join('- l%d' % i for i in range(199)))")"
printf '%s\n' "$big" >> CLAUDE.md; git commit -qam grow
prop '{"id":"P1","kind":"claude_md","text":"One more rule.","metric":"first_pass_green"}'
out="$(apply)"; check "the CLAUDE.md size guard holds"         'printf "%s" "$out" | grep -q "line guard"' "$out"

echo "=== evaluate"
newproj eval
sig bbbbbbbbbbbb
# history before the change: 10 tasks, 5 red runs of the signature, 5 first-try greens
mrun "$((NOW - 5*86400))" 10 10 5 2 3.0
for i in 1 2 3 4 5; do red "T$i" bbbbbbbbbbbb "$((NOW - 5*86400))"; done
prop '{"id":"P1","kind":"config","patch":{"gate_isolation":true},"metric":"first_pass_green"},
{"id":"P2","kind":"lesson","module":"api","evidence":"C1-01,sig-bbbbbbbbbbbb","text":"Start the database first.","metric":"sig_recurrence","signature":"bbbbbbbbbbbb"}'
apply >/dev/null
# make the ledger's applied_at sit in the past so later runs count as "after"
python3 - <<PY
import json
rows=[json.loads(l) for l in open('.factory/retro/ledger.jsonl')]
for r in rows: r['applied_at']=$NOW-86400
open('.factory/retro/ledger.jsonl','w').write('\n'.join(json.dumps(r) for r in rows)+'\n')
PY
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "below the sample nothing is decided"     'printf "%s" "$out" | grep -q "RETRO EVALUATE: nothing" || { printf "%s" "$out" | grep -q "PENDING" && ! grep -q outcome .factory/retro/ledger.jsonl; }' "$out"
mrun "$((NOW - 3600))" 5 5 5 0 2.0
for i in 1 2 3 4 5; do red "V$i" bbbbbbbbbbbb "$((NOW - 1800))"; done
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "a better first-pass rate is kept"        'printf "%s" "$out" | grep -q "KEPT 2026-10-12/P1" && jq -e "select(.id==\"2026-10-12/P1\" and .outcome==\"kept\")" .factory/retro/ledger.jsonl >/dev/null' "$out"
check "a signature that kept recurring is reverted" 'printf "%s" "$out" | grep -q "REVERTED 2026-10-12/P2"' "$out"
newproj eval2
sig cccccccccccc
mrun "$((NOW - 5*86400))" 10 10 5 2 3.0
for i in 1 2 3; do red "T$i" cccccccccccc "$((NOW - 5*86400))"; done
prop '{"id":"P1","kind":"lesson","module":"api","evidence":"C1-01,sig-cccccccccccc","text":"Seed the fixture first.","metric":"sig_recurrence","signature":"cccccccccccc"},
{"id":"P2","kind":"claude_md","text":"Name test files after the module.","metric":"first_pass_green"}'
apply >/dev/null
python3 - <<PY
import json
rows=[json.loads(l) for l in open('.factory/retro/ledger.jsonl')]
for r in rows: r['applied_at']=$NOW-86400
open('.factory/retro/ledger.jsonl','w').write('\n'.join(json.dumps(r) for r in rows)+'\n')
PY
mrun "$((NOW - 3600))" 6 6 3 0 6.0
for i in 1 2 3 4 5; do red "U$i" cccccccccccc "$((NOW - 1800))"; done
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "a lesson whose signature kept coming is retired" 'printf "%s" "$out" | grep -q "REVERTED 2026-10-12/P1" && ! grep -q "Seed the fixture" .factory/lessons/api.md' "$out"
check "a rule that did not raise first-pass is reverted from CLAUDE.md" 'printf "%s" "$out" | grep -q "REVERTED 2026-10-12/P2" && ! grep -q "Name test files" CLAUDE.md' "$out"
check "the revert is its own commit"            'git log --format=%B | grep -q "^Factory-Retro-Revert: 2026-10-12/P2$"'
check "CLAUDE.md is back to its committed text" '[ -z "$(git status --porcelain -- CLAUDE.md)" ]'
out="$(python3 "$H/factory-retro-apply.py" evaluate)"
check "a decided change is not judged twice"    'printf "%s" "$out" | grep -q "nothing waiting"' "$out"
check "the ledger lists outcomes"               'python3 "$H/factory-retro-apply.py" ledger | grep -q "outcome=reverted"'

echo "=== config revert restores the file"
newproj cfgrev
mrun "$((NOW - 5*86400))" 10 10 8 0 3.0
prop '{"id":"P1","kind":"config","patch":{"min_tests":5},"metric":"first_pass_green"}'
apply >/dev/null
check "min_tests is 5 after apply"              'jq -e ".min_tests == 5" .factory/config.json >/dev/null'
python3 - <<PY
import json
rows=[json.loads(l) for l in open('.factory/retro/ledger.jsonl')]
for r in rows: r['applied_at']=$NOW-86400
open('.factory/retro/ledger.jsonl','w').write('\n'.join(json.dumps(r) for r in rows)+'\n')
PY
mrun "$((NOW - 3600))" 6 6 1 0 3.0
python3 "$H/factory-retro-apply.py" evaluate >/dev/null
check "a worse rate reverts the patch from the ledger" 'jq -e ".min_tests == 2 and .retry_limit == 3" .factory/config.json >/dev/null'
check "the config is clean in git again"        'git diff --quiet HEAD -- .factory/config.json || git log -1 --format=%B | grep -q "Factory-Retro-Revert"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
