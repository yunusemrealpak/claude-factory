#!/usr/bin/env bash
# Sandbox tests: the observability layer - event log, dashboard, question inbox,
# status line segment, end-of-run message. Never touches a real project.
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

mktask() {  # <dir> <column> <id> [key:value ...]
  local d="$1" col="$2" id="$3" kv k f; shift 3
  mkdir -p "$d/tasks/$col"
  f="$d/tasks/$col/$id.md"
  {
    echo "---"; echo "id: $id"; echo "title: t $id"; echo "module: m"
    echo "depends_on: []"; echo "acceptance: bash gates/verify.sh $id"
    echo "needs_human: false"; echo "retries: 0"
    echo "---"; echo; echo "## Files touched"; echo "- \`src/a.txt\`"
  } > "$f"
  # Overrides replace the default key rather than adding a second copy of it:
  # a frontmatter reader takes the first match, so a duplicate would be ignored.
  for kv in "$@"; do
    k="${kv%%:*}"
    if grep -q "^${k}:" "$f"; then
      sed "s|^${k}:.*|${k}: ${kv#*:}|" "$f" > "$f.t" && mv -f "$f.t" "$f"
    else
      sed "1a\\
${k}: ${kv#*:}
" "$f" > "$f.t" && mv -f "$f.t" "$f"
    fi
  done
}

# One event payload on stdin. $1 = hook event name, rest = jq object fragment.
ev_in() { printf '%s' "$1" | bash "$H/factory-event.sh"; }

freeze_dash() { printf '%s' "$(( $(date +%s) + 99999 ))" > "$1/.factory/.dash-stamp"; }

echo "=== event log"
E="$WORK/events"; rm -rf "$E"; mkdir -p "$E/.factory"; cd "$E" || exit 1
LOG="$E/.factory/events.jsonl"

# Inert until the factory is open in that project.
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"SubagentStart", agent_type:"factory-implementer", agent_id:"a1"}')"
check "no .factory/active: nothing is recorded" '[ ! -f "$LOG" ]'

: > "$E/.factory/active"; freeze_dash "$E"
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"SubagentStart", agent_type:"factory-implementer", agent_id:"a1"}')"
check "SubagentStart writes agent_start" 'jq -e "select(.kind==\"agent_start\" and .agent==\"factory-implementer\" and .agent_id==\"a1\")" "$LOG" >/dev/null' "$(cat "$LOG" 2>/dev/null)"
check "every line carries ts/epoch/kind" 'jq -e "has(\"ts\") and has(\"epoch\") and has(\"kind\")" "$LOG" >/dev/null'

# A start two minutes old, so the pairing has something to measure.
jq -cn --argjson e "$(( $(date +%s) - 120 ))" '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-reviewer", agent_id:"a2"}' >> "$LOG"
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"SubagentStop", agent_type:"factory-reviewer", agent_id:"a2", last_assistant_message:"done"}')"
secs="$(jq -r 'select(.kind=="agent_stop" and .agent_id=="a2") | .seconds' "$LOG")"
check "SubagentStop pairs on agent_id and computes duration" '[ "$secs" -ge 119 ] && [ "$secs" -le 125 ]' "seconds=$secs"
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"SubagentStop", agent_type:"factory-lead", agent_id:"zz"}')"
check "stop with no matching start records seconds=-1" '[ "$(jq -r "select(.kind==\"agent_stop\" and .agent_id==\"zz\") | .seconds" "$LOG")" = "-1" ]'

post() {  # <command> <output>
  ev_in "$(jq -cn --arg c "$E" --arg cmd "$1" --arg out "$2" \
    '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash", tool_use_id:"t1",
      tool_input:{command:$cmd}, tool_output:$out}')"
}
post "bash gates/verify.sh C2-01" "stage 1 ok
GATE RESULT: GREEN for C2-01"
check "gate green is recorded with its task" 'jq -e "select(.kind==\"gate\" and .task==\"C2-01\" and .verdict==\"green\")" "$LOG" >/dev/null'
post "bash gates/verify.sh C2-02" "GATE RESULT: RED for C2-02 - tests failed"
check "gate red is recorded" 'jq -e "select(.kind==\"gate\" and .task==\"C2-02\" and .verdict==\"red\")" "$LOG" >/dev/null'
post "bash gates/verify.sh C2-02" "NO PROGRESS: the same failure twice"
check "no-progress outranks red" 'jq -e "select(.kind==\"gate\" and .verdict==\"no-progress\")" "$LOG" >/dev/null'
check "no-progress is not also counted as red" '[ "$(jq -r "select(.kind==\"gate\") | .verdict" "$LOG" | grep -c red)" = "1" ]'

# tool_output arrives as an object on some tools; the parser must not drop it.
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Bash",
  tool_input:{command:"bash gates/verify.sh C2-07"}, tool_output:{stdout:"GATE RESULT: GREEN for C2-07"}}')"
check "object tool_output is still read" 'jq -e "select(.kind==\"gate\" and .task==\"C2-07\" and .verdict==\"green\")" "$LOG" >/dev/null'

post "mv tasks/in-progress/C2-01.md tasks/done/" ""
check "a move records from and to" 'jq -e "select(.kind==\"move\" and .task==\"C2-01\" and .from==\"in-progress\" and .to==\"done\")" "$LOG" >/dev/null'
post "git mv tasks/backlog/C2-05.md tasks/in-progress/" ""
check "git mv counts as a move" 'jq -e "select(.kind==\"move\" and .task==\"C2-05\" and .to==\"in-progress\")" "$LOG" >/dev/null'
post "cat tasks/done/C2-01.md" ""
check "reading a task file is not a move" '[ "$(jq -r "select(.kind==\"move\")" "$LOG" | grep -c "\"task\"")" = "2" ]'

post "bash ~/.claude/hooks/factory-commit.sh C2-01" "COMMIT 9f3ab12 C2-01 (C2): src/a.txt "
check "commit records the sha" 'jq -e "select(.kind==\"commit\" and .task==\"C2-01\" and .sha==\"9f3ab12\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-commit.sh C2-09" "COMMIT SKIPPED for C2-09: none of its files differ from HEAD - nothing to commit."
check "a skipped commit records sha=none" 'jq -e "select(.kind==\"commit\" and .task==\"C2-09\" and .sha==\"none\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-risk.sh C2-03" "RISK C2-03: review before commit - the gate cannot judge these files."
check "risk hit is recorded" 'jq -e "select(.kind==\"risk\" and .task==\"C2-03\" and .review_needed==\"yes\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-risk.sh C2-04" "RISK none for C2-04: 2 file(s), none on a risk path."
check "clean risk check is recorded too" 'jq -e "select(.kind==\"risk\" and .task==\"C2-04\" and .review_needed==\"no\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-change.sh open C3 login-fix fix -" "OPENED C3-login-fix: 4 task(s), base abc123def456, summary at .factory/changes/C3-login-fix/summary.md"
check "opening a change is recorded" 'jq -e "select(.kind==\"change_open\" and .change==\"C3-login-fix\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-claim.sh" "CLAIMED: this run is owned by session abc."
check "claiming the run is recorded" 'jq -e "select(.kind==\"claim\")" "$LOG" >/dev/null'
post "bash ~/.claude/hooks/factory-ask.sh ask C2-06 \"x\"" "ASKED Q2 for C2-06: written to .factory/questions/Q2.md"
check "a question is recorded" 'jq -e "select(.kind==\"question\" and .question==\"Q2\")" "$LOG" >/dev/null'

before="$(wc -l < "$LOG")"
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"PostToolUse", tool_name:"Read", tool_input:{file_path:"x"}, tool_output:"y"}')"
ev_in "$(jq -cn --arg c "$E" '{cwd:$c, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:"ls"}}')"
check "other tools and other events write nothing" '[ "$(wc -l < "$LOG")" = "$before" ]'
check "the whole log is valid JSON lines" 'jq -e . "$LOG" >/dev/null'
check "dashboard was not rebuilt while the stamp was fresh" '[ ! -f "$E/.factory/dashboard.html" ]'

rm -f "$E/.factory/.dash-stamp"
post "bash gates/verify.sh C2-08" "GATE RESULT: GREEN for C2-08"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$E/.factory/dashboard.html" ] && break; done
check "an event rebuilds the dashboard" '[ -f "$E/.factory/dashboard.html" ] || { sleep 2; [ -f "$E/.factory/dashboard.html" ]; }'
check "the debounce stamp is written" '[ -s "$E/.factory/.dash-stamp" ]'

echo "=== question inbox"
Q="$WORK/questions"; rm -rf "$Q"; mkdir -p "$Q/.factory"; cd "$Q" || exit 1
: > .factory/active
out="$(bash "$H/factory-ask.sh" ask NOPE "what now?" 2>&1)"; rc=$?
check "a question needs a task that exists" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no task file"' "$out"
mktask "$Q" in-progress C2-01
mktask "$Q" blocked C2-02
out="$(bash "$H/factory-ask.sh" ask C2-01 "Ödeme sağlayıcısı Stripe mi kalsın?" "Stripe|Iyzico" "Stripe: entegrasyon hazır" 2>&1)"; rc=$?
check "ask writes Q1 and says so" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ASKED Q1 for C2-01" && [ -f .factory/questions/Q1.md ]' "$out"
check "the question file carries frontmatter" 'grep -q "^id: Q1" .factory/questions/Q1.md && grep -q "^task: C2-01" .factory/questions/Q1.md && grep -q "^status: open" .factory/questions/Q1.md'
check "options and recommendation are sections" 'grep -q "^- Stripe$" .factory/questions/Q1.md && grep -q "^## Öneri" .factory/questions/Q1.md'
check "ask tells the lead not to wait" 'printf "%s" "$out" | grep -q "Do not wait for the answer"' "$out"
bash "$H/factory-ask.sh" ask C2-02 "İkinci soru" >/dev/null 2>&1
check "the second question is Q2, not Q1 again" '[ -f .factory/questions/Q2.md ]'
out="$(bash "$H/factory-ask.sh" list open)"
check "list open shows both with their tasks" '[ "$(printf "%s\n" "$out" | grep -c "^Q")" = "2" ] && printf "%s" "$out" | grep -q "Q1 \[open\] task=C2-01: Ödeme"' "$out"
out="$(bash "$H/factory-ask.sh" answer Q1 "Stripe kalsın." 2>&1)"; rc=$?
check "answer flips the status and names the task" '[ $rc -eq 0 ] && grep -q "^status: answered" .factory/questions/Q1.md && printf "%s" "$out" | grep -q "C2-01"' "$out"
check "the answer is appended to the file" 'grep -q "^## Cevap" .factory/questions/Q1.md && grep -q "Stripe kalsın." .factory/questions/Q1.md'
out="$(bash "$H/factory-ask.sh" answer Q1 "again" 2>&1)"; rc=$?
check "answering twice is refused" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "already answered"' "$out"
out="$(bash "$H/factory-ask.sh" answer Q9 "x" 2>&1)"; rc=$?
check "answering a question that does not exist is refused" '[ $rc -ne 0 ]' "$out"
check "list open now shows only Q2" '[ "$(bash "$H/factory-ask.sh" list open | grep -c "^Q")" = "1" ]'
check "list all shows both" '[ "$(bash "$H/factory-ask.sh" list all | grep -c "^Q")" = "2" ]'
check "list answered shows Q1" 'bash "$H/factory-ask.sh" list answered | grep -q "^Q1 \[answered\]"'

echo "=== dashboard"
D="$WORK/dash"; rm -rf "$D"; mkdir -p "$D/.factory/no-progress"; cd "$D" || exit 1
git init -q . && git config user.email t@t && git config user.name t
: > .factory/active
mkdir -p tasks/backlog tasks/in-progress tasks/blocked tasks/done tasks/proposed src
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mktask "$D" in-progress C2-01 "owner:tolga" "stage:implementing" "stage_since:$now_iso"
mktask "$D" backlog C2-02 "retries:2"
mktask "$D" done C2-03
mktask "$D" blocked C2-04 "needs_human:true"
printf '\n## Blocked reason\n\nAPI anahtarı yok.\n' >> tasks/blocked/C2-04.md
printf 'signature=abc123 rc=1 dotnet-test\n' > .factory/no-progress/C2-02
echo x > src/a.txt; git add -A >/dev/null 2>&1; git commit -qm init >/dev/null 2>&1
printf 'Kasa akışını yenile.\n' | bash "$H/factory-change.sh" open C2 kasa-akisi feature - >/dev/null 2>&1
bash "$H/factory-ask.sh" ask C2-01 "Hangi kütüphane?" "A|B" "A daha hızlı" >/dev/null 2>&1
S=$(( $(date +%s) - 1800 ))
{
  jq -cn --argjson e "$S"           '{ts:"x", epoch:$e, kind:"move", task:"C2-03", from:"backlog", to:"in-progress"}'
  jq -cn --argjson e "$(( S+600 ))" '{ts:"x", epoch:$e, kind:"move", task:"C2-03", from:"in-progress", to:"done"}'
  jq -cn --argjson e "$S"           '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-implementer", agent_id:"a1"}'
  jq -cn --argjson e "$(( S+300 ))" '{ts:"x", epoch:$e, kind:"agent_stop", agent:"factory-implementer", agent_id:"a1", seconds:300}'
  jq -cn --argjson e "$(( S+310 ))" '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-reviewer", agent_id:"a2"}'
  jq -cn --argjson e "$(( S+320 ))" '{ts:"x", epoch:$e, kind:"gate", task:"C2-03", verdict:"green"}'
  jq -cn --argjson e "$(( S+330 ))" '{ts:"x", epoch:$e, kind:"gate", task:"C2-02", verdict:"red"}'
  jq -cn --argjson e "$S"           '{ts:"x", epoch:$e, kind:"cost", usd:0.42, session_min:3, lines_added:10, lines_removed:2, ctx:11, session:"s1"}'
  jq -cn --argjson e "$(( S+400 ))" '{ts:"x", epoch:$e, kind:"cost", usd:1.20, session_min:9, lines_added:140, lines_removed:22, ctx:31, session:"s1"}'
} > .factory/events.jsonl
out="$(bash "$H/factory-dash.sh" 2>&1)"; rc=$?
check "dashboard builds without noise" '[ $rc -eq 0 ] && [ -z "$out" ] && [ -s .factory/dashboard.html ]' "$out"
html="$(cat .factory/dashboard.html)"
check "it is a self-refreshing html page" 'printf "%s" "$html" | grep -q "http-equiv=\"refresh\"" && printf "%s" "$html" | grep -q "^<!doctype html>"'
check "KPI: one task running" 'printf "%s" "$html" | grep -q "<b>1</b><span>çalışıyor</span>"'
check "KPI: one open agent (start without stop)" 'printf "%s" "$html" | grep -q "<b>1</b><span>açık ajan</span>"'
check "KPI: one open question" 'printf "%s" "$html" | grep -q "<b>1</b><span>soru</span>"'
check "KPI: gate tally green/red" 'printf "%s" "$html" | grep -q "<b>1/1</b><span>kapı yeşil/kırmızı</span>"'
check "KPI: median task time from the moves" 'printf "%s" "$html" | grep -q "<b>10 dk</b><span>görev medyan</span>"'
check "KPI: session cost is the delta, not the total" 'printf "%s" "$html" | grep -q "<b>\$0.78</b><span>bu oturum</span>"' "$(printf "%s" "$html" | grep -o "<b>[^<]*</b><span>bu oturum</span>")"
check "KPI: lines added and removed" 'printf "%s" "$html" | grep -q "+140 −22"'
check "the running task is shown with owner and stage" 'printf "%s" "$html" | grep -q "C2-01" && printf "%s" "$html" | grep -q "tolga" && printf "%s" "$html" | grep -q "implementing"'
check "the open question is rendered with its options" 'printf "%s" "$html" | grep -q "Hangi kütüphane?" && printf "%s" "$html" | grep -q "<li>A</li>" && printf "%s" "$html" | grep -q "Ekibin önerisi"'
check "the needs-human task says so" 'printf "%s" "$html" | grep -q "C2-04 · sana ihtiyacı var" && printf "%s" "$html" | grep -q "API anahtarı yok."'
check "the stalled task is in Zorlananlar with its signature" 'printf "%s" "$html" | grep -q "aynı hataya iki kez takıldı" && printf "%s" "$html" | grep -q "abc123 rc=1"'
check "a retried task is in Zorlananlar too" 'printf "%s" "$html" | grep -q "2 kez geri döndü"'
check "the change is shown with progress" 'printf "%s" "$html" | grep -q "C2-kasa-akisi" && printf "%s" "$html" | grep -q "feature"'
check "agent time is totalled per role" 'printf "%s" "$html" | grep -q "factory-implementer" && printf "%s" "$html" | grep -q "5 dk"'
check "the feed reads in Turkish" 'printf "%s" "$html" | grep -q "in-progress → done" && printf "%s" "$html" | grep -q "kapı green"'
check "it says whether the run is live" 'printf "%s" "$html" | grep -qE "canlı · son hareket|son hareket"'

# HTML injection from a task title must not escape into markup.
mktask "$D" in-progress C2-05 "owner:x" "stage:queued" "stage_since:$now_iso"
sed -i.bak 's|^title: t C2-05$|title: <img src=x onerror=alert(1)> \& "quoted"|' tasks/in-progress/C2-05.md && rm -f tasks/in-progress/C2-05.md.bak
bash "$H/factory-dash.sh"
check "a task title cannot inject markup" 'grep -q "&lt;img src=x" .factory/dashboard.html && ! grep -q "<img src=x" .factory/dashboard.html'

check "statusline cache is written with the keys the status line reads" '
  grep -q "^change=C2-kasa-akisi$" .factory/statusline.txt &&
  grep -qE "^progress=[0-9]+/[0-9]+$" .factory/statusline.txt &&
  grep -q "^questions=1$" .factory/statusline.txt &&
  grep -q "^blocked=1$" .factory/statusline.txt &&
  grep -q "^stalled=1$" .factory/statusline.txt &&
  grep -q "^running=1$" .factory/statusline.txt' "$(cat .factory/statusline.txt 2>/dev/null)"

# An empty project must still produce a page rather than a broken one.
N="$WORK/dash-empty"; rm -rf "$N"; mkdir -p "$N/.factory"; cd "$N" || exit 1
: > .factory/active; mkdir -p tasks/backlog
out="$(bash "$H/factory-dash.sh" 2>&1)"; rc=$?
check "empty project: page still builds, no errors" '[ $rc -eq 0 ] && [ -z "$out" ] && grep -q "Şu an çalışan görev yok" .factory/dashboard.html' "$out"
check "empty project: says nothing is waiting" 'grep -q "Ekip kendi başına ilerliyor" .factory/dashboard.html'
check "empty project: no cost is shown as a dash" 'grep -q "<b>-</b><span>bu oturum</span>" .factory/dashboard.html'
cd "$D" || exit 1

echo "=== status line segment"
SL="$(cd "$(dirname "$0")/../statusline" && pwd)/factory-statusline.sh"
payload="$(jq -cn --arg d "$D" '{session_id:"s9", model:{display_name:"Opus 5"},
  workspace:{current_dir:$d, project_dir:$d},
  context_window:{used_percentage:23},
  cost:{total_cost_usd:2.5, total_duration_ms:600000, total_lines_added:200, total_lines_removed:30}}')"
rm -f "$D/.factory/.cost-sample"
out="$(printf '%s' "$payload" | bash "$SL" 2>&1)"
check "the factory segment appears in the status line" 'printf "%s" "$out" | grep -q "🏭" && printf "%s" "$out" | grep -q "C2-kasa-akisi"' "$out"
check "it shows running, questions, blocked and stalled" 'printf "%s" "$out" | grep -q "▶1" && printf "%s" "$out" | grep -q "✋1" && printf "%s" "$out" | grep -q "⛔1" && printf "%s" "$out" | grep -q "⚠1"' "$out"
check "the status line sampled the cost into the event log" 'jq -e "select(.kind==\"cost\" and .session==\"s9\" and .usd==2.5 and .lines_added==200)" .factory/events.jsonl >/dev/null' "$(tail -1 .factory/events.jsonl)"
n1="$(grep -c "\"session\":\"s9\"" .factory/events.jsonl)"
printf '%s' "$payload" | bash "$SL" >/dev/null 2>&1
check "it samples at most once a minute" '[ "$(grep -c "\"session\":\"s9\"" .factory/events.jsonl)" = "$n1" ]'
out2="$(printf '%s' "$payload" | bash "$SL" 2>&1)"
check "the status line never prints an error" '! printf "%s" "$out2" | grep -qiE "error|not found|No such file"' "$out2"
# Outside a factory project the segment must vanish entirely.
payload2="$(jq -cn --arg d "$BASE" '{session_id:"s9", model:{display_name:"Opus 5"}, workspace:{current_dir:$d, project_dir:$d}, context_window:{used_percentage:5}, cost:{total_cost_usd:1}}')"
out3="$(printf '%s' "$payload2" | bash "$SL" 2>&1)"
check "no factory, no segment" '! printf "%s" "$out3" | grep -q "🏭"' "$out3"

# A slug can be 40 characters; the line it shares is not that wide.
seg_name() {  # <change-name> - the name as the status line renders it
  sed "s/^change=.*/change=$1/" .factory/statusline.txt > .factory/sl.tmp && mv -f .factory/sl.tmp .factory/statusline.txt
  rm -f .factory/.cost-sample
  printf '%s' "$payload" | bash "$SL" 2>/dev/null \
    | sed 's/.*🏭//' | sed $'s/\033\[[0-9;]*m//g' | awk '{print $1}'
}
long="C12-refactor-the-entire-payment-pipeline"
name="$(seg_name "$long")"
check "a long change name is cut to fit" '[ "${#name}" -le 18 ] && printf "%s" "$name" | grep -q "…"' "$name"
check "the cut keeps the change id, which is the head" 'printf "%s" "$name" | grep -q "^C12-"' "$name"
name="$(seg_name "C2-invoice-export")"
check "a name that already fits is left alone" '[ "$name" = "C2-invoice-export" ]' "$name"
name="$(FACTORY_STATUSLINE_MAX=8 seg_name "C2-invoice-export")"
check "the limit can be tightened" '[ "${#name}" -le 8 ]' "$name"

echo "=== end of run"
cd "$D" || exit 1
stop_in() { jq -cn --arg c "$D" --arg s "${1:-s1}" '{cwd:$c, session_id:$s, hook_event_name:"Stop", stop_hook_active:false}'; }
printf 's1' > .factory/run-owner
out="$(stop_in s-other | bash "$H/factory-stop-gate.sh")"
check "a session that does not own the run is left alone" '[ -z "$out" ]' "$out"
# Backlog work left: the run must be held open, and no summary printed.
out="$(stop_in | bash "$H/factory-stop-gate.sh")"
check "work left in backlog holds the session" 'printf "%s" "$out" | jq -e ".decision==\"block\"" >/dev/null' "$out"
# Clear the board down to blocked-only, which is what ends a run.
mv tasks/backlog/C2-02.md tasks/done/ 2>/dev/null
rm -f tasks/in-progress/C2-01.md tasks/in-progress/C2-05.md
rm -f .factory/dashboard.html
out="$(stop_in | bash "$H/factory-stop-gate.sh")"
check "only blocked work left: the run is allowed to stop" '! printf "%s" "$out" | jq -e ".decision" >/dev/null 2>&1' "$out"
check "the developer is told the run finished" 'printf "%s" "$out" | jq -r ".systemMessage" | grep -q "Factory run finished"' "$out"
check "the open question is named in the end-of-run message" 'printf "%s" "$out" | jq -r ".systemMessage" | grep -q "1 question(s) are waiting for you"' "$out"
check "it points at the dashboard and the answer command" 'printf "%s" "$out" | jq -r ".systemMessage" | grep -q "dashboard.html" && printf "%s" "$out" | jq -r ".systemMessage" | grep -q "factory-ask answer"'
check "the dashboard is rebuilt one last time" '[ -s .factory/dashboard.html ]'
check "the claim is released" '[ ! -s .factory/run-owner ]'
check "the change was synced at the end of the run" 'grep -q "C2-03" .factory/changes/C2-kasa-akisi/summary.md'

echo "=== session brief"
out="$(jq -cn --arg c "$D" '{cwd:$c, session_id:"s1", hook_event_name:"SessionStart", source:"startup"}' | bash "$H/factory-brief.sh" | jq -r '.hookSpecificOutput.additionalContext')"
check "the brief lists the open question" 'printf "%s" "$out" | grep -q "Questions waiting for the developer" && printf "%s" "$out" | grep -q "Q1 \[open\] task=C2-01"' "$out"
check "the brief lists the change in flight" 'printf "%s" "$out" | grep -q "C2-kasa-akisi"' "$out"
check "the brief names the stalled task" 'printf "%s" "$out" | grep -q "Stalled" && printf "%s" "$out" | grep -q "C2-02"' "$out"

echo "=== agents that died with their session"
W="$WORK/sweep"; rm -rf "$W"; mkdir -p "$W/.factory/inflight" "$W/tasks/in-progress"; cd "$W" || exit 1
: > .factory/active
jq -n '{max_concurrent_agents:3, agent_stale_after_min:45}' > .factory/config.json
mktask "$W" in-progress C2-01 "owner:impl-1" "stage:implementing"
S2=$(( $(date +%s) - 600 ))
{
  jq -cn --argjson e "$S2"          '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-implementer", agent_id:"dead1"}'
  jq -cn --argjson e "$(( S2+10 ))" '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-reviewer", agent_id:"dead2"}'
} > .factory/events.jsonl
: > .factory/inflight/tool-a; : > .factory/inflight/tool-b
bash "$H/factory-dash.sh"
check "before the sweep the dead agents look like work in flight" 'grep -q "^running=2$" .factory/statusline.txt' "$(cat .factory/statusline.txt)"

out="$(bash "$H/factory-sweep.sh" test-reason "$W")"
check "the sweep reports what it cleared" 'printf "%s" "$out" | grep -q "^SWEPT 2 agent(s) and 2 concurrency slot(s)"' "$out"
check "the concurrency slots are released" '[ "$(find .factory/inflight -type f | wc -l | tr -d " ")" = "0" ]'
check "a sweep line is written to the log" 'jq -e "select(.kind==\"sweep\" and .reason==\"test-reason\" and .agents==2)" .factory/events.jsonl >/dev/null'
check "the dashboard stops counting them" 'grep -q "^running=0$" .factory/statusline.txt' "$(cat .factory/statusline.txt)"
check "the feed says why they disappeared" 'grep -q "önceki oturumdan kalma" .factory/dashboard.html'
out="$(bash "$H/factory-sweep.sh" again "$W")"
check "a second sweep with nothing to clear is silent" '[ -z "$out" ] && [ "$(grep -c sweep .factory/events.jsonl)" = "1" ]' "$out"

# An agent dispatched after the sweep is live again.
jq -cn --argjson e "$(date +%s)" '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-implementer", agent_id:"live1"}' >> .factory/events.jsonl
bash "$H/factory-dash.sh"
check "an agent started after the sweep does count" 'grep -q "^running=1$" .factory/statusline.txt' "$(cat .factory/statusline.txt)"

# Age backstop: no sweep at all, but a start older than the cutoff.
O="$WORK/sweep-age"; rm -rf "$O"; mkdir -p "$O/.factory"; cd "$O" || exit 1
: > .factory/active; jq -n '{agent_stale_after_min:45}' > .factory/config.json
jq -cn --argjson e "$(( $(date +%s) - 4000 ))" '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-implementer", agent_id:"old1"}' > .factory/events.jsonl
jq -cn --argjson e "$(( $(date +%s) - 300 ))"  '{ts:"x", epoch:$e, kind:"agent_start", agent:"factory-implementer", agent_id:"new1"}' >> .factory/events.jsonl
bash "$H/factory-dash.sh"
check "a start older than the cutoff is not counted, even with no sweep" 'grep -q "^running=1$" .factory/statusline.txt' "$(cat .factory/statusline.txt)"

echo "=== who is allowed to sweep"
cd "$W" || exit 1
brief_in() { jq -cn --arg c "$W" --arg s "$1" --arg src "$2" '{cwd:$c, session_id:$s, source:$src, hook_event_name:"SessionStart"}'; }
: > .factory/inflight/tool-c
rm -f .factory/run-owner
out="$(brief_in sA startup | bash "$H/factory-brief.sh" | jq -r '.hookSpecificOutput.additionalContext')"
check "a session starting on an unowned run sweeps" 'printf "%s" "$out" | grep -q "PREVIOUS RUN ENDED MID-FLIGHT" && [ "$(find .factory/inflight -type f | wc -l | tr -d " ")" = "0" ]' "$out"
check "and names the tasks the dead run left in flight" 'printf "%s" "$out" | grep -q "Tasks left in tasks/in-progress by that run: C2-01"' "$out"

: > .factory/inflight/tool-d
printf 'sA' > .factory/run-owner
out="$(brief_in sA resume | bash "$H/factory-brief.sh" | jq -r '.hookSpecificOutput.additionalContext')"
check "resuming the session that owns the run sweeps its own ghosts" '[ "$(find .factory/inflight -type f | wc -l | tr -d " ")" = "0" ]' "$out"

: > .factory/inflight/tool-e
printf 'sA' > .factory/run-owner
out="$(brief_in sA compact | bash "$H/factory-brief.sh" >/dev/null; find .factory/inflight -type f | wc -l | tr -d ' ')"
check "a compaction is the same process continuing, so it never sweeps" '[ "$out" = "1" ]' "$out"

printf 'sOTHER' > .factory/run-owner
out="$(brief_in sNEW startup | bash "$H/factory-brief.sh" >/dev/null; find .factory/inflight -type f | wc -l | tr -d ' ')"
check "a bystander session never sweeps a run somebody else owns" '[ "$out" = "1" ]' "$out"

echo "=== claiming a run clears what the last one left"
rm -f .factory/run-owner
printf 'sZ' > .factory/run-owner.pending
out="$(bash "$H/factory-claim.sh")"
check "the claim succeeds and reports the sweep" 'printf "%s" "$out" | grep -q "^CLAIMED" && printf "%s" "$out" | grep -q "SWEPT"' "$out"
check "the slots are free for the new run" '[ "$(find .factory/inflight -type f | wc -l | tr -d " ")" = "0" ]'

echo "=== the concurrency ceiling itself"
L="$WORK/limit"; rm -rf "$L"; mkdir -p "$L/.factory/inflight"; cd "$L" || exit 1
: > .factory/active; jq -n '{max_concurrent_agents:2, agent_stale_after_min:45}' > .factory/config.json
limit_in() { jq -cn --arg c "$L" --arg id "$1" '{cwd:$c, hook_event_name:"PreToolUse", tool_name:"Agent", tool_use_id:$id, tool_input:{prompt:"x"}}'; }
limit_in t1 | bash "$H/factory-agent-limit.sh" >/dev/null
limit_in t2 | bash "$H/factory-agent-limit.sh" >/dev/null
check "each approved dispatch takes a slot" '[ "$(find .factory/inflight -type f | wc -l | tr -d " ")" = "2" ]'
out="$(limit_in t3 | bash "$H/factory-agent-limit.sh")"
check "the ceiling denies the next one" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.permissionDecision==\"deny\"" >/dev/null' "$out"
touch -t 202001010000 .factory/inflight/t1 .factory/inflight/t2
out="$(limit_in t4 | bash "$H/factory-agent-limit.sh")"
check "markers too old to be agents stop holding the ceiling" '[ -z "$out" ] && [ -f .factory/inflight/t4 ] && [ ! -f .factory/inflight/t1 ]' "$out"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
