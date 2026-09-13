#!/usr/bin/env bash
# Claude Code hook - factory telemetry. Registered on SubagentStart,
# SubagentStop and PostToolUse(Bash), all with "async": true so the session
# never waits for it.
#
# Contract (verified against https://code.claude.com/docs/en/hooks):
#   - common input : .session_id, .cwd, .transcript_path, .hook_event_name
#   - SubagentStart/SubagentStop add .agent_type and .agent_id
#   - PostToolUse adds .tool_name, .tool_input, .tool_use_id, .tool_output
#   - nothing is returned: this hook observes, it never decides.
#
# It appends one JSON line per event to .factory/events.jsonl and then rebuilds
# the dashboard. That log is the only place the factory's history lives: the
# board shows the present, and a task file that moved on keeps no record of when
# it moved, how long it took, or how many times its gate went red.
#
# Neither duration nor token usage is in any hook payload, so duration is
# computed here, by pairing a SubagentStop with its SubagentStart.
#
# Precondition: inert unless <project>/.factory/active exists.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input="$(cat)"

project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$project_dir/.factory/active" ] || exit 0

F="$project_dir/.factory"
LOG="$F/events.jsonl"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)"
now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
now_epoch="$(date +%s)"

# One line per event, short enough to be an atomic append even when two async
# hooks fire at once.
emit() {  # <kind> <jq-args...> - remaining args are --arg pairs
  local kind="$1"; shift
  mkdir -p "$F"
  jq -cn --arg ts "$now_iso" --argjson epoch "$now_epoch" --arg kind "$kind" "$@" \
    '{ts: $ts, epoch: $epoch, kind: $kind} + $extra' >> "$LOG" 2>/dev/null
}

case "$event" in
  SubagentStart)
    agent_type="$(printf '%s' "$input" | jq -r '.agent_type // "agent"')"
    agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
    emit agent_start --argjson extra "$(jq -cn --arg t "$agent_type" --arg i "$agent_id" '{agent: $t, agent_id: $i}')"
    ;;
  SubagentStop)
    agent_type="$(printf '%s' "$input" | jq -r '.agent_type // "agent"')"
    agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
    # Duration: the matching start, newest first. No payload carries it.
    started=""
    if [ -n "$agent_id" ] && [ -f "$LOG" ]; then
      started="$(grep -F "\"agent_id\":\"$agent_id\"" "$LOG" 2>/dev/null \
        | jq -r 'select(.kind=="agent_start") | .epoch' 2>/dev/null | tail -1)"
    fi
    dur=-1
    [ -n "$started" ] && dur=$(( now_epoch - started ))
    emit agent_stop --argjson extra "$(jq -cn --arg t "$agent_type" --arg i "$agent_id" --argjson d "$dur" '{agent: $t, agent_id: $i, seconds: $d}')"
    ;;
  PostToolUse)
    tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
    [ "$tool" = "Bash" ] || exit 0
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$cmd" ] || exit 0
    out="$(printf '%s' "$input" | jq -r '.tool_output // empty | if type=="string" then . else tojson end' 2>/dev/null)"

    # The gate. Its task id is in the command and its verdict in the output.
    id="$(printf '%s' "$cmd" | sed -n -E 's#.*verify\.sh[[:space:]]+([A-Za-z0-9._-]+).*#\1#p' | head -1)"
    if [ -n "$id" ]; then
      verdict=unknown
      case "$out" in
        *"NO PROGRESS"*)            verdict=no-progress ;;
        *"GATE RESULT: GREEN"*)     verdict=green ;;
        *"GATE RESULT: RED"*)       verdict=red ;;
      esac
      emit gate --argjson extra "$(jq -cn --arg id "$id" --arg v "$verdict" '{task: $id, verdict: $v}')"
    fi

    # A task changing column. Every move goes through Bash, so this is the
    # board's history.
    printf '%s\n' "$cmd" | grep -qE '(^|[;&|[:space:]])(mv|git[[:space:]]+mv)[[:space:]]' && {
      from="$(printf '%s' "$cmd" | sed -n -E 's#.*tasks/([a-z-]+)/([A-Za-z0-9._-]+)\.md[[:space:]]+tasks/([a-z-]+)/.*#\1#p' | head -1)"
      task="$(printf '%s' "$cmd" | sed -n -E 's#.*tasks/([a-z-]+)/([A-Za-z0-9._-]+)\.md[[:space:]]+tasks/([a-z-]+)/.*#\2#p' | head -1)"
      to="$(printf '%s' "$cmd" | sed -n -E 's#.*tasks/([a-z-]+)/([A-Za-z0-9._-]+)\.md[[:space:]]+tasks/([a-z-]+)/.*#\3#p' | head -1)"
      [ -n "$task" ] && emit move --argjson extra "$(jq -cn --arg id "$task" --arg f "$from" --arg t "$to" '{task: $id, from: $f, to: $t}')"
    }

    case "$cmd" in
      *factory-commit.sh*)
        id="$(printf '%s' "$cmd" | sed -n -E 's#.*factory-commit\.sh[[:space:]]+([A-Za-z0-9._-]+).*#\1#p' | head -1)"
        sha="$(printf '%s' "$out" | sed -n -E 's#^COMMIT ([0-9a-f]+) .*#\1#p' | head -1)"
        [ -n "$id" ] && emit commit --argjson extra "$(jq -cn --arg id "$id" --arg s "${sha:-none}" '{task: $id, sha: $s}')"
        ;;
      *factory-risk.sh*)
        id="$(printf '%s' "$cmd" | sed -n -E 's#.*factory-risk\.sh[[:space:]]+([A-Za-z0-9._-]+).*#\1#p' | head -1)"
        hit=no
        case "$out" in *"review before commit"*) hit=yes ;; esac
        [ -n "$id" ] && emit risk --argjson extra "$(jq -cn --arg id "$id" --arg h "$hit" '{task: $id, review_needed: $h}')"
        ;;
      *factory-change.sh*open*)
        ch="$(printf '%s' "$out" | sed -n -E 's#^OPENED ([^:]+):.*#\1#p' | head -1)"
        [ -n "$ch" ] && emit change_open --argjson extra "$(jq -cn --arg c "$ch" '{change: $c}')"
        ;;
      *factory-claim.sh*)
        case "$out" in *CLAIMED*) emit claim --argjson extra '{}' ;; esac
        ;;
      *factory-ask.sh*)
        q="$(printf '%s' "$out" | sed -n -E 's#^ASKED ([A-Za-z0-9-]+).*#\1#p' | head -1)"
        [ -n "$q" ] && emit question --argjson extra "$(jq -cn --arg q "$q" '{question: $q}')"
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

# Rebuild the developer's view. Debounced: several events landing together
# produce one rebuild, and the page refreshes itself anyway.
stamp="$F/.dash-stamp"
last=0
[ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ "$(( now_epoch - last ))" -ge 1 ]; then
  printf '%s' "$now_epoch" > "$stamp"
  ( cd "$project_dir" && bash "${HOOK_DIR}/factory-dash.sh" >/dev/null 2>&1 ) &
fi
exit 0
