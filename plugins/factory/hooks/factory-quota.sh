#!/usr/bin/env bash
# Factory: the quota line, read from ~/.claude/.factory-quota.json (written by
# the status line and by the hooks module). NOT a hook.
#
# Usage:
#   factory-quota.sh check [margin]     QUOTA OK | OVER | STALE | NONE
#
# The line is the share of the week that has passed (even spend) plus a margin
# in percentage points (default config delivery.quota_margin, else 10). A
# seven_day figure above it means the week is being spent faster than it comes
# in. Data older than 30 minutes, or none, counts as not knowing - and not
# knowing is a reason not to start something new.
#
# Exit: 0 OK; 1 OVER, STALE or NONE. Callers decide whether the level they run
# at is one where that matters (merge and above).
set -uo pipefail

ROOT="${FACTORY_ROOT:-$PWD}"
FILE="${FACTORY_QUOTA_FILE:-${HOME}/.claude/.factory-quota.json}"
STALE_AFTER="${FACTORY_QUOTA_STALE_S:-1800}"
margin="${2:-}"
[ -n "${margin}" ] || margin="$(jq -r '.delivery.quota_margin // empty' "${ROOT}/.factory/config.json" 2>/dev/null)"
[ -n "${margin}" ] || margin=10

[ "${1:-check}" = check ] || { echo "usage: factory-quota.sh check [margin]" >&2; exit 2; }
[ -s "${FILE}" ] || { echo "QUOTA NONE: no quota file (${FILE}); not starting anything new without a reading"; exit 1; }

now="$(date +%s)"
ts="$(jq -r '.ts // 0' "${FILE}" 2>/dev/null)"
used="$(jq -r '.seven_day.used_percentage // empty' "${FILE}" 2>/dev/null)"
line="$(jq -r '.seven_day.even_line // empty' "${FILE}" 2>/dev/null)"
resets="$(jq -r '.seven_day.resets_at // empty' "${FILE}" 2>/dev/null)"

if [ -z "${line}" ] && [ -n "${resets}" ]; then
  line="$(awk -v now="${now}" -v r="${resets}" 'BEGIN{e=1-(r-now)/604800; if(e<0)e=0; if(e>1)e=1; printf "%.1f", e*100}')"
fi
if [ -z "${used}" ] || [ -z "${line}" ]; then
  echo "QUOTA NONE: the quota file has no seven-day reading"; exit 1
fi
age=$(( now - ${ts%.*} ))
if [ "${age}" -gt "${STALE_AFTER}" ]; then
  echo "QUOTA STALE: the reading is $((age / 60)) min old (limit $((STALE_AFTER / 60)))"; exit 1
fi
if awk -v u="${used}" -v l="${line}" -v m="${margin}" 'BEGIN{exit !(u > l + m)}'; then
  echo "QUOTA OVER: 7-day ${used}% is past the even-spend line ${line}% + ${margin} points"; exit 1
fi
echo "QUOTA OK: 7-day ${used}% against the line ${line}% + ${margin} points"
exit 0
