#!/usr/bin/env bash
# Factory: take one task off the board. NOT a hook: a builder runs it as its
# first command.
#
# Usage (from the project root):
#   factory-start <task-id> [owner]
#
# One call lints the task, moves it into tasks/in-progress, writes owner, stage
# and stage_since, and prints the task file together with the lessons for its
# module.
# The builder starts with everything it needs in one tool result.
#
# A task already in tasks/in-progress is a retry, or a task a dead run left
# behind: it is taken over as it is, attempts and all.
#
# Exit: 0 started; 1 refused (the output says why; "HALTED" when .factory/STOP
# is set); 2 usage error.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"

TASK_ID="${1:-}"
OWNER="${2:-builder}"
if [ -z "${TASK_ID}" ]; then
  echo "usage: factory-start <task-id> [owner]" >&2
  exit 2
fi
ROOT="$PWD"
T="${ROOT}/tasks"
F="${ROOT}/.factory"
[ -f "${F}/active" ] || { echo "START REFUSED for ${TASK_ID}: ${ROOT} has no .factory/active - not a factory project, or not its root."; exit 1; }

# The kill switch. A hard block was hit, or the developer wrote this file: no
# task starts, and the builder reports `halted` instead of working around it.
if [ -f "${F}/STOP" ]; then
  echo "START REFUSED for ${TASK_ID}: HALTED - .factory/STOP is set ($(head -1 "${F}/STOP" 2>/dev/null)). Do nothing else and return status halted; only the developer removes that file."
  exit 1
fi

# The unpushed breaker: commits that exist only on this machine pile up silently
# when autonomy is local, so past the limit nothing new starts.
if ! unpushed_msg="$(FACTORY_ROOT="${ROOT}" bash "${HOOK_DIR}/factory-unpushed.sh" check 2>/dev/null)"; then
  echo "START REFUSED for ${TASK_ID}: ${unpushed_msg} Do nothing else and return status halted."
  exit 1
fi

src=""
for col in in-progress backlog; do
  if [ -f "${T}/${col}/${TASK_ID}.md" ]; then src="${col}"; break; fi
done
if [ -z "${src}" ]; then
  where="$(ls "${T}"/*/"${TASK_ID}.md" 2>/dev/null | head -1)"
  echo "START REFUSED for ${TASK_ID}: ${where:+it is in ${where#"${T}"/} - }only a task in tasks/backlog or tasks/in-progress can be started."
  exit 1
fi

fm() {  # <file> <key>
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" 2>/dev/null | tr -d '\r' | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

# Rewrites one key inside the leading --- block, adding it when it is missing.
set_fm() {  # <file> <key> <value>
  awk -v k="$2" -v v="$3" '
    NR==1 && /^---[[:space:]]*$/ { inside=1; print; next }
    inside && /^---[[:space:]]*$/ { if (!done) print k ": " v; inside=0; print; next }
    inside && index($0, k ":") == 1 && !done { print k ": " v; done=1; next }
    { print }' "$1" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

file="${T}/${src}/${TASK_ID}.md"
if [ "$(fm "${file}" needs_human | tr '[:upper:]' '[:lower:]')" = "true" ]; then
  echo "START REFUSED for ${TASK_ID}: needs_human: true - no agent works on it. Move it to tasks/blocked and ask the developer."
  exit 1
fi
# A task builds on the committed work of what it depends on. One whose
# dependency has not landed - blocked, failed, never run, or done but its commit
# failed - would be built on code that is not there.
in_git=0
git -C "${ROOT}" rev-parse -q --verify HEAD >/dev/null 2>&1 && in_git=1
for dep in $(fm "${file}" depends_on | tr -d '[]"'"'" | tr ',' ' '); do
  if [ ! -f "${T}/done/${dep}.md" ]; then
    lane="$(ls "${T}"/*/"${dep}.md" 2>/dev/null | head -1)"; lane="${lane#"${T}"/}"; lane="${lane%%/*}"
    echo "START REFUSED for ${TASK_ID}: DEPENDENCY ${dep} is not done${lane:+ (it is in tasks/${lane})}. Change nothing and return status refused."
    exit 1
  fi
  if [ "${in_git}" = 1 ] && ! git -C "${ROOT}" check-ignore -q "tasks/done/${dep}.md" 2>/dev/null \
     && ! git -C "${ROOT}" cat-file -e "HEAD:./tasks/done/${dep}.md" 2>/dev/null; then
    echo "START REFUSED for ${TASK_ID}: DEPENDENCY ${dep} is in tasks/done but not committed, so its work is not in HEAD. Change nothing and return status refused."
    exit 1
  fi
done

if [ -f "${F}/no-progress/${TASK_ID}" ] && [ "${FACTORY_ESCALATION:-0}" != "1" ]; then
  echo "START NOTE for ${TASK_ID}: the check has already seen the same failure twice ($(sed -n 's/^detail=//p' "${F}/no-progress/${TASK_ID}")). Read the ## Attempts section first and change the approach."
fi

lint="$(bash "${HOOK_DIR}/factory-lint.sh" "${TASK_ID}" 2>&1)" || {
  echo "START REFUSED for ${TASK_ID}: the task file does not lint - fix it, then start again:"
  printf '%s\n' "${lint}"
  exit 1
}

if [ "${src}" = "backlog" ]; then
  mkdir -p "${T}/in-progress"
  mv "${file}" "${T}/in-progress/${TASK_ID}.md"
  file="${T}/in-progress/${TASK_ID}.md"
  if [ -d "${F}" ]; then
    jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" --arg id "${TASK_ID}" \
      '{ts: $ts, epoch: $epoch, kind: "move", task: $id, from: "backlog", to: "in-progress"}' \
      >> "${F}/events.jsonl" 2>/dev/null
  fi
fi
set_fm "${file}" owner "${OWNER}"
set_fm "${file}" stage implementing
set_fm "${file}" stage_since "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "STARTED ${TASK_ID} (${src} -> in-progress, owner ${OWNER})"
echo
echo "=== tasks/in-progress/${TASK_ID}.md"
cat "${file}"
module="$(fm "${file}" module)"
# What earlier tasks of this module decided: the cheapest context there is, and
# the part a fresh builder would otherwise rediscover or contradict.
if [ -n "${module}" ] && [ -s "${ROOT}/decisions.md" ]; then
  mine=""
  while IFS= read -r line; do
    id="$(printf '%s' "${line}" | sed -n -E 's/^- ([A-Za-z0-9._-]+):.*/\1/p')"
    [ -n "${id}" ] && [ "${id}" != "${TASK_ID}" ] || continue
    tf="$(ls "${T}"/*/"${id}.md" 2>/dev/null | head -1)"
    [ -n "${tf}" ] && [ "$(fm "${tf}" module)" = "${module}" ] && mine="${mine}${line}
"
  done < "${ROOT}/decisions.md"
  if [ -n "${mine}" ]; then
    echo
    echo "=== decisions already taken in module ${module}"
    printf '%s' "${mine}" | tail -8
  fi
fi
for scope in general ${module}; do
  lf="${F}/lessons/${scope}.md"
  if [ -s "${lf}" ]; then
    echo
    echo "=== lessons: ${scope} (rules approved after earlier tasks failed on them; the task file wins where they disagree)"
    cat "${lf}"
  fi
done
exit 0
