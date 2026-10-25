#!/usr/bin/env bash
# Factory: land one task. NOT a hook: a builder runs it once its check is green.
#
# Usage (from the project root):
#   factory-land <task-id>
#
# Moves the task into tasks/done and records it as one commit of exactly its own
# files (factory-commit.sh). This is the integrator's whole job, and every step
# of it was deterministic: it no longer costs an agent, its start-up and a second
# run of the test suite. Whether the tasks work together is what
# factory-check --full answers, once, when the board is built.
#
# The done-guard hook cannot see a move made inside a script, so the marker is
# checked here, before anything moves: no green check, no landing.
#
# Two builders can finish at the same moment. Git's index takes one writer, so
# lands are serialised with a lock.
#
# The last line says how it went: LANDED <id> <sha>, LAND SKIPPED (already in
# tasks/done and committed), LAND UNCOMMITTED (in tasks/done, check green, but
# no commit has it - its dependents cannot start), LAND REFUSED.
#
# Exit: 0 landed, skipped or uncommitted (the task is done either way); 1
# refused.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"

TASK_ID="${1:-}"
if [ -z "${TASK_ID}" ]; then
  echo "usage: factory-land <task-id>" >&2
  exit 2
fi
ROOT="$PWD"
T="${ROOT}/tasks"
F="${ROOT}/.factory"
[ -f "${F}/active" ] || { echo "LAND REFUSED for ${TASK_ID}: ${ROOT} has no .factory/active."; exit 1; }

if [ -f "${T}/done/${TASK_ID}.md" ]; then
  if git -C "${ROOT}" rev-parse -q --verify HEAD >/dev/null 2>&1      && ! git -C "${ROOT}" check-ignore -q "tasks/done/${TASK_ID}.md" 2>/dev/null      && ! git -C "${ROOT}" cat-file -e "HEAD:./tasks/done/${TASK_ID}.md" 2>/dev/null; then
    echo "LAND UNCOMMITTED ${TASK_ID}: it is in tasks/done, but no commit has it - its dependents cannot start until it is committed."
    exit 0
  fi
  echo "LAND SKIPPED for ${TASK_ID}: it is already in tasks/done."
  exit 0
fi
src=""
for col in in-progress backlog; do
  if [ -f "${T}/${col}/${TASK_ID}.md" ]; then src="${col}"; break; fi
done
[ -n "${src}" ] || { echo "LAND REFUSED for ${TASK_ID}: no task file in tasks/in-progress or tasks/backlog."; exit 1; }
if [ ! -f "${F}/verified/${TASK_ID}" ]; then
  echo "LAND REFUSED for ${TASK_ID}: no green check. Run factory-check ${TASK_ID} and land only after it prints CHECK RESULT: GREEN."
  exit 1
fi

lock="${F}/locks/land"
mkdir -p "${F}/locks"
waited=0
until mkdir "${lock}" 2>/dev/null; do
  # A lock older than ten minutes belongs to a land that died.
  if [ -n "$(find "${lock}" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "${lock}" 2>/dev/null; continue; fi
  sleep 0.2
  waited=$((waited + 1))
  [ "${waited}" -gt 3000 ] && break
done
trap 'rmdir "${lock}" 2>/dev/null' EXIT

emit() {  # <kind> <jq object of extra fields>
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" --arg kind "$1" --argjson extra "$2" \
    '{ts: $ts, epoch: $epoch, kind: $kind} + $extra' >> "${F}/events.jsonl" 2>/dev/null
}

mkdir -p "${T}/done"
mv "${T}/${src}/${TASK_ID}.md" "${T}/done/${TASK_ID}.md"
emit move "$(jq -cn --arg id "${TASK_ID}" --arg f "${src}" '{task: $id, from: $f, to: "done"}')"

out="$(bash "${HOOK_DIR}/factory-commit.sh" "${TASK_ID}" 2>&1)"
rc=$?
printf '%s\n' "${out}"
sha="$(printf '%s\n' "${out}" | sed -n -E 's#^COMMIT ([0-9a-f]+) .*#\1#p' | head -1)"
emit commit "$(jq -cn --arg id "${TASK_ID}" --arg s "${sha:-none}" '{task: $id, sha: $s}')"
if [ "${rc}" -ne 0 ]; then
  echo "LAND UNCOMMITTED ${TASK_ID}: the task is done and its check is green, but the commit was refused (above) - its dependents cannot start until it is committed."
  exit 0
fi
echo "LANDED ${TASK_ID} ${sha:-(nothing to commit)}"
exit 0
