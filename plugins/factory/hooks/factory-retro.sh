#!/usr/bin/env bash
# Factory retrospective - evidence collector. NOT a hook; /factory-retro runs it.
#
# Usage: factory-retro [project-dir]
#
# Prints a digest of everything the factory recorded about its own failures.
# Deliberately does no interpretation: clustering failures into mechanisms and
# proposing harness changes is judgement, and judgement belongs to the model
# reading this, with a human approving the result. The split matters - a
# collector that also guessed would put its guesses in the evidence.
set -uo pipefail

ROOT="${1:-$PWD}"
ROOT="$(cd "${ROOT}" 2>/dev/null && pwd)" || { echo "no such directory: ${1:-$PWD}" >&2; exit 2; }
F="${ROOT}/.factory"

if [ ! -d "${F}" ]; then
  echo "Not a factory project: ${ROOT}/.factory does not exist." >&2
  exit 2
fi

section() { printf '\n## %s\n\n' "$1"; }

printf '# Factory retrospective evidence\n\nproject: %s\ncollected: %s\n' \
  "${ROOT}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- board ----------------------------------------------------------------
section "Board"
for col in backlog in-progress blocked done; do
  n=$(ls "${ROOT}/tasks/${col}" 2>/dev/null | grep -c '\.md$')
  printf '%-12s %s\n' "${col}" "${n}"
done

# --- retries --------------------------------------------------------------
section "Retries recorded in task frontmatter"
retries="$(grep -h '^retries:' "${ROOT}"/tasks/*/*.md 2>/dev/null | sed 's/retries:[[:space:]]*//' | sort -n)"
if [ -n "${retries}" ]; then
  printf '%s\n' "${retries}" | uniq -c | awk '{printf "retries=%-3s %s task(s)\n", $2, $1}'
  total=$(printf '%s\n' "${retries}" | grep -c .)
  nonzero=$(printf '%s\n' "${retries}" | grep -vc '^0$')
  [ "${total}" -gt 0 ] && printf '\n%s of %s tasks needed at least one retry (%s%%)\n' \
    "${nonzero}" "${total}" "$(( nonzero * 100 / total ))"
else
  echo "(no task files with a retries field)"
fi

# --- failure signatures ---------------------------------------------------
section "Failure signatures"
pairs=""
for f in "${F}"/failures/*.log "${F}"/failures/resolved/*.log; do
  [ -f "${f}" ] || continue
  id="$(basename "${f}" .log)"
  pairs="${pairs}$(awk -v id="${id}" '{print $2 " " id}' "${f}")
"
done
pairs="$(printf '%s' "${pairs}" | grep -c . >/dev/null 2>&1 && printf '%s' "${pairs}" || printf '')"

if [ -z "$(printf '%s' "${pairs}" | tr -d '[:space:]')" ]; then
  echo "(no red gate runs recorded yet - the gate started fingerprinting failures"
  echo " when the no-progress check was added, so an old project starts empty here)"
else
  # Per signature: how many red runs, and across how many distinct tasks. A
  # signature spanning several tasks is the interesting one: that is the harness
  # failing the same way repeatedly, not one task being hard.
  printf '%s\n' "${pairs}" | grep . | sort -u > /tmp/factory-retro-uniq.$$
  printf '%s\n' "${pairs}" | grep . | awk '{print $1}' | sort | uniq -c | sort -rn \
  | while read -r runs sha; do
      tasks="$(awk -v s="${sha}" '$1==s {print $2}' /tmp/factory-retro-uniq.$$ | sort -u | tr '\n' ' ')"
      ntasks="$(printf '%s' "${tasks}" | wc -w | tr -d ' ')"
      printf -- '--- %s | %s red run(s) | %s task(s): %s\n' "${sha}" "${runs}" "${ntasks}" "${tasks}"
      if [ -f "${F}/failures/sig-${sha}.txt" ]; then
        head -4 "${F}/failures/sig-${sha}.txt" | sed 's/^/      /'
        extra=$(( $(wc -l < "${F}/failures/sig-${sha}.txt") - 4 ))
        [ "${extra}" -gt 0 ] && printf '      ... %s more line(s)\n' "${extra}"
      else
        echo "      (signature text no longer on disk)"
      fi
    done
  rm -f /tmp/factory-retro-uniq.$$
fi

# --- which stage fails ----------------------------------------------------
section "Which gate stage failed"
if ls "${F}"/failures/sig-*.txt >/dev/null 2>&1; then
  grep -ho 'GATE [a-z]*: FAIL' "${F}"/failures/sig-*.txt 2>/dev/null \
    | sort | uniq -c | sort -rn | sed 's/^/  /'
  grep -l 'self-certifying' "${F}"/failures/sig-*.txt 2>/dev/null | wc -l \
    | awk '{ if ($1 > 0) printf "  %s signature(s) were a rejected acceptance criterion\n", $1 }'
  grep -l 'census: FAIL' "${F}"/failures/sig-*.txt 2>/dev/null | wc -l \
    | awk '{ if ($1 > 0) printf "  %s signature(s) were a test census violation\n", $1 }'
  grep -l 'reported 0 test' "${F}"/failures/sig-*.txt 2>/dev/null | wc -l \
    | awk '{ if ($1 > 0) printf "  %s signature(s) were a zero-test suite\n", $1 }'
else
  echo "  (no signatures on disk)"
fi

# --- stalled --------------------------------------------------------------
section "Tasks the gate stopped for no progress"
if ls "${F}"/no-progress/* >/dev/null 2>&1; then
  for m in "${F}"/no-progress/*; do
    printf -- '- %s: %s\n' "$(basename "${m}")" "$(tr '\n' ' ' < "${m}")"
  done
else
  echo "(none currently flagged)"
fi

# --- blocked --------------------------------------------------------------
section "Blocked tasks and why"
if ls "${ROOT}"/tasks/blocked/*.md >/dev/null 2>&1; then
  for t in "${ROOT}"/tasks/blocked/*.md; do
    id="$(basename "${t}" .md)"
    human="$(sed -n 's/^needs_human:[[:space:]]*//p' "${t}" | head -1)"
    reason="$(sed -n '/^## Blocked reason/,$p' "${t}" | sed -n '2,4p' | tr '\n' ' ' | sed 's/  */ /g')"
    [ -z "${reason}" ] && reason="(no ## Blocked reason section)"
    printf -- '- %s (needs_human=%s): %s\n' "${id}" "${human:-?}" "${reason}"
  done
else
  echo "(none)"
fi

# --- what fixed the tasks that went green -------------------------------------
# The raw material for lessons: a task that failed, then passed, and a line from
# the implementer saying what made the difference.
section "Red tasks that went green, and what fixed them"
if ls "${F}"/failures/resolved/*.log >/dev/null 2>&1; then
  for lf in "${F}"/failures/resolved/*.log; do
    id="$(basename "${lf}" .log)"
    runs="$(grep -c . "${lf}")"
    tf="$(ls "${ROOT}"/tasks/*/"${id}".md 2>/dev/null | head -1)"
    module=""; fixed=""
    if [ -n "${tf}" ]; then
      module="$(sed -n 's/^module:[[:space:]]*//p' "${tf}" | head -1)"
      fixed="$(grep -h '^[[:space:]]*Resolved by:' "${tf}" | tail -1 | sed 's/^[[:space:]]*Resolved by:[[:space:]]*//')"
    fi
    sigs="$(awk '{print $2}' "${lf}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    printf -- '- %s (module %s): %s red run(s), signature(s) %s\n    resolved by: %s\n' \
      "${id}" "${module:-?}" "${runs}" "${sigs}" "${fixed:-(not recorded in the task file)}"
  done
else
  echo "(no task has gone from red to green yet)"
fi

# --- red runs that name somebody else's files ----------------------------------
# Several tasks share one working tree. A red run whose error names a file the
# task never listed is either the task breaking a file it did not own up to, or
# the gate tripping over another task's half-written work. "also listed by"
# separates the two: a file that belongs to another task points at the second,
# which is what gate_isolation exists for.
section "Red runs naming files outside the task's own list"
files_touched() {
  awk '/^##[[:space:]]+Files touched[[:space:]]*$/ {inside=1; next}
       inside && /^#/ {exit}
       inside && /^[[:space:]]*[-*][[:space:]]+/ {
         sub(/^[[:space:]]*[-*][[:space:]]+/, ""); gsub(/`/, "")
         split($0, w, /[[:space:]]+/); if (w[1] != "") print w[1]
       }' "$1"
}
# "<path> <task>" for every listed file, digits normalised the way the gate
# normalises signatures so the two compare.
index="$(for tf in "${ROOT}"/tasks/*/*.md; do
    [ -e "${tf}" ] || continue
    tid="$(basename "${tf}" .md)"
    files_touched "${tf}" | sed -E 's#^\./##; s/[0-9]+/<n>/g' | awk -v t="${tid}" '{print $1, t}'
  done)"
hints="$(for lf in "${F}"/failures/*.log "${F}"/failures/resolved/*.log; do
    [ -f "${lf}" ] || continue
    id="$(basename "${lf}" .log)"
    printf '%s\n' "${index}" | awk -v t="${id}" '$2==t' | grep -q . || continue  # no list, no comparison
    for sha in $(awk '{print $2}' "${lf}" | sort -u); do
      sf="${F}/failures/sig-${sha}.txt"
      [ -f "${sf}" ] || continue
      grep -oE '[A-Za-z0-9_.<>-]+(/[A-Za-z0-9_.<>-]+)+\.[A-Za-z]{1,6}' "${sf}" | sed 's#^<root>/##' | sort -u \
      | while IFS= read -r p; do
          printf '%s\n' "${index}" | awk -v p="${p}" -v t="${id}" '$1==p && $2==t' | grep -q . && continue
          others="$(printf '%s\n' "${index}" | awk -v p="${p}" -v t="${id}" '$1==p && $2!=t {print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
          if [ -n "${others}" ]; then label="also listed by: ${others}"; else label="listed by no task"; fi
          printf -- '- %s %s: %s (%s)\n' "${id}" "${sha}" "${p}" "${label}"
        done
    done
  done | head -30)"
if [ -n "${hints}" ]; then
  printf '%s\n' "${hints}"
else
  echo "(none - every file named in a red run belongs to the task that ran it)"
fi
echo "gate_isolation in config: $(jq -r '.gate_isolation // false' "${F}/config.json" 2>/dev/null)"

# --- lessons ----------------------------------------------------------------------
# A lesson that was supposed to stop a signature and did not is not a lesson.
section "Lessons in force"
if ls "${F}"/lessons/*.md >/dev/null 2>&1; then
  for lf in "${F}"/lessons/*.md; do
    echo "### $(basename "${lf}" .md) ($(grep -c '^- ' "${lf}")/15)"
    grep '^- ' "${lf}" | while IFS= read -r line; do
      echo "${line}"
      added="$(printf '%s' "${line}" | sed -n 's/.*added: \([0-9TZ:-]*\)\].*/\1/p')"
      for sig in $(printf '%s' "${line}" | grep -oE 'sig-[0-9a-f]+' | sed 's/^sig-//'); do
        again="$(cat "${F}"/failures/*.log "${F}"/failures/resolved/*.log 2>/dev/null \
          | awk -v s="${sig}" -v d="${added}" '$2==s && $1 > d' | grep -c .)"
        echo "    sig-${sig}: ${again} red run(s) since this lesson was added"
      done
    done
  done
else
  echo "(none yet)"
fi

# --- decisions ------------------------------------------------------------
section "Decisions log"
if [ -s "${ROOT}/decisions.md" ]; then
  lines=$(grep -c '^- ' "${ROOT}/decisions.md" 2>/dev/null || echo 0)
  bytes=$(wc -c < "${ROOT}/decisions.md" | tr -d ' ')
  printf '%s decision line(s), %s bytes' "${lines}" "${bytes}"
  [ "${lines}" -gt 0 ] && printf ' (%s bytes per decision)' "$(( bytes / lines ))"
  printf '\n'
  echo "Nothing reads more than the last 5. Anything older is written, not remembered."
else
  echo "(decisions.md missing or empty)"
fi

# --- what the run cost ------------------------------------------------------
# Money and wall-clock come from the status line's samples; agent time from the
# SubagentStart/Stop pairs. Neither is in any hook payload, so this is the only
# record of it.
section "Cost and agent time"
LOG="${F}/events.jsonl"
if [ -f "${LOG}" ]; then
  grep '"kind":"cost"' "${LOG}" 2>/dev/null | jq -r '"\(.session) \(.usd) \(.session_min) \(.lines_added) \(.lines_removed)"' 2>/dev/null \
    | awk '{ if (!(($1) in first)) { first[$1]=$2; fmin[$1]=$3 }
             last[$1]=$2; lmin[$1]=$3; la[$1]=$4; lr[$1]=$5 }
           END { for (s in last) printf "session %s: $%.2f, %d min, +%d/-%d lines\n", substr(s,1,8), last[s]-first[s], lmin[s]-fmin[s], la[s], lr[s] }'
  echo
  grep '"kind":"agent_stop"' "${LOG}" 2>/dev/null | jq -r 'select(.seconds>0) | "\(.agent) \(.seconds)"' 2>/dev/null \
    | awk '{ n[$1]++; s[$1]+=$2 } END { for (a in n) printf "%-22s %3d run(s), %4d min total, %3d min median-ish avg\n", a, n[a], s[a]/60, (s[a]/n[a])/60 }' | sort
  echo
  grep '"kind":"gate"' "${LOG}" 2>/dev/null | jq -r '.verdict' 2>/dev/null | sort | uniq -c | sed 's/^/  gate /'
else
  echo "(no event log yet - this project ran before the telemetry hooks existed)"
fi

# --- config ---------------------------------------------------------------
section "Config in force"
[ -f "${F}/config.json" ] && jq -S . "${F}/config.json" 2>/dev/null | sed 's/^/  /'

section "Previous retrospectives"
if ls "${F}"/retro/*.md >/dev/null 2>&1; then
  for r in "${F}"/retro/*.md; do
    printf -- '- %s: %s\n' "$(basename "${r}")" "$(sed -n 's/^## Proposal/&/p' "${r}" | wc -l | tr -d ' ') proposal(s)"
  done
  echo
  echo "Read the most recent one before proposing anything: a proposal that was"
  echo "already made and rejected must not be made again as if it were new, and"
  echo "one that was applied needs its effect checked, not its text repeated."
else
  echo "(none - this is the first)"
fi
