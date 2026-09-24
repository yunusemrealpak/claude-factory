#!/usr/bin/env bash
# Factory: is this project running the current harness, and what is missing?
#
# Usage (from the project root):
#   factory-upgrade          report what is missing
#   factory-upgrade --apply  add the safe parts
#   factory-upgrade --brief  one line, or nothing
#
# The hooks, commands and agents live in ~/.claude and are shared by every
# project, so those upgrade themselves the moment they are edited. What does
# NOT upgrade itself is everything /factory-init wrote INTO the project:
# gates/verify.sh, .factory/config.json, the task file layout, .gitignore. A
# project initialised by an older factory keeps running the older gate, and
# nothing about that is visible - the board still moves, it just stops being
# checked by whatever the newer gate added.
#
# --apply only ever adds: config keys that are missing, directories that are
# missing, gitignore lines that are missing, task sections that are missing. It
# never rewrites a value, a gate, or a task body. The gate is reported and left
# alone: it is the one file that is legitimately project-specific, and merging
# into it is /factory-init's job, with the developer watching.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="$PWD"
F="${ROOT}/.factory"
CONFIG="${F}/config.json"
GATE="${ROOT}/gates/verify.sh"
HARNESS="$(cat "${HOOK_DIR}/factory-version.txt" 2>/dev/null || echo unknown)"

mode=report
case "${1:-}" in
  --apply) mode=apply ;;
  --brief) mode=brief ;;
esac

[ -f "${F}/active" ] || { [ "${mode}" = "brief" ] && exit 0; echo "factory-upgrade: no .factory/active here - this is not a factory project."; exit 2; }

project_version="$(jq -r '.factory_version // "unknown"' "${CONFIG}" 2>/dev/null || echo unknown)"

# --- what is missing ---------------------------------------------------------
gaps=0
note() { gaps=$((gaps + 1)); [ "${mode}" = "brief" ] || echo "  - $*"; }

missing_keys=""
for key in verify workers max_concurrent_agents retry_limit min_tests gate_mode gate_isolation isolation_links risk_paths agent_stale_after_min; do
  jq -e --arg k "${key}" 'has($k)' "${CONFIG}" >/dev/null 2>&1 || missing_keys="${missing_keys} ${key}"
done

missing_dirs=""
for d in verified failures no-progress changes lessons questions inflight; do
  [ -d "${F}/${d}" ] || missing_dirs="${missing_dirs} ${d}"
done

missing_ignore=""
if [ -f "${ROOT}/.gitignore" ]; then
  for line in ".factory/verified/" ".factory/inflight/" ".factory/events.jsonl" ".factory/dashboard.html" ".factory/statusline.txt" ".factory/questions/" ".factory/run-owner" ".factory/logs/" ".factory/locks/" ".factory/run-start.json" ".factory/last-run.md" ".factory/parked/" ".factory/audit.md" ".factory/gate-start/"; do
    grep -qF "${line}" "${ROOT}/.gitignore" || missing_ignore="${missing_ignore} ${line}"
  done
fi

missing_gate=""
if [ -f "${GATE}" ]; then
  grep -q 'count_tests'        "${GATE}" || missing_gate="${missing_gate} count_tests"
  grep -q 'guard_test_census'  "${GATE}" || missing_gate="${missing_gate} guard_test_census"
  grep -q 'guard_acceptance'   "${GATE}" || missing_gate="${missing_gate} guard_acceptance"
  grep -q 'record_failure'     "${GATE}" || missing_gate="${missing_gate} record_failure"
  grep -q 'rm -f "${ROOT}/.factory/verified' "${GATE}" || missing_gate="${missing_gate} marker-invalidation"
  grep -q 'tree=' "${GATE}"            || missing_gate="${missing_gate} tree-fingerprint"
  grep -q 'isolate()' "${GATE}"        || missing_gate="${missing_gate} isolate(optional)"
else
  missing_gate=" (no gates/verify.sh at all)"
fi

missing_sections=""
for col in backlog in-progress proposed; do
  [ -d "${ROOT}/tasks/${col}" ] || continue
  for f in "${ROOT}/tasks/${col}"/*.md; do
    [ -e "${f}" ] || continue
    grep -qF '## Files touched' "${f}" && grep -qF '## Attempts' "${f}" && continue
    missing_sections="${missing_sections} $(basename "${f}" .md)"
  done
done

[ -n "${missing_keys}" ]     && note "config.json is missing:${missing_keys}"
[ -n "${missing_dirs}" ]     && note ".factory/ is missing:${missing_dirs}"
[ -n "${missing_ignore}" ]   && note ".gitignore is missing:${missing_ignore}"
[ -n "${missing_gate}" ]     && note "gates/verify.sh is missing:${missing_gate}"
[ -n "${missing_sections}" ] && note "task files with no '## Files touched' / '## Attempts':${missing_sections}"
[ "${project_version}" = "${HARNESS}" ] || note "initialised by factory ${project_version}, harness is now ${HARNESS}"

# --- brief: one line for the session briefing --------------------------------
if [ "${mode}" = "brief" ]; then
  [ "${gaps}" -eq 0 ] && exit 0
  echo "This project was set up by factory ${project_version}; the harness is ${HARNESS}, and ${gaps} thing(s) it writes into a project are out of date. Run /factory-upgrade - it is additive and takes seconds."
  exit 0
fi

if [ "${gaps}" -eq 0 ]; then
  echo "UPGRADE NONE: this project is current with factory ${HARNESS}."
  exit 0
fi

if [ "${mode}" = "report" ]; then
  echo
  echo "UPGRADE ${gaps} gap(s). 'factory-upgrade.sh --apply' adds the config keys, directories, gitignore lines and task sections."
  [ -n "${missing_gate}" ] && echo "The gate is never touched by --apply: run /factory-init in this project and it will offer to merge the missing parts into gates/verify.sh, keeping everything the file already does."
  exit 1
fi

# --- apply -------------------------------------------------------------------
applied=0

if [ -n "${missing_keys}" ] && [ -f "${CONFIG}" ]; then
  tmp="${CONFIG}.tmp.$$"
  # Defaults are the ones /factory-init writes. Existing values win: this is a
  # merge where the project's own config is on the right.
  jq -n --slurpfile cur "${CONFIG}" --arg v "${HARNESS}" '
    {
      factory_version: "unknown",
      verify: "gates/verify.sh",
      workers: 2,
      max_concurrent_agents: 3,
      retry_limit: 2,
      min_tests: 1,
      gate_mode: "staged",
      gate_isolation: false,
      agent_stale_after_min: 45,
      isolation_links: [],
      risk_paths: [
        "*/auth/*", "*authentication*", "*authorization*", "*identity*",
        "*permission*", "*tenant*", "*payment*", "*billing*",
        "*/migrations/*", "*.sql", "*secret*", "*crypto*", "*/.github/workflows/*"
      ]
    } * $cur[0]' > "${tmp}" 2>/dev/null \
    && mv -f "${tmp}" "${CONFIG}" && { echo "  added config keys:${missing_keys}"; applied=$((applied + 1)); }
fi

if [ -n "${missing_dirs}" ]; then
  for d in ${missing_dirs}; do mkdir -p "${F}/${d}"; done
  echo "  created .factory/:${missing_dirs}"
  applied=$((applied + 1))
fi

if [ -n "${missing_ignore}" ] && [ -f "${ROOT}/.gitignore" ]; then
  {
    echo ""
    echo "# factory (added by factory-upgrade)"
    for line in ${missing_ignore}; do echo "${line}"; done
  } >> "${ROOT}/.gitignore"
  echo "  added gitignore lines:${missing_ignore}"
  applied=$((applied + 1))
fi

if [ -n "${missing_sections}" ]; then
  for id in ${missing_sections}; do
    f="$(ls "${ROOT}"/tasks/*/"${id}".md 2>/dev/null | head -1)"
    [ -n "${f}" ] || continue
    grep -qF '## Files touched' "${f}" || printf '\n## Files touched\n' >> "${f}"
    grep -qF '## Attempts' "${f}" || printf '\n## Attempts\n' >> "${f}"
  done
  echo "  added the missing sections to:${missing_sections}"
  applied=$((applied + 1))
fi

# Stamp the version even when nothing else was missing, so the next check is
# quiet - except when the gate is behind, which --apply cannot fix.
if [ -z "${missing_gate}" ] && [ -f "${CONFIG}" ]; then
  tmp="${CONFIG}.tmp.$$"
  jq --arg v "${HARNESS}" '.factory_version = $v' "${CONFIG}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${CONFIG}"
fi

echo "UPGRADE APPLIED: ${applied} area(s) brought up to factory ${HARNESS}."
if [ -n "${missing_gate}" ]; then
  echo "STILL BEHIND - gates/verify.sh is missing:${missing_gate}"
  echo "The gate is the project's own file and is never rewritten by this script. Run /factory-init here: it reads the existing gate, reports exactly which protections it lacks and what each one would have caught, and merges in only the missing parts once you approve. Until then the config still says ${project_version}."
  exit 1
fi
exit 0
