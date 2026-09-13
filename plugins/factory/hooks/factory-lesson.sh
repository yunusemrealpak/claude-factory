#!/usr/bin/env bash
# Factory lessons. NOT a hook: /factory-retro writes lessons with it once the
# developer has approved them; implementers only read the files.
#
# Usage (from the project root):
#   factory-lesson add <module> <evidence> <lesson>
#   factory-lesson list [module]
#   factory-lesson remove <module> <number>
#
#   <module>    the task frontmatter's module, or "general" for the whole repo
#   <evidence>  comma-separated task ids and failure signatures (sig-<hash>)
#
# A lesson is one rule about working in this project that an earlier task had to
# learn by failing: "the integration tests need the compose database up",
# "register new handlers in Modules/X/Registration.cs". Implementers read the
# lessons of their module, and the general ones, before they start, so the next
# task does not pay for the same discovery.
#
# Context files agents write for other agents measurably hurt - roughly 3% lower
# success at 20% more cost in one study. What separates a lesson from that is
# enforced here rather than asked for:
#   - evidence: every lesson names the tasks or failure signatures it came from,
#     and each of them must exist on disk;
#   - approval: only /factory-retro adds lessons, one by one, after the
#     developer approves each;
#   - scope: one file per module, read only by tasks of that module;
#   - size: at most 15 lessons per file and 200 characters per lesson, so a full
#     file gives one up before it takes another.
#
# Lessons live in .factory/lessons/ and stay on this machine.
set -uo pipefail

ROOT="$PWD"
L="${ROOT}/.factory/lessons"
MAX_LESSONS=15
MAX_CHARS=200

die() { echo "factory-lesson: $*" >&2; exit 1; }

valid_module() {
  printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "module must be letters, digits, dot, dash or underscore, got '$1'"
}

cmd_add() {
  local module="${1:-}" evidence="${2:-}" text="${3:-}"
  [ -n "${text}" ] || die "usage: add <module> <evidence> <lesson>"
  valid_module "${module}"

  case "${text}" in *"
"*) die "a lesson is one line" ;; esac
  [ "${#text}" -le "${MAX_CHARS}" ] || die "a lesson is at most ${MAX_CHARS} characters; this one is ${#text}. Say less."

  local tok found=0 ev_clean=""
  for tok in $(printf '%s' "${evidence}" | tr ',' ' '); do
    case "${tok}" in
      sig-*)
        [ -f "${ROOT}/.factory/failures/${tok}.txt" ] || die "evidence ${tok}: no .factory/failures/${tok}.txt"
        ;;
      *)
        ls "${ROOT}"/tasks/*/"${tok}".md >/dev/null 2>&1 || die "evidence ${tok}: no task file tasks/*/${tok}.md"
        ;;
    esac
    found=$((found + 1))
    ev_clean="${ev_clean:+${ev_clean}, }${tok}"
  done
  [ "${found}" -gt 0 ] || die "a lesson needs evidence: at least one task id or sig-<hash>"

  mkdir -p "${L}"
  local file="${L}/${module}.md" count=0
  if [ -f "${file}" ]; then
    count="$(grep -c '^- ' "${file}")"
    grep -qF -- "- ${text} [" "${file}" && die "that lesson is already in ${module}.md"
  else
    printf '# Lessons: %s\n\n' "${module}" > "${file}"
  fi
  [ "${count}" -lt "${MAX_LESSONS}" ] || die "${module}.md already holds ${MAX_LESSONS} lessons. Retire one first: factory-lesson.sh list ${module}, then remove ${module} <number>."

  # A full timestamp, not a date: /factory-retro counts the red runs of each
  # evidence signature that happened after it, to see whether the lesson worked.
  printf -- '- %s [evidence: %s; added: %s]\n' "${text}" "${ev_clean}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "${file}"
  echo "LESSON added to .factory/lessons/${module}.md ($((count + 1))/${MAX_LESSONS})"
}

cmd_list() {
  local want="${1:-}" f
  [ -d "${L}" ] || { echo "(no lessons yet)"; return 0; }
  for f in "${L}"/*.md; do
    [ -e "${f}" ] || continue
    [ -n "${want}" ] && [ "$(basename "${f}" .md)" != "${want}" ] && continue
    echo "## $(basename "${f}" .md)"
    grep '^- ' "${f}" | awk '{ printf "%2d %s\n", NR, $0 }'
  done
}

cmd_remove() {
  local module="${1:-}" n="${2:-}"
  valid_module "${module}"
  case "${n}" in ''|*[!0-9]*) die "usage: remove <module> <number>" ;; esac
  local file="${L}/${module}.md"
  [ -f "${file}" ] || die "no lessons for ${module}"
  local total
  total="$(grep -c '^- ' "${file}")"
  [ "${n}" -ge 1 ] && [ "${n}" -le "${total}" ] || die "${module}.md has lessons 1..${total}"
  local tmp="${file}.tmp.$$"
  awk -v n="${n}" '/^- / { k++; if (k == n) { removed = $0; next } } { print } END { print removed > "/dev/stderr" }' "${file}" > "${tmp}" 2> "${tmp}.removed"
  mv "${tmp}" "${file}"
  echo "LESSON removed from ${module}.md: $(cat "${tmp}.removed")"
  rm -f "${tmp}.removed"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   shift; cmd_list "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *)
    echo "usage: factory-lesson.sh add <module> <evidence> <lesson> | list [module] | remove <module> <number>" >&2
    exit 2
    ;;
esac
