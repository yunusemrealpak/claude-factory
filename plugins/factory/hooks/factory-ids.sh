#!/usr/bin/env bash
# Factory task-id integrity. NOT a hook: /factory-init, /factory-run and the
# SessionStart brief run it.
#
# Usage:
#   factory-ids check       [project-dir]
#   factory-ids next-prefix [project-dir]
#
# Everything the factory records is keyed by task id: the verified marker the
# done-guard trusts, the failure history the no-progress check reads, the file
# the lead's ready rule looks for in tasks/done. Two tasks sharing an id share
# all of that, so a second feature that reuses an id from the first inherits the
# first one's green marker, its failures and its place in the dependency graph.
# The instructions ask for unique ids; this script is what makes sure of it.
#
# check exits 1 on any finding (a collision, a reused id, a stale marker) and 0
# otherwise.
set -uo pipefail

cmd="${1:-check}"
ROOT="${2:-$PWD}"
ROOT="$(cd "${ROOT}" 2>/dev/null && pwd)" || { echo "no such directory: ${2:-$PWD}" >&2; exit 2; }
T="${ROOT}/tasks"
F="${ROOT}/.factory"
COLUMNS="proposed backlog in-progress blocked done"

list_ids() {  # one "<id> <column>" line per task file
  local col f
  for col in ${COLUMNS}; do
    [ -d "${T}/${col}" ] || continue
    for f in "${T}/${col}"/*.md; do
      [ -e "${f}" ] || continue
      printf '%s %s\n' "$(basename "${f}" .md)" "${col}"
    done
  done
}

case "${cmd}" in
  next-prefix)
    # A prefix names a change: one feature, bugfix or migration handed to the
    # factory. The original tasks (P0-, T-) are change 1, so the first increment
    # is C2. Both the task ids and the change archive are consulted, because ids
    # are never reused - not even those of a change whose task files were later
    # deleted. Numeric sort, so C10 comes after C9.
    n="$( { list_ids | awk '{print $1}' | sed -n 's/^C\([0-9][0-9]*\)-.*/\1/p'
            for d in "${F}"/changes/C*-*; do
              [ -d "${d}" ] && basename "${d}" | sed -n 's/^C\([0-9][0-9]*\)-.*/\1/p'
            done; } | sort -n | tail -1)"
    printf 'C%s\n' "$(( ${n:-1} + 1 ))"
    exit 0
    ;;
  check) ;;
  *)
    echo "usage: factory-ids.sh check|next-prefix [project-dir]" >&2
    exit 2
    ;;
esac

[ -d "${T}" ] || exit 0
ids="$(list_ids)"
blocking=0

# 1. The same id in two columns.
dups="$(printf '%s\n' "${ids}" | awk 'NF {print $1}' | sort | uniq -d)"
for id in ${dups}; do
  cols="$(printf '%s\n' "${ids}" | awk -v i="${id}" '$1==i {print $2}' | tr '\n' ' ')"
  echo "DUPLICATE ${id}: in ${cols}- two tasks share one id, and with it one verified marker, one failure history and one place in the dependency graph. Rename the one that is not in done."
  blocking=1
done

# 2. A proposed task whose id already has history. A task nobody has approved
#    has never run, so any marker, failure log or stall flag under its id was
#    left there by some other, earlier task.
reused="$(printf '%s\n' "${ids}" | awk '$2=="proposed" {print $1}' | while read -r id; do
  [ -n "${id}" ] || continue
  hist=""
  [ -e "${F}/verified/${id}" ]              && hist="${hist} verified-marker"
  [ -e "${F}/failures/${id}.log" ]          && hist="${hist} failure-log"
  [ -e "${F}/failures/resolved/${id}.log" ] && hist="${hist} resolved-failure-log"
  [ -e "${F}/no-progress/${id}" ]           && hist="${hist} no-progress-flag"
  [ -n "${hist}" ] && echo "REUSED ${id}: this new task's id already carries${hist} from an earlier task. Rename it."
done)"
if [ -n "${reused}" ]; then
  printf '%s\n' "${reused}"
  blocking=1
fi

# 3. A backlog task with a green marker. Either its id collides with an earlier
#    task, or it was sent back after a green gate and the marker was not
#    cleared. Either way the marker describes work that is not the current
#    work, and the done-guard, which only checks that a marker exists, would
#    accept the task on it without a new gate.
stale="$(printf '%s\n' "${ids}" | awk '$2=="backlog" {print $1}' | while read -r id; do
  [ -n "${id}" ] || continue
  [ -e "${F}/verified/${id}" ] && echo "STALE-MARKER ${id}: sits in backlog but carries a green verified marker from earlier work; the done-guard would accept it without a new gate. Delete .factory/verified/${id} before it is dispatched."
done)"
if [ -n "${stale}" ]; then
  printf '%s\n' "${stale}"
  blocking=1
fi

exit "${blocking}"
