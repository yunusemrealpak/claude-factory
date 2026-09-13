#!/usr/bin/env bash
# Factory status line for Claude Code.
#
# Renders: the model, context usage, and - inside a project where the factory
# is open - one segment saying what the team is doing right now:
#
#   🏭 C2-kasa-akisi 3/7 ▶2 ✋1 ⛔1 ⚠1
#      change       done ▶agents ✋questions ⛔blocked ⚠stalled
#
# Use it as-is:
#   "statusLine": { "type": "command",
#                   "command": "bash <this file>", "refreshInterval": 30 }
# in ~/.claude/settings.json - or copy the "Factory segment" block below into
# the status line you already have. It is deliberately self-contained: it reads
# a cache the factory wrote and computes nothing, because a status line blocks
# the UI while it runs.
#
# A plugin cannot install a status line for you (a plugin's settings.json
# supports only `agent` and `subagentStatusLine`), so this is a file you point
# your own settings at.
set -uo pipefail

INPUT=$(cat)
RESET=$'\033[0m'
DIM=$'\033[38;5;240m'
GAP="   "
PARTS=()

MODEL=$(printf '%s' "$INPUT" | jq -r '.model.display_name // .model.id // ""' 2>/dev/null)
[ -n "$MODEL" ] && PARTS+=("$(printf '\033[38;5;245m🤖%s %s%s' "$RESET" "$MODEL" "$RESET")")

CTX=$(printf '%s' "$INPUT" | jq -r '.context_window.used_percentage // 0 | floor' 2>/dev/null)
case "$CTX" in ''|*[!0-9]*) CTX=0 ;; esac
if [ "$CTX" -ge 70 ]; then CC=$'\033[38;5;196m'
elif [ "$CTX" -ge 40 ]; then CC=$'\033[38;5;214m'
else CC=$'\033[38;5;70m'; fi
PARTS+=("$(printf '\033[38;5;245m🧠 ctx%s %s%s%%%s' "$RESET" "$CC" "$CTX" "$RESET")")

# --- Factory segment ---------------------------------------------------------
# Only inside a project where the factory is open. Everything shown here is read
# from a cache that factory-dash.sh wrote; this script computes nothing, because
# the status line blocks the UI while it runs.
FDIR=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null)
if [ -n "$FDIR" ] && [ -f "$FDIR/.factory/active" ]; then
  FS="$FDIR/.factory/statusline.txt"
  if [ -f "$FS" ]; then
    fval() { sed -n "s/^$1=//p" "$FS" | head -1; }
    CH=$(fval change); PROG=$(fval progress); RUN=$(fval running); QS=$(fval questions)
    BLK=$(fval blocked); STL=$(fval stalled)
    # A change name is a slug of up to 40 characters, which pushes everything
    # after it off the line. Keep the head: the change id lives there.
    FMAX=${FACTORY_STATUSLINE_MAX:-18}
    CH="${CH:-factory}"
    [ "${#CH}" -gt "$FMAX" ] && CH="${CH:0:$((FMAX - 1))}…"
    SEG=$(printf '\033[38;5;245m🏭%s %s' "$RESET" "$CH")
    [ -n "$PROG" ] && SEG="$SEG $(printf '\033[38;5;74m%s%s' "$PROG" "$RESET")"
    [ "${RUN:-0}" -gt 0 ] 2>/dev/null && SEG="$SEG $(printf '\033[38;5;70m▶%s%s' "$RUN" "$RESET")"
    [ "${QS:-0}" -gt 0 ] 2>/dev/null && SEG="$SEG $(printf '\033[38;5;196m✋%s%s' "$QS" "$RESET")"
    [ "${BLK:-0}" -gt 0 ] 2>/dev/null && SEG="$SEG $(printf '\033[38;5;214m⛔%s%s' "$BLK" "$RESET")"
    [ "${STL:-0}" -gt 0 ] 2>/dev/null && SEG="$SEG $(printf '\033[38;5;196m⚠%s%s' "$STL" "$RESET")"
    PARTS+=("$SEG")
  fi
  # The status line is the only place Claude Code hands over what the session has
  # cost. The factory's dashboard and retrospective need that number, so one
  # sample a minute goes into the event log. Nothing else here writes to it.
  COSTF="$FDIR/.factory/.cost-sample"
  NOWS=$(date +%s); LASTS=0; [ -f "$COSTF" ] && LASTS=$(cat "$COSTF" 2>/dev/null)
  case "$LASTS" in ''|*[!0-9]*) LASTS=0 ;; esac
  if [ $((NOWS - LASTS)) -ge 60 ]; then
    printf '%s' "$NOWS" > "$COSTF"
    printf '%s' "$INPUT" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$NOWS" \
      '{ts:$ts, epoch:$epoch, kind:"cost", usd:(.cost.total_cost_usd//0),
        session_min:((.cost.total_duration_ms//0)/60000|floor),
        lines_added:(.cost.total_lines_added//0), lines_removed:(.cost.total_lines_removed//0),
        ctx:(.context_window.used_percentage//0|floor), session:(.session_id//"")}' \
      >> "$FDIR/.factory/events.jsonl" 2>/dev/null
  fi
fi

OUT=""
for i in "${!PARTS[@]}"; do
  [ "$i" -gt 0 ] && OUT+="$GAP"
  OUT+="${PARTS[$i]}"
done
printf '%s' "$OUT"
