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
# Dependency manifests and lockfiles are always risk paths, whatever the
# config says: a new package is code nobody on the project wrote or reviewed,
# and a green test suite says nothing about where it came from. "risk_builtin":
# false in the config turns that list off.
#
# A file marked linguist-generated in .gitattributes, or matching a glob in
# "risk_exclude", is never a reason for review.
#
# What the check found for a reviewer is a reason too, whatever the paths: the
# "review=" lines factory-check writes into the task's marker (an ambiguous
# cheat signature, HEAD's version of a changed test failing on the new code).
# The marker is the factory's own record, which no agent may write.
#
# Exit: 0 nothing risky touched; 1 review needed (the output says why);
#       2 usage error.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/factory-compat.sh"

TASK_ID="${1:-}"
if [ -z "${TASK_ID}" ]; then
  echo "usage: factory-risk <task-id>" >&2
  exit 2
fi
ROOT="$PWD"

checked=""
MARKER="${ROOT}/.factory/verified/${TASK_ID}"
if [ -f "${MARKER}" ]; then
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "${line}" in
      review=?*) checked="${checked}RISK ${TASK_ID}: ${line#review=}
" ;;
    esac
  done < "${MARKER}"
fi
# Nothing on a risk path: still a review when the check asked for one.
none() {  # <the "RISK none" line>
  if [ -n "${checked}" ]; then
    printf '%s' "${checked}"
    echo "RISK ${TASK_ID}: review before commit - the check found what it cannot judge."
    exit 1
  fi
  echo "$1"
  exit 0
}

TASK_FILE="$(ls "${ROOT}"/tasks/*/"${TASK_ID}".md 2>/dev/null | head -1)"
if [ -z "${TASK_FILE}" ]; then
  echo "RISK: no task file for ${TASK_ID} under tasks/" >&2
  exit 2
fi

patterns="$(jq -r '.risk_paths // [] | .[]' "${ROOT}/.factory/config.json" 2>/dev/null)"
builtin=1
[ "$(jq -r '.risk_builtin' "${ROOT}/.factory/config.json" 2>/dev/null)" = "false" ] && builtin=0
if [ -z "${patterns}" ] && [ "${builtin}" = 0 ]; then
  none "RISK none for ${TASK_ID}: .factory/config.json has no risk_paths, so nothing is checked."
fi
# Matched against the file name alone, at any depth.
MANIFESTS='package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml pnpm-workspace.yaml bun.lock bun.lockb deno.json deno.lock
pubspec.yaml pubspec.lock
requirements*.txt constraints*.txt Pipfile Pipfile.lock poetry.lock uv.lock pdm.lock pyproject.toml setup.py setup.cfg
go.mod go.sum go.work
Cargo.toml Cargo.lock
*.csproj *.fsproj *.vbproj packages.config packages.lock.json Directory.Packages.props Directory.Build.props global.json
Gemfile Gemfile.lock *.gemspec
build.gradle build.gradle.kts settings.gradle settings.gradle.kts libs.versions.toml gradle-wrapper.properties pom.xml
composer.json composer.lock
Package.swift Package.resolved Podfile Podfile.lock Cartfile Cartfile.resolved
mix.exs mix.lock rebar.config cpanfile vcpkg.json conanfile.txt conanfile.py'
# Split with globbing off: "*.csproj" is a pattern, not the .csproj files that
# happen to sit in the current directory.
set -f
MANIFEST_PATTERNS=(${MANIFESTS})
set +f
is_manifest() {  # <path>
  local base="${1##*/}" m
  for m in "${MANIFEST_PATTERNS[@]}"; do
    # Unquoted on the right: it is a pattern.
    [[ "${base}" == ${m} ]] && return 0
  done
  return 1
}

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

if [ -z "${listed}" ] && [ -z "${patterns}" ]; then
  none "RISK none for ${TASK_ID}: the task lists no files and .factory/config.json has no risk_paths."
fi
if [ -z "${listed}" ]; then
  printf '%s' "${checked}"
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
  if [ "${builtin}" = 1 ] && is_manifest "${p}"; then
    hits="${hits}RISK ${TASK_ID}: ${p} is a dependency manifest - what it pulls in is code nobody here reviewed
"
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
hits="${checked}${hits}"

[ -n "${generated}" ] && echo "RISK skipped for ${TASK_ID}: generated or excluded:${generated}"
if [ -n "${hits}" ]; then
  printf '%s' "${hits}"
  echo "RISK ${TASK_ID}: review before commit - the gate cannot judge what is listed above."
  exit 1
fi
none "RISK none for ${TASK_ID}: $(printf '%s\n' "${listed}" | grep -c .) file(s), none on a risk path."
