#!/usr/bin/env bash
# Factory: stop working on a task and say why. NOT a hook.
#
# Usage (from the project root):
#   factory-block <task-id> "<reason>"          block it and park its unlanded work
#   factory-block <task-id> --keep "<reason>"   block it and leave its files in the tree
#   factory-block --unpark <task-id>            put parked work back into the tree
#
# Moves the task to tasks/blocked, appends the reason under "## Blocked reason"
# and drops any verified marker, so nothing downstream mistakes it for finished.
#
# Parking. The factory works in one shared tree, so a task that stops half-way
# leaves half-written files behind - and every other task's build and tests run
# over them. A blocked task's work therefore leaves the tree with it: each file
# on its "## Files touched" list that differs from HEAD is copied to
# .factory/parked/<task-id>/ and put back to what HEAD holds (a file HEAD does not
# have is removed). Nothing is lost - --unpark restores it - and a file another
# task in progress also lists is left alone, because it holds that task's work
# too.
set -uo pipefail

ROOT="$PWD"
T="${ROOT}/tasks"
F="${ROOT}/.factory"
[ -f "${F}/active" ] || { echo "BLOCK REFUSED: ${ROOT} has no .factory/active."; exit 1; }

listed() {  # <task file> - the "- path" lines under "## Files touched"
  awk '
    /^##[[:space:]]+Files touched[[:space:]]*$/ {inside=1; next}
    inside && /^#/ {exit}
    inside && /^[[:space:]]*[-*][[:space:]]+/ {
      sub(/^[[:space:]]*[-*][[:space:]]+/, ""); gsub(/`/, "")
      split($0, w, /[[:space:]]+/); if (w[1] != "") print w[1]
    }' "$1" | sed 's#^\./##' | sort -u
}

if [ "${1:-}" = "--unpark" ]; then
  TASK_ID="${2:-}"
  dir="${F}/parked/${TASK_ID}"
  [ -n "${TASK_ID}" ] && [ -d "${dir}" ] || { echo "UNPARK REFUSED: nothing parked for ${TASK_ID:-?}."; exit 1; }
  n=0
  if [ -d "${dir}/files" ]; then
    while IFS= read -r f; do
      rel="${f#"${dir}/files/"}"
      mkdir -p "$(dirname "${ROOT}/${rel}")" && cp -p "${f}" "${ROOT}/${rel}" && n=$((n + 1))
    done <<< "$(find "${dir}/files" -type f)"
  fi
  if [ -s "${dir}/deleted" ]; then
    while IFS= read -r rel; do [ -n "${rel}" ] && rm -f "${ROOT}/${rel}" && n=$((n + 1)); done < "${dir}/deleted"
  fi
  rm -rf "${dir}"
  echo "UNPARKED ${TASK_ID}: ${n} file(s) back in the tree."
  exit 0
fi

TASK_ID="${1:-}"
shift 2>/dev/null
keep=0
if [ "${1:-}" = "--keep" ]; then keep=1; shift; fi
REASON="$*"
if [ -z "${TASK_ID}" ] || [ -z "${REASON}" ]; then
  echo "usage: factory-block <task-id> [--keep] \"<reason>\" | factory-block --unpark <task-id>" >&2
  exit 2
fi

src=""
for col in in-progress backlog; do
  if [ -f "${T}/${col}/${TASK_ID}.md" ]; then src="${col}"; break; fi
done
[ -n "${src}" ] || { echo "BLOCK REFUSED for ${TASK_ID}: no task file in tasks/in-progress or tasks/backlog."; exit 1; }
file="${T}/${src}/${TASK_ID}.md"

parked=0; shared=""
if [ "${keep}" -eq 0 ] && git -C "${ROOT}" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  others=""
  for o in "${T}"/in-progress/*.md; do
    [ -e "${o}" ] && [ "${o}" != "${file}" ] || continue
    others="${others}$(listed "${o}")
"
  done
  dir="${F}/parked/${TASK_ID}"
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    case "${rel}" in /*|..|../*|*/../*|.factory/*|.git/*|tasks/*|decisions.md) continue ;; esac
    [ -n "$(git -C "${ROOT}" status --porcelain -- "${rel}" 2>/dev/null)" ] || continue
    if printf '%s' "${others}" | grep -qxF -- "${rel}"; then shared="${shared} ${rel}"; continue; fi
    if [ -e "${ROOT}/${rel}" ]; then
      mkdir -p "$(dirname "${dir}/files/${rel}")" && cp -p "${ROOT}/${rel}" "${dir}/files/${rel}"
    else
      mkdir -p "${dir}" && printf '%s\n' "${rel}" >> "${dir}/deleted"
    fi
    if git -C "${ROOT}" cat-file -e "HEAD:./${rel}" 2>/dev/null; then
      mkdir -p "$(dirname "${ROOT}/${rel}")" && git -C "${ROOT}" show "HEAD:./${rel}" > "${ROOT}/${rel}"
    else
      rm -f "${ROOT}/${rel}"
    fi
    parked=$((parked + 1))
  done <<< "$(listed "${file}")"
fi

line="- $(date -u +"%Y-%m-%dT%H:%M:%SZ"): ${REASON}"
[ "${parked}" -gt 0 ] && line="${line}
- parked ${parked} file(s) of unlanded work in .factory/parked/${TASK_ID}/ - restore with: factory-block --unpark ${TASK_ID}"
[ -n "${shared}" ] && line="${line}
- left in the tree because another task in progress lists them too:${shared}"
if grep -qE '^##[[:space:]]+Blocked reason[[:space:]]*$' "${file}"; then
  printf '%s\n' "${line}" >> "${file}"
else
  printf '\n## Blocked reason\n%s\n' "${line}" >> "${file}"
fi
rm -f "${F}/verified/${TASK_ID}"
mkdir -p "${T}/blocked"
mv "${file}" "${T}/blocked/${TASK_ID}.md"
jq -cn --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson epoch "$(date +%s)" --arg id "${TASK_ID}" --arg f "${src}" \
  '{ts: $ts, epoch: $epoch, kind: "move", task: $id, from: $f, to: "blocked"}' >> "${F}/events.jsonl" 2>/dev/null
note=""; [ "${parked}" -gt 0 ] && note=" (parked ${parked} file(s))"
echo "BLOCKED ${TASK_ID}: ${REASON}${note}"
exit 0
