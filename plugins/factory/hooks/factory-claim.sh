#!/usr/bin/env bash
# Factory run claim. NOT a hook: /factory-run runs it as its first step.
#
# Usage (from the project root, as a Claude Code Bash tool call):
#   factory-claim               claim an unowned run
#   factory-claim --take-over   replace another session's claim
#
# The Stop hook holds exactly one session in the loop: the one named in
# .factory/run-owner. Naming it needs the session id, and the session id reaches
# hooks only - there is no environment variable for it in a Bash tool call. So
# the claim happens in two halves:
#
#   1. The factory-done-guard PreToolUse hook sees this command, checks the
#      current owner (refusing when another session holds the run and
#      --take-over is absent) and stages this session's id in
#      .factory/run-owner.pending.
#   2. This script, which only runs if the call was allowed, promotes the
#      pending id to .factory/run-owner.
#
# The split matters when the call is denied at the permission prompt: the hook
# has already run by then, and had it written run-owner directly, a session the
# developer just refused would still be held in the loop.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

F="$PWD/.factory"
[ -f "${F}/active" ] || { echo "CLAIM FAILED: ${PWD} has no .factory/active - not a factory project, or not its root."; exit 1; }

if [ ! -s "${F}/run-owner.pending" ]; then
  echo "CLAIM FAILED: no pending claim. The session id is visible only to the PreToolUse hook, so this works only as a Claude Code Bash tool call made from the project root, spelled exactly: factory-claim"
  exit 1
fi

mv -f "${F}/run-owner.pending" "${F}/run-owner"

# A run is being claimed, so no agent dispatched before this moment is still
# working for it: either the previous session ended, or it is being taken over
# after the developer confirmed it is gone. Clear the slots it left holding.
swept="$(bash "${HOOK_DIR}/factory-sweep.sh" claim "$PWD" 2>/dev/null)"
[ -n "${swept}" ] && echo "${swept}"
echo "CLAIMED: this run is owned by session $(tr -d '[:space:]' < "${F}/run-owner"). The Stop hook now holds this session until only blocked work remains, and releases the claim itself when the run ends."
exit 0
