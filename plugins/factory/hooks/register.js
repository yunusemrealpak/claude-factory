// Factory mod: the hooks module Claude Code loads from hooks.json "modules".
//
// Observe-only. No hook here refuses, rewrites or answers an event in Claude
// Code's place, and nothing calls a model: every hook passes its event on
// unchanged, and a failure inside one is swallowed so it can never stop a turn.
//
//   - session.measure / turn.complete: the plan's rate-limit windows, written
//     to ~/.claude/.factory-quota.json in the shape the status line writes, so
//     the quota breaker has a reading in `claude -p` runs too.
//   - agent.spawn / turn.complete: one line per agent turn in
//     .factory/usage.jsonl (tokens, model, agent label), for cost per task.
//   - /factory-board: the board from disk, with no model turn.

const WEEK_MS = 7 * 24 * 3600 * 1000
// A turn refreshes the quota file at most this often; session.measure writes
// whenever a window moves a whole point.
const QUOTA_REFRESH_MS = 5 * 60 * 1000
const LANES = ['backlog', 'in-progress', 'blocked', 'done']

// Per load: a reload runs register again and starts these over.
let root = null
let agents = {}
let quotaWrittenAt = 0

export function register(on) {
  root = null
  agents = {}
  quotaWrittenAt = 0

  on('session.start', async ($, e, next) => {
    try {
      root = await $.session.root()
    } catch {
      root = null
    }
    try {
      await $.command.register({
        name: 'factory-board',
        description: 'Factory board from disk: lane counts, what is ready, the week\'s quota (no model turn)',
        immediate: true,
      })
    } catch {}
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    try {
      if (e.changed.includes('rateLimits')) await saveQuota($, e.rateLimits)
    } catch {}
    return next(e)
  })

  // The spawn's result carries the id its turns report; keep the label the
  // caller gave so a turn can say which task it worked on.
  on('agent.spawn', async ($, e, next) => {
    const r = await next(e)
    try {
      if (r && r.agentId) agents[r.agentId] = { type: e.subagentType, label: e.description }
    } catch {}
    return r
  })

  on('turn.complete', async ($, e, next) => {
    try {
      await meter($, e)
    } catch {}
    try {
      if ((await $.clock.now()) - quotaWrittenAt >= QUOTA_REFRESH_MS) {
        const usage = await $.session.usage()
        await saveQuota($, usage.rateLimits)
      }
    } catch {}
    return next(e)
  })

  on('command.run', { command: 'factory-board' }, async ($) => {
    try {
      return { text: await board($) }
    } catch (err) {
      return { text: 'factory-board failed: ' + String(err && err.message ? err.message : err) }
    }
  })
}

// Rate-limit windows -> the status line's quota file. resets_at is epoch
// seconds there, an ISO timestamp here.
async function saveQuota($, limits) {
  if (!Array.isArray(limits) || limits.length === 0) return
  const now = await $.clock.now()
  const saved = { ts: Math.floor(now / 1000), source: 'mod' }
  for (const w of limits) {
    if (w.kind !== 'five_hour' && w.kind !== 'seven_day') continue
    const at = w.resetsAt ? Math.floor(Date.parse(w.resetsAt) / 1000) : NaN
    const row = { used_percentage: w.percentUsed, resets_at: Number.isFinite(at) ? at : null }
    if (w.kind === 'seven_day' && row.resets_at !== null) {
      const elapsed = 1 - Math.max(0, Math.min(1, (row.resets_at * 1000 - now) / WEEK_MS))
      row.even_line = Math.round(elapsed * 1000) / 10
    }
    saved[w.kind] = row
  }
  if (!saved.five_hour && !saved.seven_day) return
  const home = await $.env.get('HOME')
  if (!home) return
  // Same rename-over the status line does, under its own temp name.
  await $.process.run(
    ['sh', '-c', 'cat > "$1.mod.tmp" && mv -f "$1.mod.tmp" "$1"', 'sh', home + '/.claude/.factory-quota.json'],
    { stdin: JSON.stringify(saved), timeoutMs: 5000 },
  )
  quotaWrittenAt = now
}

// One usage line per agent turn, appended in a single write. Inert unless the
// factory is open in the session's project.
async function meter($, e) {
  if (!root || !e.usage) return
  if (!(await $.fs.exists(root + '/.factory/active'))) return
  const id = e.agentId || 'main'
  let who = agents[id]
  if (!who && e.agentId) {
    const found = (await $.agent.list()).find((a) => a.id === e.agentId)
    who = found ? { type: found.type, label: found.description } : { type: null, label: null }
    agents[id] = who
  }
  const u = e.usage
  const line = JSON.stringify({
    ts: Math.floor((await $.clock.now()) / 1000),
    turn: e.turnId,
    agent: id,
    type: who ? who.type : 'main',
    label: who ? who.label : null,
    model: u.model,
    input: u.input_tokens,
    output: u.output_tokens,
    cache_read: u.cache_read_input_tokens,
    cache_write: u.cache_creation_input_tokens,
    ms: e.durationMs,
    reason: e.reason,
  })
  await $.process.run(['sh', '-c', 'cat >> "$1"', 'sh', root + '/.factory/usage.jsonl'], {
    stdin: line + '\n',
    timeoutMs: 5000,
  })
}

async function board($) {
  if (!root || !(await $.fs.exists(root + '/.factory/active'))) return 'factory is not initialised in this project'
  const counts = []
  for (const lane of LANES) {
    let n = 0
    if (await $.fs.exists(root + '/tasks/' + lane)) {
      n = (await $.fs.list(root + '/tasks/' + lane)).filter((f) => f.kind === 'file' && f.name.endsWith('.md')).length
    }
    counts.push(lane + '=' + n)
  }
  const out = [counts.join('  ')]
  const ready = await $.process.run(['bash', $.plugin.root + '/hooks/factory-ready.sh'], { cwd: root, timeoutMs: 15000 })
  const lines = ready.stdout.trim()
  out.push(lines || '(nothing ready or waiting)')
  const home = await $.env.get('HOME')
  if (home && (await $.fs.exists(home + '/.claude/.factory-quota.json'))) {
    const q = JSON.parse(await $.fs.read(home + '/.claude/.factory-quota.json'))
    const week = q.seven_day
    if (week) {
      const age = Math.round(((await $.clock.now()) / 1000 - q.ts) / 60)
      const line = week.even_line === undefined ? '' : ' (even-spend line ' + week.even_line + '%)'
      out.push('quota: 7-day ' + week.used_percentage + '%' + line + ', read ' + age + ' min ago')
    }
  }
  return out.join('\n')
}
