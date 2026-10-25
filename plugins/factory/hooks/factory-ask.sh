#!/usr/bin/env bash
# Factory question inbox. NOT a hook: factory-preflight, factory-settle and
# factory-review-submit run it when the run needs a decision only the developer
# can make.
#
# Usage (from the project root):
#   factory-ask ask <task-id> "<question>" ["<option>|<option>"] ["<recommendation>"]
#                   [--deadline <N>m|<N>h|<N>d|<ISO date>] [--default "<answer>"]
#   factory-ask answer <question-id> "<answer>"
#   factory-ask list [open|answered|expired|all]
#   factory-ask expire
#
# Until now a task that needed the developer went quiet: it moved to blocked
# with needs_human: true and sat there until somebody read the board. A team
# that cannot ask a question is not a team, it is a queue. This is the
# channel: one question, the options as the team sees them, and what the team
# would do - so the answer can be one word.
#
# Every question carries a deadline: --deadline, else questions.deadline_hours
# from .factory/config.json, else 24 hours. A question asked with --default
# carries the answer the team will go with when nobody answers in time.
# `expire` (factory-preflight runs it before it reads the answers) settles
# every open question past its deadline: one with a default is answered with
# it, and the task carries on; one without is marked expired, the developer is
# told once, and the task stays blocked. An expired question can still be
# answered, and the task then carries on as with any answer.
#
# Questions appear on the dashboard under "Sana ihtiyacı var", and reach the
# developer through factory-notify - the desktop, and ntfy when the project
# set one up - the moment they are asked and again when they expire. They live
# in .factory/questions/ and stay on this machine.
set -uo pipefail

ROOT="$PWD"
Q="${ROOT}/.factory/questions"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "factory-ask: $*" >&2; exit 1; }

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

notify() {  # <body> <tag>: best effort, never fatal, never waits
  # factory-notify mutes and detaches (--bg); only the test log
  # (FACTORY_NOTIFY_LOG) gets past FACTORY_NO_NOTIFY.
  [ "${FACTORY_NO_NOTIFY:-0}" = "1" ] && [ -z "${FACTORY_NOTIFY_LOG:-}" ] && return 0
  [ -f "${HOOK_DIR}/factory-notify.py" ] || return 0
  (cd "${ROOT}" && python3 "${HOOK_DIR}/factory-notify.py" "Factory · $(basename "${ROOT}")" "$1" --tag "$2" --bg) \
    </dev/null >/dev/null 2>&1
  return 0
}

fmv() {  # <file> <key>: a frontmatter value, never a line from the body
  awk -v k="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    { i = index($0, ":"); if (i && substr($0, 1, i - 1) == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); print v; exit } }
  ' "$1" 2>/dev/null
}

fm_status() {  # <file> <from> <to>
  local tmp="$1.tmp.$$"
  awk -v from="status: $2" -v to="status: $3" '
    NR > 1 && $0 == "---" { past = 1 }
    !past && NR > 1 && $0 == from { $0 = to }
    { print }
  ' "$1" > "${tmp}" && mv -f "${tmp}" "$1"
}

fm_add() {  # <file> <key> <value>: one more frontmatter line, before the closing ---
  local tmp="$1.tmp.$$"
  FM_LINE="$2: $3" awk '
    NR > 1 && !done && $0 == "---" { print ENVIRON["FM_LINE"]; done = 1 }
    { print }
  ' "$1" > "${tmp}" && mv -f "${tmp}" "$1"
}

# The deadline as an ISO UTC time. Python, not date: GNU and BSD date share no
# way to add hours. An empty spec means the project's default.
deadline_of() {
  python3 -c '
import datetime as dt, json, re, sys
spec = sys.argv[1].strip()
utc = dt.timezone.utc
now = dt.datetime.now(utc).replace(microsecond=0)
def show(t):
    print(t.astimezone(utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    sys.exit(0)
if not spec:
    try:
        with open(".factory/config.json", encoding="utf-8") as fh:
            hours = float((json.load(fh).get("questions") or {}).get("deadline_hours", 24))
    except Exception:
        hours = 24.0
    show(now + dt.timedelta(hours=hours if hours > 0 else 24.0))
m = re.fullmatch(r"([0-9]+(?:[.][0-9]+)?) *([mhd])", spec.lower())
if m:
    unit = {"m": "minutes", "h": "hours", "d": "days"}[m.group(2)]
    show(now + dt.timedelta(**{unit: float(m.group(1))}))
try:
    t = dt.datetime.fromisoformat(re.sub(r"[zZ]$", "+00:00", spec))
except ValueError:
    sys.exit(1)
show(t if t.tzinfo else t.astimezone())
' "$1" 2>/dev/null | tr -d '\r'  # a Windows python ends its lines with CRLF
}

cmd_ask() {
  local spec="" default="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --deadline)   [ $# -ge 2 ] || die "--deadline needs <N>m, <N>h, <N>d or an ISO date"; spec="$2"; shift 2 ;;
      --deadline=*) spec="${1#--deadline=}"; shift ;;
      --default)    [ $# -ge 2 ] || die "--default needs the answer to go with"; default="$2"; shift 2 ;;
      --default=*)  default="${1#--default=}"; shift ;;
      *)            args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  local task="${1:-}" text="${2:-}" options="${3:-}" rec="${4:-}"
  [ -n "${task}" ] && [ -n "${text}" ] || die "usage: ask <task-id> \"<question>\" [\"<option>|<option>\"] [\"<recommendation>\"] [--deadline <N>h] [--default \"<answer>\"]"
  ls "${ROOT}"/tasks/*/"${task}".md >/dev/null 2>&1 || die "no task file tasks/*/${task}.md - a question belongs to a task"
  local deadline
  deadline="$(deadline_of "${spec}")" || die "--deadline ${spec}: not <N>m, <N>h, <N>d or an ISO date"
  [ -n "${deadline}" ] || die "could not work out the deadline (is python3 on PATH?)"
  default="$(printf '%s' "${default}" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  mkdir -p "${Q}"
  local n=1 qid
  n="$(find "${Q}" -maxdepth 1 -name 'Q*.md' 2>/dev/null | sed -n 's#.*/Q\([0-9][0-9]*\)\.md#\1#p' | sort -n | tail -1)"
  qid="Q$(( ${n:-0} + 1 ))"

  {
    echo "---"
    echo "id: ${qid}"
    echo "task: ${task}"
    echo "asked: $(iso_now)"
    echo "deadline: ${deadline}"
    [ -n "${default}" ] && echo "default: ${default}"
    echo "status: open"
    echo "---"
    echo
    echo "## Soru"
    echo
    printf '%s\n' "${text}"
    if [ -n "${options}" ]; then
      echo
      echo "## Seçenekler"
      echo
      printf '%s\n' "${options}" | tr '|' '\n' | sed 's/^[[:space:]]*//; s/^/- /'
    fi
    if [ -n "${rec}" ]; then
      echo
      echo "## Öneri"
      echo
      printf '%s\n' "${rec}"
    fi
  } > "${Q}/${qid}.md"

  if [ -n "${default}" ]; then
    notify "${qid} ${task}: ${text} (by ${deadline}, else: ${default})" question
  else
    notify "${qid} ${task}: ${text} (by ${deadline})" question
  fi
  echo "ASKED ${qid} for ${task}: written to .factory/questions/${qid}.md, the developer was notified, and it is on the dashboard."
  if [ -n "${default}" ]; then
    echo "Deadline ${deadline}: with no answer by then the task carries on with the default: ${default}"
  else
    echo "Deadline ${deadline}: with no answer by then the question expires and the task stays blocked."
  fi
  echo "Do not wait for the answer inside this turn: block the task, carry on with the rest of the board, and pick it up when the answer arrives."
}

cmd_answer() {
  local qid="${1:-}" answer="${2:-}"
  [ -n "${qid}" ] && [ -n "${answer}" ] || die "usage: answer <question-id> \"<answer>\""
  local file="${Q}/${qid}.md" status
  [ -f "${file}" ] || die "no such question: ${qid}"
  status="$(fmv "${file}" status)"
  case "${status}" in
    open|expired) ;;
    *) die "${qid} is already answered" ;;
  esac

  fm_status "${file}" "${status}" answered
  {
    echo
    echo "## Cevap ($(iso_now))"
    echo
    printf '%s\n' "${answer}"
  } >> "${file}"
  echo "ANSWERED ${qid}. The task it belongs to can be unblocked: $(fmv "${file}" task)"
}

cmd_expire() {
  [ -d "${Q}" ] || return 0
  local now f dl qid task def text
  now="$(iso_now)"
  for f in "${Q}"/Q*.md; do
    [ -e "${f}" ] || continue
    [ "$(fmv "${f}" status)" = "open" ] || continue
    dl="$(fmv "${f}" deadline)"
    # A question from before deadlines existed has none, and never expires.
    case "${dl}" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) continue ;;
    esac
    [ "${dl//[!0-9]/}" -gt "${now//[!0-9]/}" ] && continue
    qid="$(fmv "${f}" id)"; task="$(fmv "${f}" task)"; def="$(fmv "${f}" default)"
    if [ -n "${def}" ]; then
      fm_status "${f}" open answered
      fm_add "${f}" answered_by default
      {
        echo
        echo "## Cevap (${now})"
        echo
        printf '%s\n' "${def}"
        echo
        echo "(Nobody answered by ${dl}: this is the default the question was asked with.)"
      } >> "${f}"
      echo "DEFAULTED ${qid} for ${task}: no answer by ${dl}, so it was answered with its default: ${def}"
      notify "${qid} ${task}: no answer by ${dl}; the task carries on with the default: ${def}" question
    else
      fm_status "${f}" open expired
      fm_add "${f}" expired "${now}"
      text="$(sed -n '/^## Soru/,/^## /p' "${f}" | sed '1d;/^## /d' | grep -v '^$' | head -1)"
      echo "EXPIRED ${qid} for ${task}: no answer by ${dl} and no default, so the task stays blocked until factory-ask answer ${qid} \"...\"."
      notify "${qid} ${task}: still waiting for you, the task stays blocked: ${text}" question
    fi
  done
  return 0
}

cmd_list() {
  local which="${1:-open}" f status note dl def
  [ -d "${Q}" ] || { echo "(no questions)"; return 0; }
  for f in "${Q}"/Q*.md; do
    [ -e "${f}" ] || continue
    status="$(fmv "${f}" status)"
    case "${which}" in
      all) ;;
      # Open means waiting for the developer, and an expired question still is.
      open) [ "${status}" = open ] || [ "${status}" = expired ] || continue ;;
      *) [ "${status}" = "${which}" ] || continue ;;
    esac
    note=""
    dl="$(fmv "${f}" deadline)"; def="$(fmv "${f}" default)"
    case "${status}" in
      open)    [ -n "${dl}" ] && note=" (by ${dl}${def:+, else: ${def}})" ;;
      expired) note=" (expired ${dl}, the task stays blocked)" ;;
    esac
    printf '%s [%s] task=%s: %s%s\n' \
      "$(fmv "${f}" id)" \
      "${status}" \
      "$(fmv "${f}" task)" \
      "$(sed -n '/^## Soru/,/^## /p' "${f}" | sed '1d;/^## /d' | grep -v '^$' | head -1)" \
      "${note}"
  done
}

case "${1:-}" in
  ask)    shift; cmd_ask "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  list)   shift; cmd_list "$@" ;;
  expire) shift; cmd_expire "$@" ;;
  *)
    echo "usage: factory-ask.sh ask <task-id> \"<question>\" [\"<option>|<option>\"] [\"<recommendation>\"] [--deadline <N>h] [--default \"<answer>\"] | answer <question-id> \"<answer>\" | list [open|answered|expired|all] | expire" >&2
    exit 2
    ;;
esac
