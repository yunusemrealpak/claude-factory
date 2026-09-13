#!/usr/bin/env bash
# Claude Code "SessionStart" hook - Factory session briefing.
#
# Contract (verified against https://code.claude.com/docs/en/hooks):
#   - stdin  : JSON with .cwd, .source
#   - stdout : {"hookSpecificOutput":{"hookEventName":"SessionStart",
#               "additionalContext":"..."}} injects context before the
#               first prompt. No decision control on this event.
#
# Precondition: this hook is inert unless <project>/.factory/active exists.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input="$(cat)"

project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

[ -f "$project_dir/.factory/active" ] || exit 0

count_md() {
  local dir="$1"
  [ -d "$dir" ] || { printf '0'; return 0; }
  find "$dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' '
}

backlog=$(count_md "$project_dir/tasks/backlog")
in_progress=$(count_md "$project_dir/tasks/in-progress")
done_count=$(count_md "$project_dir/tasks/done")
blocked=$(count_md "$project_dir/tasks/blocked")
proposed=$(count_md "$project_dir/tasks/proposed")

# Task-id integrity. Every record the factory keeps is keyed by id, so a
# collision is the one board error that silently corrupts the rest.
id_issues="$(bash "${HOOK_DIR}/factory-ids.sh" check "$project_dir" 2>/dev/null)"

blocked_list="(none)"
if [ "$blocked" -gt 0 ]; then
  blocked_list="$(find "$project_dir/tasks/blocked" -maxdepth 1 -name '*.md' -type f -exec basename {} .md \; | sort | sed 's/^/  - /')"
fi

needs_human_list="(none)"
if [ -d "$project_dir/tasks/blocked" ]; then
  nh="$(grep -rliE '^[[:space:]]*needs_human:[[:space:]]*true' "$project_dir/tasks/blocked" 2>/dev/null | xargs -I{} basename {} .md 2>/dev/null | sort | sed 's/^/  - /')"
  [ -n "$nh" ] && needs_human_list="$nh"
fi

# Tasks the gate stopped for repeating themselves. These outrank the ordinary
# blocked list: a blocked task is waiting for something, a stalled one is waiting
# for somebody to change the approach.
stalled="(none)"
if [ -d "$project_dir/.factory/no-progress" ]; then
  st="$(find "$project_dir/.factory/no-progress" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort | sed 's/^/  - /')"
  [ -n "$st" ] && stalled="$st"
fi

# Changes still in flight. A closed change is history; its summary is on disk.
changes="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-change.sh" list 2>/dev/null | awk '$1!="closed" {print "  - " $2 " " $1 " " $3 " " $4}')"
[ -n "$changes" ] || changes="(none open)"

# Is the project still running what the harness now writes? The hooks upgrade
# themselves; what /factory-init wrote into the project does not.
upgrade="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-upgrade.sh" --brief 2>/dev/null)"

# What could be dispatched right now, worked out from disk rather than by the
# lead reading the whole board again after a compaction.
ready="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-ready.sh" 2>/dev/null | grep -E '^(READY|STALL)' | sed 's/^/  - /')"
[ -n "$ready" ] || ready="(nothing ready)"

# The inbox. An answered question that nobody acts on is worse than not asking.
questions="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-ask.sh" list all 2>/dev/null | sed 's/^/  - /')"
[ -n "$questions" ] || questions="(none)"

decisions="(decisions.md is empty or missing)"
if [ -s "$project_dir/decisions.md" ]; then
  decisions="$(grep -v '^[[:space:]]*$' "$project_dir/decisions.md" | tail -5 | sed 's/^/  /')"
fi

verify_cmd="$(jq -r '.verify // "gates/verify.sh"' "$project_dir/.factory/config.json" 2>/dev/null || printf 'gates/verify.sh')"

# The Stop hook only holds the session that claimed the run. /factory-run claims
# it through factory-claim.sh; this only reports who holds it now.
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
run_owner="(unclaimed - no session is running the loop)"
ro=""
if [ -s "$project_dir/.factory/run-owner" ]; then
  ro="$(tr -d '[:space:]' < "$project_dir/.factory/run-owner")"
  if [ "$ro" = "$session_id" ]; then
    run_owner="this session"
  else
    run_owner="another session (${ro})"
  fi
fi

# Agents die with the session that dispatched them, silently: no SubagentStop
# arrives, so their concurrency slots stay held and the dashboard keeps showing
# them at work. A session that is starting or resuming is a new process, so
# nothing it finds in flight can be alive - unless another session owns the run,
# which is the one case where those agents may be somebody else's and live.
#
# "compact" is excluded deliberately: that is this same process continuing, and
# its agents are still running.
source="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)"
swept=""
case "$source" in
  compact) ;;
  *)
    if [ -z "$ro" ] || [ "$ro" = "$session_id" ]; then
      swept="$(bash "${HOOK_DIR}/factory-sweep.sh" "session-${source:-start}" "$project_dir" 2>/dev/null)"
    fi
    ;;
esac

# Tasks the dead run left mid-flight. Their agent is gone; nothing re-dispatches
# them on its own.
stranded=""
if [ -n "$swept" ] && [ -d "$project_dir/tasks/in-progress" ]; then
  st="$(find "$project_dir/tasks/in-progress" -maxdepth 1 -name '*.md' -type f -exec basename {} .md \; 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$st" ] && stranded="$st"
fi


# Written by the PreCompact hook. On the SessionStart that fires with source
# "compact", this is how the lead's pre-summary state re-enters context.
lead_state=""
if [ -f "$project_dir/.factory/lead-state.md" ]; then
  lead_state="$(cat "$project_dir/.factory/lead-state.md")"
fi

brief="$(cat <<BRIEF
FACTORY ACTIVE in this project (.factory/active present).

Task counts: backlog=${backlog}  in-progress=${in_progress}  done=${done_count}  blocked=${blocked}  proposed=${proposed} (awaiting approval, never dispatched)

${id_issues:+TASK ID PROBLEMS - resolve before dispatching anything:
${id_issues}
}
Blocked tasks:
${blocked_list}

Stalled - the gate saw the identical failure twice, do not re-dispatch these:
${stalled}

Needs-human queue:
${needs_human_list}

Changes in flight (.factory/changes/):
${changes}

${upgrade:+FACTORY VERSION: ${upgrade}
}${swept:+PREVIOUS RUN ENDED MID-FLIGHT: ${swept}
}${stranded:+  Tasks left in tasks/in-progress by that run: ${stranded}. No agent is alive for them. Re-dispatch each one to a fresh agent, or move it back to tasks/backlog with owner cleared and stage: queued - do not assume work is still going on.
}
Ready to dispatch now:
${ready}

Questions waiting for the developer:
${questions}

Last decisions (decisions.md):
${decisions}

${lead_state:+
--- STATE CARRIED OVER FROM BEFORE THE LAST COMPACTION ---
${lead_state}
--- end carried state ---
}
Session id: ${session_id:-unknown}
Run owner: ${run_owner}

Rules in force: a task enters tasks/done only after "${verify_cmd} <task-id>" wrote .factory/verified/<task-id>; the PreToolUse gate rejects any other move. The Stop hook keeps the session running while actionable tasks remain. Run /factory-status for detail, /factory-run to continue the loop.
BRIEF
)"

jq -n --arg ctx "$brief" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
