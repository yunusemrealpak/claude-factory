#!/usr/bin/env bash
# Factory: which tasks can be dispatched right now?
#
# Usage (from the project root):
#   factory-ready [--ids]
#
# The lead used to work this out by reading every backlog file and holding the
# dependency graph in its head - model turns spent on arithmetic, and the one
# part of the loop where a mistake dispatches work whose dependency is not
# finished. This answers it from disk.
#
# Output, one line per task:
#   READY <id> <module> <title>
#   WAIT  <id> needs <id>,<id>
#   HOLD  <id> needs_human - never dispatched
#   STALL <id> the gate saw the identical failure twice
# and a final SUMMARY line.
set -uo pipefail

ROOT="$PWD"
T="${ROOT}/tasks"
ids_only=0
[ "${1:-}" = "--ids" ] && ids_only=1

fm() {  # <file> <key>
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" 2>/dev/null | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

done_ids=" "
if [ -d "${T}/done" ]; then
  for f in "${T}/done"/*.md; do
    [ -e "${f}" ] || continue
    done_ids="${done_ids}$(basename "${f}" .md) "
  done
fi

ready=0; wait_n=0; hold=0; stall=0
for f in "${T}/backlog"/*.md; do
  [ -e "${f}" ] || continue
  id="$(basename "${f}" .md)"

  if [ -f "${ROOT}/.factory/no-progress/${id}" ]; then
    [ "${ids_only}" -eq 1 ] || echo "STALL ${id} the gate saw the identical failure twice - it needs a different approach, not another dispatch"
    stall=$((stall + 1)); continue
  fi

  human="$(fm "${f}" needs_human | tr '[:upper:]' '[:lower:]')"
  if [ "${human}" = "true" ]; then
    [ "${ids_only}" -eq 1 ] || echo "HOLD ${id} needs_human - move it to tasks/blocked, never dispatch it"
    hold=$((hold + 1)); continue
  fi

  # depends_on: [A, B] - ids, in brackets or not, comma or space separated.
  deps="$(fm "${f}" depends_on | tr -d '[]"' | tr ',' ' ')"
  missing=""
  for d in ${deps}; do
    [ -n "${d}" ] || continue
    case "${done_ids}" in
      *" ${d} "*) ;;
      *) missing="${missing}${d}," ;;
    esac
  done
  if [ -n "${missing}" ]; then
    [ "${ids_only}" -eq 1 ] || echo "WAIT  ${id} needs ${missing%,}"
    wait_n=$((wait_n + 1)); continue
  fi

  if [ "${ids_only}" -eq 1 ]; then
    echo "${id}"
  else
    echo "READY ${id} $(fm "${f}" module) $(fm "${f}" title)"
  fi
  ready=$((ready + 1))
done

if [ "${ids_only}" -eq 0 ]; then
  in_prog=0
  [ -d "${T}/in-progress" ] && in_prog="$(find "${T}/in-progress" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "SUMMARY ready=${ready} wait=${wait_n} hold=${hold} stall=${stall} in-progress=${in_prog}"
fi
exit 0
