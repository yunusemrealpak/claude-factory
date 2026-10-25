#!/usr/bin/env bash
# Factory: forget agents that died with their session.
#
# Usage:
#   factory-sweep <reason> [project-dir]
#
# An agent leaves an agent_start line in the event log when it is dispatched,
# which the dashboard pairs with a later agent_stop. SubagentStop writes that
# stop when the agent returns.
#
# It never arrives when the session is killed mid-run: the process is gone, and
# the dashboard keeps showing agents at work that no longer exist.
#
# This is called at the moments when nothing from before can still be alive: a
# session starting or resuming (not compacting - that is the same process
# continuing) with no run in progress, a run starting, and a run ending.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"

reason="${1:-unknown}"
project_dir="${2:-$PWD}"
F="${project_dir}/.factory"
LOG="${F}/events.jsonl"

[ -f "${F}/active" ] || exit 0

# Concurrency markers from before 3.4 hold nothing any more.
[ -d "${F}/inflight" ] && rm -rf "${F}/inflight" 2>/dev/null

# Starts with no stop, as the dashboard counts them.
open_agents=0
if [ -f "${LOG}" ]; then
  # Starts already covered by an earlier sweep are not counted again: they were
  # written off then, and counting them would make every sweep look eventful.
  # The log only grows, so "before the sweep" is "above its line" - never a
  # comparison of seconds, which a start in the sweep's own second would fail.
  open_agents="$(grep -E '"kind":"(agent_start|agent_stop|sweep)"' "${LOG}" 2>/dev/null \
    | jq -r '"\(.kind) \(.agent_id // "?")"' 2>/dev/null \
    | awk '
           $1=="sweep" { for (i in open) delete open[i]; next }
           { if ($1=="agent_start") open[$2]=1; else delete open[$2] }
           END { n=0; for (i in open) n++; print n }')"
  case "${open_agents}" in ''|*[!0-9]*) open_agents=0 ;; esac
fi

if [ "${open_agents}" -eq 0 ]; then
  exit 0
fi

# The sweep line is the cut: every agent_start at or before it is finished,
# whatever the log says, because the process that would have reported it is gone.
if [ -f "${LOG}" ] || [ -d "${F}" ]; then
  mkdir -p "${F}"
  jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" \
     --arg reason "${reason}" --argjson agents "${open_agents}" \
     '{ts: $ts, epoch: $epoch, kind: "sweep", reason: $reason, agents: $agents}' \
     >> "${LOG}" 2>/dev/null
fi

( cd "${project_dir}" && bash "${HOOK_DIR}/factory-dash.sh" >/dev/null 2>&1 )

echo "SWEPT ${open_agents} agent(s) left behind by a session that ended (${reason})."
exit 0
