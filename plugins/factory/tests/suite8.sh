#!/usr/bin/env bash
# Sandbox tests: release 2.8 - delivery. A bare origin repository stands in for
# GitHub and a fake `gh` stands in for its CLI: it logs every call, merges into
# the bare origin for real, and misbehaves on demand (no login, red CI, a head
# that moved). Nothing here touches a network or a real remote.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$H/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1 FACTORY_NO_CAFFEINATE=1 FACTORY_PUBLISH_POLL_S=0 FACTORY_PUBLISH_CI_POLLS=2
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# --- the fake gh -------------------------------------------------------------
FG="$WORK/s8-fakegh"; rm -rf "$FG"; mkdir -p "$FG"
cat > "$FG/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
S="$GHSTATE"; a="$*"
case "$1 $2" in
  "pr create")
    [ -f "$S/auth_fail" ] && { echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4; }
    while [ $# -gt 0 ]; do [ "$1" = "--head" ] && echo "$2" > "$S/branch"; shift; done
    echo "https://github.com/o/r/pull/7"; exit 0 ;;
  "pr checks")
    [ -f "$S/checks_sleep" ] && sleep 30
    exit "$(cat "$S/checks_rc" 2>/dev/null || echo 0)" ;;
  "pr view")
    case "$a" in
      *"--json state,headRefOid,mergeCommit"*)
        head="$(cat "$S/head_override" 2>/dev/null || git --git-dir="$GH_ORIGIN" rev-parse "refs/heads/$(cat "$S/branch")")"
        st=OPEN; [ -f "$S/merged" ] && st=MERGED
        printf '{"state":"%s","headRefOid":"%s","mergeCommit":{"oid":"%s"}}\n' "$st" "$head" "$(cat "$S/merge_sha" 2>/dev/null)" ;;
      *"--json mergeCommit"*) cat "$S/merge_sha" ;;
      *"--json id"*) echo PRNODE ;;
      *"--json number"*) echo 7 ;;
    esac; exit 0 ;;
  "pr merge")
    if [ -f "$S/no_rebase" ] && [[ "$a" == *--rebase* ]]; then echo "Rebase merges are not allowed on this repository." >&2; exit 1; fi
    m=""; body=""; args=("$@")
    for ((i=0;i<${#args[@]};i++)); do
      [ "${args[$i]}" = "--match-head-commit" ] && m="${args[$((i+1))]}"
      [ "${args[$i]}" = "--body" ] && body="${args[$((i+1))]}"
    done
    br="$(cat "$S/branch")"
    actual="$(git --git-dir="$GH_ORIGIN" rev-parse "refs/heads/$br")"
    [ "$m" = "$actual" ] || { echo "Head branch was modified. Review and try the merge again." >&2; exit 1; }
    t="$(mktemp -d)"; git clone -q "$GH_ORIGIN" "$t"; cd "$t" || exit 1
    git config user.email f@example.invalid; git config user.name fake
    git checkout -q main
    if [[ "$a" == *--squash* ]]; then
      git merge --squash -q "origin/$br"; git commit -q -m "C2: add thing (#7)" -m "$body"
    else
      for c in $(git rev-list --reverse "origin/main..origin/$br"); do git cherry-pick --allow-empty "$c" >/dev/null 2>&1 || exit 1; done
    fi
    git push -q origin main; git rev-parse HEAD > "$S/merge_sha"; touch "$S/merged"; rm -rf "$t"; exit 0 ;;
  "run list")
    case "$(cat "$S/main_ci" 2>/dev/null || echo green)" in
      green) echo '[{"databaseId":55,"status":"completed","conclusion":"success","url":"https://x/55"}]' ;;
      red)   echo '[{"databaseId":56,"status":"in_progress","conclusion":null,"url":"https://x/56"}]' ;;
      none)  echo '[]' ;;
    esac; exit 0 ;;
  "run watch") [ "$(cat "$S/main_ci" 2>/dev/null)" = red ] && exit 1; exit 0 ;;
  "api graphql") echo '{"data":{"revertPullRequest":{"revertPullRequest":{"number":9,"url":"https://github.com/o/r/pull/9"}}}}'; exit 0 ;;
esac
echo "fake gh: unhandled $a" >&2; exit 9
SH
chmod +x "$FG/gh"
export FACTORY_GH="$FG/gh"
TP="$WORK/s8-transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"auto devam et"}}' > "$TP"

newproj() {  # <name> <branch-mode> <consent-level>  -> sets P, O, S; cd's into P
  P="$WORK/s8-$1"; O="$WORK/s8-$1.git"; S="$WORK/s8-$1.gh"
  rm -rf "$P" "$O" "$S"; mkdir -p "$S"
  git init -q --bare -b main "$O"
  git clone -q "$O" "$P" 2>/dev/null; cd "$P" || exit 1
  git config user.email dev@example.com; git config user.name dev
  mkdir -p src tasks/backlog tasks/in-progress tasks/done tasks/blocked tasks/proposed .factory/changes .factory/verified .factory/inflight
  echo base > src/a.txt; : > .factory/active
  printf '.factory/\n' > .gitignore
  jq -cn --arg b "$2" --arg l "$3" '{verify:"gates/verify.sh", autonomy_default:$l, risk_paths:["*/auth/*"], fast:{risk_review:"before"},
    delivery:{branch:$b, merge_method:"rebase", base:"main", quota_margin:10}}' > .factory/config.json
  git add -A; git commit -qm base; git push -q -u origin main 2>/dev/null
  export FACTORY_ROOT="$P" GHSTATE="$S" GHLOG="$S/log" GH_ORIGIN="$O"
  : > "$GHLOG"
  printf -- '---\nid: C2-01\ntitle: add thing\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: done\nstage_since:\n---\n\n## Files touched\n- src/new.txt\n\n## Attempts\n' > tasks/done/C2-01.md
  printf 'add the thing\n' | bash "$H/factory-change.sh" open C2 add-thing feature - >/dev/null 2>&1
  jq -cn --arg p "auto devam et" --arg cwd "$P" --arg s sess8 --arg tp "$TP" '{prompt:$p,cwd:$cwd,session_id:$s,transcript_path:$tp}' \
    | bash "$H/factory-consent.sh" >/dev/null
}
other_lands_on_main() {  # a second developer pushes to main, so the rebase has to move our commits
  local t="$WORK/s8-other"; rm -rf "$t"; git clone -q "$O" "$t" 2>/dev/null
  ( cd "$t" && git config user.email o@example.invalid && git config user.name other \
    && echo other > other.txt && git add -A && git commit -qm "other work" && git push -q origin main ) 2>/dev/null
  rm -rf "$t"
}
change_commit() {  # <path> <content>: one factory-style commit of C2
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
  git add -- "$1"; git commit -q -m "C2-01: add thing" -m "Factory-Task: C2-01
Factory-Change: C2"
}
pub() { python3 "$H/factory-publish.py" "$@" 2>&1; }
state() { jq -r ".$1 // empty" ".factory/publish/$2.json" 2>/dev/null; }

echo "=== quota line"
Q="$WORK/s8-quota.json"; now="$(date +%s)"
mkq() { jq -cn --argjson ts "$1" --argjson u "$2" --argjson l "$3" '{ts:$ts, seven_day:{used_percentage:$u, even_line:$l, resets_at:null}}' > "$Q"; }
cd "$WORK" || exit 1
quota() { FACTORY_ROOT="$WORK" FACTORY_QUOTA_FILE="$Q" bash "$H/factory-quota.sh" check "$@"; }
mkq "$now" 30 40;  out="$(quota)";  check "under the line is OK"            '[ $? -eq 0 ] && printf "%s" "$out" | grep -q "^QUOTA OK"' "$out"
mkq "$now" 52 40;  out="$(quota)";  check "past line + margin is OVER"     '[ $? -eq 1 ] && printf "%s" "$out" | grep -q "^QUOTA OVER"' "$out"
mkq "$now" 52 40;  out="$(quota 20)"; check "the margin is an argument"    '[ $? -eq 0 ]' "$out"
mkq "$((now - 3600))" 10 40; out="$(quota)"; check "an hour-old reading is STALE" 'printf "%s" "$out" | grep -q "^QUOTA STALE"' "$out"
rm -f "$Q"; out="$(quota)"; check "no file is NONE"                        'printf "%s" "$out" | grep -q "^QUOTA NONE"' "$out"

echo "=== branch per change"
newproj branch per-change merge
out="$(bash "$H/factory-branch.sh" C2)"
check "a change gets its own branch from origin/main" '[ "$(git symbolic-ref --short HEAD)" = factory/C2-add-thing ] && printf "%s" "$out" | grep -q "BRANCH READY"' "$out"
out="$(bash "$H/factory-branch.sh" C2)"
check "asking again is a no-op"                       'printf "%s" "$out" | grep -q "already on it"' "$out"
git switch -q main; echo stray > src/stray.txt
out="$(bash "$H/factory-branch.sh" C2)"; rc=$?
check "a tree with foreign work is refused"           '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "BRANCH REFUSED"' "$out"
rm -f src/stray.txt
mkdir -p .factory/publish; echo '{"change":"C1","state":"pr_open"}' > .factory/publish/C1.json
sed -i.bak 's/^extends:.*$//' .factory/changes/C2-add-thing/goal.md; echo 'extends: C1' >> .factory/changes/C2-add-thing/goal.md; rm -f .factory/changes/C2-add-thing/goal.md.bak
git switch -q main 2>/dev/null; git branch -q -D factory/C2-add-thing 2>/dev/null
out="$(bash "$H/factory-branch.sh" C2)"; rc=$?
check "a dependent change waits for its base's publish" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "whose publish is still"' "$out"
rm -f .factory/publish/C1.json
newproj branchmain main merge
out="$(bash "$H/factory-branch.sh" C2)"
check "delivery.branch main leaves the branch alone"  '[ "$(git symbolic-ref --short HEAD)" = main ] && printf "%s" "$out" | grep -q "BRANCH STAY"' "$out"

echo "=== plan --change"
newproj plan per-change merge
mktask() { printf -- '---\nid: %s\ntitle: t\nmodule: core\ndepends_on: [%s]\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: queued\nstage_since:\n---\n\n## Goal\nx\n\n## Files touched\n\n## Attempts\n' "$2" "${3:-}" > "tasks/$1/$2.md"; }
rm -f tasks/done/C2-01.md
mktask backlog C2-01; mktask backlog C3-01; mktask backlog C3-02 C3-01; mktask backlog C3-03 C2-01; mktask backlog LEGACY-1
out="$(python3 "$H/factory-plan.py" --change C3 --json)"
check "only the change's tasks are planned"     'printf "%s" "$out" | jq -e "[.tasks[].id] | sort == [\"C3-01\",\"C3-02\"] or ([.tasks[].id] | sort == [\"C3-01\"])" >/dev/null' "$out"
check "...and not the other change's"           '! printf "%s" "$out" | jq -e "[.tasks[].id] | index(\"C2-01\")" >/dev/null 2>&1'
check "a cross-change wait says which change"   'printf "%s" "$out" | jq -r ".held[].reason" | grep -q "change C2"' "$out"
out="$(python3 "$H/factory-plan.py" --change C1 --json)"
check "a task without a prefix belongs to C1"   'printf "%s" "$out" | jq -e "[.tasks[].id] == [\"LEGACY-1\"]" >/dev/null' "$out"
echo '{"ts":1,"seven_day":{"used_percentage":90,"even_line":10}}' > "$WORK/s8-q2.json"
out="$(FACTORY_QUOTA_FILE="$WORK/s8-q2.json" python3 "$H/factory-plan.py" --change C3 --start --json)"
check "--start at level merge refuses when over the quota line" 'printf "%s" "$out" | jq -e ".ok == false and (.problems | join(\" \") | test(\"QUOTA\"))" >/dev/null' "$out"
git switch -q main 2>/dev/null
rm -f .factory/run-start.json

echo "=== delivery: rebase merge, class A"
newproj flow per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null
change_commit src/new.txt "new"
sha="$(git rev-parse HEAD)"
other_lands_on_main
out="$(pub C2)"
check "the change is delivered"                 '[ "$(state state C2)" = done ]' "$out"
check "the branch was pushed"                   'git --git-dir="$O" rev-parse -q --verify refs/heads/factory/C2-add-thing >/dev/null || [ -n "$(git --git-dir="$O" log main --grep="^Factory-Change: C2" --format=%H)" ]'
check "a pull request was opened against main"  'grep -q "^pr create --base main --head factory/C2-add-thing" "$GHLOG"'
check "CI was watched, failing fast"            'grep -q "^pr checks 7 --watch --fail-fast" "$GHLOG"'
check "the merge is pinned to the tested head"  'grep -q "^pr merge 7 --rebase --match-head-commit $sha" "$GHLOG"'
check "main CI was looked at"                   'grep -q "^run list --branch main --commit" "$GHLOG"'
rsha="$(git --git-dir="$O" log main --grep='^Factory-Change: C2' --format=%H | head -1)"
check "the rebased commit is on origin/main"    '[ -n "$rsha" ] && [ "$rsha" != "$sha" ]'
check "...with its trailers"                    'git --git-dir="$O" log -1 --format=%B "$rsha" | grep -q "^Factory-Task: C2-01"'
check "local main caught up and holds the work" '[ "$(git symbolic-ref --short HEAD)" = main ] && [ -f src/new.txt ] && [ -f other.txt ]'
check "the local change branch is gone"         '! git rev-parse -q --verify refs/heads/factory/C2-add-thing >/dev/null'
bash "$H/factory-change.sh" sync C2 >/dev/null
check "refs/factory follows the rebased commit" 'git rev-parse -q --verify refs/factory/C2-add-thing >/dev/null && git merge-base --is-ancestor "$(git rev-parse refs/factory/C2-add-thing)" origin/main'
check "a second call does nothing"              'pub C2 | grep -q "already done"'
check "the digest names it"                     'python3 "$H/factory-digest.py" --line | grep -q "1 delivered"'

echo "=== delivery: level pr stops at the pull request"
newproj prlevel per-change pr
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "new"
out="$(pub C2)"
check "state is pr_only"                        '[ "$(state state C2)" = pr_only ]' "$out"
check "a PR was opened"                         'grep -q "^pr create" "$GHLOG"'
check "nothing was merged"                      '! grep -q "^pr merge" "$GHLOG" && ! grep -q "^pr checks" "$GHLOG"'
newproj local per-change merge
rm -f .factory/autonomy.json
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "new"
out="$(pub C2)"
check "level local publishes nothing"           'printf "%s" "$out" | grep -q "level is local" && [ ! -s "$GHLOG" ] && [ -z "$(git --git-dir="$O" branch --list "factory/*")" ]' "$out"

echo "=== delivery: class C is a pull request only"
newproj classc per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit db/migrations/001.sql "create table x;"
out="$(pub C2)"
check "a migration makes it class C"            '[ "$(state class C2)" = C ] && [ "$(state state C2)" = pr_only ]' "$out"
check "even at merge level it is not merged"    '! grep -q "^pr merge" "$GHLOG"'
newproj classb per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/auth/login.txt "x"
printf -- '\n## Review 2026-10-12\nverdict: fail\nfindings:\n- x\n' >> tasks/done/C2-01.md
out="$(pub C2)"
check "class B with a failed review is held"    '[ "$(state class C2)" = B ] && [ -n "$(state held C2)" ] && ! grep -q "^pr merge" "$GHLOG"' "$out"
printf -- '\n## Review 2026-10-12\nverdict: pass\nfindings:\n' >> tasks/done/C2-01.md
out="$(pub C2)"
check "...and goes through once the review passes" '[ "$(state state C2)" = done ] && grep -q "^pr merge" "$GHLOG"' "$out"
newproj audit per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
printf '# Audit\n\n## high - tenant filter missing\nWhere: a\n' > .factory/audit.md
out="$(pub C2)"
check "a high audit finding holds the merge"    '[ -n "$(state held C2)" ] && ! grep -q "^pr merge" "$GHLOG"' "$out"
python3 "$H/factory-publish.py" --ack-audit C2 >/dev/null
out="$(pub C2)"
check "acknowledging it lets the merge go"      '[ "$(state state C2)" = done ]' "$out"

echo "=== delivery: gh auth error holds, and resumes"
newproj auth per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
touch "$S/auth_fail"
out="$(pub C2)"
check "no login is held, not failed"           '[ -n "$(state held C2)" ] && printf "%s" "$(state held C2)" | grep -q "gh auth login" && [ "$(state state C2)" = pushed ]' "$out"
rm -f "$S/auth_fail"
out="$(pub C2)"
check "the next call carries on from the push"  '[ "$(state state C2)" = done ] && [ -z "$(state held C2)" ]' "$out"

echo "=== delivery: a moved head is not merged"
newproj moved per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
echo 0000000000000000000000000000000000000000 > "$S/head_override"
out="$(pub C2)"
check "head moved: held, no merge call"         '[ -n "$(state held C2)" ] && ! grep -q "^pr merge" "$GHLOG"' "$out"
check "the reason says head moved"              'state held C2 | grep -q "head moved"'

echo "=== delivery: squash fallback keeps the trailers"
newproj squash main merge
change_commit src/new.txt "x"
touch "$S/no_rebase"
out="$(pub C2)"
check "rebase refused, squash used"             'grep -q "^pr merge 7 --rebase" "$GHLOG" && grep -q "^pr merge 7 --squash --match-head-commit" "$GHLOG"' "$out"
check "the squash commit carries Factory-Change" 'git --git-dir="$O" log main -1 --format=%B | grep -q "^Factory-Change: C2"'
check "main mode: local main followed origin"   '[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]'

echo "=== delivery: no checkout while a run is active"
newproj active per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
touch .factory/inflight/C3-01
out="$(pub C2)"
check "merged, but the local branch is left"    '[ "$(state state C2)" = done ] && [ "$(git symbolic-ref --short HEAD)" = factory/C2-add-thing ]' "$out"
check "...and the record says why"              '[ -n "$(state sync_pending C2)" ]'
rm -f .factory/inflight/C3-01

echo "=== delivery: kill -9 and resume"
newproj kill per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
touch "$S/checks_sleep"
python3 "$H/factory-publish.py" C2 >/dev/null 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ "$(state state C2)" = pr_open ] && break; sleep 0.5; done
pid="$(state pid C2)"
# The pid is the one Python recorded: a Windows pid under Git Bash, which
# bash's kill does not know.
kill -9 "$pid" 2>/dev/null || taskkill //F //PID "$pid" >/dev/null 2>&1
pkill -9 -f "$FG/gh pr checks" 2>/dev/null; sleep 0.3
check "the record survives with the step it reached" '[ "$(state state C2)" = pr_open ] && [ "$(state pid C2)" = "$pid" ]'
rm -f "$S/checks_sleep"
out="$(pub C2)"
check "the next call resumes and delivers"      '[ "$(state state C2)" = done ]' "$out"
check "the PR was not opened twice"             '[ "$(grep -c "^pr create" "$GHLOG")" -eq 1 ]'

echo "=== delivery: red main reverts, and two reverts trip the breaker"
newproj red per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
echo red > "$S/main_ci"
out="$(pub C2)"
check "red main CI reverts"                     '[ "$(state state C2)" = reverted ] && grep -q "^api graphql" "$GHLOG"' "$out"
check "a fix task is proposed"                  'ls tasks/proposed/FIX-C2-main-red*.md >/dev/null 2>&1'
check "one revert does not trip the breaker"    '[ ! -e .factory/autonomy-cap ] && [ "$(bash "$H/factory-autonomy.sh")" = merge ]'
git switch -q main 2>/dev/null
# a second change, red again
printf -- '---\nid: C3-01\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: false\nreview: on-red\nretries: 0\nowner:\nstage: done\nstage_since:\n---\n\n## Files touched\n\n## Attempts\n' > tasks/done/C3-01.md
printf 'two\n' | bash "$H/factory-change.sh" open C3 second feature - >/dev/null 2>&1
bash "$H/factory-change.sh" sync C3 >/dev/null
git switch -q -c factory/C3-second origin/main 2>/dev/null; change_commit src/two.txt "two"; sed -i.bak 's/Factory-Change: C2/Factory-Change: C3/' /dev/null 2>/dev/null
rm -f "$S/merged" "$S/branch"
out="$(pub C3)"
check "the second revert caps the level at pr"  '[ -s .factory/autonomy-cap ] && [ "$(bash "$H/factory-autonomy.sh")" = pr ]' "$out"
check "the digest shows the breaker"            'python3 "$H/factory-digest.py" --line | grep -q "BREAKER"'
jq -cn --arg p "auto devam et" --arg cwd "$P" --arg s sess8 --arg tp "$TP" '{prompt:$p,cwd:$cwd,session_id:$s,transcript_path:$tp}' | bash "$H/factory-consent.sh" >/dev/null
check "a new consent clears the cap"            '[ ! -e .factory/autonomy-cap ] && [ "$(bash "$H/factory-autonomy.sh")" = merge ]'

echo "=== a hard-ban hit caps the level"
bash "$H/factory-hardblock.sh" trip "$P" git-push Bash agent-9 >/dev/null
check "the trip writes the cap"                 '[ "$(head -1 .factory/autonomy-cap)" = pr ] && [ "$(bash "$H/factory-autonomy.sh")" = pr ]'
rm -f .factory/STOP .factory/autonomy-cap

echo "=== pending marks resume"
newproj pending per-change merge
bash "$H/factory-branch.sh" C2 >/dev/null; change_commit src/new.txt "x"
mkdir -p .factory/publish; : > .factory/publish/C2.pending
out="$(python3 "$H/factory-publish.py" --resume-all 2>&1)"
check "--resume-all delivers a pending change"  '[ "$(state state C2)" = done ] && [ ! -e .factory/publish/C2.pending ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
