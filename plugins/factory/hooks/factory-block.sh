#!/usr/bin/env bash
# Factory: stop working on a task and say why. NOT a hook.
#
# Usage (from the project root):
#   factory-block <task-id> "<reason>"
#
# Moves the task to tasks/blocked, appends the reason under "## Blocked reason"
# and drops any verified marker, so nothing downstream mistakes it for finished.
# Used when a builder gives up on a task: it needs a decision, it needs work
# outside its scope, or the check keeps failing on the same wall.
set -uo pipefail

TASK_ID="${1:-}"
shift 2>/dev/null
REASON="$*"
if [ -z "${TASK_ID}" ] || [ -z "${REASON}" ]; then
  echo "usage: factory-block <task-id> \"<reason>\"" >&2
  exit 2
fi
ROOT="$PWD"
T="${ROOT}/tasks"
F="${ROOT}/.factory"
[ -f "${F}/active" ] || { echo "BLOCK REFUSED for ${TASK_ID}: ${ROOT} has no .factory/active."; exit 1; }

src=""
for col in in-progress backlog; do
  if [ -f "${T}/${col}/${TASK_ID}.md" ]; then src="${col}"; break; fi
done
[ -n "${src}" ] || { echo "BLOCK REFUSED for ${TASK_ID}: no task file in tasks/in-progress or tasks/backlog."; exit 1; }

file="${T}/${src}/${TASK_ID}.md"
line="- $(date -u +"%Y-%m-%dT%H:%M:%SZ"): ${REASON}"
if grep -qE '^##[[:space:]]+Blocked reason[[:space:]]*$' "${file}"; then
  printf '%s\n' "${line}" >> "${file}"
else
  printf '\n## Blocked reason\n%s\n' "${line}" >> "${file}"
fi
rm -f "${F}/verified/${TASK_ID}"
mkdir -p "${T}/blocked"
mv "${file}" "${T}/blocked/${TASK_ID}.md"
jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" --arg id "${TASK_ID}" --arg f "${src}" \
  '{ts: $ts, epoch: $epoch, kind: "move", task: $id, from: $f, to: "blocked"}' >> "${F}/events.jsonl" 2>/dev/null
echo "BLOCKED ${TASK_ID}: ${REASON}"
exit 0
