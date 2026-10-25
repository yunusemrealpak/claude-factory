#!/usr/bin/env bash
# Factory: the optional bans, per project. The developer decides which of the
# bans in hooks/hard-blocks.txt "group" lines apply to this project (store and
# TestFlight tooling, git tags, GitHub releases); every other ban stays.
#
# Usage (from the project root):
#   factory-bans                  status: each group and whether it is allowed here
#   factory-bans questions        "name<TAB>question" per group, for /factory:init
#   factory-bans allow <g> ...    allow groups (the bans on them are lifted)
#   factory-bans forbid <g> ...   ban them again
#   factory-bans set [g ...]      allow exactly these groups, nothing else
#
# The choice lives in .factory/config.json (hard_blocks.allow), which no agent
# may write; a change here is the developer's own session, and agents may not
# run allow/forbid/set (a hard block of its own). A change is applied to
# .claude/settings.json at once (factory-deny --apply) and voids an autonomy
# consent given before it, because the consent's hard-block version carries the
# allowed set: type "auto devam et" again.
#
# Exit: 0 ok; 1 unknown group; 2 usage / no config.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"
ROOT="${FACTORY_ROOT:-$PWD}"
CFG="${ROOT}/.factory/config.json"
HB="${HOOK_DIR}/factory-hardblock.sh"

known() { bash "${HB}" groups | cut -f1; }
allowed() { bash "${HB}" allowed "${ROOT}"; }

status() {
  local g q mark
  while IFS=$'\t' read -r g q; do
    if allowed | grep -qxF -- "${g}"; then mark="ALLOWED"; else mark="banned "; fi
    printf '%s  %-12s %s\n' "${mark}" "${g}" "${q}"
  done < <(bash "${HB}" groups)
}

write() {  # <group>...  -> config.json hard_blocks.allow
  [ -s "${CFG}" ] || { echo "BANS ERROR: no .factory/config.json here; run /factory:init first" >&2; exit 2; }
  local list tmp="${CFG}.tmp.$$"
  list="$(printf '%s\n' "$@" | awk 'NF' | sort -u | jq -R . | jq -sc .)"
  jq --argjson l "${list}" '.hard_blocks = ((.hard_blocks // {}) | .allow = $l)' "${CFG}" > "${tmp}" \
    && mv -f "${tmp}" "${CFG}" || { rm -f "${tmp}"; echo "BANS ERROR: could not write ${CFG}" >&2; exit 2; }
  FACTORY_ROOT="${ROOT}" bash "${HOOK_DIR}/factory-deny.sh" --apply | sed 's/^/  /'
  echo "BANS: allowed here now: ${list}"
}

check_known() {
  local g
  for g in "$@"; do
    known | grep -qxF -- "${g}" || { echo "BANS ERROR: unknown group '${g}'; groups: $(known | paste -sd' ' -)" >&2; exit 1; }
  done
}

case "${1:-status}" in
  status) status ;;
  questions) bash "${HB}" groups ;;
  allow)  shift; [ $# -gt 0 ] || { echo "usage: factory-bans allow <group> ..." >&2; exit 2; }
          check_known "$@"; write $(allowed) "$@" ;;
  forbid) shift; [ $# -gt 0 ] || { echo "usage: factory-bans forbid <group> ..." >&2; exit 2; }
          check_known "$@"
          keep="$(allowed | grep -vxF -- "$(printf '%s\n' "$@")")"
          write ${keep} ;;
  set)    shift; check_known "$@"; write "$@" ;;
  *) echo "usage: factory-bans [status|questions|allow <g>..|forbid <g>..|set [g..]]" >&2; exit 2 ;;
esac
exit 0
