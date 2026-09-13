#!/usr/bin/env bash
# Factory: run a change's own acceptance command and record the verdict.
#
# Usage (from the project root):
#   factory-accept <change-id>
#   factory-accept <change-id> --show    last verdict only
#
# Every task green is not the same claim as "the change works". Tasks pass one
# at a time, against their own acceptance command; the feature they add up to
# can still be broken at the seams - a screen nobody wired up, a migration that
# runs but leaves the app unable to read its own data. A change may therefore
# carry one command of its own, written into goal.md at approval. This runs it.
#
# The verdict is recorded against the change's task set, not against a moment in
# time: add a task to the change afterwards and the verdict stops counting, so
# it has to run again. factory-change.sh will not close a change whose
# acceptance command has not run green against the task set it has now.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="$PWD"
CH="${ROOT}/.factory/changes"

die() { echo "factory-accept: $*" >&2; exit 2; }

id="${1:-}"
[ -n "${id}" ] || die "usage: factory-accept.sh <change-id> [--show]"
shift
show_only=0
[ "${1:-}" = "--show" ] && show_only=1

dir=""
for d in "${CH}/${id}"-*; do [ -d "${d}" ] && dir="${d}"; done
[ -n "${dir}" ] || die "no change ${id} under .factory/changes/"

fm_field() {
  [ -f "$1" ] || return 0
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

cmd="$(fm_field "${dir}/goal.md" acceptance)"
sig="$(bash "${HOOK_DIR}/factory-change.sh" sig "${id}" 2>/dev/null)"
acc="${dir}/acceptance"
log="${dir}/acceptance.log"

if [ -z "${cmd}" ]; then
  echo "ACCEPT NONE ${id}: this change has no acceptance command of its own, so it closes on its tasks alone."
  exit 0
fi

if [ "${show_only}" -eq 1 ]; then
  if [ ! -f "${acc}" ]; then
    echo "ACCEPT NEVER-RUN ${id}: ${cmd}"
    exit 1
  fi
  verdict="$(sed -n 's/^verdict=//p' "${acc}" | head -1)"
  seen="$(sed -n 's/^sig=//p' "${acc}" | head -1)"
  [ "${seen}" = "${sig}" ] || verdict="stale"
  echo "ACCEPT ${verdict} ${id}: ${cmd} (last run $(sed -n 's/^at=//p' "${acc}" | head -1))"
  [ "${verdict}" = "green" ]
  exit $?
fi

# Anything uncommitted is part of what gets judged: the change's work is in the
# tree, committed task by task, and the developer's own edits are in there too.
echo "ACCEPT RUNNING ${id}: ${cmd}"
start="$(date +%s)"
out="$( { eval "${cmd}"; } 2>&1 )"
rc=$?
took=$(( $(date +%s) - start ))

{
  echo "=== $(date -u +"%Y-%m-%dT%H:%M:%SZ")  ${cmd}  (exit ${rc}, ${took}s)"
  printf '%s\n' "${out}"
  echo
} >> "${log}"

verdict=red
[ "${rc}" -eq 0 ] && verdict=green
{
  echo "verdict=${verdict}"
  echo "at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "sig=${sig}"
  echo "command=${cmd}"
  echo "commit=$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo none)"
  echo "seconds=${took}"
} > "${acc}"

printf '%s\n' "${out}" | tail -30

if [ "${verdict}" = "green" ]; then
  echo "ACCEPT GREEN ${id} in ${took}s. The change can close: factory-change sync ${id}"
  exit 0
fi

echo "ACCEPT RED ${id} (exit ${rc}, ${took}s). The change stays open; full output in ${log#"${ROOT}/"}."
echo "Every task is green on its own, so this is a seam between them: what the tasks add up to does not do what the change asked for. Report it with the failing output - do not close the change and do not edit the acceptance command to make it pass."
exit 1
