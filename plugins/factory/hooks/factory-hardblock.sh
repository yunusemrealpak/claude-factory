#!/usr/bin/env bash
# Factory: the hard-block matcher, shell side. NOT a hook itself: the
# PreToolUse guard (factory-done-guard.sh) calls it, and the tests do.
# register.js matches the same hooks/hard-blocks.txt in JavaScript.
#
# Usage:
#   factory-hardblock.sh version [root]               the file's hard_blocks_version; with a
#                                                     root, "+group,..." when the project
#                                                     allows optional bans
#   factory-hardblock.sh deny-rules [root]            the permissions.deny lines the project
#                                                     keeps (allowed groups left out)
#   factory-hardblock.sh groups                       "name<TAB>question" per optional group
#   factory-hardblock.sh allowed <root>               the groups the project allows
#   factory-hardblock.sh lifted-deny <root>           deny lines of allowed groups
#   factory-hardblock.sh check <root> bash  < command the command text on stdin
#   factory-hardblock.sh check <root> path  < path    one file path on stdin
#   factory-hardblock.sh trip <root> <rule> <tool> <agent>
#                                                     the breaker: .factory/STOP,
#                                                     an event, a notification
#
# check: prints the rule's name and exits 3 on a hit (refuse, halt the run) or
# 5 on a soft one (refuse this call only); exits 0 on a clean call. A rules
# file that cannot be read exits 4 - callers treat that as a hit (fail closed):
# a missing rule list is not permission.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/factory-compat.sh"
RULES="${FACTORY_HARD_BLOCKS:-${HERE}/hard-blocks.txt}"

[ -r "${RULES}" ] || { echo "hard-blocks.txt unreadable: ${RULES}" >&2; exit 4; }

fields() {  # <kind> -> one rule per line, fields tab-separated
  awk -F' ## ' -v k="$1" '$1 == k { out = $2; for (i = 3; i <= NF; i++) out = out "\t" $i; print out }' "${RULES}"
}

# The groups of optional bans a project allows: .factory/config.json,
# hard_blocks.allow. Only names the rules file declares count; anything else in
# the list (a typo, an old name) lifts nothing.
allowed_groups() {  # <root>
  local cfg="${1%/}/.factory/config.json" known g
  [ -s "${cfg}" ] || return 0
  known="$(awk -F' ## ' '$1 == "group" { print $2 }' "${RULES}")"
  jq -r '(.hard_blocks.allow // []) | if type == "array" then .[] else empty end | strings' "${cfg}" 2>/dev/null \
    | while IFS= read -r g; do printf '%s\n' "${known}" | grep -qxF -- "${g}" && printf '%s\n' "${g}"; done \
    | sort -u
}
members() {  # <root> <kind> -> member values of the allowed groups
  local g
  for g in $(allowed_groups "$1"); do
    awk -F' ## ' -v g="${g}" -v k="$2" '$1 == "member" && $2 == g && $3 == k { print $4 }' "${RULES}"
  done
}

case "${1:-}" in
  version)
    v="$(sed -n 's/^hard_blocks_version:[[:space:]]*//p' "${RULES}" | head -1)"
    if [ -n "${2:-}" ]; then
      a="$(allowed_groups "$2" | paste -sd, -)"
      [ -n "${a}" ] && v="${v}+${a}"
    fi
    printf '%s\n' "${v}"
    exit 0
    ;;
  deny-rules)
    all="$(awk -F' ## ' '$1 == "deny" { print $2 }' "${RULES}"
           awk -F' ## ' '$1 == "member" && $3 == "deny" { print $4 }' "${RULES}")"
    all="$(printf '%s\n' "${all}" | awk 'NF && !seen[$0]++')"
    if [ -n "${2:-}" ]; then
      lifted="$(members "$2" deny)"
      [ -n "${lifted}" ] && all="$(printf '%s\n' "${all}" | grep -vxF -- "${lifted}")"
    fi
    printf '%s\n' "${all}"
    exit 0
    ;;
  groups)
    awk -F' ## ' '$1 == "group" { print $2 "\t" $3 }' "${RULES}"
    exit 0
    ;;
  allowed)
    allowed_groups "${2:-}"
    exit 0
    ;;
  lifted-deny)
    members "${2:-}" deny
    exit 0
    ;;
  trip)
    # A hard block was hit: stop the run from starting anything new (STOP is what
    # factory-start and the workflow read), say why where the developer looks,
    # and tell them. Never fails the caller.
    root="${2:-}"; rule="${3:-}"; tool="${4:-}"; agent="${5:-}"
    [ -d "${root}/.factory" ] || exit 0
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ ! -f "${root}/.factory/STOP" ]; then
      printf 'hard block "%s" hit by %s (%s) at %s. Remove this file once you have looked.\n' \
        "${rule}" "${agent:-an agent}" "${tool}" "${now}" > "${root}/.factory/STOP"
    fi
    # A ban was hit: the run may not publish more than a PR until the developer
    # consents again.
    if [ ! -s "${root}/.factory/autonomy-cap" ]; then
      printf 'pr\nhard block "%s" at %s\n' "${rule}" "${now}" > "${root}/.factory/autonomy-cap"
    fi
    jq -cn --arg ts "${now}" --argjson epoch "$(date +%s)" --arg rule "${rule}" --arg tool "${tool}" --arg agent "${agent}" \
      '{ts: $ts, epoch: $epoch, kind: "hard_block", rule: $rule, tool: $tool, agent_id: $agent}' \
      >> "${root}/.factory/events.jsonl" 2>/dev/null
    if [ "${FACTORY_NO_NOTIFY:-0}" != "1" ] && command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"hard block ${rule}: run stopped\" with title \"Factory\" sound name \"Glass\"" >/dev/null 2>&1 &
    fi
    exit 0
    ;;
  check) ;;
  *)
    echo "usage: factory-hardblock.sh version|deny-rules|check <root> bash|path|trip ..." >&2
    exit 2
    ;;
esac

ROOT="${2:-}"
KIND="${3:-}"
# The judge is factory-hardblock.py: the same algorithm as register.js, in a
# language with the same regular expressions. The rule names the project's
# allowed groups lift go with it. No Python, no judge: the call is refused.
command -v python3 >/dev/null 2>&1 || { echo "python3 not found: the hard blocks cannot be judged" >&2; exit 4; }
# The root goes in on the first line of stdin: under MSYS an argument that looks
# like a path is rewritten on its way to a Windows program, and the root has to
# arrive in the spelling the command uses.
HB_LIFTED="$(members "${ROOT}" bash; members "${ROOT}" path)"
export HB_LIFTED
{ printf '%s\n' "${ROOT}"; cat; } | python3 -I "${HERE}/factory-hardblock.py" "${RULES}" "${KIND}"
