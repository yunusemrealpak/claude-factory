#!/usr/bin/env bash
# Factory: which task's commit broke this?
#
# Usage (from the project root):
#   factory-bisect                 the config's test command
#   factory-bisect "<command>"     any command
#   factory-bisect "<command>" --max 20
#
# The factory records one commit per task, each carrying a Factory-Task trailer.
# That turns "the suite is red and it was green yesterday" into a question with
# an exact answer: which task's commit made it red. This binary-searches the
# task commits and names it.
#
# Nothing is checked out in the working tree. Each candidate is tested in a
# detached worktree built from that commit, with the project's own hooks
# disabled and the paths listed in "isolation_links" (config) symlinked in, so
# dependencies that live outside git - node_modules, build caches - are there
# without being copied. Uncommitted work is deliberately not part of any run:
# the question is about committed history.
#
# The command runs log2(N)+2 times, which is the whole cost. Nothing is written
# to the repository, and no branch, ref or index is touched.
set -uo pipefail

ROOT="$PWD"
CONFIG="${ROOT}/.factory/config.json"

die() { echo "factory-bisect: $*" >&2; exit 2; }

git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "this is not a git repository, so there is no history to bisect"

CMD="${1:-}"
if [ -n "${CMD}" ] && [ "${CMD#--}" != "${CMD}" ]; then CMD=""; else shift 2>/dev/null || true; fi
MAX=40
while [ $# -gt 0 ]; do
  case "$1" in
    --max) MAX="${2:-40}"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "${CMD}" ]; then
  CMD="$(jq -r '.commands.test // empty' "${CONFIG}" 2>/dev/null)"
  [ -n "${CMD}" ] || die "no command given and .factory/config.json has no commands.test"
fi

LINKS="$(jq -r '.isolation_links[]? // empty' "${CONFIG}" 2>/dev/null)"

WORK=""
cleanup() {
  [ -n "${WORK}" ] || return 0
  git -C "${ROOT}" worktree remove --force "${WORK}" >/dev/null 2>&1
  rm -rf "${WORK}" 2>/dev/null
  WORK=""
}
trap cleanup EXIT INT TERM

# Run the command against one commit. 0 = good, non-zero = bad.
try() {  # <sha>
  local sha="$1" rc=0 link target
  cleanup
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/factory-bisect.XXXXXX")"
  rm -rf "${WORK}"
  # core.hooksPath=/dev/null: a project's own git hooks are not part of the
  # question, and some of them write to the repository.
  git -C "${ROOT}" -c core.hooksPath=/dev/null worktree add --detach --quiet "${WORK}" "${sha}" >/dev/null 2>&1 \
    || { echo "  (could not build a worktree at ${sha})" >&2; return 125; }
  for link in ${LINKS}; do
    target="${ROOT}/${link}"
    [ -e "${target}" ] || continue
    mkdir -p "$(dirname "${WORK}/${link}")"
    ln -s "${target}" "${WORK}/${link}" 2>/dev/null
  done
  ( cd "${WORK}" && eval "${CMD}" ) >/dev/null 2>&1
  rc=$?
  cleanup
  return ${rc}
}

# Oldest first, newest last: the order the tasks landed in.
commits="$(git -C "${ROOT}" log --reverse --format='%H %h' --grep='^Factory-Task: ' -n "${MAX}" 2>/dev/null)"
n="$(printf '%s\n' "${commits}" | grep -c .)"
[ "${n}" -gt 0 ] || die "no commit carries a Factory-Task trailer, so there is nothing to bisect"

echo "BISECT ${n} task commit(s), command: ${CMD}"

head_sha="$(git -C "${ROOT}" rev-parse HEAD)"
echo "  testing HEAD ..."
if try "${head_sha}"; then
  echo "BISECT CLEAN: the command passes at HEAD. Whatever is failing is in the working tree, not in the committed history - check uncommitted changes first."
  exit 0
fi

first_sha="$(printf '%s\n' "${commits}" | head -1 | awk '{print $1}')"
parent="$(git -C "${ROOT}" rev-parse -q --verify "${first_sha}^" 2>/dev/null)"
if [ -n "${parent}" ]; then
  echo "  testing the commit before the first task ..."
  if ! try "${parent}"; then
    echo "BISECT INCONCLUSIVE: the command already fails at ${parent:0:12}, before the first task commit in range. The breakage predates this range - widen it with --max, or the command needs something the old tree cannot provide (dependencies, a migration, an environment variable)."
    exit 1
  fi
fi

# Binary search for the first bad commit.
lo=1; hi="${n}"; bad=""
while [ "${lo}" -le "${hi}" ]; do
  mid=$(( (lo + hi) / 2 ))
  line="$(printf '%s\n' "${commits}" | sed -n "${mid}p")"
  sha="$(printf '%s' "${line}" | awk '{print $1}')"
  short="$(printf '%s' "${line}" | awk '{print $2}')"
  printf '  [%d/%d] %s ... ' "${mid}" "${n}" "${short}"
  try "${sha}"; rc=$?
  if [ "${rc}" -eq 125 ]; then
    echo "skipped"
    die "the worktree for ${short} could not be built, so this commit cannot be judged and the search cannot continue"
  elif [ "${rc}" -eq 0 ]; then
    echo "good"
    lo=$(( mid + 1 ))
  else
    echo "BAD"
    bad="${sha}"
    hi=$(( mid - 1 ))
  fi
done

if [ -z "${bad}" ]; then
  echo "BISECT INCONCLUSIVE: every task commit in range passes on its own, but HEAD fails. The break is in a commit that carries no Factory-Task trailer - work committed by hand, a merge, or a dependency change."
  exit 1
fi

task="$(git -C "${ROOT}" show -s --format='%(trailers:key=Factory-Task,valueonly)' "${bad}" | head -1)"
subject="$(git -C "${ROOT}" show -s --format='%s' "${bad}")"
when="$(git -C "${ROOT}" show -s --format='%ci' "${bad}")"
file="$(ls "${ROOT}"/tasks/*/"${task}".md 2>/dev/null | head -1)"

echo
echo "FIRST BAD $(git -C "${ROOT}" rev-parse --short "${bad}") task ${task:-unknown}: ${subject}"
echo "  committed ${when}"
[ -n "${file}" ] && echo "  task file ${file#"${ROOT}/"}"
echo "  what it changed: git show $(git -C "${ROOT}" rev-parse --short "${bad}")"
echo "  undo just this task: git revert $(git -C "${ROOT}" rev-parse --short "${bad}")"
echo
echo "This is the first commit where \"${CMD}\" fails; the one before it passes. It is where to look, not proof of what is wrong: a commit can be the first to expose a fault that another task left behind."
exit 0
