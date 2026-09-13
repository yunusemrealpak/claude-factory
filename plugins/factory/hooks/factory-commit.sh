#!/usr/bin/env bash
# Factory per-task commit. NOT a hook: the factory-integrator runs it once a
# task's post-integration gate is green and its file sits in tasks/done.
#
# Usage: factory-commit <task-id>      (from the project root)
#
# Commits exactly one task as exactly one commit:
#   - the paths listed under "## Files touched" in the task file,
#   - the task file itself, at its new place in tasks/done,
#   - decisions.md.
# Nothing else. The factory works in one shared tree, and that tree can hold the
# developer's own uncommitted work and another task's work in flight, so
# "git add -A" would sweep both into this task's commit. The file list is what
# keeps them out; staging is by name and the commit is --only those names, so
# whatever the developer had already staged stays staged and uncommitted.
#
# The message carries two trailers:
#   Factory-Task: <task-id>
#   Factory-Change: <change-id>
# which is how factory-change.sh finds a change's commits even when other
# commits landed in between.
#
# Never pushes, never amends, never bypasses the project's commit hooks.
#
# Exit: 0 committed, or skipped because there is no repository / nothing to
# commit (the output says which); 1 refused or failed (the output says why).
set -uo pipefail

TASK_ID="${1:-}"
if [ -z "${TASK_ID}" ]; then
  echo "usage: factory-commit <task-id>" >&2
  exit 2
fi
ROOT="$PWD"
TASK_FILE="${ROOT}/tasks/done/${TASK_ID}.md"

refuse() { echo "COMMIT REFUSED for ${TASK_ID}: $*"; exit 1; }

if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "COMMIT SKIPPED for ${TASK_ID}: ${ROOT} is not inside a git repository."
  exit 0
fi

# A commit in the middle of somebody's merge, rebase or cherry-pick would land
# inside their operation.
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if [ -e "$(git -C "${ROOT}" rev-parse --git-path "${state}")" ]; then
    refuse "the repository is in the middle of an operation (${state}). Leave it to the developer; do not finish or abort it."
  fi
done

[ -f "${TASK_FILE}" ] || refuse "tasks/done/${TASK_ID}.md does not exist. The commit records a finished task: move it to done after a green gate first."

# --- what the task says it touched ------------------------------------------
# Lines of the form "- path" (backticks allowed) between "## Files touched" and
# the next heading of any level - an "### Attempt" written straight under the
# list must end it, or its bullets would be read as paths. The first word is the
# path; anything after it is a note for the reader.
listed="$(awk '
  /^##[[:space:]]+Files touched[[:space:]]*$/ {inside=1; next}
  inside && /^#/ {exit}
  inside && /^[[:space:]]*[-*][[:space:]]+/ {
    sub(/^[[:space:]]*[-*][[:space:]]+/, "")
    gsub(/`/, "")
    split($0, w, /[[:space:]]+/)
    if (w[1] != "") print w[1]
  }' "${TASK_FILE}" | sort -u)"

paths=()
skipped=""
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  p="${p#./}"
  case "${p}" in
    /*|..|../*|*/../*|*/..)  skipped="${skipped} ${p}(outside-project)"; continue ;;
    .factory/*|.git/*|.git)  skipped="${skipped} ${p}(factory-or-git-internal)"; continue ;;
    tasks/*|decisions.md)    continue ;;  # added below on their own terms
  esac
  if [ -e "${ROOT}/${p}" ] || [ -n "$(git -C "${ROOT}" ls-files -- "${p}" 2>/dev/null)" ]; then
    paths+=("${p}")
  else
    skipped="${skipped} ${p}(no-such-file)"
  fi
done <<< "${listed}"

[ "${#paths[@]}" -gt 0 ] || refuse "the task file has no usable \"## Files touched\" entries${skipped:+ (skipped:${skipped})}. The implementer records one repo-relative path per line there; without it this script cannot tell the task's changes from everything else in the tree. Report it to the lead; do not commit by hand."

# --- shared files -------------------------------------------------------------
# A file that another in-flight task also lists holds that task's edits too. It
# cannot be split here: the commit goes ahead and says so.
shared=""
for other in "${ROOT}"/tasks/in-progress/*.md; do
  [ -e "${other}" ] || continue
  oid="$(basename "${other}" .md)"
  [ "${oid}" = "${TASK_ID}" ] && continue
  theirs="$(awk '
    /^##[[:space:]]+Files touched[[:space:]]*$/ {inside=1; next}
    inside && /^#/ {exit}
    inside && /^[[:space:]]*[-*][[:space:]]+/ {
      sub(/^[[:space:]]*[-*][[:space:]]+/, ""); gsub(/`/, "")
      split($0, w, /[[:space:]]+/); if (w[1] != "") print w[1]
    }' "${other}")"
  for p in "${paths[@]}"; do
    if printf '%s\n' "${theirs}" | sed 's#^\./##' | grep -qxF -- "${p}"; then
      shared="${shared} ${p}(also-${oid})"
    fi
  done
done

# --- the task file and decisions.md ---------------------------------------------
# The done copy is new or changed; a copy git still tracks at an earlier column
# is recorded as removed, which is how the move shows up in history.
for col in proposed backlog in-progress blocked done; do
  tp="tasks/${col}/${TASK_ID}.md"
  if [ -e "${ROOT}/${tp}" ] || [ -n "$(git -C "${ROOT}" ls-files -- "${tp}" 2>/dev/null)" ]; then
    paths+=("${tp}")
  fi
done
if [ -e "${ROOT}/decisions.md" ] || [ -n "$(git -C "${ROOT}" ls-files -- decisions.md 2>/dev/null)" ]; then
  paths+=("decisions.md")
fi

# --- which change it belongs to ---------------------------------------------------
case "${TASK_ID}" in
  C[0-9]*-*) change="${TASK_ID%%-*}" ;;
  *)         change="C1" ;;
esac

title="$(awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
              inside && /^---[[:space:]]*$/ {exit}
              inside && /^title:/ {sub(/^title:[[:space:]]*/, ""); print; exit}' "${TASK_FILE}")"
[ -n "${title}" ] || title="factory task"

if ! git -C "${ROOT}" add -A -- "${paths[@]}"; then
  refuse "git add failed on:$(printf ' %s' "${paths[@]}")"
fi

if git -C "${ROOT}" diff --cached --quiet -- "${paths[@]}" 2>/dev/null \
   && git -C "${ROOT}" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo "COMMIT SKIPPED for ${TASK_ID}: none of its files differ from HEAD - nothing to commit."
  exit 0
fi

msg_trailers="$(printf 'Factory-Task: %s\nFactory-Change: %s' "${TASK_ID}" "${change}")"
if ! out="$(git -C "${ROOT}" commit -q -m "${TASK_ID}: ${title}" -m "${msg_trailers}" -- "${paths[@]}" 2>&1)"; then
  printf '%s\n' "${out}"
  refuse "git commit failed (output above). If a project commit hook rejected it, that is a finding for the lead, not something to route around: never --no-verify."
fi

sha="$(git -C "${ROOT}" rev-parse --short HEAD)"
echo "COMMIT ${sha} ${TASK_ID} (${change}): $(printf '%s ' "${paths[@]}")"
[ -n "${skipped}" ] && echo "COMMIT NOTE: listed but not committed:${skipped}"
[ -n "${shared}" ]  && echo "COMMIT SHARED: these files are also listed by a task still in flight, so this commit may carry part of its work:${shared}"
exit 0
