#!/usr/bin/env bash
# Factory: the second layer of the hard blocks - the permissions.deny rules of
# hooks/hard-blocks.txt, merged into the project's .claude/settings.json.
#
# Usage (from the project root):
#   factory-deny            report how many rules the project lacks
#   factory-deny --apply    add them
#
# A jq union: the rules already there, the developer's own included, stay and
# keep their order; only missing ones are appended; a second run changes
# nothing. Everything else in the file is left as it is.
#
# Optional bans the project allows (config.json, hard_blocks.allow; see
# hard-blocks.txt "group") are not added, and the factory's own lines for them
# are taken out again, so allowing one in /factory:bans is enough.
#
# Exit: 0 nothing missing (or applied); 1 rules missing (report mode); 2 usage.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FACTORY_ROOT:-$PWD}"
FILE="${ROOT}/.claude/settings.json"
apply=0
case "${1:-}" in
  "") ;;
  --apply) apply=1 ;;
  *) echo "usage: factory-deny [--apply]" >&2; exit 2 ;;
esac

rules="$(bash "${HOOK_DIR}/factory-hardblock.sh" deny-rules "${ROOT}" | jq -R . | jq -s .)"
lifted="$(bash "${HOOK_DIR}/factory-hardblock.sh" lifted-deny "${ROOT}" | jq -R . | jq -s .)"
[ "$(printf '%s' "${rules}" | jq 'length')" -gt 0 ] || { echo "DENY ERROR: hard-blocks.txt lists no deny rules" >&2; exit 2; }

current='{}'
if [ -s "${FILE}" ]; then
  current="$(jq -c . "${FILE}" 2>/dev/null)" || { echo "DENY ERROR: ${FILE} is not valid JSON; fix it by hand first" >&2; exit 2; }
fi

missing="$(jq -n --argjson cur "${current}" --argjson want "${rules}" --argjson lifted "${lifted}" \
  '($cur.permissions.deny // []) as $have | (($want - $have) + ($have - ($have - $lifted))) | length')"

if [ "${apply}" -eq 0 ]; then
  if [ "${missing}" -eq 0 ]; then echo "DENY OK: all rules are in .claude/settings.json"; exit 0; fi
  echo "DENY ${missing} rule(s) to change in .claude/settings.json; 'factory-deny --apply' does it."
  exit 1
fi

mkdir -p "${ROOT}/.claude"
tmp="${FILE}.tmp.$$"
jq -n --argjson cur "${current}" --argjson want "${rules}" --argjson lifted "${lifted}" '
  $cur | .permissions = ((.permissions // {}) | .deny = ((((.deny // []) - $lifted) + $want) | reduce .[] as $r ([]; if index($r) then . else . + [$r] end)))' \
  > "${tmp}" && mv -f "${tmp}" "${FILE}"
echo "DENY APPLIED: ${missing} rule(s) added to .claude/settings.json"
exit 0
