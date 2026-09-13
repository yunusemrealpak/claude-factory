#!/usr/bin/env bash
# Claude Code "PreToolUse" hook - Factory quality gate.
#
# Contract (verified against https://code.claude.com/docs/en/hooks):
#   - stdin  : JSON with .cwd, .tool_name, .tool_input
#   - stdout : {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#               "permissionDecision":"deny","permissionDecisionReason":"..."}}
#              denies the tool call and shows the reason to Claude.
#
# Two jobs, both needing what only a hook sees:
#
#   1. The done gate. Rejects any attempt to move a task into tasks/done unless
#      .factory/verified/<task-id> exists, i.e. unless gates/verify.sh went green.
#   2. The run claim. A Bash call to factory-claim.sh is where a session asks to
#      own the run; the session id is in this hook's input and nowhere a Bash
#      command can read it. See factory-claim.sh for the two-step handshake.
#
# Precondition: this hook is inert unless <project>/.factory/active exists.
set -uo pipefail

input="$(cat)"

project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

[ -f "$project_dir/.factory/active" ] || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

# Stages this session's id for factory-claim.sh to promote. Refuses when a
# different session already owns the run, unless the command says --take-over:
# two leads on one board duplicate dispatches, race on the same task files and
# run competing gates.
stage_claim() {
  local line="$1" session_id owner_file current
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$session_id" ] || deny "Factory claim: this tool call carries no session id, so there is nothing to claim the run with. The Stop hook will not hold this session; run the loop without it and tell the developer."
  owner_file="$project_dir/.factory/run-owner"
  # A redirect from a missing file fails in the shell before tr runs, so the
  # existence check has to come first.
  current=""
  [ -f "$owner_file" ] && current="$(tr -d '[:space:]' < "$owner_file")"
  if [ -n "$current" ] && [ "$current" != "$session_id" ]; then
    case "$line" in
      *--take-over*) ;;
      *) deny "Factory claim: the run is already owned by session ${current}. Do not start a second lead on the same board. Tell the developer; only if they confirm that session is gone, run: factory-claim --take-over" ;;
    esac
  fi
  printf '%s\n' "$session_id" > "$owner_file.pending"
}

case "$tool_name" in
  Bash)
    payload="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    # Join backslash continuations first, so a move written across two lines is
    # still one line by the time it is examined.
    payload="$(printf '%s\n' "$payload" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
    # Only an invocation counts as a claim - "bash <path>/factory-claim.sh" at
    # the start of a command - so reading, grepping or editing the script from a
    # factory project does not quietly make that session the run owner.
    claim="$(printf '%s\n' "$payload" \
      | grep -E '(^|[;&|(])[[:space:]]*(bash|sh)[[:space:]]+[^[:space:];&|]*factory-claim\.sh([[:space:];&|)]|$)' \
      | head -1)"
    [ -n "$claim" ] && stage_claim "$claim"
    # A move is a single command. Only a line where a moving verb and the done
    # directory appear TOGETHER is a move; a comment, a heredoc body, or an
    # unrelated move elsewhere in the same script is prose and must not be
    # blocked. Narrowing the payload to those lines also keeps the task-id scan
    # below from claiming every other .md file the command happens to name.
    moves="$(printf '%s\n' "$payload" \
      | grep -E '(^|[|;&(]|[[:space:]])(mv|cp|rsync|ln|install)([[:space:]]|$)|git[[:space:]]+mv|>[[:space:]]*[^[:space:]]*tasks/done' \
      | grep 'tasks/done')"
    [ -n "$moves" ] || exit 0
    payload="$moves"
    ;;
  Write|Edit|NotebookEdit)
    payload="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    case "$payload" in
      *tasks/done*) ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

# The task ids are the ones landing in the done directory. When the target is
# written as a bare directory rather than a file there is no id on that side,
# so fall back to every .md token on the move line itself.
task_ids="$(printf '%s\n' "$payload" | grep -oE 'tasks/done/[A-Za-z0-9._-]+\.md' | sed 's#.*/##; s/\.md$//' | sort -u)"
if [ -z "$task_ids" ]; then
  task_ids="$(printf '%s\n' "$payload" | grep -oE '[A-Za-z0-9._-]+\.md' | sed 's/\.md$//' | sort -u)"
fi

if [ -z "$task_ids" ]; then
  deny "Factory gate: this operation writes into tasks/done without naming a task file, so the verification gate cannot be checked. Move exactly one task at a time and spell out its file, e.g. mv tasks/in-progress/<task-id>.md tasks/done/<task-id>.md, after gates/verify.sh <task-id> went green."
fi

# An id collision, caught at the point where it would do its damage. When the
# incoming task's id already has a finished file in the done column, this is a
# different task wearing the same id: the move would overwrite the finished
# one, and the verified marker checked below belongs to the old task, not to
# this one - a gate bypass nothing downstream would notice. Only a Bash move is
# an arrival; a Write or Edit on an existing done file is an edit of that file.
if [ "$tool_name" = "Bash" ]; then
  for id in $task_ids; do
    [ -f "$project_dir/tasks/done/$id.md" ] || continue
    for col in proposed backlog in-progress blocked; do
      if [ -f "$project_dir/tasks/$col/$id.md" ]; then
        deny "Factory gate: task id collision on ${id}. tasks/done/${id}.md already exists and tasks/${col}/${id}.md is a different task with the same id. Moving it would overwrite the finished task, and the verified marker it would be judged by belongs to the old one. Rename the newer task - a new change takes a fresh prefix from: factory-ids next-prefix - then gate it under its new id."
      fi
    done
  done
fi

missing=""
for id in $task_ids; do
  [ -f "$project_dir/.factory/verified/$id" ] || missing="$missing $id"
done

if [ -n "$missing" ]; then
  deny "Factory gate: no verification marker for:${missing}. A task may not enter tasks/done before its gate is green. Run: bash gates/verify.sh <task-id> from the project root. It writes .factory/verified/<task-id> only when build, tests, architecture tests and lint all pass. If it fails, append the failing output to the task file, increment retries and hand the task back to an implementer."
fi

# All named tasks are verified: stay silent so the normal permission flow applies.
exit 0
