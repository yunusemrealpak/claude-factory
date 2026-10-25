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
. "$HOOK_DIR/factory-compat.sh"

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

# What a run would start right now, worked out from disk.
ready="$(cd "$project_dir" && python3 "${HOOK_DIR}/factory-plan.py" --ready 2>/dev/null | grep -E '^(READY|STALL)' | sed 's/^/  - /')"
[ -n "$ready" ] || ready="(nothing ready)"

# The inbox. An answered question that nobody acts on is worse than not asking.
questions="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-ask.sh" list all 2>/dev/null | sed 's/^/  - /')"
[ -n "$questions" ] || questions="(none)"

decisions="(decisions.md is empty or missing)"
if [ -s "$project_dir/decisions.md" ]; then
  decisions="$(grep -v '^[[:space:]]*$' "$project_dir/decisions.md" | tail -5 | sed 's/^/  /')"
fi

verify_cmd="$(jq -r '.verify // "gates/verify.sh"' "$project_dir/.factory/config.json" 2>/dev/null || printf 'gates/verify.sh')"

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"

# A run in progress holds .factory/run.lock and keeps it fresh; one that halted
# marks it so, and the next /factory:run continues from its base.
run_state=""
if [ -f "$project_dir/.factory/run.lock" ]; then
  if grep -q '"state": *"halted"' "$project_dir/.factory/run.lock" 2>/dev/null; then
    run_state="the last run halted ($(jq -r '.halted // "unknown"' "$project_dir/.factory/run.lock" 2>/dev/null)) - /factory:run continues it from the same base"
  elif [ -n "$(find "$project_dir/.factory/run.lock" -mmin -120 2>/dev/null)" ]; then
    run_state="a run is in progress (another session) - do not start a second one"
  else
    run_state="a run stopped without finishing - /factory:run continues it from the same base"
  fi
fi

# Agents die with the session that dispatched them, silently: no SubagentStop
# arrives, so the dashboard keeps showing them at work. A session that is
# starting or resuming is a new process, so nothing it finds in flight can be
# alive - unless a run is in progress in another session.
# "compact" is excluded deliberately: that is this same process continuing.
source="$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)"
swept=""
case "$source" in
  compact) ;;
  *)
    case "$run_state" in
      "a run is in progress"*) ;;
      *) swept="$(bash "${HOOK_DIR}/factory-sweep.sh" "session-${source:-start}" "$project_dir" 2>/dev/null)" ;;
    esac
    ;;
esac

# Tasks the dead run left mid-flight. Their agent is gone; nothing re-dispatches
# them on its own.
stranded=""
if [ -n "$swept" ] && [ -d "$project_dir/tasks/in-progress" ]; then
  st="$(find "$project_dir/tasks/in-progress" -maxdepth 1 -name '*.md' -type f -exec basename {} .md \; 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
  [ -n "$st" ] && stranded="$st"
fi


# Delivery (2.8): a change that stopped half-way - a sleeping laptop, an expired
# gh login - is picked up again here, detached so the session never waits. The
# digest's one line says where deliveries stand. Quiet when there is nothing.
delivery=""
if [ -d "$project_dir/.factory/publish" ]; then
  if ls "$project_dir/.factory/publish"/*.pending "$project_dir/.factory/publish"/*.json >/dev/null 2>&1; then
    ( cd "$project_dir" && FACTORY_ROOT="$project_dir" nohup python3 "${HOOK_DIR}/factory-publish.py" --resume-all >/dev/null 2>&1 & ) 2>/dev/null
  fi
  delivery="$(cd "$project_dir" && FACTORY_ROOT="$project_dir" python3 "${HOOK_DIR}/factory-digest.py" --line 2>/dev/null)"
fi

# Unpushed commits (3.1): at autonomy level local the publisher skips every change
# and nothing leaves the machine. Say so at the start of every session, with the
# way out, so a pile of local commits is never a surprise.
unpushed_n="$(cd "$project_dir" && FACTORY_ROOT="$project_dir" bash "${HOOK_DIR}/factory-unpushed.sh" count 2>/dev/null)"
case "${unpushed_n}" in ''|*[!0-9]*) unpushed_n=0 ;; esac
if [ "${unpushed_n}" -gt 0 ]; then
  unpushed_lvl="$(cd "$project_dir" && FACTORY_ROOT="$project_dir" bash "${HOOK_DIR}/factory-autonomy.sh" 2>/dev/null | head -1)"
  delivery="${delivery:+${delivery}
}UNPUSHED: ${unpushed_n} commit(s) are only on this machine (autonomy level ${unpushed_lvl:-local}). Push them, or say 'auto devam et' so changes are delivered."
fi

# Retrospective (2.9): factory-finish writes .factory/retro-due when failure
# evidence piled up. The brief only says so; /factory:retro or retro.mode full acts.
retro=""
[ -s "$project_dir/.factory/retro-due" ] && retro="$(head -1 "$project_dir/.factory/retro-due")"

# An empty board with nothing open anywhere is two lines: the full briefing
# would only spend tokens on "(none)" in every session of an idle project.
if [ "$((backlog + in_progress + blocked + proposed))" -eq 0 ] \
   && [ -z "$id_issues" ] && [ -z "$upgrade" ] && [ -z "$swept" ] && [ -z "$run_state" ] && [ -z "$delivery" ] && [ -z "$retro" ] \
   && [ "$stalled" = "(none)" ] && [ "$changes" = "(none open)" ] \
   && { [ "$questions" = "(none)" ] || [ "$questions" = "  - (no questions)" ]; }; then
  brief="FACTORY ACTIVE in this project: the board is empty (done=${done_count}), nothing is open or waiting.
Session id: ${session_id:-unknown}. /factory:status for detail."
  jq -n --arg ctx "$brief" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  exit 0
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

${delivery:+DELIVERY: ${delivery} (.factory/digest/, factory-publish --status)
}${retro:+RETRO DUE: ${retro}. Run /factory:retro, or set retro.mode to full in .factory/config.json to let a run do it.
}${upgrade:+FACTORY VERSION: ${upgrade}
}${run_state:+RUN: ${run_state}
}${swept:+PREVIOUS RUN ENDED MID-FLIGHT: ${swept}
}${stranded:+  Tasks left in tasks/in-progress by that run: ${stranded}. No agent is alive for them; the next /factory:run takes them over as they are.
}
Ready to build now:
${ready}

Questions waiting for the developer:
${questions}

Last decisions (decisions.md):
${decisions}

Session id: ${session_id:-unknown}

Rules in force: a task enters tasks/done only through factory-settle or factory-land, after "${verify_cmd} <task-id>" wrote .factory/verified/<task-id>; the PreToolUse gate rejects any other move. /factory:status for detail, /factory:run to build.
While /factory:run's loop runs: do not attach a Monitor, a poll or a progress message to it. Every wake-up of this session re-reads its whole context; the workflow reports once, when it is done.
BRIEF
)"

jq -n --arg ctx "$brief" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
