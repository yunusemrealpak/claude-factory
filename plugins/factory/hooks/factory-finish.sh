#!/usr/bin/env bash
# Factory: close a build. NOT a hook: the /factory:fast workflow runs it once,
# after every task it could build has landed.
#
# Usage (from the project root):
#   factory-finish          one JSON object on stdout
#
# Each task was checked on what it touched. This is where the tree is judged as
# a whole, once: factory-check --full (analyze, format, every test), then the
# change archive is synced and every change whose tasks are all done runs its own
# acceptance command. A red here is a seam between tasks that each passed alone;
# /factory:bisect finds the task commit that opened it.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$PWD"
F="${ROOT}/.factory"
[ -f "${F}/active" ] || { echo '{"error":"no .factory/active here"}'; exit 1; }

full="$(python3 "${HOOK_DIR}/factory-check.py" --full 2>&1)"
full_rc=$?
verdict=green; [ "${full_rc}" -ne 0 ] && verdict=red

sync="$(bash "${HOOK_DIR}/factory-change.sh" sync 2>/dev/null)"
acc_json="[]"
for ch in $(printf '%s\n' "${sync}" | awk '$1=="unverified" {print $2}'); do
  cid="${ch%%-*}"
  a="$(bash "${HOOK_DIR}/factory-accept.sh" "${cid}" 2>&1 | grep -E '^ACCEPT (GREEN|RED|NONE)' | tail -1)"
  acc_json="$(jq -c --arg c "${cid}" --arg l "${a:-ACCEPT ? ${cid}}" '. + [{change: $c, result: $l}]' <<< "${acc_json}")"
done
# A green acceptance lets the change close on this sync.
[ "${acc_json}" != "[]" ] && sync="$(bash "${HOOK_DIR}/factory-change.sh" sync 2>/dev/null)"
( bash "${HOOK_DIR}/factory-dash.sh" >/dev/null 2>&1 )

jq -n --arg v "${verdict}" --arg out "$(printf '%s\n' "${full}" | tail -60)" --arg sync "${sync}" --argjson acc "${acc_json}" '{
  full_check: $v,
  full_output: (if $v == "red" then $out else ($out | split("\n") | map(select(test("^  |FULL CHECK"))) | join("\n")) end),
  changes: ($sync | split("\n") | map(select(length > 0))),
  acceptance: $acc
}'
exit 0
