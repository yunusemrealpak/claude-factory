#!/usr/bin/env bash
# Claude Code "Stop" hook - Factory continuous-run gate.
#
# Contract (verified against https://code.claude.com/docs/en/hooks):
#   - stdin  : JSON with .cwd, .session_id, .hook_event_name,
#              .stop_hook_active, .background_tasks
#   - stdout : {"decision":"block","reason":"..."} prevents the turn from ending.
#              Omitting the field lets Claude stop normally.
#   - Claude Code caps consecutive stop-hook blocks at 8, which is the
#     built-in escape hatch against an unresolvable loop.
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

# Never interfere with ordinary sessions.
[ -f "$project_dir/.factory/active" ] || exit 0

# Which session owns this run?
#
# .factory/active says the factory is open, not who is running it. Without this
# check the gate fired for every session in the project - one opened to read the
# code, fix a hook or answer a question got told to "continue the loop", and a
# session that obeyed would start a second lead dispatching against the same
# board. /factory-run claims the run through factory-claim.sh, which leaves its
# session id in .factory/run-owner, and only that session is held here.
#
# Every direction of doubt fails open: no owner file, an owner that is not this
# session, or no session id in the payload means stay out of the way. Failing
# open costs a run that stops early and gets restarted; failing closed costs an
# unrelated session trapped in somebody else's loop, which is the bug this
# replaces.
owner_file="$project_dir/.factory/run-owner"
[ -f "$owner_file" ] || exit 0
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$session_id" ] && exit 0
run_owner="$(tr -d '[:space:]' < "$owner_file" 2>/dev/null)"
[ "$run_owner" = "$session_id" ] || exit 0

# Tasks flagged needs_human are never assignable; they only count as work
# still to be routed into tasks/blocked.
count_tasks() {
  local dir="$1" mode="$2" total=0 file
  [ -d "$dir" ] || { printf '0'; return 0; }
  for file in "$dir"/*.md; do
    [ -e "$file" ] || continue
    if grep -qiE '^[[:space:]]*needs_human:[[:space:]]*true[[:space:]]*$' "$file"; then
      [ "$mode" = "human" ] && total=$((total + 1))
    else
      [ "$mode" = "actionable" ] && total=$((total + 1))
    fi
  done
  printf '%s' "$total"
}

backlog=$(count_tasks "$project_dir/tasks/backlog" actionable)
in_progress=$(count_tasks "$project_dir/tasks/in-progress" actionable)
stray_human=$(count_tasks "$project_dir/tasks/backlog" human)
stray_human=$((stray_human + $(count_tasks "$project_dir/tasks/in-progress" human)))

emit_block() {
  jq -n --arg reason "$1" '{decision: "block", reason: $reason}'
  exit 0
}

# Claude Code reports in-flight work in background_tasks. A lead that dispatched
# agents and is now waiting is NOT an idle lead: the harness wakes it when an
# agent returns. Blocking here produced a burst of empty turns that reported
# "still waiting, nothing changed" and did no work, until the 8-block cap ended
# the turn. Let the session rest while agents run.
running="$(printf '%s' "$input" | jq -r '[.background_tasks[]? | select(.status != "completed" and .status != "failed")] | length' 2>/dev/null)"
[ -z "$running" ] && running=0

# Reconcile the concurrency markers written by factory-agent-limit.sh against
# what the harness actually reports as in flight. A marker whose agent already
# returned would otherwise hold a slot forever.
inflight_dir="$project_dir/.factory/inflight"
if [ -d "$inflight_dir" ]; then
  markers="$(find "$inflight_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "$markers" ] && markers=0
  if [ "$markers" -gt "$running" ]; then
    # Drop the oldest surplus markers; the newest ones match the live agents.
    find "$inflight_dir" -maxdepth 1 -type f -print0 2>/dev/null \
      | xargs -0 ls -t 2>/dev/null \
      | tail -n "+$((running + 1))" \
      | while IFS= read -r stale; do rm -f "$stale" 2>/dev/null; done
  fi
fi
if [ "$running" -gt 0 ]; then
  exit 0
fi

# Every in-progress task must name its owner and its pipeline stage, so the
# run can be resumed after a compaction. Missing metadata is a
# blocking condition, not a cosmetic one: an unowned task has no one to finish it.
missing_meta=""
if [ -d "$project_dir/tasks/in-progress" ]; then
  for file in "$project_dir/tasks/in-progress"/*.md; do
    [ -e "$file" ] || continue
    id="$(basename "$file" .md)"
    grep -qE '^[[:space:]]*owner:[[:space:]]*[^[:space:]]' "$file" || { missing_meta="$missing_meta $id(owner)"; continue; }
    grep -qE '^[[:space:]]*stage:[[:space:]]*(queued|implementing|verifying|review|integrating)[[:space:]]*$' "$file" || missing_meta="$missing_meta $id(stage)"
  done
fi

if [ -n "$missing_meta" ]; then
  emit_block "Task metadata is incomplete for:${missing_meta}. Every file in tasks/in-progress must carry owner: <teammate name> and stage: one of queued|implementing|verifying|review|integrating, plus stage_since: <UTC ISO-8601> updated on every stage change. Fill them in, then continue the loop."
fi

if [ "$backlog" -gt 0 ] || [ "$in_progress" -gt 0 ]; then
  emit_block "Factory run is not finished: ${backlog} task(s) in tasks/backlog, ${in_progress} task(s) in tasks/in-progress. Do not stop. Claim every task whose depends_on entries are all in tasks/done, dispatch it to an implementer, and if a teammate is idle or unresponsive respawn it and reassign its task. A task may only reach tasks/done after gates/verify.sh wrote .factory/verified/<task-id>. Continue the loop now."
fi

if [ "$stray_human" -gt 0 ]; then
  emit_block "${stray_human} task(s) with needs_human: true are still sitting in tasks/backlog or tasks/in-progress. No agent may work on them. Move each one to tasks/blocked, then stop."
fi

# Only blocked / needs-human work remains: the run is over.
#
# Bring the change archive up to date first. A change whose last task just
# reached done is closed here, and gets its local ref. This is the only point
# that is guaranteed to come once, at the end of a run, in the session that ran
# it. Nothing here runs a project command: sync only reads the board.
changes="$(cd "$project_dir" && bash "${HOOK_DIR}/factory-change.sh" sync 2>/dev/null)"
closed_now="$(printf '%s\n' "$changes" | awk '$1=="CLOSED-NOW" {print $2}' | tr '\n' ' ' | sed 's/ $//')"
still_open="$(printf '%s\n' "$changes" | awk '$1=="open" || $1=="blocked" {print $2 " (" $1 ", " $3 ")"}' | tr '\n' ' ' | sed 's/ $//')"

# A change with every task done and its own acceptance command still to prove.
# The run does not end on "all tasks green" when the change claimed more than
# that - but only an acceptance that was never run holds the session here. Once
# it has run and gone red, the verdict is recorded, the developer is told, and
# the session is free to stop: a red acceptance is a decision for a person, not
# a loop to spin in.
unverified="$(printf '%s\n' "$changes" | awk '$1=="unverified" {print $2}')"
never_run=""
for ch in $unverified; do
  cid="${ch%%-*}"
  state="$( (cd "$project_dir" && bash "${HOOK_DIR}/factory-accept.sh" "$cid" --show 2>/dev/null) | awk '{print $2}')"
  case "$state" in
    NEVER-RUN|stale) never_run="$never_run $cid" ;;
  esac
done
if [ -n "$never_run" ]; then
  emit_block "Every task is done, but these changes carry an acceptance command of their own that has not run against the task set they have now:${never_run}. Run it for each one - factory-accept <change-id> - and report the verdict. Green closes the change. Red is a seam between tasks that each passed alone: report the failing output to the developer, leave the change open, and do not edit the acceptance command to make it pass."
fi

# Release the claim so the next /factory-run - this session or another - can
# take it, and allow the session to stop. Nothing is in flight at this point:
# the run is over, so any inflight marker or unfinished agent_start left in the
# records belongs to a dispatch that never reported back.
bash "${HOOK_DIR}/factory-sweep.sh" run-end "$project_dir" >/dev/null 2>&1
rm -f "$owner_file" 2>/dev/null

# The developer's screen, brought up to date one last time: the event hook
# rebuilds it during the run, but the last few moves land after its final event.
( cd "$project_dir" && bash "${HOOK_DIR}/factory-dash.sh" >/dev/null 2>&1 )

open_q=0
[ -d "$project_dir/.factory/questions" ] && open_q="$(grep -l '^status: open' "$project_dir/.factory/questions"/*.md 2>/dev/null | grep -c .)"

msg="Factory run finished."
[ "$open_q" -gt 0 ] 2>/dev/null && msg="$msg ${open_q} question(s) are waiting for you - see .factory/dashboard.html, answer with: factory-ask answer <id> \"...\""
[ -n "$closed_now" ] && msg="$msg Closed: ${closed_now} - summary in .factory/changes/<change>/summary.md, local ref under refs/factory/."
[ -n "$still_open" ] && msg="$msg Not finished: ${still_open}."
if [ -n "$unverified" ]; then
  acc_red="$(printf '%s\n' "$unverified" | tr '\n' ' ' | sed 's/ $//')"
  msg="$msg Waiting on a change acceptance: ${acc_red} - see .factory/changes/<change>/acceptance.log."
fi
msg="$msg /factory-retro reviews the run."

# systemMessage is shown to the developer; with no decision field the session
# stops normally.
jq -n --arg m "$msg" '{systemMessage: $m}'
exit 0
