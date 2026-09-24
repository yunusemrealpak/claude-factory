#!/usr/bin/env bash
# Factory: is this task file fit to dispatch?
#
# Usage (from the project root):
#   factory-lint <task-id>
#   factory-lint --all      every task not yet done
#
# A malformed task is found the expensive way: an agent is dispatched, works
# from a template placeholder or a dependency that does not exist, and the turn
# is spent before anyone notices. Everything here is checkable from the file
# itself, so it is checked before the dispatch, for free.
#
# Exit 0 = clean. Exit 1 = at least one problem, one per line.
set -uo pipefail

ROOT="$PWD"
T="${ROOT}/tasks"
problems=0

frontmatter() {
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" 2>/dev/null
}

lint_one() {  # <file>
  local f="$1" id fm bad=0
  id="$(basename "${f}" .md)"
  say() { echo "LINT ${id}: $*"; bad=1; problems=$((problems + 1)); }

  head -1 "${f}" | grep -qE '^---[[:space:]]*$' || { say "the file does not start with a frontmatter block"; return; }
  fm="$(frontmatter "${f}")"
  [ -n "${fm}" ] || { say "the frontmatter block is empty or never closes"; return; }

  local key val
  for key in id title module depends_on acceptance needs_human retries stage; do
    printf '%s\n' "${fm}" | grep -qE "^${key}:" || say "frontmatter has no ${key}:"
  done

  # A duplicated key is worse than a missing one: every reader takes the first
  # match, so the second copy is silently ignored.
  local dup
  dup="$(printf '%s\n' "${fm}" | sed -n 's/^\([a-z_]*\):.*/\1/p' | sort | uniq -d | tr '\n' ' ')"
  [ -n "${dup}" ] && say "frontmatter repeats: ${dup% } - only the first copy of a key is ever read"

  val="$(printf '%s\n' "${fm}" | sed -n 's/^id:[[:space:]]*//p' | head -1)"
  [ "${val}" = "${id}" ] || say "id: ${val:-(empty)} does not match the filename ${id}.md"

  val="$(printf '%s\n' "${fm}" | sed -n 's/^title:[[:space:]]*//p' | head -1)"
  [ -n "${val}" ] || say "title: is empty"

  val="$(printf '%s\n' "${fm}" | sed -n 's/^needs_human:[[:space:]]*//p' | head -1)"
  case "${val}" in true|false) ;; *) say "needs_human: must be true or false, not '${val}'" ;; esac

  val="$(printf '%s\n' "${fm}" | sed -n 's/^review:[[:space:]]*//p' | head -1)"
  case "${val}" in ''|on-red|always) ;; *) say "review: must be on-red or always, not '${val}'" ;; esac

  val="$(printf '%s\n' "${fm}" | sed -n 's/^retries:[[:space:]]*//p' | head -1)"
  case "${val}" in ''|*[!0-9]*) say "retries: must be a number, not '${val}'" ;; esac

  # The acceptance command is the whole contract. A command that only reads a
  # markdown file is satisfied by writing a sentence.
  val="$(printf '%s\n' "${fm}" | sed -n 's/^acceptance:[[:space:]]*//p' | head -1)"
  if [ -z "${val}" ]; then
    say "acceptance: is empty - a task with no runnable command cannot go green"
  else
    case "${val}" in
      *"<"*) say "acceptance: still holds a template placeholder: ${val}" ;;
    esac
    if printf '%s' "${val}" | grep -qE '(decisions\.md|tasks/)' \
       && ! printf '%s' "${val}" | grep -qE '(test|verify|build|lint|run|pytest|jest|gradle|dotnet|npm|yarn|pnpm|make|cargo|go )'; then
      say "acceptance: its only evidence is a markdown file (${val}) - the gate rejects those"
    fi
  fi

  # Dependencies have to exist somewhere on the board, and a task cannot wait
  # for itself.
  local deps d found
  deps="$(printf '%s\n' "${fm}" | sed -n 's/^depends_on:[[:space:]]*//p' | head -1 | tr -d '[]"' | tr ',' ' ')"
  for d in ${deps}; do
    [ -n "${d}" ] || continue
    [ "${d}" = "${id}" ] && { say "depends_on lists itself"; continue; }
    found="$(find "${T}" -maxdepth 2 -name "${d}.md" -type f 2>/dev/null | head -1)"
    [ -n "${found}" ] || say "depends_on names ${d}, which is not a task on the board"
  done

  local sec
  for sec in "## Goal" "## Acceptance criteria" "## Files touched" "## Attempts"; do
    grep -qF "${sec}" "${f}" || say "the ${sec} section is missing"
  done
  grep -qE '^- \[[ xX]\] ' "${f}" || say "## Acceptance criteria lists no checkable criterion"
  grep -qE '^<(what must be true|files/modules|filled in by|appended by|the files a builder)' "${f}" \
    && say "template placeholder text is still in the body"

  [ "${bad}" -eq 0 ] && echo "LINT OK ${id}"
}

case "${1:-}" in
  --all)
    for col in proposed backlog in-progress; do
      for f in "${T}/${col}"/*.md; do
        [ -e "${f}" ] || continue
        lint_one "${f}"
      done
    done
    ;;
  '')
    echo "usage: factory-lint.sh <task-id> | --all" >&2; exit 2 ;;
  *)
    file="$(find "${T}" -maxdepth 2 -name "${1}.md" -type f 2>/dev/null | head -1)"
    [ -n "${file}" ] || { echo "factory-lint: no task file for ${1} under tasks/" >&2; exit 2; }
    lint_one "${file}"
    ;;
esac

[ "${problems}" -eq 0 ]
