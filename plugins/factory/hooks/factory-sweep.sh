#!/usr/bin/env bash
# Factory: forget agents that died with their session.
#
# Usage:
#   factory-sweep <reason> [project-dir]
#
# An agent leaves two traces when it is dispatched: a marker in
# .factory/inflight/ that holds one of the max_concurrent_agents slots, and an
# agent_start line in the event log that the dashboard pairs with a later
# agent_stop. Both are cleared by the agent returning - SubagentStop fires, the
# Stop hook reconciles the markers against what the harness reports in flight.
#
# Neither happens when the session is killed mid-dispatch. The process is gone,
# so no SubagentStop ever arrives and no Stop hook ever runs: the markers hold
# slots for agents that no longer exist, and the dashboard keeps showing them as
# running. Reopen the session and the factory believes it has three agents at
# work and refuses to dispatch a fourth.
#
# This is called at the three moments when nothing from before can still be
# alive: a session starting or resuming (not compacting - that is the same
# process continuing), a run being claimed, and a run ending.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

reason="${1:-unknown}"
project_dir="${2:-$PWD}"
F="${project_dir}/.factory"
LOG="${F}/events.jsonl"

[ -f "${F}/active" ] || exit 0

markers=0
if [ -d "${F}/inflight" ]; then
  markers="$(find "${F}/inflight" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "${markers}" ] && markers=0
  find "${F}/inflight" -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null
fi

# Starts with no stop, as the dashboard counts them.
open_agents=0
if [ -f "${LOG}" ]; then
  # Starts already covered by an earlier sweep are not counted again: they were
  # written off then, and counting them would make every sweep look eventful.
  last_sweep="$(grep '"kind":"sweep"' "${LOG}" 2>/dev/null | tail -1 | jq -r '.epoch // 0' 2>/dev/null)"
  case "${last_sweep}" in ''|*[!0-9]*) last_sweep=0 ;; esac
  open_agents="$(grep -E '"kind":"agent_(start|stop)"' "${LOG}" 2>/dev/null \
    | jq -r '"\(.kind) \(.agent_id // "?") \(.epoch // 0)"' 2>/dev/null \
    | awk -v sweep="${last_sweep}" '
           { if ($1=="agent_start") open[$2]=$3; else delete open[$2] }
           END { n=0; for (i in open) if (open[i] + 0 > sweep + 0) n++; print n }')"
  case "${open_agents}" in ''|*[!0-9]*) open_agents=0 ;; esac
fi

if [ "${markers}" -eq 0 ] && [ "${open_agents}" -eq 0 ]; then
  exit 0
fi

# The sweep line is the cut: every agent_start at or before it is finished,
# whatever the log says, because the process that would have reported it is gone.
if [ -f "${LOG}" ] || [ -d "${F}" ]; then
  mkdir -p "${F}"
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" \
     --arg reason "${reason}" --argjson agents "${open_agents}" --argjson markers "${markers}" \
     '{ts: $ts, epoch: $epoch, kind: "sweep", reason: $reason, agents: $agents, markers: $markers}' \
     >> "${LOG}" 2>/dev/null
fi

( cd "${project_dir}" && bash "${HOOK_DIR}/factory-dash.sh" >/dev/null 2>&1 )

echo "SWEPT ${open_agents} agent(s) and ${markers} concurrency slot(s) left behind by a session that ended (${reason})."
exit 0
