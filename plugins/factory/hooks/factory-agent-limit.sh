#!/usr/bin/env bash
# Claude Code "PreToolUse" hook (matcher: Agent) - concurrency ceiling.
#
# Caps how many agents can be open at once, whatever their type. Without this the
# lead can hold two implementers plus a reviewer plus an integrator plus a retry
# open at the same time: five or six Claude processes on the developer's laptop.
#
# The ceiling is enforced here rather than in the run instructions because a limit
# that depends on the lead remembering it is not a limit.
#
# Bookkeeping: this hook writes one marker per approved dispatch into
# .factory/inflight/. The Stop hook reconciles that directory against the
# background_tasks the harness reports, so markers cannot leak.
#
# Precondition: inert unless <project>/.factory/active exists.
set -uo pipefail

input="$(cat)"

project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$project_dir/.factory/active" ] || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool_name" = "Agent" ] || exit 0

max="$(jq -r '.max_concurrent_agents // 3' "$project_dir/.factory/config.json" 2>/dev/null)"
case "$max" in ''|*[!0-9]*) max=3 ;; esac

inflight_dir="$project_dir/.factory/inflight"
mkdir -p "$inflight_dir" 2>/dev/null

# A marker older than any plausible agent is not an agent: it is a dispatch
# whose session died before anything could clear it. factory-sweep.sh catches
# those at the session boundary; this is the backstop for a marker that leaks
# inside a long-lived session, where nothing else would ever remove it and the
# ceiling would end up permanently full.
stale_min="$(jq -r '.agent_stale_after_min // 45' "$project_dir/.factory/config.json" 2>/dev/null)"
case "$stale_min" in ''|*[!0-9]*) stale_min=45 ;; esac
find "$inflight_dir" -maxdepth 1 -type f -mmin "+${stale_min}" -exec rm -f {} + 2>/dev/null

open_count="$(find "$inflight_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
[ -z "$open_count" ] && open_count=0

if [ "$open_count" -ge "$max" ]; then
  jq -n --arg reason "Concurrency ceiling reached: ${open_count} agent(s) already open, limit is ${max} (max_concurrent_agents in .factory/config.json). Every concurrent agent is a separate Claude process on this machine, so the ceiling protects the laptop, not the budget. Do not retry this dispatch and do not narrate the wait: end the turn. The Stop hook lets the session rest while agents run, and the harness wakes you the moment one returns - dispatch this task then." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi

# Approved: record the slot. The id keeps markers unique per dispatch.
marker_id="$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null)"
[ -z "$marker_id" ] && marker_id="dispatch-$$-$(date +%s%N 2>/dev/null || date +%s)"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$inflight_dir/$marker_id" 2>/dev/null

exit 0
