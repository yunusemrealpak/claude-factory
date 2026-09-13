#!/usr/bin/env bash
# Factory: is the integrator's second gate run necessary?
#
# Usage (from the project root):
#   factory-gate-skip hash [root]   fingerprint the product tree
#   factory-gate-skip check <task>  SKIP (exit 0) / RUN (exit 1)
#
# The gate runs twice per task: once for the implementer, once for the
# integrator on the tree everything else landed in. The second run is what
# catches two tasks that each pass alone and fail together - but when the tree
# has not changed by a single byte since the first run went green, it is a
# duplicate that costs the whole test suite in wall-clock time. This decides.
#
# The fingerprint covers the product tree only: HEAD, the diff against it, and
# the untracked files. Factory bookkeeping is excluded on purpose - the task
# file gets its "## Attempts" note and decisions.md gets its line between the
# gate and the integrator, and neither is code the gate tests.
#
# Every direction of doubt answers RUN.
set -uo pipefail

EXCLUDE=(':(exclude)tasks/' ':(exclude)decisions.md' ':(exclude).factory/')

fingerprint() {  # <root> - prints a hash, or nothing if this is not a git repo
  local root="$1"
  git -C "${root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  {
    git -C "${root}" rev-parse HEAD 2>/dev/null || echo "no-head"
    git -C "${root}" diff HEAD -- . "${EXCLUDE[@]}" 2>/dev/null \
      || git -C "${root}" diff -- . "${EXCLUDE[@]}" 2>/dev/null
    # Untracked files are part of the tree the gate saw; .gitignore keeps this
    # list short, so hashing their contents is cheap.
    git -C "${root}" ls-files --others --exclude-standard -z -- . "${EXCLUDE[@]}" 2>/dev/null \
      | while IFS= read -r -d '' f; do
          printf '%s ' "$f"
          shasum "${root}/${f}" 2>/dev/null | awk '{print $1}'
        done
  } | shasum | awk '{print $1}'
}

case "${1:-}" in
  hash)
    root="${2:-$PWD}"
    fingerprint "${root}" || { echo "unknown"; exit 0; }
    ;;
  check)
    id="${2:-}"
    [ -n "${id}" ] || { echo "factory-gate-skip: usage: check <task-id>" >&2; exit 2; }
    marker="${PWD}/.factory/verified/${id}"
    if [ ! -f "${marker}" ]; then
      echo "GATE RUN ${id}: no green marker - the gate has to run."
      exit 1
    fi
    if grep -q '^isolated=yes' "${marker}" 2>/dev/null; then
      echo "GATE RUN ${id}: the first run was isolated, so the shared tree has never been verified."
      exit 1
    fi
    want="$(sed -n 's/^tree=//p' "${marker}" | head -1)"
    if [ -z "${want}" ] || [ "${want}" = "unknown" ]; then
      echo "GATE RUN ${id}: the marker carries no tree fingerprint."
      exit 1
    fi
    have="$(fingerprint "${PWD}")" || have=""
    if [ -z "${have}" ]; then
      echo "GATE RUN ${id}: not a git repository, so the tree cannot be compared."
      exit 1
    fi
    if [ "${have}" != "${want}" ]; then
      echo "GATE RUN ${id}: the tree changed since the gate went green."
      exit 1
    fi
    echo "GATE SKIP ${id}: the tree is byte-identical to the one the gate passed on, so a second run would test the same bytes. Move the task to done and commit it."
    exit 0
    ;;
  *)
    echo "usage: factory-gate-skip.sh hash [root] | check <task-id>" >&2
    exit 2
    ;;
esac
