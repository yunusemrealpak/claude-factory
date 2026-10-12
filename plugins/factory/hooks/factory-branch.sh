#!/usr/bin/env bash
# Factory: where a change's commits go. NOT a hook: factory-plan --start calls
# it when config delivery.branch is "per-change".
#
# Usage (from the project root):
#   factory-branch.sh <change-id>
#
# delivery.branch = main        the run commits on the current branch; nothing
#                               here changes (BRANCH STAY). The publisher then
#                               pushes HEAD to factory/<Cn>-<slug> without a
#                               checkout.
# delivery.branch = per-change  fetch origin, cut factory/<Cn>-<slug> from
#                               origin/<delivery.base> and switch to it.
#
# Refused (exit 1, the output says why): a tree with work that is not the
# factory's, and a change that depends on one whose publish is still pending -
# it would branch from a main that does not hold it yet.
#
# Exit: 0 ready; 1 refused; 2 usage.
set -uo pipefail

ROOT="${FACTORY_ROOT:-$PWD}"
F="${ROOT}/.factory"
CH="${1:-}"
[ -n "${CH}" ] || { echo "usage: factory-branch.sh <change-id>" >&2; exit 2; }

mode="$(jq -r '.delivery.branch // "main"' "${F}/config.json" 2>/dev/null)"
base="$(jq -r '.delivery.base // "main"' "${F}/config.json" 2>/dev/null)"
if [ "${mode}" != "per-change" ]; then
  echo "BRANCH STAY: delivery.branch is ${mode}; the run commits on the current branch"
  exit 0
fi

slug=""
for d in "${F}/changes/${CH}"-*; do [ -d "${d}" ] && slug="$(basename "${d}")" && break; done
[ -n "${slug}" ] || { echo "BRANCH REFUSED: no change ${CH} under .factory/changes"; exit 1; }
branch="factory/${slug}"

git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "BRANCH REFUSED: not a git repository"; exit 1; }

# Already on it: a resumed run.
cur="$(git -C "${ROOT}" symbolic-ref --short -q HEAD 2>/dev/null)"
[ "${cur}" = "${branch}" ] && { echo "BRANCH READY ${branch}: already on it"; exit 0; }

dirty="$(git -C "${ROOT}" status --porcelain 2>/dev/null | cut -c4- \
  | grep -vE '^(tasks/|decisions\.md|\.factory/|gates/|specs/|CLAUDE\.md|\.gitignore|\.claude/)' | head -5)"
if [ -n "${dirty}" ]; then
  echo "BRANCH REFUSED: the tree holds work that is not the factory's ($(printf '%s' "${dirty}" | tr '\n' ' ')); commit or stash it first"
  exit 1
fi

# A change this one builds on that is not on the base yet.
for p in "${F}/publish"/C*.json; do
  [ -f "${p}" ] || continue
  other="$(basename "${p}" .json)"
  [ "${other}" = "${CH}" ] && continue
  st="$(jq -r '.state // empty' "${p}" 2>/dev/null)"
  case "${st}" in done|merged|synced|abandoned|"") continue ;; esac
  if grep -qE "^extends:.*\b${other}\b" "${F}/changes/${slug}/goal.md" 2>/dev/null; then
    echo "BRANCH REFUSED: ${CH} builds on ${other}, whose publish is still ${st}; it would branch from a ${base} that does not hold it"
    exit 1
  fi
done

git -C "${ROOT}" fetch -q origin "${base}" 2>/dev/null \
  || { echo "BRANCH REFUSED: could not fetch origin/${base}"; exit 1; }
if git -C "${ROOT}" rev-parse --verify -q "refs/heads/${branch}" >/dev/null; then
  git -C "${ROOT}" switch -q "${branch}" || { echo "BRANCH REFUSED: could not switch to ${branch}"; exit 1; }
else
  git -C "${ROOT}" switch -q -c "${branch}" "origin/${base}" || { echo "BRANCH REFUSED: could not cut ${branch}"; exit 1; }
fi
echo "BRANCH READY ${branch}: from origin/${base} $(git -C "${ROOT}" rev-parse --short "origin/${base}")"
exit 0
