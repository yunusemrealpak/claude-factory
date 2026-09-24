#!/usr/bin/env bash
# Factory risk check. NOT a hook: the lead runs it on every task that comes back
# with a green gate and without `review: always`, before the integrator gets it.
#
# Usage: factory-risk <task-id>      (from the project root)
#
# A green gate means build, tests, architecture rules and lint passed. It says
# nothing about whether an authorization check is right, a tenant filter is
# present or a migration is safe to run - the things a test suite written by the
# same agent is least likely to probe. `review: always` covers that, but it is
# set by a model's judgement when the tasks are written, before anyone knows
# which files the work will actually touch.
#
# This check uses what is known afterwards: the task's "## Files touched" list,
# matched against the "risk_paths" patterns in .factory/config.json. A match
# sends the task to a reviewer before it is committed.
#
# Patterns are shell globs matched case-insensitively against "/<path>", and "*"
# also matches "/". A pattern that starts with neither "/" nor "*" matches at any
# depth. So "*/migrations/*" catches db/Migrations/001.sql, "*.sql" every SQL
# file, and "src/Auth/*" the same directory wherever the repo nests it.
#
# A file marked linguist-generated in .gitattributes, or matching a glob in
# "risk_exclude", is never a reason for review.
#
# Exit: 0 nothing risky touched; 1 review needed (the output says why);
#       2 usage error.
set -uo pipefail

TASK_ID="${1:-}"
if [ -z "${TASK_ID}" ]; then
  echo "usage: factory-risk <task-id>" >&2
  exit 2
fi
ROOT="$PWD"

TASK_FILE="$(ls "${ROOT}"/tasks/*/"${TASK_ID}".md 2>/dev/null | head -1)"
if [ -z "${TASK_FILE}" ]; then
  echo "RISK: no task file for ${TASK_ID} under tasks/" >&2
  exit 2
fi

patterns="$(jq -r '.risk_paths // [] | .[]' "${ROOT}/.factory/config.json" 2>/dev/null)"
if [ -z "${patterns}" ]; then
  echo "RISK none for ${TASK_ID}: .factory/config.json has no risk_paths, so nothing is checked."
  exit 0
fi

# Same parser as factory-commit.sh: "- path" lines (backticks allowed) under
# "## Files touched", up to the next heading of any level.
listed="$(awk '
  /^##[[:space:]]+Files touched[[:space:]]*$/ {inside=1; next}
  inside && /^#/ {exit}
  inside && /^[[:space:]]*[-*][[:space:]]+/ {
    sub(/^[[:space:]]*[-*][[:space:]]+/, "")
    gsub(/`/, "")
    split($0, w, /[[:space:]]+/)
    if (w[1] != "") print w[1]
  }' "${TASK_FILE}" | sed 's#^\./##' | sort -u)"

if [ -z "${listed}" ]; then
  echo "RISK ${TASK_ID}: the task lists no files under \"## Files touched\", so what it changed cannot be checked. Review it."
  exit 1
fi

# Generated files are not reviewed: nobody wrote them, and approving the output
# of a generator a reviewer cannot change is a dispatch spent on nothing. Two
# signals, neither tied to any tool: git's own linguist-generated attribute in
# .gitattributes, and the risk_exclude globs in the config.
excludes="$(jq -r '.risk_exclude // [] | .[]' "${ROOT}/.factory/config.json" 2>/dev/null)"
generated=""
matches_any() {  # <path> <newline-separated globs>
  local p="$1" pat glob
  while IFS= read -r pat; do
    [ -n "${pat}" ] || continue
    case "${pat}" in /*|\**) glob="${pat}" ;; *) glob="*/${pat}" ;; esac
    [[ "/${p}" == ${glob} ]] && return 0
  done <<< "$2"
  return 1
}

shopt -s nocasematch
hits=""
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  if [ "$(git -C "${ROOT}" check-attr linguist-generated -- "${p}" 2>/dev/null | awk -F': ' '{print $3}')" = "true" ] \
     || { [ -n "${excludes}" ] && matches_any "${p}" "${excludes}"; }; then
    generated="${generated} ${p}"
    continue
  fi
  while IFS= read -r pat; do
    [ -n "${pat}" ] || continue
    case "${pat}" in
      /*|\**) glob="${pat}" ;;
      *)      glob="*/${pat}" ;;
    esac
    # Unquoted on the right: it is a pattern, not a string.
    if [[ "/${p}" == ${glob} ]]; then
      hits="${hits}RISK ${TASK_ID}: ${p} matches \"${pat}\"
"
      break
    fi
  done <<< "${patterns}"
done <<< "${listed}"
shopt -u nocasematch

[ -n "${generated}" ] && echo "RISK skipped for ${TASK_ID}: generated or excluded:${generated}"
if [ -n "${hits}" ]; then
  printf '%s' "${hits}"
  echo "RISK ${TASK_ID}: review before commit - the gate cannot judge these files."
  exit 1
fi
echo "RISK none for ${TASK_ID}: $(printf '%s\n' "${listed}" | grep -c .) file(s), none on a risk path."
exit 0
