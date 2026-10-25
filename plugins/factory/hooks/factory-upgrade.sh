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
# never rewrites a value, a gate, or a task body. The one replacement it makes is
# the old 64-line "## Factory Protokolü" section of CLAUDE.md, which every agent
# read on every turn and which contradicted the agents' own instructions: it
# becomes the short pointer /factory:init now writes, and the old text is kept
# in .factory/claude-md-protocol.old.md. The gate is reported and left
# alone: it is the one file that is legitimately project-specific, and merging
# into it is /factory-init's job, with the developer watching.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"

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
for key in verify workers max_concurrent_agents retry_limit min_tests gate_mode gate_isolation isolation_links risk_paths agent_stale_after_min autonomy_default; do
  jq -e --arg k "${key}" 'has($k)' "${CONFIG}" >/dev/null 2>&1 || missing_keys="${missing_keys} ${key}"
done

# Keys one level down, in the blocks the fast lane reads. Only the ones that
# have a default worth writing down: the rest are optional and absent on purpose.
for key in fast.workers fast.risk_review fast.audit fast.effort_build fast.effort_escalate fast.effort_review fast.effort_audit check.claude_md_max_lines check.untracked_guard delivery.branch delivery.merge_method delivery.max_unpushed retro.mode; do
  block="${key%%.*}"; leaf="${key#*.}"
  jq -e --arg b "${block}" --arg k "${leaf}" '(.[$b] // {}) | has($k)' "${CONFIG}" >/dev/null 2>&1 || missing_keys="${missing_keys} ${key}"
done

missing_dirs=""
for d in verified failures no-progress changes lessons questions inflight; do
  [ -d "${F}/${d}" ] || missing_dirs="${missing_dirs} ${d}"
done

missing_ignore=""
if [ -f "${ROOT}/.gitignore" ]; then
  for line in ".factory/verified/" ".factory/inflight/" ".factory/events.jsonl" ".factory/dashboard.html" ".factory/statusline.txt" ".factory/questions/" ".factory/run-owner" ".factory/logs/" ".factory/locks/" ".factory/run-start.json" ".factory/last-run.md" ".factory/parked/" ".factory/audit.md" ".factory/gate-start/" ".factory/usage.jsonl" ".factory/autonomy.json" ".factory/autonomy-off" ".factory/autonomy-cap" ".factory/publish/" ".factory/digest/" ".factory/retro-due" ".factory/STOP" ".factory/lead-state.read.md" ".factory/claude-md-protocol.old.md"; do
    grep -qF "${line}" "${ROOT}/.gitignore" || missing_ignore="${missing_ignore} ${line}"
  done
fi

# The hard bans' second layer: the permissions.deny rules of hard-blocks.txt in
# .claude/settings.json. factory-deny.sh holds the list and does the merge.
missing_deny=""
if ! FACTORY_ROOT="${ROOT}" bash "${HOOK_DIR}/factory-deny.sh" >/dev/null 2>&1; then
  missing_deny=" permissions.deny"
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

old_protocol=""
if [ -f "${ROOT}/CLAUDE.md" ] && grep -q '^## Factory Protokolü[[:space:]]*$' "${ROOT}/CLAUDE.md"; then
  old_protocol=yes
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
[ -n "${missing_deny}" ]     && note ".claude/settings.json is missing hard-ban rules in:${missing_deny}"
[ -n "${missing_gate}" ]     && note "gates/verify.sh is missing:${missing_gate}"
[ -n "${missing_sections}" ] && note "task files with no '## Files touched' / '## Attempts':${missing_sections}"
[ -n "${old_protocol}" ]     && note "CLAUDE.md still carries the old '## Factory Protokolü' section (every agent reads it on every turn)"
[ "${project_version}" = "${HARNESS}" ] || note "initialised by factory ${project_version}, harness is now ${HARNESS}"

# --- brief: one line for the session briefing --------------------------------
if [ "${mode}" = "brief" ]; then
  [ "${gaps}" -eq 0 ] && exit 0
  echo "This project was set up by factory ${project_version}; the harness is ${HARNESS}, and ${gaps} thing(s) it writes into a project are out of date. Run /factory:upgrade - it is additive and takes seconds."
  exit 0
fi

if [ "${gaps}" -eq 0 ]; then
  echo "UPGRADE NONE: this project is current with factory ${HARNESS}."
  exit 0
fi

if [ "${mode}" = "report" ]; then
  echo
  echo "UPGRADE ${gaps} gap(s). 'factory-upgrade.sh --apply' adds the config keys, directories, gitignore lines, deny rules and task sections, and replaces the old CLAUDE.md protocol with its pointer."
  [ -n "${missing_gate}" ] && echo "The gate is never touched by --apply: run /factory:init in this project and it will offer to merge the missing parts into gates/verify.sh, keeping everything the file already does."
  exit 1
fi

# --- apply -------------------------------------------------------------------
applied=0

# Whether config.json is tracked and untouched right now. The retrospective
# refuses to change a file with uncommitted edits, so an upgrade that leaves its
# own edit uncommitted would lock the retrospective out of the config.
config_was_clean=no
if git -C "${ROOT}" ls-files --error-unmatch -- ".factory/config.json" >/dev/null 2>&1 \
   && [ -z "$(git -C "${ROOT}" status --porcelain -- ".factory/config.json" 2>/dev/null)" ]; then
  config_was_clean=yes
fi

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
      autonomy_default: "merge",
      isolation_links: [],
      fast: {
        workers: 4, risk_review: "after", audit: true,
        effort_build: "medium", effort_escalate: "high", effort_review: "high", effort_audit: "high"
      },
      check: { claude_md_max_lines: 200, untracked_guard: true },
      delivery: { branch: "main", merge_method: "rebase", base: "main", quota_margin: 10, max_unpushed: 30 },
      retro: { mode: "suggest", min_sample: 10 },
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

if [ -n "${missing_deny}" ]; then
  FACTORY_ROOT="${ROOT}" bash "${HOOK_DIR}/factory-deny.sh" --apply | sed 's/^/  /'
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

if [ -n "${old_protocol}" ]; then
  claude_was_clean=no
  if git -C "${ROOT}" ls-files --error-unmatch -- CLAUDE.md >/dev/null 2>&1 \
     && [ -z "$(git -C "${ROOT}" status --porcelain -- CLAUDE.md 2>/dev/null)" ]; then
    claude_was_clean=yes
  fi
  # The section runs from its heading to the next level-1 or level-2 heading, or
  # to the end of the file; its own subsections are level 3.
  if FACTORY_POINTER="$(cat <<'POINTER'
<!-- factory: written by /factory:init, kept current by /factory:upgrade -->
## Factory
While `.factory/active` exists this project is built by the factory plugin: `tasks/` is the board, each task file is the source of truth for its work, and every factory agent follows its own instructions. Hooks enforce the hard blocks (`/factory:bans`); `/factory:fast` builds the approved backlog and `/factory:status` shows the board.
Compact instructions: keep which tasks were dispatched and at which stage, the last check results, retries and blocked reasons; where the summary and `.factory/lead-state.md` disagree, the file is right.
<!-- /factory -->
POINTER
)" awk -v keep="${F}/claude-md-protocol.old.md" '
      BEGIN { pointer = ENVIRON["FACTORY_POINTER"] }
      !inside && /^## Factory Protokolü[[:space:]]*$/ { inside = 1; print pointer; print $0 > keep; next }
      inside && /^##?[ 	]/ { inside = 0 }
      inside { print > keep; next }
      { print }' "${ROOT}/CLAUDE.md" > "${ROOT}/CLAUDE.md.tmp.$$" \
     && mv -f "${ROOT}/CLAUDE.md.tmp.$$" "${ROOT}/CLAUDE.md"; then
    echo "  replaced the old CLAUDE.md protocol with the pointer (the old text is in .factory/claude-md-protocol.old.md)"
    applied=$((applied + 1))
    if [ "${claude_was_clean}" = yes ]; then
      git -C "${ROOT}" add -- CLAUDE.md >/dev/null 2>&1 \
        && git -C "${ROOT}" commit -q -m "factory: CLAUDE.md protocol replaced by its pointer" -m "Factory-Upgrade: ${HARNESS}" -- CLAUDE.md >/dev/null 2>&1 \
        && echo "  committed CLAUDE.md"
    fi
  else
    rm -f "${ROOT}/CLAUDE.md.tmp.$$"
  fi
fi

# Stamp the version even when nothing else was missing, so the next check is
# quiet - except when the gate is behind, which --apply cannot fix.
if [ -z "${missing_gate}" ] && [ -f "${CONFIG}" ]; then
  tmp="${CONFIG}.tmp.$$"
  jq --arg v "${HARNESS}" '.factory_version = $v' "${CONFIG}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${CONFIG}"
fi

if [ "${config_was_clean}" = yes ] && [ -n "$(git -C "${ROOT}" status --porcelain -- ".factory/config.json" 2>/dev/null)" ]; then
  if git -C "${ROOT}" add -- ".factory/config.json" >/dev/null 2>&1 \
     && git -C "${ROOT}" commit -q -m "factory: config.json brought up to ${HARNESS}" -m "Factory-Upgrade: ${HARNESS}" -- ".factory/config.json" >/dev/null 2>&1; then
    echo "  committed .factory/config.json (so the retrospective can change it)"
  fi
fi

echo "UPGRADE APPLIED: ${applied} area(s) brought up to factory ${HARNESS}."
if [ -n "${missing_gate}" ]; then
  echo "STILL BEHIND - gates/verify.sh is missing:${missing_gate}"
  echo "The gate is the project's own file and is never rewritten by this script. Run /factory:init here: it reads the existing gate, reports exactly which protections it lacks and what each one would have caught, and merges in only the missing parts once you approve. Until then the config still says ${project_version}."
  exit 1
fi
exit 0
