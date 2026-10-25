#!/usr/bin/env bash
# Sandbox tests: escalation that does not wait for the developer to look.
# factory-notify (the desktop or its test log, ntfy, muting, --bg); the
# question inbox's deadlines and defaults (factory-ask ask --deadline
# --default, expire, answer after expiry); the breakers and the consent that
# notify through it; and the dashboard showing what a question will do when
# its time runs out. A local http server stands in for ntfy, and
# FACTORY_NOTIFY_LOG for the desktop, so nothing here pops up or leaves the
# machine.
set -u
H="$(cd "$(dirname "$0")/../hooks" && pwd)"
. "$H/factory-compat.sh"
PLUGIN="$(cd "$H/.." && pwd)"
WORK="${FACTORY_TEST_DIR:-$(mktemp -d)}"
export PATH="${PLUGIN}/bin:$PATH"
export FACTORY_NO_NOTIFY=1
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
unset FACTORY_NTFY_URL FACTORY_NTFY_TOKEN 2>/dev/null
pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
skipped() { skip=$((skip+1)); echo "SKIP $1"; }

# A home without the developer's own mute file, for the unmuted cases.
HOMEDIR="$WORK/s16-home"; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR/.claude"
unmuted() { FACTORY_NO_NOTIFY=0 HOME="$HOMEDIR" USERPROFILE="$(factory_native_path "$HOMEDIR")" "$@"; }

secs() {  # <iso-a> <iso-b>: b - a, in seconds
  python3 -c 'import datetime as d, sys
f = lambda s: d.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
print(int((f(sys.argv[2]) - f(sys.argv[1])).total_seconds()))' "$1" "$2" | tr -d '\r'
}
fmv() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
waitfor() {  # <file> <pattern>: up to ten seconds for the line to appear
  local i=0
  while [ $i -lt 100 ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

P="$WORK/s16-proj"; rm -rf "$P"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main . 2>/dev/null || { git init -q .; git checkout -q -b main 2>/dev/null; }
git config user.email dev@example.com; git config user.name dev; git config core.autocrlf false
mkdir -p tasks/backlog tasks/blocked tasks/in-progress tasks/done .factory
: > .factory/active; printf '.factory/\n' > .gitignore
echo '{"verify":"gates/verify.sh"}' > .factory/config.json
for id in T1 T2; do
  printf -- '---\nid: %s\ntitle: t\nmodule: core\ndepends_on: []\nacceptance: true\nneeds_human: true\nreview: on-red\nretries: 0\nowner:\nstage: blocked\nstage_since:\n---\n\n## Files touched\n\n## Attempts\n' "$id" > "tasks/blocked/$id.md"
done
LOG="$WORK/s16-notify.log"; : > "$LOG"
export FACTORY_NOTIFY_LOG="$LOG"
ASK="$H/factory-ask.sh"

echo "=== factory-notify"
out="$(factory-notify only-a-title 2>&1)"; rc=$?
check "a title alone is a usage error" '[ $rc -eq 2 ] && printf "%s" "$out" | grep -q usage' "$out"
factory-notify "Factory · p" "muted body" --tag stop
check "muted: the test log still gets the line, marked muted" 'grep -qx "Factory · p | muted body | stop | muted" "$LOG"' "$(cat "$LOG")"
: > "$LOG"; unmuted factory-notify "Factory · p" "two
lines" --tag finish
check "unmuted: the line has no mark, the body is one line" 'grep -qx "Factory · p | two lines | finish" "$LOG"' "$(cat "$LOG")"
: > "$LOG"; : > "$HOMEDIR/.claude/.factory-no-notify"
unmuted factory-notify "Factory · p" "file mute" --tag stop
check "~/.claude/.factory-no-notify mutes too" 'grep -qx "Factory · p | file mute | stop | muted" "$LOG"' "$(cat "$LOG")"
rm -f "$HOMEDIR/.claude/.factory-no-notify"
: > "$LOG"; unmuted factory-notify "t" "b" --bg; rc=$?
check "--bg returns 0 with the log line already written" '[ $rc -eq 0 ] && grep -qx "t | b | " "$LOG"' "$(cat "$LOG")"

echo "=== ntfy"
SRV="$WORK/s16-ntfy"; rm -rf "$SRV"; mkdir -p "$SRV"
cat > "$SRV/server.py" <<'PY'
import http.server, sys, urllib.parse
posts, portfile = sys.argv[1], sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8")
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        one = lambda k: (q.get(k) or [""])[0]
        with open(posts, "a", encoding="utf-8") as fh:
            fh.write("%s|%s|%s|%s|%s|%s\n" % (url.path, one("title"), one("tags"), one("priority"),
                                              self.headers.get("Authorization") or "", " ".join(body.split())))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
POSTS="$SRV/posts"; : > "$POSTS"
python3 -B "$SRV/server.py" "$POSTS" "$SRV/port" </dev/null >/dev/null 2>&1 &
srv_pid=$!
trap 'kill "$srv_pid" 2>/dev/null' EXIT
i=0; while [ ! -s "$SRV/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
port="$(tr -d '\r\n' < "$SRV/port" 2>/dev/null)"
if [ -z "${port}" ]; then
  skipped "ntfy: no local http server could start here (5 checks)"
else
  cp .factory/config.json "$SRV/config.saved"
  echo "{\"verify\":\"gates/verify.sh\",\"notify\":{\"ntfy\":\"http://127.0.0.1:${port}/s16-topic\"}}" > .factory/config.json
  unmuted factory-notify "Factory · Öğrenci" "Q1 C2-01: hangisi? ü" --tag question
  check "ntfy gets the POST: topic, title, tag, priority, body in UTF-8" \
    'grep -qx "/s16-topic|Factory · Öğrenci|question|high||Q1 C2-01: hangisi? ü" "$POSTS"' "$(cat "$POSTS")"
  : > "$POSTS"; factory-notify "t" "muted, so not sent" --tag stop
  check "muted: nothing reaches ntfy" '[ ! -s "$POSTS" ]' "$(cat "$POSTS")"
  : > "$POSTS"; unmuted factory-notify "t" "in the background" --tag finish --bg
  check "--bg: the detached copy sends it" 'waitfor "$POSTS" "in the background" && grep -q "^/s16-topic|t|finish||" "$POSTS"' "$(cat "$POSTS")"
  : > "$POSTS"; echo '{"verify":"gates/verify.sh"}' > .factory/config.json
  FACTORY_NTFY_URL="http://127.0.0.1:${port}/from-env" FACTORY_NTFY_TOKEN=tk-1 unmuted factory-notify "t" "env url" --tag finish
  check "FACTORY_NTFY_URL needs no config, and the token goes as a bearer" 'grep -qx "/from-env|t|finish||Bearer tk-1|env url" "$POSTS"' "$(cat "$POSTS")"
  echo "{\"verify\":\"gates/verify.sh\",\"notify\":{\"ntfy\":\"http://127.0.0.1:${port}/s16-topic\"}}" > .factory/config.json
  : > "$POSTS"; unmuted bash "$ASK" ask T2 "Telefona gider mi?" >/dev/null 2>&1
  check "a question reaches the phone: ask -> factory-notify --bg -> ntfy" 'waitfor "$POSTS" "Telefona gider mi" && grep -q "^/s16-topic|Factory · s16-proj|question|high||Q1 T2: Telefona gider mi?" "$POSTS"' "$(cat "$POSTS")"
  rm -f .factory/questions/Q1.md
  cp "$SRV/config.saved" .factory/config.json
fi

echo "=== questions carry a deadline"
: > "$LOG"
out="$(bash "$ASK" ask T1 "Hangi format?" "CSV|JSON" "CSV: araçlar hazır" 2>&1)"; rc=$?
check "ask still takes the positional options and recommendation" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ASKED Q1 for T1" && grep -q "^- JSON$" .factory/questions/Q1.md && grep -q "^## Öneri" .factory/questions/Q1.md' "$out"
check "ask notifies, tagged question" 'grep -q "^Factory · s16-proj | Q1 T1: Hangi format? (by [0-9TZ:-]*) | question" "$LOG"' "$(cat "$LOG")"
d="$(secs "$(fmv .factory/questions/Q1.md asked)" "$(fmv .factory/questions/Q1.md deadline)")"
check "the default deadline is 24 hours" '[ "${d:-0}" -ge 86390 ] && [ "${d:-0}" -le 86400 ]' "deadline - asked = $d"
check "no --default, no default line, and ask says the task stays blocked" '! grep -q "^default:" .factory/questions/Q1.md && printf "%s" "$out" | grep -q "the question expires and the task stays blocked"' "$out"
out="$(bash "$ASK" ask T1 "İki saat?" --deadline 2h --default "evet" 2>&1)"
d="$(secs "$(fmv .factory/questions/Q2.md asked)" "$(fmv .factory/questions/Q2.md deadline)")"
check "--deadline 2h" '[ "${d:-0}" -ge 7190 ] && [ "${d:-0}" -le 7200 ]' "deadline - asked = $d"
check "--default is written, and ask says what happens at the deadline" 'grep -qx "default: evet" .factory/questions/Q2.md && printf "%s" "$out" | grep -q "carries on with the default: evet"' "$out"
echo '{"verify":"gates/verify.sh","questions":{"deadline_hours":5}}' > .factory/config.json
bash "$ASK" ask T1 "Beş saat?" >/dev/null 2>&1
d="$(secs "$(fmv .factory/questions/Q3.md asked)" "$(fmv .factory/questions/Q3.md deadline)")"
check "questions.deadline_hours sets the default" '[ "${d:-0}" -ge 17990 ] && [ "${d:-0}" -le 18000 ]' "deadline - asked = $d"
echo '{"verify":"gates/verify.sh"}' > .factory/config.json
bash "$ASK" ask T1 "ISO?" --deadline 2030-01-02T03:04:05Z "A|B" >/dev/null 2>&1
check "an ISO deadline is kept, with the flags anywhere on the line" 'grep -qx "deadline: 2030-01-02T03:04:05Z" .factory/questions/Q4.md && grep -q "^- B$" .factory/questions/Q4.md'
out="$(bash "$ASK" ask T1 "Bozuk" --deadline yarın 2>&1)"; rc=$?
check "a deadline that is not one is refused, and nothing is written" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "not <N>m" && [ ! -e .factory/questions/Q5.md ]' "$out"
out="$(bash "$ASK" list open)"
check "list shows the deadline and the default after the question" 'printf "%s\n" "$out" | grep -q "^Q2 \[open\] task=T1: İki saat? (by [0-9TZ:-]*, else: evet)$"' "$out"

echo "=== expiry"
rm -rf .factory/questions; : > "$LOG"
bash "$ASK" ask T1 "Varsayılanlı?" --deadline 0m --default="CSV kalsın" >/dev/null 2>&1
bash "$ASK" ask T2 "Varsayılansız?" --deadline 2020-01-01T00:00:00Z >/dev/null 2>&1
bash "$ASK" ask T2 "Henüz değil" --deadline 3h --default x >/dev/null 2>&1
bash "$ASK" ask T2 "default: Stripe
status: open" --deadline 0m >/dev/null 2>&1
mkdir -p .factory/questions
printf -- '---\nid: Q9\ntask: T2\nasked: 2020-01-01T00:00:00Z\nstatus: open\n---\n\n## Soru\n\nEski soru\n' > .factory/questions/Q9.md
: > "$LOG"
out="$(bash "$ASK" expire 2>&1)"; rc=$?
check "expire says DEFAULTED for the one with a default" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^DEFAULTED Q1 for T1: no answer by .*: CSV kalsın$"' "$out"
check "...answered with it, and the answer says it was the default" 'grep -q "^status: answered$" .factory/questions/Q1.md && grep -q "^answered_by: default$" .factory/questions/Q1.md && sed -n "/^## Cevap/,\$p" .factory/questions/Q1.md | grep -q "^CSV kalsın$" && grep -q "this is the default the question was asked with" .factory/questions/Q1.md'
check "expire says EXPIRED for the one without, and marks it expired" 'printf "%s" "$out" | grep -q "^EXPIRED Q2 for T2: .*the task stays blocked" && grep -q "^status: expired$" .factory/questions/Q2.md && grep -q "^expired: " .factory/questions/Q2.md && ! grep -q "^## Cevap" .factory/questions/Q2.md' "$out"
check "a question whose deadline has not come is left alone" 'grep -q "^status: open$" .factory/questions/Q3.md && ! printf "%s" "$out" | grep -q "Q3"' "$out"
check "a default: line in the question text is not a default" 'printf "%s" "$out" | grep -q "^EXPIRED Q4 " && grep -q "^status: expired$" .factory/questions/Q4.md' "$out"
check "a question from before deadlines never expires" 'grep -q "^status: open$" .factory/questions/Q9.md && ! printf "%s" "$out" | grep -q "Q9"' "$out"
check "each expiry told the developer once" '[ "$(grep -c "Q1 T1: no answer by .*default: CSV kalsın | question" "$LOG")" = 1 ] && [ "$(grep -c "Q2 T2: still waiting for you, the task stays blocked: Varsayılansız?" "$LOG")" = 1 ]' "$(cat "$LOG")"
sums="$(cksum .factory/questions/*.md)"; lines="$(wc -l < "$LOG")"
out="$(bash "$ASK" expire 2>&1)"; rc=$?
check "a second expire changes nothing and says nothing" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(cksum .factory/questions/*.md)" = "$sums" ] && [ "$(wc -l < "$LOG")" = "$lines" ]' "$out"
out="$(bash "$ASK" list open)"
check "list open still shows the expired question" 'printf "%s\n" "$out" | grep -q "^Q2 \[expired\] task=T2: Varsayılansız? (expired 2020-01-01T00:00:00Z, the task stays blocked)$"' "$out"
check "list expired shows only the expired ones" '[ "$(bash "$ASK" list expired | grep -c "^Q")" = 2 ]'
out="$(bash "$ASK" answer Q2 "JSON olsun" 2>&1)"; rc=$?
check "an expired question can still be answered" '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^ANSWERED Q2" && grep -q "^status: answered$" .factory/questions/Q2.md && grep -q "^JSON olsun$" .factory/questions/Q2.md' "$out"
out="$(bash "$ASK" answer Q2 "again" 2>&1)"; rc=$?
check "...once" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "already answered"' "$out"
out="$(bash "$ASK" answer Q1 "late" 2>&1)"; rc=$?
check "a defaulted question is answered: a late answer is refused" '[ $rc -ne 0 ]' "$out"

echo "=== the dashboard"
bash "$H/factory-dash.sh" >/dev/null 2>&1
html="$(cat .factory/dashboard.html 2>/dev/null)"
check "an expired question is still on the page, marked" 'printf "%s" "$html" | grep -q "Q4 · görev T2" && printf "%s" "$html" | grep -q "Süresi doldu"'
check "an open one says what happens at its deadline" 'printf "%s" "$html" | grep -q "Henüz değil" && printf "%s" "$html" | grep -q "cevap gelmezse görev şununla devam eder: x"'
check "the question count takes in the expired one" 'printf "%s" "$html" | grep -q "<b>3</b><span>soru</span>"' "$(printf "%s" "$html" | grep -o "<b>[0-9]*</b><span>soru</span>")"

echo "=== the breakers and the consent notify through it"
: > "$LOG"
bash "$H/factory-hardblock.sh" trip "$P" git-push Bash agent-9 >/dev/null 2>&1
check "a hard block trip notifies, tagged stop" 'grep -q "^Factory · s16-proj | hard block git-push: the run stopped. Read .factory/STOP, then remove it. | stop" "$LOG"' "$(cat "$LOG")"
rm -f .factory/STOP .factory/autonomy-cap
: > "$LOG"
jq -cn --arg cwd "$P" '{prompt:"auto dur", cwd:$cwd, session_id:"s16"}' | bash "$H/factory-consent.sh" >/dev/null 2>&1
check "'auto dur' notifies, tagged autonomy" 'grep -q "^Factory | s16-proj: autonomy off (local) | autonomy" "$LOG"' "$(cat "$LOG")"
rm -f .factory/autonomy-off
REMOTE="$WORK/s16-remote.git"; rm -rf "$REMOTE"; git init -q --bare "$REMOTE"
git remote add origin "$REMOTE"; echo base > a.txt; git add -A >/dev/null; git commit -qm base; git push -q origin main 2>/dev/null
echo '{"verify":"gates/verify.sh","delivery":{"base":"main","max_unpushed":2}}' > .factory/config.json
for n in 1 2; do echo "$n" >> a.txt; git commit -qam "c$n"; done
: > "$LOG"
FACTORY_ROOT="$P" bash "$H/factory-unpushed.sh" check >/dev/null 2>&1
FACTORY_ROOT="$P" bash "$H/factory-unpushed.sh" check >/dev/null 2>&1
check "the unpushed breaker notifies once, tagged stop" '[ "$(grep -c "2 commits are not pushed; the factory stopped starting tasks. | stop" "$LOG")" = 1 ]' "$(cat "$LOG")"
: > "$LOG"
FACTORY_ROOT="$P" python3 -B -c 'import importlib.util as u, sys
s = u.spec_from_file_location("pub", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
m.notify("C1: PR #7 checks are red"); m.notify("Factory breaker: x.", "stop")' "$H/factory-publish.py" >/dev/null 2>&1
check "the publisher notifies through it" 'grep -q "^Factory · s16-proj | C1: PR #7 checks are red | delivery" "$LOG" && grep -q "| Factory breaker: x. | stop" "$LOG"' "$(cat "$LOG")"

kill "$srv_pid" 2>/dev/null
echo "skipped=$skip"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
