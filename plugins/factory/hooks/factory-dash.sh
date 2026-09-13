#!/usr/bin/env bash
# Factory dashboard. NOT a hook itself: factory-event.sh runs it after every
# recorded event, the Stop gate runs it when a run ends, and /factory-dash runs
# it on demand.
#
# Usage: factory-dash        (from the project root)
#
# Writes two files, both from what is already on disk - no model, no tokens:
#   .factory/dashboard.html   the developer's screen; open it once in a browser
#                             and leave it there, it refreshes itself
#   .factory/statusline.txt   key=value line the terminal status line renders
#
# What it is for: the board says where every task is, but not what the team is
# doing, what it is stuck on, or whether it is waiting for the developer. Those
# three questions are the ones somebody running a team actually asks, and until
# now the only way to answer them was to read the scrollback.
set -uo pipefail

# Where this script lives. Siblings are called through it, so the whole
# toolkit works from any install path - a plugin directory changes on
# every update.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="$PWD"
F="${ROOT}/.factory"
T="${ROOT}/tasks"
LOG="${F}/events.jsonl"
[ -d "${F}" ] || exit 0

OUT="${F}/dashboard.html"
TMP="${OUT}.tmp.$$"
NOW="$(date +%s)"
COLUMNS="proposed backlog in-progress blocked done"

esc() { sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

fm() {  # <file> <key>
  [ -f "$1" ] || return 0
  awk 'NR==1 && /^---[[:space:]]*$/ {inside=1; next}
       inside && /^---[[:space:]]*$/ {exit}
       inside {print}' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

to_epoch() {  # ISO-8601 UTC -> epoch, on BSD date or GNU date
  [ -n "${1:-}" ] || return 0
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

hhmm() { date -r "$1" "+%H:%M" 2>/dev/null || date -d "@$1" "+%H:%M" 2>/dev/null; }

ago() {  # seconds -> "4dk", "2sa 10dk", "3g"
  local s="${1:-0}" d h m
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dg %dsa' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dsa %ddk' "$h" "$m"
  else printf '%ddk' "$m"; fi
}

count_md() { [ -d "$1" ] && find "$1" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ' || printf '0'; }

# --- board ------------------------------------------------------------------
declare_counts=""
for col in ${COLUMNS}; do
  eval "n_${col//-/_}=$(count_md "${T}/${col}")"
done
total_tasks=$(( n_proposed + n_backlog + n_in_progress + n_blocked + n_done ))

# --- events -----------------------------------------------------------------
EV=""
[ -f "${LOG}" ] && EV="$(tail -600 "${LOG}")"
ev() { printf '%s\n' "${EV}" | grep -v '^$' | jq -c "$1" 2>/dev/null; }

# An agent that died with its session never reports a stop. Two things say a
# start is finished even without one: a sweep line written after it (a session
# started, a run was claimed, a run ended - nothing from before is alive), and
# plain age, as a backstop for a machine that was shut down mid-run.
last_sweep=0
if [ -f "${LOG}" ]; then
  last_sweep="$(grep '"kind":"sweep"' "${LOG}" 2>/dev/null | tail -1 | jq -r '.epoch // 0' 2>/dev/null)"
  case "${last_sweep}" in ''|*[!0-9]*) last_sweep=0 ;; esac
fi
stale_after="$(jq -r '.agent_stale_after_min // 45' "${F}/config.json" 2>/dev/null)"
case "${stale_after}" in ''|*[!0-9]*) stale_after=45 ;; esac

running_agents=0
agent_lines=""
if [ -n "${EV}" ]; then
  # An agent is running when its start has no stop. Ids are unique per dispatch.
  agent_lines="$(printf '%s\n' "${EV}" | grep -v '^$' | jq -r '
      select(.kind=="agent_start" or .kind=="agent_stop")
      | "\(.kind) \(.agent_id // "?") \(.agent // "agent") \(.epoch)"' 2>/dev/null \
    | awk -v sweep="${last_sweep}" -v now="${NOW}" -v maxage="$(( stale_after * 60 ))" '
           { if ($1=="agent_start") { start[$2]=$4; type[$2]=$3 } else { delete start[$2] } }
           END { for (id in start) {
                   if (start[id] + 0 < sweep + 0) continue
                   if (now - start[id] > maxage) continue
                   printf "%s %s %s\n", id, type[id], start[id]
                 } }')"
  running_agents="$(printf '%s\n' "${agent_lines}" | grep -c .)"
fi

gate_green=0; gate_red=0; gate_stall=0
if [ -n "${EV}" ]; then
  gate_green="$(ev 'select(.kind=="gate" and .verdict=="green")' | grep -c .)"
  gate_red="$(ev 'select(.kind=="gate" and .verdict=="red")' | grep -c .)"
  gate_stall="$(ev 'select(.kind=="gate" and .verdict=="no-progress")' | grep -c .)"
fi

# How long tasks take, from the move into in-progress to the move into done.
median_task="-"
if [ -n "${EV}" ]; then
  median_task="$(printf '%s\n' "${EV}" | grep -v '^$' | jq -r '
      select(.kind=="move") | "\(.task) \(.to) \(.epoch)"' 2>/dev/null \
    | awk '$2=="in-progress" { started[$1]=$3 }
           $2=="done" && started[$1] { print int(($3 - started[$1]) / 60); delete started[$1] }' \
    | sort -n | awk '{a[NR]=$1} END { if (NR) printf "%d dk", (NR%2 ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)); else printf "-" }')"
fi

agent_time="$(printf '%s\n' "${EV}" | grep -v '^$' | jq -r 'select(.kind=="agent_stop" and .seconds>0) | "\(.agent) \(.seconds)"' 2>/dev/null \
  | awk '{ s[$1]+=$2; n[$1]++ } END { for (a in s) printf "%s %d %d\n", a, n[a], s[a]/60 }' | sort)"

last_event_age=-1
if [ -f "${LOG}" ]; then
  last_epoch="$(tail -1 "${LOG}" | jq -r '.epoch // empty' 2>/dev/null)"
  [ -n "${last_epoch}" ] && last_event_age=$(( NOW - last_epoch ))
fi

# --- cost -------------------------------------------------------------------
# Sampled by the status line, which is the only place Claude Code exposes it.
cost_now="-"; cost_run="-"; lines_delta="-"
if [ -f "${LOG}" ]; then
  last_cost="$(grep '"kind":"cost"' "${LOG}" 2>/dev/null | tail -1)"
  if [ -n "${last_cost}" ]; then
    sess="$(printf '%s' "${last_cost}" | jq -r '.session // ""' 2>/dev/null)"
    first_cost="$(grep '"kind":"cost"' "${LOG}" 2>/dev/null | jq -c --arg s "${sess}" 'select(.session==$s)' 2>/dev/null | head -1)"
    [ -n "${first_cost}" ] || first_cost="${last_cost}"
    cost_now="$(printf '%s' "${last_cost}" | jq -r '"$" + (((.usd//0)*100|round)/100|tostring)' 2>/dev/null)"
    cost_run="$(jq -rn --argjson a "${last_cost}" --argjson b "${first_cost}" \
      '"$" + ((((($a.usd//0)-($b.usd//0))*100)|round)/100|tostring)' 2>/dev/null)"
    lines_delta="$(printf '%s' "${last_cost}" | jq -r '"+\(.lines_added//0) −\(.lines_removed//0)"' 2>/dev/null)"
  fi
fi

# --- questions --------------------------------------------------------------
open_questions=0
[ -d "${F}/questions" ] && open_questions="$(grep -l '^status: open' "${F}/questions"/*.md 2>/dev/null | grep -c .)"

# --- changes ----------------------------------------------------------------
changes="$(bash "${HOOK_DIR}/factory-change.sh" list 2>/dev/null)"
cur_change="$(printf '%s\n' "${changes}" | awk '$1=="open" || $1=="blocked" || $1=="unverified" {print; exit}')"
[ -n "${cur_change}" ] || cur_change="$(printf '%s\n' "${changes}" | tail -1)"

# --- status line cache ------------------------------------------------------
{
  printf 'change=%s\n' "$(printf '%s' "${cur_change}" | awk '{print $2}')"
  printf 'progress=%s\n' "$(printf '%s' "${cur_change}" | awk '{print $3}' | sed 's/done=//')"
  printf 'running=%s\nquestions=%s\nblocked=%s\nbacklog=%s\nin_progress=%s\ndone=%s\nlast=%s\n' \
    "${running_agents}" "${open_questions}" "${n_blocked}" "${n_backlog}" "${n_in_progress}" "${n_done}" "${last_event_age}"
  printf 'stalled=%s\n' "$([ -d "${F}/no-progress" ] && find "${F}/no-progress" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ' || printf 0)"
} > "${F}/statusline.txt.tmp.$$" && mv -f "${F}/statusline.txt.tmp.$$" "${F}/statusline.txt"

# --- html -------------------------------------------------------------------
row_now=""
if [ -d "${T}/in-progress" ]; then
  for file in "${T}/in-progress"/*.md; do
    [ -e "${file}" ] || continue
    id="$(basename "${file}" .md)"
    title="$(fm "${file}" title | esc)"
    owner="$(fm "${file}" owner)"; owner="${owner:-—}"
    stage="$(fm "${file}" stage)"; stage="${stage:-?}"
    since="$(to_epoch "$(fm "${file}" stage_since)")"
    in_stage="—"
    [ -n "${since}" ] && in_stage="$(ago $(( NOW - since )))"
    retries="$(fm "${file}" retries)"
    marker="—"; [ -f "${F}/verified/${id}" ] && marker="yeşil"
    warn=""
    [ -n "${since}" ] && [ "$(( NOW - since ))" -gt 900 ] && warn=" class=\"warn\""
    row_now="${row_now}<tr${warn}><td class=\"id\">${id}</td><td>${title}</td><td>${owner}</td><td>${stage}</td><td>${in_stage}</td><td>${retries:-0}</td><td>${marker}</td></tr>"
  done
fi
[ -n "${row_now}" ] || row_now='<tr><td colspan="7" class="empty">Şu an çalışan görev yok.</td></tr>'

needs=""
if [ -d "${F}/questions" ]; then
  for q in "${F}/questions"/*.md; do
    [ -e "${q}" ] || continue
    grep -q '^status: open' "${q}" || continue
    qid="$(fm "${q}" id)"; qtask="$(fm "${q}" task)"
    qtext="$(sed -n '/^## Soru/,/^## /p' "${q}" | sed '1d;/^## /d' | grep -v '^$' | head -3 | esc | tr '\n' ' ')"
    qopts="$(sed -n '/^## Seçenekler/,/^## /p' "${q}" | sed -n 's/^- //p' | esc | sed 's|^|<li>|; s|$|</li>|' | tr -d '\n')"
    qrec="$(sed -n '/^## Öneri/,$p' "${q}" | sed '1d' | grep -v '^$' | head -2 | esc | tr '\n' ' ')"
    needs="${needs}<div class=\"q\"><div class=\"qh\">${qid} · görev ${qtask}</div><div>${qtext}</div>${qopts:+<ul>${qopts}</ul>}${qrec:+<div class=\"rec\">Ekibin önerisi: ${qrec}</div>}<div class=\"how\">Cevap: <code>factory-ask answer ${qid} \"...\"</code></div></div>"
  done
fi
if [ -d "${T}/blocked" ]; then
  for file in "${T}/blocked"/*.md; do
    [ -e "${file}" ] || continue
    id="$(basename "${file}" .md)"
    human="$(fm "${file}" needs_human)"
    reason="$(awk '/^##[[:space:]]+Blocked reason/ {inside=1; next} inside && /^#/ {exit} inside && NF {print; exit}' "${file}" | esc)"
    [ -z "${reason}" ] && reason="(görev dosyasında sebep yazılmamış)"
    tag="tıkandı"; [ "${human}" = "true" ] && tag="sana ihtiyacı var"
    needs="${needs}<div class=\"q\"><div class=\"qh\">${id} · ${tag}</div><div>${reason}</div></div>"
  done
fi
# A change whose tasks are all done and whose own acceptance command has not
# gone green. The board says finished; the change does not.
printf '%s\n' "${changes}" | awk '$1=="unverified" {print $2}' | while IFS= read -r chname; do
  [ -n "${chname}" ] || continue
  cdir="${F}/changes/${chname}"
  ccmd="$(fm "${cdir}/goal.md" acceptance | esc)"
  cverdict="$(sed -n 's/^verdict=//p' "${cdir}/acceptance" 2>/dev/null | head -1)"
  case "${cverdict}" in
    red) ctag="kabul komutu KIRMIZI" ;;
    "")  ctag="kabul komutu hiç çalışmadı" ;;
    *)   ctag="kabul komutu eski görev kümesine ait" ;;
  esac
  printf '<div class="q"><div class="qh">%s · %s</div><div><code>%s</code></div><div class="how">Çalıştır: <code>factory-accept %s</code></div></div>' \
    "${chname}" "${ctag}" "${ccmd}" "${chname%%-*}"
done > "${F}/.needs-acc.$$" 2>/dev/null
needs="${needs}$(cat "${F}/.needs-acc.$$" 2>/dev/null)"
rm -f "${F}/.needs-acc.$$"

[ -n "${needs}" ] || needs='<div class="empty">Bekleyen bir şey yok. Ekip kendi başına ilerliyor.</div>'

struggle=""
if [ -d "${F}/no-progress" ]; then
  for m in "${F}/no-progress"/*; do
    [ -e "${m}" ] || continue
    struggle="${struggle}<tr class=\"warn\"><td class=\"id\">$(basename "${m}")</td><td>aynı hataya iki kez takıldı</td><td>$(sed -n 's/^signature=//p' "${m}")</td></tr>"
  done
fi
for col in backlog in-progress blocked; do
  [ -d "${T}/${col}" ] || continue
  for file in "${T}/${col}"/*.md; do
    [ -e "${file}" ] || continue
    r="$(fm "${file}" retries)"
    case "${r}" in ''|0|*[!0-9]*) continue ;; esac
    struggle="${struggle}<tr><td class=\"id\">$(basename "${file}" .md)</td><td>${r} kez geri döndü</td><td>${col}</td></tr>"
  done
done
[ -n "${struggle}" ] || struggle='<tr><td colspan="3" class="empty">Zorlanan görev yok.</td></tr>'

ch_rows=""
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  st="$(printf '%s' "${line}" | awk '{print $1}')"
  name="$(printf '%s' "${line}" | awk '{print $2}')"
  prog="$(printf '%s' "${line}" | awk '{print $3}' | sed 's/done=//')"
  typ="$(printf '%s' "${line}" | awk '{print $4}' | sed 's/type=//')"
  d="${prog%%/*}"; t="${prog##*/}"
  pct=0; [ "${t:-0}" -gt 0 ] 2>/dev/null && pct=$(( d * 100 / t ))
  ch_rows="${ch_rows}<tr><td class=\"id\">${name}</td><td>${typ}</td><td>${st}</td><td><div class=\"bar\"><span style=\"width:${pct}%\"></span></div> ${prog}</td></tr>"
done <<< "${changes}"
[ -n "${ch_rows}" ] || ch_rows='<tr><td colspan="4" class="empty">Henüz açılmış bir değişiklik yok.</td></tr>'

feed=""
if [ -n "${EV}" ]; then
  feed="$(printf '%s\n' "${EV}" | grep -v '^$' | tail -25 | jq -r '
    [ .epoch,
      (if .kind=="gate" then "\(.task) · kapı \(.verdict)"
       elif .kind=="move" then "\(.task) · \(.from) → \(.to)"
       elif .kind=="commit" then "\(.task) · commit \(.sha)"
       elif .kind=="agent_start" then "\(.agent) başladı"
       elif .kind=="agent_stop" then "\(.agent) bitti (\(if .seconds>0 then "\(.seconds/60|floor) dk" else "?" end))"
       elif .kind=="risk" then "\(.task) · risk kontrolü: \(if .review_needed=="yes" then "review gerekli" else "temiz" end)"
       elif .kind=="question" then "\(.question) · sana soru soruldu"
       elif .kind=="change_open" then "\(.change) · değişiklik açıldı"
       elif .kind=="claim" then "koşu sahiplendi"
       elif .kind=="sweep" then "\(.agents) ajan + \(.markers) slot temizlendi (önceki oturumdan kalma)"
       else .kind end) ] | @tsv' 2>/dev/null \
  | while IFS="$(printf '\t')" read -r e text; do
      printf '<li><span class="t">%s</span> %s</li>' "$(hhmm "${e}")" "$(printf '%s' "${text}" | esc)"
    done)"
fi
[ -n "${feed}" ] || feed='<li class="empty">Henüz kayıt yok.</li>'

agent_rows=""
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  agent_rows="${agent_rows}<tr><td class=\"id\">$(printf '%s' "${line}" | awk '{print $1}')</td><td>$(printf '%s' "${line}" | awk '{print $2}')</td><td>$(printf '%s' "${line}" | awk '{print $3}') dk</td></tr>"
done <<< "${agent_time}"
[ -n "${agent_rows}" ] || agent_rows='<tr><td colspan="3" class="empty">—</td></tr>'

live="çevrimdışı"; live_cls="off"
if [ "${last_event_age}" -ge 0 ] 2>/dev/null; then
  if [ "${last_event_age}" -lt 300 ]; then live="canlı · son hareket $(ago "${last_event_age}") önce"; live_cls="on"
  else live="son hareket $(ago "${last_event_age}") önce"; fi
fi
owner_state="sahipsiz"
[ -s "${F}/run-owner" ] && owner_state="koşu sahipli"

cat > "${TMP}" <<HTML
<!doctype html>
<html lang="tr"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Factory · $(basename "${ROOT}")</title>
<style>
:root { --bg:#f6f7f9; --card:#fff; --ink:#15181d; --dim:#6b7280; --line:#e5e7eb; --acc:#2563eb; --warn:#b45309; --warnbg:#fef3c7; --ok:#15803d; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0e1116; --card:#161a21; --ink:#e6e8ec; --dim:#9aa3af; --line:#252b35; --acc:#60a5fa; --warn:#fbbf24; --warnbg:#3b2f0b; --ok:#4ade80; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Segoe UI,sans-serif; padding:16px; }
h1 { font-size:17px; margin:0 0 2px; }
h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--dim); margin:0 0 8px; }
.sub { color:var(--dim); font-size:12px; margin-bottom:14px; }
.dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--dim); margin-right:6px; }
.on .dot { background:var(--ok); }
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:12px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; }
.wide { grid-column:1/-1; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th { text-align:left; color:var(--dim); font-weight:500; font-size:11px; text-transform:uppercase; letter-spacing:.04em; padding:0 8px 6px 0; }
td { padding:5px 8px 5px 0; border-top:1px solid var(--line); vertical-align:top; }
.id { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; color:var(--acc); white-space:nowrap; }
.empty { color:var(--dim); font-style:italic; }
tr.warn td { background:var(--warnbg); color:var(--warn); }
.kpi { display:flex; gap:18px; flex-wrap:wrap; }
.kpi div { min-width:72px; }
.kpi b { display:block; font-size:20px; font-weight:600; }
.kpi span { color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:.04em; }
.q { border-left:3px solid var(--warn); background:var(--warnbg); padding:8px 10px; border-radius:0 8px 8px 0; margin-bottom:8px; }
.qh { font-weight:600; margin-bottom:2px; }
.q ul { margin:6px 0; padding-left:18px; }
.rec { color:var(--dim); margin-top:4px; }
.how { margin-top:6px; font-size:12px; color:var(--dim); }
code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
.bar { display:inline-block; width:110px; height:7px; border-radius:4px; background:var(--line); overflow:hidden; vertical-align:middle; margin-right:6px; }
.bar span { display:block; height:100%; background:var(--acc); }
ul.feed { list-style:none; margin:0; padding:0; font-size:13px; }
ul.feed li { padding:3px 0; border-top:1px solid var(--line); }
ul.feed .t { color:var(--dim); font-family:ui-monospace,Menlo,monospace; margin-right:8px; }
</style></head><body>
<h1>$(basename "${ROOT}") · fabrika</h1>
<div class="sub ${live_cls}"><span class="dot"></span>${live} · ${owner_state} · pano $(date "+%H:%M:%S")'te yenilendi</div>

<div class="card wide">
  <div class="kpi">
    <div><b>${n_in_progress}</b><span>çalışıyor</span></div>
    <div><b>${running_agents}</b><span>açık ajan</span></div>
    <div><b>${n_backlog}</b><span>sırada</span></div>
    <div><b>${n_done}</b><span>bitti</span></div>
    <div><b>${n_blocked}</b><span>tıkandı</span></div>
    <div><b>${open_questions}</b><span>soru</span></div>
    <div><b>${median_task}</b><span>görev medyan</span></div>
    <div><b>${gate_green}/${gate_red}</b><span>kapı yeşil/kırmızı</span></div>
    <div><b>${cost_run}</b><span>bu oturum</span></div>
    <div><b>${lines_delta}</b><span>satır</span></div>
  </div>
</div>

<div class="grid">
  <div class="card wide">
    <h2>Şu an ne yapılıyor</h2>
    <table><tr><th>görev</th><th>başlık</th><th>kim</th><th>aşama</th><th>süre</th><th>tekrar</th><th>kapı</th></tr>${row_now}</table>
  </div>

  <div class="card">
    <h2>Sana ihtiyacı var</h2>
    ${needs}
  </div>

  <div class="card">
    <h2>Zorlananlar</h2>
    <table><tr><th>görev</th><th>durum</th><th>ayrıntı</th></tr>${struggle}</table>
  </div>

  <div class="card">
    <h2>Değişiklikler</h2>
    <table><tr><th>ad</th><th>tür</th><th>durum</th><th>ilerleme</th></tr>${ch_rows}</table>
  </div>

  <div class="card">
    <h2>Ajan zamanı</h2>
    <table><tr><th>rol</th><th>koşu</th><th>toplam</th></tr>${agent_rows}</table>
  </div>

  <div class="card wide">
    <h2>Son hareketler</h2>
    <ul class="feed">${feed}</ul>
  </div>
</div>
</body></html>
HTML
mv -f "${TMP}" "${OUT}"
exit 0
