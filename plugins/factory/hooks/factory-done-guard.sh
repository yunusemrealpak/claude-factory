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
#   1. The hard blocks (hooks/hard-blocks.txt), for a subagent's call.
#   2. The done gate. Rejects any attempt to move a task into tasks/done unless
#      .factory/verified/<task-id> exists, i.e. unless the task's check went
#      green. factory-land is the one way in, and it checks the same marker.
#
# Precondition: this hook is inert unless <project>/.factory/active exists.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/factory-compat.sh"
input="$(cat)"

project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$project_dir" ] && project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# The call's cwd is wherever the agent last cd'd to. The factory is the nearest
# folder above it that has .factory/active - a cd into src/ must not turn the
# guard off.
factory_root() {  # <dir>
  local d
  d="$(factory_posix_path "$1")"; d="${d%/}"
  while [ -n "$d" ]; do
    [ -f "$d/.factory/active" ] && { printf '%s' "$d"; return 0; }
    case "$d" in */*) d="${d%/*}" ;; *) break ;; esac
  done
  return 1
}
found="$(factory_root "$project_dir")" || found="$(factory_root "${CLAUDE_PROJECT_DIR:-}")" || exit 0
project_dir="$found"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

# The hard blocks (hooks/hard-blocks.txt), second layer. register.js holds the
# same list in the session; this copy answers when the hooks module is off
# (--safe-mode, an older Claude Code). Only a subagent's call is judged: the
# developer's own session pushes and writes gates when it has to.
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
if [ -n "$agent_id" ]; then
  hb_kind=""; hb_text=""
  case "$tool_name" in
    Bash) hb_kind=bash; hb_text="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" ;;
    PowerShell) hb_kind=powershell; hb_text="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" ;;
    Write|Edit|MultiEdit) hb_kind=path; hb_text="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" ;;
    NotebookEdit) hb_kind=path; hb_text="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null)" ;;
  esac
  if [ -n "$hb_kind" ] && [ -n "$hb_text" ]; then
    hb_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
    hb_rule="$(printf '%s' "$hb_text" | HB_CWD="$hb_cwd" bash "$HOOK_DIR/factory-hardblock.sh" check "$project_dir" "$hb_kind" 2>/dev/null)"
    hb_rc=$?
    # 6: a test HEAD has, which no task in progress was approved to change.
    if [ "$hb_rc" -eq 6 ]; then
      deny "Factory: ${hb_rule#head-tests } is a test the project already has, and existing tests are read-only for this task - a test that was green is the evidence the code works. Write a new test file for what the task adds. If the task truly has to change this test, do not get around it: say so in your result; the developer approves it with modifies_tests in the task file. The run goes on."
    fi
    # 5: inline code that writes and names a protected path - a guess, so only
    # this call is refused and the run goes on.
    if [ "$hb_rc" -eq 5 ]; then
      deny "Factory: inline code that writes files and names a protected path (${hb_rule}) is refused - the factory cannot tell what it writes. Read protected files with the Read tool; if the task has to change one, say so in your result. The run goes on."
    fi
    if [ "$hb_rc" -ne 0 ]; then
      [ "$hb_rc" -eq 3 ] || hb_rule="rule-list-unreadable"
      bash "$HOOK_DIR/factory-hardblock.sh" trip "$project_dir" "$hb_rule" "$tool_name" "$agent_id" >/dev/null 2>&1
      deny "Factory hard block (${hb_rule}): no agent of a factory run may do this - it publishes, spends or rewrites the rules the run is judged by. Do not look for another way. Say in your result that the task needs it, and stop; the run is halted (.factory/STOP) until the developer has looked."
    fi
  fi
fi

case "$tool_name" in
  Bash|PowerShell)
    payload="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    # Join backslash continuations first, so a move written across two lines is
    # still one line by the time it is examined.
    payload="$(printf '%s\n' "$payload" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
    # A move is a single command. Only a line where a moving verb and the done
    # directory appear TOGETHER is a move; a comment, a heredoc body, or an
    # unrelated move elsewhere in the same script is prose and must not be
    # blocked. Narrowing the payload to those lines also keeps the task-id scan
    # below from claiming every other .md file the command happens to name.
    # PowerShell moves with Move-Item / Copy-Item and their aliases, in any
    # letter case.
    moves="$(printf '%s\n' "$payload" | tr '\\' '/' \
      | grep -Ei '(^|[|;&(]|[[:space:]])(mv|cp|rsync|ln|install|move-item|copy-item|mi|cpi|move|copy)([[:space:]]|$)|git[[:space:]]+mv|>[[:space:]]*[^[:space:]]*tasks/done' \
      | grep -i 'tasks/done')"
    [ -n "$moves" ] || exit 0
    payload="$moves"
    ;;
  Write|Edit|MultiEdit|NotebookEdit)
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
  deny "Factory gate: this operation writes into tasks/done without naming a task file, so the verification gate cannot be checked. A task lands through factory-settle <task-id> (or factory-land <task-id>), after factory-check <task-id> went green - never by a hand-written move."
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
  deny "Factory gate: no verification marker for:${missing}. A task may not enter tasks/done before its check is green. Run factory-check <task-id> from the project root: it writes .factory/verified/<task-id> only when the build, the tests, the architecture rules and the linters pass. Then factory-settle <task-id> lands it."
fi

# All named tasks are verified: stay silent so the normal permission flow applies.
exit 0
