#!/usr/bin/env bash
# Factory: records the developer's own words as autonomy consent. A
# UserPromptSubmit hook, and the process register.js starts from prompt.submit.
#
# stdin: JSON { prompt, cwd, session_id, transcript_path?, origin? }
#   origin  set by register.js to the prompt's origin kind; only a prompt the
#           developer typed counts (composer, or the Remote Control bridge). The
#           command hook has no origin: Claude Code runs it for typed prompts.
#
# Phrases, whole prompt, case-insensitive:
#   auto devam [et]  -> .factory/autonomy.json (level = config.autonomy_default,
#                       else merge), and .factory/autonomy-off is removed
#   auto dur         -> .factory/autonomy-off
# Anything else - text before or after, a quote, several lines, "auto devam
# etme" - is not consent and is ignored without a word.
#
# Idempotent: running it twice (hook and module both) writes once and notifies
# once. Never fails a prompt: always exits 0.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

prompt="$(printf '%s' "${input}" | jq -r '.prompt // empty' 2>/dev/null)"
cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"
transcript="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
origin="$(printf '%s' "${input}" | jq -r '.origin // empty' 2>/dev/null)"

[ -n "${prompt}" ] || exit 0
[ -n "${cwd}" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
F="${cwd}/.factory"
[ -f "${F}/active" ] || exit 0

case "${origin}" in
  ""|composer|bridge) ;;
  *) exit 0 ;;
esac

phrase="$(printf '%s' "${prompt}" | tr '[:upper:]' '[:lower:]')"
action=""
if [[ "${phrase}" =~ ^[[:space:]]*auto\ devam(\ et)?[[:space:]]*$ ]]; then
  action=on
elif [[ "${phrase}" =~ ^[[:space:]]*auto\ dur[[:space:]]*$ ]]; then
  action=off
else
  exit 0
fi

notify() {  # <body>
  [ "${FACTORY_NO_NOTIFY:-0}" = "1" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"${1//\"/}\" with title \"Factory\"" >/dev/null 2>&1 &
}

now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
project="$(basename "${cwd}")"

if [ "${action}" = "off" ]; then
  if [ ! -f "${F}/autonomy-off" ]; then
    jq -cn --arg ts "${now}" --arg s "${sid}" '{off_at: $ts, by: "auto dur", session_id: $s}' > "${F}/autonomy-off"
    notify "${project}: autonomy off (local)"
    echo "Factory: autonomy is off (level local)."
  fi
  exit 0
fi

level="$(jq -r '.autonomy_default // empty' "${F}/config.json" 2>/dev/null)"
case "${level}" in pr|merge|local) ;; *) level=merge ;; esac

if [ -z "${transcript}" ] && [ -n "${sid}" ]; then
  transcript="${HOME}/.claude/projects/$(printf '%s' "${cwd}" | sed 's/[^A-Za-z0-9]/-/g')/${sid}.jsonl"
fi
version="$(bash "${HOOK_DIR}/factory-hardblock.sh" version 2>/dev/null)"
email="$(git -C "${cwd}" config user.email 2>/dev/null)"

# Same consent already on file: nothing to write, nothing to announce.
if [ -s "${F}/autonomy.json" ] && [ ! -f "${F}/autonomy-off" ] \
   && [ "$(jq -r '[.level, .session_id, .hard_blocks_version | tostring] | join("|")' "${F}/autonomy.json" 2>/dev/null)" = "${level}|${sid}|${version}" ]; then
  exit 0
fi

tmp="${F}/autonomy.json.tmp.$$"
jq -n --arg level "${level}" --arg scope "project" --arg at "${now}" --arg by "${email}" \
      --arg sid "${sid}" --arg tp "${transcript}" --arg v "${version}" \
  '{level: $level, scope: $scope, consented_at: $at, consented_by: $by,
    session_id: $sid, transcript_path: $tp, hard_blocks_version: $v}' > "${tmp}" 2>/dev/null \
  && mv -f "${tmp}" "${F}/autonomy.json"
rm -f "${F}/autonomy-off"
notify "${project}: autonomy raised to ${level}"
echo "Factory: autonomy level ${level} recorded from your 'auto devam et'. 'auto dur' turns it off."
exit 0
