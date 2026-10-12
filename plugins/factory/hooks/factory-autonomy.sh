#!/usr/bin/env bash
# Factory: the autonomy level of this project, read - never raised - here.
#
# Usage (from the project root):
#   factory-autonomy            prints the level: local | pr | merge
#   factory-autonomy status     the level, and why it is that one
#   factory-autonomy off        writes .factory/autonomy-off (back to local)
#
# The level goes UP only through factory-consent.sh, which runs on a prompt the
# developer typed ("auto devam et"). This reader refuses to believe a file by
# itself: it re-checks the consent against the session transcript, and against
# the hard-block list the consent was given under. Anything it cannot confirm
# is `local`, the level at which nothing leaves the machine and nothing waits
# less than it used to.
#
# Exit: 0 always for level/status (the answer is the output); 2 usage error.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FACTORY_ROOT:-$PWD}"
F="${ROOT}/.factory"
CONSENT="${F}/autonomy.json"
OFF="${F}/autonomy-off"
CAP="${F}/autonomy-cap"
GLOBAL_OFF="${HOME}/.claude/.factory-autonomy-off"

cmd="${1:-level}"
case "${cmd}" in
  level|status|off) ;;
  *) echo "usage: factory-autonomy [status|off]" >&2; exit 2 ;;
esac

if [ "${cmd}" = "off" ]; then
  [ -f "${F}/active" ] || { echo "factory-autonomy: no .factory/active here - not a factory project."; exit 2; }
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '{off_at: $ts, by: "factory-autonomy off"}' > "${OFF}"
  echo "AUTONOMY OFF: level is local until a new 'auto devam et' is typed."
  exit 0
fi

LEVEL=local
WHY=""

resolve() {
  if [ -f "${GLOBAL_OFF}" ]; then WHY="the global kill switch ${GLOBAL_OFF} exists"; return; fi
  if [ -f "${OFF}" ]; then WHY=".factory/autonomy-off exists"; return; fi
  if [ ! -s "${CONSENT}" ]; then WHY="no consent recorded (.factory/autonomy.json)"; return; fi
  local level version current transcript
  level="$(jq -r '.level // empty' "${CONSENT}" 2>/dev/null)"
  case "${level}" in
    pr|merge|local) ;;
    *) WHY="the recorded level is not one of local, pr, merge"; return ;;
  esac
  version="$(jq -r '.hard_blocks_version // empty' "${CONSENT}" 2>/dev/null)"
  current="$(bash "${HOOK_DIR}/factory-hardblock.sh" version 2>/dev/null)"
  if [ -z "${current}" ] || [ "${version}" != "${current}" ]; then
    WHY="the consent was given under hard-block list ${version:-?}, this is ${current:-unreadable}"
    return
  fi
  transcript="$(jq -r '.transcript_path // empty' "${CONSENT}" 2>/dev/null)"
  if [ -z "${transcript}" ] || [ ! -f "${transcript}" ]; then
    WHY="the consent's transcript is not on disk (${transcript:-no path recorded})"
    return
  fi
  # A line the developer typed, whole, and nothing else: a user turn whose text
  # blocks join to exactly the phrase. Tool results are user-typed turns too in
  # the transcript, but they hold tool_result blocks, never text.
  if ! grep -i 'auto devam' "${transcript}" 2>/dev/null | jq -R -e '
        fromjson? | select(.type == "user") | .message.content
        | (if type == "string" then .
           elif type == "array" then ([.[] | select(type == "object" and .type == "text") | .text] | join("\n"))
           else "" end)
        | select(test("\\A\\s*auto devam( et)?\\s*\\z"; "i"))' >/dev/null 2>&1; then
    WHY="the transcript holds no line of yours that says exactly 'auto devam et'"
    return
  fi
  # A breaker's cap: the level may be lowered by the factory, never raised.
  if [ -s "${CAP}" ]; then
    cap="$(head -1 "${CAP}" | tr -d '[:space:]')"
    rank() { case "$1" in local) echo 0 ;; pr) echo 1 ;; merge) echo 2 ;; *) echo 0 ;; esac; }
    if [ "$(rank "${cap}")" -lt "$(rank "${level}")" ]; then
      LEVEL="${cap}"
      WHY="capped to ${cap} by a breaker (.factory/autonomy-cap): $(sed -n 2p "${CAP}")"
      return
    fi
  fi
  LEVEL="${level}"
  WHY="consent by $(jq -r '.consented_by // "unknown"' "${CONSENT}" 2>/dev/null) at $(jq -r '.consented_at // "?"' "${CONSENT}" 2>/dev/null)"
}

resolve

if [ "${cmd}" = "status" ]; then
  echo "AUTONOMY ${LEVEL}: ${WHY}"
  [ -f "${F}/STOP" ] && echo "STOP is set: $(head -1 "${F}/STOP" 2>/dev/null)"
  exit 0
fi
echo "${LEVEL}"
exit 0
