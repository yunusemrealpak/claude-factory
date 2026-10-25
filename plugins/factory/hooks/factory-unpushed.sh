#!/usr/bin/env bash
# Factory: how many commits of this project exist only on this machine.
#
# Usage (from the project root, or with FACTORY_ROOT):
#   factory-unpushed            prints the number of commits on HEAD that the
#                               delivery base on origin does not have
#   factory-unpushed check      exit 0 below the limit; exit 1 and say why at or
#                               above it (`delivery.max_unpushed`, default 30,
#                               0 turns the check off)
#
# Why it exists: at autonomy level `local` the publisher skips every change and
# nothing tells the developer, so a night of work piled up as 106 commits that
# never left the laptop. The count is read from the remote-tracking ref the last
# fetch left; nothing here touches the network, and no remote ref means 0.
#
# Exit: 0 below the limit or nothing to count; 1 over the limit.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/factory-compat.sh"

ROOT="${FACTORY_ROOT:-$PWD}"
F="${ROOT}/.factory"
cmd="${1:-count}"

base="main"
limit=30
if [ -s "${F}/config.json" ] && command -v jq >/dev/null 2>&1; then
  b="$(jq -r '.delivery.base // empty' "${F}/config.json" 2>/dev/null)"
  [ -n "${b}" ] && base="${b}"
  l="$(jq -r '.delivery.max_unpushed // empty' "${F}/config.json" 2>/dev/null)"
  case "${l}" in ''|*[!0-9]*) ;; *) limit="${l}" ;; esac
fi

count=0
if git -C "${ROOT}" rev-parse --verify -q "refs/remotes/origin/${base}" >/dev/null 2>&1; then
  count="$(git -C "${ROOT}" rev-list --count "refs/remotes/origin/${base}..HEAD" 2>/dev/null || echo 0)"
fi

case "${cmd}" in
  count) echo "${count}"; exit 0 ;;
  check)
    if [ "${limit}" -gt 0 ] && [ "${count}" -ge "${limit}" ]; then
      lvl="$(bash "$(dirname "${BASH_SOURCE[0]}")/factory-autonomy.sh" 2>/dev/null | head -1)"
      echo "UNPUSHED LIMIT: ${count} commit(s) exist only on this machine (limit ${limit}, autonomy level ${lvl:-local}). Push them (git push origin HEAD:${base}) or say 'auto devam et', then start again; raise delivery.max_unpushed to change the limit."
      if [ ! -e "${F}/unpushed-notified" ]; then
        : > "${F}/unpushed-notified" 2>/dev/null
        if [ "${FACTORY_NO_NOTIFY:-}" != "1" ] && command -v osascript >/dev/null 2>&1; then
          osascript -e "display notification \"${count} commits are not pushed; the factory stopped starting tasks.\" with title \"Factory\" sound name \"Glass\"" >/dev/null 2>&1 &
        fi
      fi
      exit 1
    fi
    rm -f "${F}/unpushed-notified" 2>/dev/null
    exit 0 ;;
  *) echo "usage: factory-unpushed [count|check]" >&2; exit 2 ;;
esac
