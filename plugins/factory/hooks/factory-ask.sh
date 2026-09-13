#!/usr/bin/env bash
# Factory question inbox. NOT a hook: the lead runs it when the run needs a
# decision only the developer can make.
#
# Usage (from the project root):
#   factory-ask ask <task-id> "<question>" ["<option>|<option>"] ["<recommendation>"]
#   factory-ask answer <question-id> "<answer>"
#   factory-ask list [open|answered|all]
#
# Until now a task that needed the developer went quiet: it moved to blocked
# with needs_human: true and sat there until somebody read the board. A team
# that cannot ask its lead a question is not a team, it is a queue. This is the
# channel: one question, the options as the team sees them, and what the team
# would do - so the answer can be one word.
#
# Questions appear on the dashboard under "Sana ihtiyacı var", and raise a
# desktop notification the moment they are asked. They live in
# .factory/questions/ and stay on this machine.
set -uo pipefail

ROOT="$PWD"
Q="${ROOT}/.factory/questions"

die() { echo "factory-ask: $*" >&2; exit 1; }

notify() {  # best effort, never fatal
  local title="$1" body="$2"
  # Muted for tests and for anyone who does not want the popup.
  [ "${FACTORY_NO_NOTIFY:-0}" = "1" ] && return 0
  [ -f "$HOME/.claude/.factory-no-notify" ] && return 0
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${body//\"/}\" with title \"${title//\"/}\" sound name \"Glass\"" >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${body}" >/dev/null 2>&1 &
  fi
}

cmd_ask() {
  local task="${1:-}" text="${2:-}" options="${3:-}" rec="${4:-}"
  [ -n "${task}" ] && [ -n "${text}" ] || die "usage: ask <task-id> \"<question>\" [\"<option>|<option>\"] [\"<recommendation>\"]"
  ls "${ROOT}"/tasks/*/"${task}".md >/dev/null 2>&1 || die "no task file tasks/*/${task}.md - a question belongs to a task"

  mkdir -p "${Q}"
  local n=1 qid
  n="$(find "${Q}" -maxdepth 1 -name 'Q*.md' 2>/dev/null | sed -n 's#.*/Q\([0-9][0-9]*\)\.md#\1#p' | sort -n | tail -1)"
  qid="Q$(( ${n:-0} + 1 ))"

  {
    echo "---"
    echo "id: ${qid}"
    echo "task: ${task}"
    echo "asked: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
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

  notify "Factory · $(basename "${ROOT}")" "${task}: ${text}"
  echo "ASKED ${qid} for ${task}: written to .factory/questions/${qid}.md, the developer was notified, and it is on the dashboard."
  echo "Do not wait for the answer inside this turn: block the task, carry on with the rest of the board, and pick it up when the answer arrives."
}

cmd_answer() {
  local qid="${1:-}" answer="${2:-}"
  [ -n "${qid}" ] && [ -n "${answer}" ] || die "usage: answer <question-id> \"<answer>\""
  local file="${Q}/${qid}.md"
  [ -f "${file}" ] || die "no such question: ${qid}"
  grep -q '^status: open' "${file}" || die "${qid} is already answered"

  local tmp="${file}.tmp.$$"
  sed 's/^status: open$/status: answered/' "${file}" > "${tmp}" && mv -f "${tmp}" "${file}"
  {
    echo
    echo "## Cevap ($(date -u +"%Y-%m-%dT%H:%M:%SZ"))"
    echo
    printf '%s\n' "${answer}"
  } >> "${file}"
  echo "ANSWERED ${qid}. The task it belongs to can be unblocked: $(sed -n 's/^task:[[:space:]]*//p' "${file}" | head -1)"
}

cmd_list() {
  local which="${1:-open}" f status
  [ -d "${Q}" ] || { echo "(no questions)"; return 0; }
  for f in "${Q}"/Q*.md; do
    [ -e "${f}" ] || continue
    status="$(sed -n 's/^status:[[:space:]]*//p' "${f}" | head -1)"
    case "${which}" in
      all) ;;
      *) [ "${status}" = "${which}" ] || continue ;;
    esac
    printf '%s [%s] task=%s: %s\n' \
      "$(sed -n 's/^id:[[:space:]]*//p' "${f}" | head -1)" \
      "${status}" \
      "$(sed -n 's/^task:[[:space:]]*//p' "${f}" | head -1)" \
      "$(sed -n '/^## Soru/,/^## /p' "${f}" | sed '1d;/^## /d' | grep -v '^$' | head -1)"
  done
}

case "${1:-}" in
  ask)    shift; cmd_ask "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  list)   shift; cmd_list "$@" ;;
  *)
    echo "usage: factory-ask.sh ask <task-id> \"<question>\" [\"<option>|<option>\"] [\"<recommendation>\"] | answer <question-id> \"<answer>\" | list [open|answered|all]" >&2
    exit 2
    ;;
esac
