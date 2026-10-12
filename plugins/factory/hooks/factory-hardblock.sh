#!/usr/bin/env bash
# Factory: the hard-block matcher, shell side. NOT a hook itself: the
# PreToolUse guard (factory-done-guard.sh) calls it, and the tests do.
# register.js matches the same hooks/hard-blocks.txt in JavaScript.
#
# Usage:
#   factory-hardblock.sh version                      the file's hard_blocks_version
#   factory-hardblock.sh deny-rules                   the permissions.deny lines
#   factory-hardblock.sh check <root> bash  < command the command text on stdin
#   factory-hardblock.sh check <root> path  < path    one file path on stdin
#   factory-hardblock.sh trip <root> <rule> <tool> <agent>
#                                                     the breaker: .factory/STOP,
#                                                     an event, a notification
#
# check: prints the rule's name and exits 3 on a hit; exits 0 on a clean call.
# A rules file that cannot be read exits 4 - callers treat that as a hit
# (fail closed): a missing rule list is not permission.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES="${FACTORY_HARD_BLOCKS:-${HERE}/hard-blocks.txt}"

[ -r "${RULES}" ] || { echo "hard-blocks.txt unreadable: ${RULES}" >&2; exit 4; }

fields() {  # <kind> -> one rule per line, fields tab-separated
  awk -F' ## ' -v k="$1" '$1 == k { out = $2; for (i = 3; i <= NF; i++) out = out "\t" $i; print out }' "${RULES}"
}

case "${1:-}" in
  version)
    sed -n 's/^hard_blocks_version:[[:space:]]*//p' "${RULES}" | head -1
    exit 0
    ;;
  deny-rules)
    awk -F' ## ' '$1 == "deny" { print $2 }' "${RULES}"
    exit 0
    ;;
  trip)
    # A hard block was hit: stop the run from starting anything new (STOP is what
    # factory-start and the workflow read), say why where the developer looks,
    # and tell them. Never fails the caller.
    root="${2:-}"; rule="${3:-}"; tool="${4:-}"; agent="${5:-}"
    [ -d "${root}/.factory" ] || exit 0
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ ! -f "${root}/.factory/STOP" ]; then
      printf 'hard block "%s" hit by %s (%s) at %s. Remove this file once you have looked.\n' \
        "${rule}" "${agent:-an agent}" "${tool}" "${now}" > "${root}/.factory/STOP"
    fi
    # A ban was hit: the run may not publish more than a PR until the developer
    # consents again.
    if [ ! -s "${root}/.factory/autonomy-cap" ]; then
      printf 'pr\nhard block "%s" at %s\n' "${rule}" "${now}" > "${root}/.factory/autonomy-cap"
    fi
    jq -cn --arg ts "${now}" --argjson epoch "$(date +%s)" --arg rule "${rule}" --arg tool "${tool}" --arg agent "${agent}" \
      '{ts: $ts, epoch: $epoch, kind: "hard_block", rule: $rule, tool: $tool, agent_id: $agent}' \
      >> "${root}/.factory/events.jsonl" 2>/dev/null
    if [ "${FACTORY_NO_NOTIFY:-0}" != "1" ] && command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"hard block ${rule}: run stopped\" with title \"Factory\" sound name \"Glass\"" >/dev/null 2>&1 &
    fi
    exit 0
    ;;
  check) ;;
  *)
    echo "usage: factory-hardblock.sh version|deny-rules|check <root> bash|path|trip ..." >&2
    exit 2
    ;;
esac

ROOT="${2:-}"
KIND="${3:-}"
text="$(cat)"

# Same normalisation as register.js: a continued line is one line, every
# remaining newline separates commands, and the project root is spelled
# relative, so an absolute path cannot hide a root-relative rule.
if [ "${KIND}" = "bash" ]; then
  text="$(printf '%s\n' "${text}" | sed -e :a -e '/\\$/N; s/\\\n//; ta' | tr '\n' ';')"
fi
if [ -n "${ROOT}" ]; then
  rootpre="${ROOT%/}/"
  text="${text//"${rootpre}"/}"
fi

hit() { printf '%s\n' "$1"; exit 3; }
matches() { printf '%s' "$2" | grep -Eq -- "$1"; }

T='([[:space:];&|)"'"'"'>]|$)'

if [ "${KIND}" = "bash" ]; then
  while IFS=$'\t' read -r name re; do
    [ -n "${name}" ] || continue
    matches "${re}" "${text}" && hit "${name}"
  done < <(fields bash)
  while IFS=$'\t' read -r name anchor x; do
    [ -n "${name}" ] || continue
    if [ "${anchor}" = "root" ]; then
      lead='(\./)?'
      pre='[[:space:]"'"'"'=<>]'
      vlead='(\./)?'
    else
      lead='([^[:space:];&|"'"'"']*/)?'
      pre='[[:space:]/"'"'"'=<>]'
      vlead=''
    fi
    verbs='(^|[^[:alnum:]_.-])(tee|cp|mv|install|ln|rm|rsync|truncate|touch|chmod|chown|dd|shred|unlink|(sed|perl)[[:space:]]+([^;&|]*[[:space:]])?-[A-Za-z]*i)'
    redirect=">>?[|]?[[:space:]]*[\"']?${lead}(${x})${T}"
    verb="${verbs}[[:space:]]+([^;&|]*${pre})?${vlead}(${x})${T}"
    matches "${redirect}" "${text}" && hit "${name}"
    matches "${verb}" "${text}" && hit "${name}"
  done < <(fields path)
  exit 0
fi

if [ "${KIND}" = "path" ]; then
  while IFS=$'\t' read -r name anchor x; do
    [ -n "${name}" ] || continue
    if [ "${anchor}" = "root" ]; then
      matches "^(\./)?(${x})\$" "${text}" && hit "${name}"
    else
      matches "(^|/)(${x})\$" "${text}" && hit "${name}"
    fi
  done < <(fields path)
  exit 0
fi

echo "unknown kind: ${KIND}" >&2
exit 2
