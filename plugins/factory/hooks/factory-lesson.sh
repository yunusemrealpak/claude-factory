#!/usr/bin/env bash
# Factory lessons. NOT a hook: /factory-retro writes lessons with it once the
# developer has approved them; builders only read the files.
#
# Usage (from the project root):
#   factory-lesson add <module> <evidence> <lesson> [--category C] [--retire-when X]
#   factory-lesson update <module> <number> <evidence> <lesson> [--category C] [--retire-when X]
#   factory-lesson list [module]
#   factory-lesson remove <module> <number>
#   factory-lesson check [module]
#
#   <module>    the task frontmatter's module, or "general" for the whole repo
#   <evidence>  comma-separated task ids and failure signatures (sig-<hash>)
#   --category  one of: build test tooling convention environment dependency
#   --retire-when
#               a path (relative to the root) that must exist, or a commit sha
#               that must be reachable from HEAD, for the lesson to hold. When
#               it is gone, `check` says the lesson is due to retire.
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
#     file gives one up before it takes another;
#   - no second copy: a lesson that overlaps one already in the file is
#     refused, and the refusal names the one to update instead (see OVERLAP);
#   - an end: a lesson that names what it depends on (--retire-when) is flagged
#     by `check` once that is gone.
#
# A line: - <lesson> [evidence: <ids>; category: <c>; retire_when: <x>; added: <UTC>]
# category and retire_when are optional, and a line written before they
# existed (evidence and added only) is read the same as ever.
#
# OVERLAP - measured against every lesson of the same file, in five
# dimensions, each worth one point:
#   module    always (only the lessons of one module file are compared)
#   category  both have one, and it is the same
#   paths     they name a path in common (a word with a / or a file.ext, and the
#             retire_when path)
#   command   the first `code span` of each starts with the same two words
#   words     their words (lower case, letters and digits, a few stop words
#             left out) overlap by at least half: |A and B| / |A or B| >= 0.5
# Three points, or 80% of the same words on their own, is an overlap.
#
# Lessons live in .factory/lessons/ and stay on this machine.
set -uo pipefail

ROOT="$PWD"
L="${ROOT}/.factory/lessons"
MAX_LESSONS=15
MAX_CHARS=200
CATEGORIES="build test tooling convention environment dependency"

die() { echo "factory-lesson: $*" >&2; exit 1; }

valid_module() {
  printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "module must be letters, digits, dot, dash or underscore, got '$1'"
}

# The positional arguments in P1..P4, the options in OPT_CATEGORY and
# OPT_RETIRE (no arrays: an empty one trips set -u in bash 3.2).
parse_args() {
  P1=""; P2=""; P3=""; P4=""; OPT_CATEGORY=""; OPT_RETIRE=""
  local np=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --category) [ $# -ge 2 ] || die "--category needs a value"; OPT_CATEGORY="$2"; shift 2; continue ;;
      --category=*) OPT_CATEGORY="${1#*=}"; shift; continue ;;
      --retire-when) [ $# -ge 2 ] || die "--retire-when needs a value"; OPT_RETIRE="$2"; shift 2; continue ;;
      --retire-when=*) OPT_RETIRE="${1#*=}"; shift; continue ;;
    esac
    np=$((np + 1))
    case "${np}" in
      1) P1="$1" ;; 2) P2="$1" ;; 3) P3="$1" ;; 4) P4="$1" ;;
      *) die "too many arguments (a lesson with spaces goes in quotes)" ;;
    esac
    shift
  done
}

valid_text() {
  local text="$1"
  case "${text}" in *"
"*) die "a lesson is one line" ;; esac
  [ "${#text}" -le "${MAX_CHARS}" ] || die "a lesson is at most ${MAX_CHARS} characters; this one is ${#text}. Say less."
}

valid_category() {
  [ -z "$1" ] && return 0
  case " ${CATEGORIES} " in *" $1 "*) return 0 ;; esac
  die "category must be one of: ${CATEGORIES}; got '$1'"
}

is_sha() { printf '%s\n' "$1" | grep -qE '^[0-9a-f]{7,40}$'; }

# A retire_when that holds now: a path that exists, or a commit HEAD reaches.
valid_retire() {
  local v="$1"
  [ -z "${v}" ] && return 0
  [ "${#v}" -le 160 ] || die "retire_when is at most 160 characters"
  case "${v}" in *";"*|*"["*|*"]"*|*"
"*) die "retire_when may not hold ; [ ] or a line break" ;; esac
  if is_sha "${v}"; then
    git -C "${ROOT}" merge-base --is-ancestor "${v}" HEAD >/dev/null 2>&1 \
      || die "retire_when ${v}: no commit reachable from HEAD; a lesson about it would retire at once"
    return 0
  fi
  case "/${v}/" in /\/*|*/../*|/~*) die "retire_when is a path inside the project, relative to its root: got '${v}'" ;; esac
  [ -e "${ROOT}/${v}" ] || die "retire_when ${v}: no such path; a lesson about it would retire at once"
}

# The evidence, checked on disk, comma-joined in EV_CLEAN.
check_evidence() {
  local tok found=0
  EV_CLEAN=""
  for tok in $(printf '%s' "$1" | tr ',' ' '); do
    case "${tok}" in
      sig-*)
        [ -f "${ROOT}/.factory/failures/${tok}.txt" ] || die "evidence ${tok}: no .factory/failures/${tok}.txt"
        ;;
      *)
        ls "${ROOT}"/tasks/*/"${tok}".md >/dev/null 2>&1 || die "evidence ${tok}: no task file tasks/*/${tok}.md"
        ;;
    esac
    found=$((found + 1))
    EV_CLEAN="${EV_CLEAN:+${EV_CLEAN}, }${tok}"
  done
  [ "${found}" -gt 0 ] || die "a lesson needs evidence: at least one task id or sig-<hash>"
}

# The parts of a lesson line.
line_text() { printf '%s\n' "$1" | sed 's/^- \(.*\) \[evidence: .*$/\1/'; }
line_field() { printf '%s\n' "$1" | sed -n "s/.*[[;] *$2: \\([^];]*\\).*/\\1/p" | sed 's/ *$//'; }

format_line() { # text evidence category retire
  printf -- '- %s [evidence: %s%s%s; added: %s]' "$1" "$2" "${3:+; category: $3}" "${4:+; retire_when: $4}" \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

read -r -d '' OVERLAP_AWK <<'AWK'
function clear(a,   k) { for (k in a) delete a[k] }
function words(s, set,   n, i, a, t, c) {
  clear(set); c = 0
  s = tolower(s); gsub(/[^a-z0-9]+/, " ", s)
  n = split(s, a, " ")
  for (i = 1; i <= n; i++) {
    t = a[i]
    if (t == "" || (t in STOP) || (length(t) < 2 && t !~ /^[0-9]+$/)) continue
    if (!(t in set)) { set[t] = 1; c++ }
  }
  return c
}
function paths(s, retire, set,   n, i, a, t) {
  clear(set)
  n = split(s, a, " ")
  for (i = 1; i <= n; i++) {
    t = a[i]
    gsub(/^[`"'(<[]+/, "", t); gsub(/[]`"')>.,;:!?]+$/, "", t)
    if (t !~ /[A-Za-z0-9]/) continue
    if (t ~ /\// || t ~ /^[A-Za-z0-9_.-]*[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]*$/) {
      t = tolower(t)
      if (t != "and/or" && t != "e.g" && t != "i.e") set[t] = 1
    }
  }
  if (retire != "" && retire !~ /^[0-9a-f]+$/) set[tolower(retire)] = 1
}
function cmd(s,   i, j, rest, n, a) {
  i = index(s, "`"); if (!i) return ""
  rest = substr(s, i + 1); j = index(rest, "`"); if (j < 2) return ""
  n = split(tolower(substr(rest, 1, j - 1)), a, " ")
  if (n == 0) return ""
  return n >= 2 ? a[1] " " a[2] : a[1]
}
function field(br, name,   p) {
  if (!match(br, "[[;] *" name ": [^];]*")) return ""
  p = substr(br, RSTART, RLENGTH); sub(/^[[;] *[a-z_]+: /, "", p); sub(/ +$/, "", p)
  return p
}
BEGIN {
  ns = split("the and for with that this from into when then than are was were has have not but its use run all any each only also must should can will before after unless until while what which who you your our out off per via", sw, " ")
  for (i = 1; i <= ns; i++) STOP[sw[i]] = 1
  nt = ENVIRON["NEW_TEXT"]; ncat = ENVIRON["NEW_CAT"]; nret = ENVIRON["NEW_RETIRE"]; skip = ENVIRON["SKIP"] + 0
  nw = words(nt, NW); paths(nt, nret, NP); nc = cmd(nt)
}
/^- / {
  k++
  if (k == skip) next
  line = $0
  i = index(line, " [evidence: ")
  text = i ? substr(line, 3, i - 3) : substr(line, 3)
  br = i ? substr(line, i + 1) : ""
  cat = field(br, "category"); ret = field(br, "retire_when")
  ow = words(text, OW); paths(text, ret, OP); oc = cmd(text)
  score = 1; why = "same module"
  if (ncat != "" && cat == ncat) { score++; why = why ", same category " cat }
  for (p in NP) if (p in OP) { score++; why = why ", same path " p; break }
  if (nc != "" && nc == oc) { score++; why = why ", same command " nc }
  inter = 0; for (w in NW) if (w in OW) inter++
  uni = nw + ow - inter
  j = uni ? inter / uni : 0
  if (j >= 0.5) { score++; why = why sprintf(", %d%% the same words", int(j * 100 + 0.5)) }
  if (score >= 3 || j >= 0.8) { printf "%d\t%s\t%s\n", k, why, text; exit }
}
AWK

# Refuses a lesson that overlaps another of the file; SKIP is the number of
# the lesson being updated, 0 for a new one.
check_overlap() { # file module text category retire skip evidence
  local hit n why old
  hit="$(NEW_TEXT="$3" NEW_CAT="$4" NEW_RETIRE="$5" SKIP="$6" awk "${OVERLAP_AWK}" "$1")"
  [ -n "${hit}" ] || return 0
  n="$(printf '%s' "${hit}" | cut -f1)"; why="$(printf '%s' "${hit}" | cut -f2)"; old="$(printf '%s' "${hit}" | cut -f3-)"
  die "that lesson overlaps lesson ${n} of $2.md (${why}): ${old}. Change that one instead: factory-lesson update $2 ${n} $7 \"<the lesson, reworded>\""
}

cmd_add() {
  parse_args "$@"
  local module="${P1}" evidence="${P2}" text="${P3}"
  [ -z "${P4}" ] || die "too many arguments (a lesson with spaces goes in quotes)"
  [ -n "${text}" ] || die "usage: add <module> <evidence> <lesson> [--category C] [--retire-when X]"
  valid_module "${module}"
  valid_text "${text}"
  valid_category "${OPT_CATEGORY}"
  check_evidence "${evidence}"
  valid_retire "${OPT_RETIRE}"

  mkdir -p "${L}"
  local file="${L}/${module}.md" count=0
  if [ -f "${file}" ]; then
    count="$(grep -c '^- ' "${file}")"
    grep -qF -- "- ${text} [" "${file}" && die "that lesson is already in ${module}.md"
    check_overlap "${file}" "${module}" "${text}" "${OPT_CATEGORY}" "${OPT_RETIRE}" 0 "${evidence}"
  else
    printf '# Lessons: %s\n\n' "${module}" > "${file}"
  fi
  [ "${count}" -lt "${MAX_LESSONS}" ] || die "${module}.md already holds ${MAX_LESSONS} lessons. Retire one first: factory-lesson.sh list ${module}, then remove ${module} <number>."

  # A full timestamp, not a date: /factory-retro counts the red runs of each
  # evidence signature that happened after it, to see whether the lesson worked.
  format_line "${text}" "${EV_CLEAN}" "${OPT_CATEGORY}" "${OPT_RETIRE}" >> "${file}"
  printf '\n' >> "${file}"
  echo "LESSON added to .factory/lessons/${module}.md ($((count + 1))/${MAX_LESSONS})"
}

# Rewords lesson <n> in place: the evidence is the old ids and the new ones,
# category and retire_when are kept unless given again, and added is now (the
# retro measures a reworded lesson from the day it changed).
cmd_update() {
  parse_args "$@"
  local module="${P1}" n="${P2}" evidence="${P3}" text="${P4}"
  [ -n "${text}" ] || die "usage: update <module> <number> <evidence> <lesson> [--category C] [--retire-when X]"
  valid_module "${module}"
  case "${n}" in ''|*[!0-9]*) die "usage: update <module> <number> <evidence> <lesson>" ;; esac
  local file="${L}/${module}.md"
  [ -f "${file}" ] || die "no lessons for ${module}"
  local total
  total="$(grep -c '^- ' "${file}")"
  [ "${n}" -ge 1 ] && [ "${n}" -le "${total}" ] || die "${module}.md has lessons 1..${total}"
  valid_text "${text}"
  valid_category "${OPT_CATEGORY}"
  check_evidence "${evidence}"
  valid_retire "${OPT_RETIRE}"

  local old cat ret ev tok
  old="$(grep '^- ' "${file}" | sed -n "${n}p")"
  cat="${OPT_CATEGORY:-$(line_field "${old}" category)}"
  ret="${OPT_RETIRE:-$(line_field "${old}" retire_when)}"
  ev="$(line_field "${old}" evidence)"
  for tok in $(printf '%s' "${EV_CLEAN}" | tr ',' ' '); do
    case ", ${ev}, " in *", ${tok}, "*) ;; *) ev="${ev:+${ev}, }${tok}" ;; esac
  done

  if grep '^- ' "${file}" | awk -v n="${n}" 'NR != n' | grep -qF -- "- ${text} ["; then
    die "that lesson is already in ${module}.md"
  fi
  check_overlap "${file}" "${module}" "${text}" "${cat}" "${ret}" "${n}" "${evidence}"

  local tmp="${file}.tmp.$$"
  NEW_LINE="$(format_line "${text}" "${ev}" "${cat}" "${ret}")" \
    awk -v n="${n}" '/^- / { k++; if (k == n) { print ENVIRON["NEW_LINE"]; next } } { print }' "${file}" > "${tmp}" \
    && mv "${tmp}" "${file}" || { rm -f "${tmp}"; die "could not write ${module}.md"; }
  echo "LESSON updated in .factory/lessons/${module}.md: ${n} was: ${old}"
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

# The lessons whose retire_when is gone: a path that no longer exists, a sha
# HEAD no longer reaches. One RETIRE line each; exit 1 when there is one.
cmd_check() {
  local want="${1:-}" f m k line rw text flagged=0 named=0 git_ok=1
  [ -n "${want}" ] && valid_module "${want}"
  git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || git_ok=0
  if [ -d "${L}" ]; then
    for f in "${L}"/*.md; do
      [ -e "${f}" ] || continue
      m="$(basename "${f}" .md)"
      [ -n "${want}" ] && [ "${m}" != "${want}" ] && continue
      k=0
      while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in "- "*) k=$((k + 1)) ;; *) continue ;; esac
        rw="$(line_field "${line}" retire_when)"
        [ -n "${rw}" ] || continue
        named=$((named + 1))
        text="$(line_text "${line}")"
        if is_sha "${rw}"; then
          [ "${git_ok}" -eq 1 ] || { echo "CHECK SKIPPED ${m} ${k}: sha:${rw} - not a git work tree"; continue; }
          git -C "${ROOT}" merge-base --is-ancestor "${rw}" HEAD >/dev/null 2>&1 && continue
          echo "RETIRE ${m} ${k} sha:${rw} is gone: ${text}"
        else
          [ -e "${ROOT}/${rw}" ] && continue
          echo "RETIRE ${m} ${k} path:${rw} is gone: ${text}"
        fi
        flagged=$((flagged + 1))
      done < "${f}"
    done
  fi
  if [ "${flagged}" -eq 0 ]; then
    echo "CHECK OK: ${named} lesson(s) name a retire_when, none is gone"
    return 0
  fi
  echo "CHECK: ${flagged} lesson(s) to retire (factory-lesson remove <module> <number>)"
  return 1
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  update) shift; cmd_update "$@" ;;
  list)   shift; cmd_list "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  check)  shift; cmd_check "$@" ;;
  *)
    echo "usage: factory-lesson.sh add <module> <evidence> <lesson> [--category C] [--retire-when X] | update <module> <number> <evidence> <lesson> [...] | list [module] | remove <module> <number> | check [module]" >&2
    exit 2
    ;;
esac
