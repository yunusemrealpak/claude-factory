#!/usr/bin/env bash
# Factory change archive. NOT a hook: /factory-init opens a change when the
# developer approves its tasks; the Stop hook syncs it when a run finishes, and
# /factory-status syncs it on demand.
#
# Usage (from the project root):
#   factory-change open <change-id> <slug> <type> <goal-file | -> [<acceptance command>]
#   factory-change sync [<change-id>]
#   factory-change list
#   factory-change sig <change-id>
#
# A change is one piece of work the developer handed to the factory - a feature,
# a bugfix, a migration - together with the tasks it was split into. Task ids
# carry it: C2-01 belongs to C2, and the ids of the very first run (P0-01,
# T-014, ...) belong to C1.
#
#   .factory/changes/<id>-<slug>/goal.md     written once, at approval
#   .factory/changes/<id>-<slug>/summary.md  rewritten by every sync
#   .factory/changes/<id>-<slug>/closed      written once, when the last task is done
#   .factory/changes/<id>-<slug>/acceptance   the last factory-accept.sh verdict
#
# A change may carry its own acceptance command - one command that proves the
# whole thing works, not task by task. Every task green is not the same claim:
# tasks pass in isolation and the feature they add up to can still be broken.
# When a change has one, it does not close until factory-accept.sh has run it
# green against the task set it has now.
#
# Closing a change also points a local ref at its last commit:
#   refs/factory/<id>-<slug>
# A ref under refs/factory/ is neither a branch nor a tag. "git push", "--tags"
# and "--follow-tags" all leave it behind; only "--mirror" would send it. It
# stays on this machine, which is the point.
#
# Commits are found by their trailers (Factory-Task / Factory-Change, written by
# factory-commit.sh), not by a commit range, so a change whose commits
# interleave with other work is still listed exactly.
set -uo pipefail

ROOT="$PWD"
T="${ROOT}/tasks"
F="${ROOT}/.factory"
CH="${F}/changes"
COLUMNS="proposed backlog in-progress blocked done"
TYPES="feature bugfix refactor migration chore"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
die() { echo "factory-change: $*" >&2; exit 1; }
in_git() { git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

change_of() {  # task id -> change id
  case "$1" in
    C[0-9]*-*) printf '%s\n' "${1%%-*}" ;;
    *)         printf 'C1\n' ;;
  esac
}

fm_field() {  # <file> <key>: a frontmatter value
  [ -f "$1" ] || return 0
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

tasks_of() {  # <change-id>: one "<id> <column>" line per task, sorted by id
  local want="$1" col f id
  for col in ${COLUMNS}; do
    [ -d "${T}/${col}" ] || continue
    for f in "${T}/${col}"/*.md; do
      [ -e "${f}" ] || continue
      id="$(basename "${f}" .md)"
      [ "$(change_of "${id}")" = "${want}" ] && printf '%s %s\n' "${id}" "${col}"
    done
  done | sort
}

# A fingerprint of the change's task set. An acceptance verdict is only about
# the tasks that existed when it ran: add a task to the change afterwards and
# the verdict says nothing about it, so the signature has to match for the
# verdict to count.
tasks_sig() {  # <change-id>
  tasks_of "$1" | awk '{print $1}' | sort | shasum | awk '{print $1}'
}

change_dir() {  # <change-id> -> its directory, or nothing
  local d
  for d in "${CH}/$1"-*; do
    [ -d "${d}" ] && { printf '%s\n' "${d}"; return 0; }
  done
  return 0
}

# Every commit that carries a Factory-Task trailer: "<short-sha> <task> <change>",
# newest first. One git call for the whole sync.
factory_commits() {
  in_git || return 0
  git -C "${ROOT}" log --all --grep='^Factory-Change: ' \
    --format='%h%x09%(trailers:key=Factory-Task,valueonly,separator=%x2C)%x09%(trailers:key=Factory-Change,valueonly,separator=%x2C)' \
    2>/dev/null | awk -F '\t' 'NF >= 3 && $2 != "" {print $1, $2, $3}'
}

# --- open ---------------------------------------------------------------------
cmd_open() {
  local id="${1:-}" slug="${2:-}" type="${3:-}" src="${4:-}" accept="${5:-}"
  [ -n "${src}" ] || die "usage: open <change-id> <slug> <type> <goal-file | -> [<acceptance command>]"

  printf '%s\n' "${id}" | grep -qE '^C[0-9]+$' || die "change id must look like C2, got '${id}'"
  printf '%s\n' "${slug}" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' \
    || die "slug must be lowercase ascii words joined by hyphens, got '${slug}'"
  [ "${#slug}" -le 40 ] || die "slug is longer than 40 characters"
  case " ${TYPES} " in *" ${type} "*) ;; *) die "type must be one of: ${TYPES}" ;; esac
  [ -z "$(change_dir "${id}")" ] || die "${id} is already open at $(change_dir "${id}"); ids are never reused"

  # The change-level acceptance command, if the developer approved one.
  if [ -n "${accept}" ]; then
    case "${accept}" in
      *"<"*) die "the acceptance command still holds a placeholder: ${accept}" ;;
    esac
    printf '%s' "${accept}" | grep -q '[[:cntrl:]]' && die "the acceptance command must be a single line"
  fi

  local tasks
  tasks="$(tasks_of "${id}" | awk '{print $1}')"
  [ -n "${tasks}" ] || die "no task belongs to ${id}. Write and approve the tasks first; the change is opened on approval."

  local goal source_line
  if [ "${src}" = "-" ]; then
    goal="$(cat)"
    source_line="Source: the /factory-init argument"
  elif [ -f "${src}" ]; then
    goal="$(cat "${src}")"
    source_line="Source: ${src} (copied at approval; the file may have changed since)"
  else
    die "goal source '${src}' is neither a file nor '-'"
  fi
  [ -n "${goal}" ] || die "the goal is empty"


  local base="none" branch="none"
  if in_git; then
    base="$(git -C "${ROOT}" rev-parse --verify -q HEAD 2>/dev/null || echo none)"
    branch="$(git -C "${ROOT}" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"
    git check-ref-format "refs/factory/${id}-${slug}" || die "refs/factory/${id}-${slug} is not a valid ref name"
  fi

  # Changes whose tasks this one depends on. Recorded so the reader can see
  # that a bugfix builds on an earlier feature without opening every task.
  local extends
  extends="$(for tid in ${tasks}; do
      f="$(ls "${T}"/*/"${tid}".md 2>/dev/null | head -1)"
      fm_field "${f}" depends_on | tr -d '[]' | tr ',' '\n' | tr -d ' '
    done | while read -r dep; do
      [ -n "${dep}" ] || continue
      c="$(change_of "${dep}")"
      [ "${c}" = "${id}" ] || printf '%s\n' "${c}"
    done | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"

  local dir="${CH}/${id}-${slug}"
  mkdir -p "${dir}"
  {
    echo "---"
    echo "change: ${id}"
    echo "slug: ${slug}"
    echo "type: ${type}"
    echo "created: $(now)"
    echo "branch: ${branch}"
    echo "base_commit: ${base}"
    echo "tasks: [$(printf '%s\n' "${tasks}" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')]"
    [ -n "${accept}" ] && echo "acceptance: ${accept}"
    echo "extends: [${extends}]"
    echo "---"
    echo
    echo "# ${id} · ${slug}"
    echo
    echo "## Goal"
    echo
    echo "${source_line}"
    echo
    printf '%s\n' "${goal}"
  } > "${dir}/goal.md"

  sync_one "${dir}" >/dev/null
  echo "OPENED ${id}-${slug}: $(printf '%s\n' "${tasks}" | grep -c .) task(s), base ${base:0:12}, summary at .factory/changes/${id}-${slug}/summary.md"
  [ -n "${accept}" ] && echo "It closes only after \"${accept}\" runs green: factory-accept ${id}"
}

# --- sync ---------------------------------------------------------------------
# Rewrites one summary.md, closes the change if every task is done, and prints
# one status line:
#   <STATUS> <id>-<slug> done=<n>/<total> ref=<ref|->
# STATUS is open | blocked | closed, or CLOSED-NOW on the sync that closed it.
sync_one() {
  local dir="$1" name id slug goal
  name="$(basename "${dir}")"
  goal="${dir}/goal.md"
  id="$(fm_field "${goal}" change)"; [ -n "${id}" ] || id="${name%%-*}"
  slug="$(fm_field "${goal}" slug)"; [ -n "${slug}" ] || slug="${name#*-}"

  local rows total=0 done_n=0 active=0 blocked_n=0
  rows="$(tasks_of "${id}")"
  total="$(printf '%s\n' "${rows}" | grep -c .)"
  done_n="$(printf '%s\n' "${rows}" | awk '$2=="done"' | grep -c .)"
  blocked_n="$(printf '%s\n' "${rows}" | awk '$2=="blocked"' | grep -c .)"
  active="$(printf '%s\n' "${rows}" | awk '$2=="proposed" || $2=="backlog" || $2=="in-progress"' | grep -c .)"

  # The change-level acceptance command, and the last verdict recorded for the
  # task set the change has right now.
  local accept accept_state="none" acc_file="${dir}/acceptance"
  accept="$(fm_field "${goal}" acceptance)"
  if [ -n "${accept}" ]; then
    accept_state="never-run"
    if [ -f "${acc_file}" ]; then
      local seen_sig seen_verdict
      seen_sig="$(sed -n 's/^sig=//p' "${acc_file}" | head -1)"
      seen_verdict="$(sed -n 's/^verdict=//p' "${acc_file}" | head -1)"
      if [ "${seen_sig}" = "$(tasks_sig "${id}")" ]; then
        accept_state="${seen_verdict:-never-run}"
      else
        accept_state="stale"
      fi
    fi
  fi

  local status
  if [ "${total}" -gt 0 ] && [ "${done_n}" -eq "${total}" ]; then
    if [ "${accept_state}" = "none" ] || [ "${accept_state}" = "green" ]; then
      status="closed"
    else
      # Every task is done and the change still has something to prove.
      status="unverified"
    fi
  elif [ "${active}" -gt 0 ] || [ "${total}" -eq 0 ]; then
    status="open"
  else
    status="blocked"
  fi

  local commits last_commit="" ref="refs/factory/${id}-${slug}" ref_sha="" note=""
  commits="$(factory_commits)"
  last_commit="$(printf '%s\n' "${commits}" | awk -v c="${id}" '$3==c {print $1; exit}')"

  if [ "${status}" = "closed" ]; then
    if [ ! -f "${dir}/closed" ]; then
      { echo "closed_at=$(now)"; echo "last_commit=${last_commit:-none}"; } > "${dir}/closed"
      note="CLOSED-NOW"
    fi
    if [ -n "${last_commit}" ] && in_git; then
      cur="$(git -C "${ROOT}" rev-parse --verify -q --short "${ref}" 2>/dev/null)"
      full="$(git -C "${ROOT}" rev-parse --verify -q "${last_commit}^{commit}" 2>/dev/null)"
      if [ -n "${full}" ] && [ "${cur}" != "$(git -C "${ROOT}" rev-parse --short "${full}")" ]; then
        git -C "${ROOT}" update-ref "${ref}" "${full}" 2>/dev/null
      fi
    fi
  fi
  in_git && ref_sha="$(git -C "${ROOT}" rev-parse --verify -q --short "${ref}" 2>/dev/null)"

  local type created base branch closed_at
  type="$(fm_field "${goal}" type)"
  created="$(fm_field "${goal}" created)"
  base="$(fm_field "${goal}" base_commit)"
  branch="$(fm_field "${goal}" branch)"
  closed_at="$(sed -n 's/^closed_at=//p' "${dir}/closed" 2>/dev/null)"

  {
    echo "# ${id} · ${slug}"
    echo
    echo "<!-- Generated by factory-change.sh sync. Rewritten on every sync: do not edit. The request itself is in goal.md. -->"
    echo
    echo "| | |"
    echo "| --- | --- |"
    echo "| type | ${type:-?} |"
    echo "| status | **${status}** - ${done_n}/${total} done, ${blocked_n} blocked |"
    if [ -n "${accept}" ]; then
      case "${accept_state}" in
        green)     echo "| acceptance | \`${accept}\` - green $(sed -n 's/^at=//p' "${acc_file}" | head -1) |" ;;
        red)       echo "| acceptance | \`${accept}\` - **RED** $(sed -n 's/^at=//p' "${acc_file}" | head -1), output in acceptance.log |" ;;
        stale)     echo "| acceptance | \`${accept}\` - the last run was against a different task set; run it again |" ;;
        *)         echo "| acceptance | \`${accept}\` - never run |" ;;
      esac
    fi
    echo "| created | ${created:-?} |"
    [ -n "${closed_at}" ] && echo "| closed | ${closed_at} |"
    echo "| branch at approval | ${branch:-?} |"
    echo "| base commit | ${base:0:12} |"
    if [ -n "${ref_sha}" ]; then
      echo "| local ref | \`${ref}\` -> ${ref_sha} |"
    elif [ "${status}" = "closed" ]; then
      echo "| local ref | none - no commit carries \`Factory-Change: ${id}\`, so this change's work is not committed |"
    else
      echo "| local ref | set when the change closes |"
    fi
    echo
    echo "## Tasks"
    echo
    echo "| id | title | column | red gate runs | tests at green | commit |"
    echo "| --- | --- | --- | --- | --- | --- |"
    printf '%s\n' "${rows}" | while read -r tid col; do
      [ -n "${tid}" ] || continue
      tf="${T}/${col}/${tid}.md"
      title="$(fm_field "${tf}" title | tr '|' '/')"
      reds=0
      for lf in "${F}/failures/${tid}.log" "${F}/failures/resolved/${tid}.log"; do
        [ -f "${lf}" ] && reds=$((reds + $(grep -c . "${lf}")))
      done
      tests="$(sed -n 's/^tests=//p' "${F}/verified/${tid}" 2>/dev/null | head -1)"
      sha="$(printf '%s\n' "${commits}" | awk -v t="${tid}" '$2==t {print $1; exit}')"
      if [ -z "${sha}" ]; then
        [ "${col}" = "done" ] && sha="uncommitted" || sha="-"
      fi
      echo "| ${tid} | ${title} | ${col} | ${reds} | ${tests:--} | ${sha} |"
    done
    echo
    echo "## Decisions"
    echo
    dec="$(printf '%s\n' "${rows}" | while read -r tid col; do
        [ -n "${tid}" ] || continue
        awk -v p="- ${tid}:" 'index($0, p) == 1' "${ROOT}/decisions.md" 2>/dev/null
      done)"
    if [ -n "${dec}" ]; then printf '%s\n' "${dec}"; else echo "(none recorded yet)"; fi
    if [ "${blocked_n}" -gt 0 ]; then
      echo
      echo "## Blocked"
      echo
      printf '%s\n' "${rows}" | awk '$2=="blocked" {print $1}' | while read -r tid; do
        reason="$(awk '/^##[[:space:]]+Blocked reason/ {inside=1; next}
                       inside && /^##[[:space:]]/ {exit}
                       inside && NF {print; exit}' "${T}/blocked/${tid}.md")"
        [ -f "${F}/no-progress/${tid}" ] && reason="${reason:+${reason} - }stalled: $(sed -n 's/^detail=//p' "${F}/no-progress/${tid}")"
        echo "- ${tid}: ${reason:-no reason written in the task file}"
      done
    fi
    echo
    if [ "${status}" = "unverified" ]; then
      echo
      echo "## Waiting on its acceptance"
      echo
      echo "Every task is done, but this change claims more than the sum of its"
      echo "tasks. It closes when this runs green:"
      echo
      echo "    factory-accept ${id}"
      echo
    fi
    echo "## Getting back to it"
    echo
    echo "- Every commit of this change: \`git log --all --grep='^Factory-Change: ${id}\$'\`"
    echo "- One task: \`git show <commit>\` from the table above; undo one task: \`git revert <commit>\`"
    if [ -n "${ref_sha}" ]; then
      echo "- The tree as this change left it: \`git switch --detach ${ref}\` (back with \`git switch -\`)"
      if [ -n "${base}" ] && [ "${base}" != "none" ]; then
        echo "- Everything since approval: \`git diff ${base:0:12} ${ref}\` - this range also holds any unrelated commits that landed in between; the commit list above is exact"
      fi
    fi
  } > "${dir}/summary.md"

  local shown="${status}"
  [ -n "${note}" ] && shown="${note}"
  echo "${shown} ${id}-${slug} done=${done_n}/${total} ref=${ref_sha:+${ref}}"
}

cmd_sync() {
  local want="${1:-}" d
  [ -d "${CH}" ] || return 0
  if [ -n "${want}" ]; then
    d="$(change_dir "${want}")"
    [ -n "${d}" ] || die "no open change ${want}"
    sync_one "${d}"
    return 0
  fi
  for d in "${CH}"/C*-*; do
    [ -d "${d}" ] && sync_one "${d}"
  done
  return 0
}

# Read-only: the same status lines, nothing written. A change whose tasks are
# all done but that no sync has closed yet - the run ended without the Stop hook
# getting to it - shows as "unsynced": it has no ref and a stale summary until
# someone runs sync.
cmd_list() {
  local d name id slug rows total done_n active status
  [ -d "${CH}" ] || return 0
  for d in "${CH}"/C*-*; do
    [ -d "${d}" ] || continue
    name="$(basename "${d}")"
    id="$(fm_field "${d}/goal.md" change)"; [ -n "${id}" ] || id="${name%%-*}"
    slug="$(fm_field "${d}/goal.md" slug)"; [ -n "${slug}" ] || slug="${name#*-}"
    rows="$(tasks_of "${id}")"
    total="$(printf '%s\n' "${rows}" | grep -c .)"
    done_n="$(printf '%s\n' "${rows}" | awk '$2=="done"' | grep -c .)"
    active="$(printf '%s\n' "${rows}" | awk '$2=="proposed" || $2=="backlog" || $2=="in-progress"' | grep -c .)"
    if [ "${total}" -gt 0 ] && [ "${done_n}" -eq "${total}" ]; then
      if [ -f "${d}/closed" ]; then status="closed"
      elif [ -n "$(fm_field "${d}/goal.md" acceptance)" ] \
           && [ "$(sed -n 's/^verdict=//p' "${d}/acceptance" 2>/dev/null | head -1)" != "green" ]; then
        status="unverified"
      elif [ -n "$(fm_field "${d}/goal.md" acceptance)" ] \
           && [ "$(sed -n 's/^sig=//p' "${d}/acceptance" 2>/dev/null | head -1)" != "$(tasks_sig "${id}")" ]; then
        status="unverified"
      else status="unsynced"; fi
    elif [ "${active}" -gt 0 ] || [ "${total}" -eq 0 ]; then status="open"
    else status="blocked"; fi
    echo "${status} ${id}-${slug} done=${done_n}/${total} type=$(fm_field "${d}/goal.md" type)"
  done
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  list) cmd_list ;;
  sig)  shift; [ -n "${1:-}" ] || die "usage: sig <change-id>"; tasks_sig "$1" ;;
  *)
    echo "usage: factory-change.sh open <change-id> <slug> <type> <goal-file | -> [<acceptance command>] | sync [<change-id>] | list | sig <change-id>" >&2
    exit 2
    ;;
esac
