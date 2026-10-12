// Factory mod: the hooks module Claude Code loads from hooks.json "modules".
//
// Two kinds of hook, and the difference is the contract:
//
//   - observers (quota, usage, board, the autonomy band) never refuse or
//     rewrite anything and never call a model; a failure inside one is
//     swallowed so it can never stop a turn.
//   - the hard blocks (tool.call) and the consent record (prompt.submit) are the
//     only hooks that act. The first refuses a subagent's call that
//     hooks/hard-blocks.txt forbids and FAILS CLOSED: if it cannot decide, the
//     call is refused. The second only reads the developer's own prompt.
//
//   - session.measure / turn.complete: the plan's rate-limit windows, written
//     to ~/.claude/.factory-quota.json in the shape the status line writes, so
//     the quota breaker has a reading in `claude -p` runs too.
//   - agent.spawn / turn.complete: one line per agent turn in
//     .factory/usage.jsonl (tokens, model, agent label), for cost per task.
//   - /factory-board: the board from disk, with no model turn.
//   - tool.call: the hard blocks (class D) for subagents - see hard-blocks.txt.
//   - prompt.submit: "auto devam et" / "auto dur" typed by the developer is
//     handed to factory-consent.sh, which writes the autonomy record.
//   - an AbovePrompt band showing the autonomy level, with an "auto dur" button.

const WEEK_MS = 7 * 24 * 3600 * 1000
// A turn refreshes the quota file at most this often; session.measure writes
// whenever a window moves a whole point.
const QUOTA_REFRESH_MS = 5 * 60 * 1000
const LANES = ['backlog', 'in-progress', 'blocked', 'done']
// The whole prompt, nothing before or after (factory-consent.sh holds the same
// phrase). "origin" kinds that are the developer's own hand.
const CONSENT = /^\s*auto (devam( et)?|dur)\s*$/i
const HUMAN_ORIGINS = ['composer', 'bridge']

// Per load: a reload runs register again and starts these over.
let root = null
let agents = {}
let quotaWrittenAt = 0
let rules = null
let band = { level: 'local', stopped: false }

export function register(on) {
  root = null
  agents = {}
  quotaWrittenAt = 0
  rules = null
  band = { level: 'local', stopped: false }

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
      await refreshBand($)
    } catch {}
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

  // The hard blocks. Only a subagent's call is judged here (the developer's
  // own session pushes and writes gates when it has to); the same list is
  // enforced for every session by factory-done-guard.sh and the project's
  // permissions.deny. `.catch` is the fail-closed part: a hook that cannot
  // decide refuses.
  on('tool.call', async ($, e, next) => {
    if (!e.agentId) return next(e)
    const hit = await judge($, e).catch((err) => ({
      rule: 'hook-error',
      why: 'the hard-block check failed (' + String(err && err.message ? err.message : err) + ')',
    }))
    if (!hit) return next(e)
    await trip($, e, hit).catch(() => {})
    return {
      deny:
        'Factory hard block (' + hit.rule + '): ' + (hit.why || 'no agent of a factory run may do this - it publishes, spends or rewrites the rules the run is judged by') +
        '. Do not look for another way. Say in your result that the task needs it and stop; the run is halted (.factory/STOP) until the developer has looked.',
    }
  }).catch(($, e, next) =>
    next.called ? next(e) : { deny: 'Factory hard block (hook-error): the hard-block check could not run, so the call is refused.' },
  )

  // The developer's own words, when they are exactly the consent phrase. The
  // record is written by factory-consent.sh; this hook only hands it the prompt
  // and only when the prompt came from a person.
  on('prompt.submit', async ($, e, next) => {
    try {
      const kind = e.origin && e.origin.kind
      if (HUMAN_ORIGINS.includes(kind) && CONSENT.test(e.text || '')) {
        if (root && (await $.fs.exists(root + '/.factory/active'))) {
          await runConsent($, e.text, kind)
          await refreshBand($)
        }
      }
    } catch {}
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    try {
      if (!root || (band.level === 'local' && !band.stopped)) return next(e)
      const { Box, Text, Button } = $.ui.resolve(e)
      const label = band.stopped ? 'factory: STOPPED (.factory/STOP)' : 'factory autonomy: ' + band.level
      return h(
        Box,
        null,
        h(Text, { dimColor: true }, label + ' '),
        h(Button, { key: 'stop', label: 'auto dur', onPress: () => runConsent($, 'auto dur', 'composer').then(() => refreshBand($)).catch(() => {}) }),
      )
    } catch {
      return next(e)
    }
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

// --- hard blocks ------------------------------------------------------------

// hard-blocks.txt is POSIX ERE; these two classes are all JavaScript lacks.
const js = (re) => re.replace(/\[:space:\]/g, '\\s').replace(/\[:alnum:\]/g, 'A-Za-z0-9')
const TERM = '([\\s;&|)"\'>]|$)'
const VERBS =
  '(^|[^A-Za-z0-9_.-])(tee|cp|mv|install|ln|rm|rsync|truncate|touch|chmod|chown|dd|shred|unlink|(sed|perl)\\s+([^;&|]*\\s)?-[A-Za-z]*i)'

async function loadRules($) {
  if (rules) return rules
  const text = await $.fs.read($.plugin.root + '/hooks/hard-blocks.txt')
  const out = { bash: [], path: [] }
  for (const line of text.split('\n')) {
    const f = line.split(' ## ')
    if (f[0] === 'bash' && f.length === 3) out.bash.push({ name: f[1], re: new RegExp(js(f[2])) })
    if (f[0] === 'path' && f.length === 4) {
      const [, name, anchor, x] = f
      const X = js(x)
      const root = anchor === 'root'
      const lead = root ? '(\\./)?' : '([^\\s;&|"\']*/)?'
      const pre = root ? '[\\s"\'=<>]' : '[\\s/"\'=<>]'
      out.path.push({
        name,
        file: root ? new RegExp('^(\\./)?(' + X + ')$') : new RegExp('(^|/)(' + X + ')$'),
        redirect: new RegExp('>>?[|]?\\s*["\']?' + lead + '(' + X + ')' + TERM),
        verb: new RegExp(VERBS + '\\s+([^;&|]*' + pre + ')?' + (root ? '(\\./)?' : '') + '(' + X + ')' + TERM),
      })
    }
  }
  if (!out.bash.length || !out.path.length) throw new Error('hard-blocks.txt holds no rules')
  rules = out
  return out
}

// The same text the shell matcher sees: continuations joined, newlines as
// separators, the project root spelled relative.
function normalise(text, dir) {
  let t = String(text)
  const prefix = dir.replace(/\/+$/, '') + '/'
  t = t.split(prefix).join('')
  return t
}

async function judge($, e) {
  if (!root) root = await $.session.root()
  if (!(await $.fs.exists(root + '/.factory/active'))) return null
  const r = await loadRules($)
  if (e.tool === 'Bash') {
    const cmd = normalise(String(e.command || '').replace(/\\\n/g, '').replace(/\n/g, ';'), root)
    for (const b of r.bash) if (b.re.test(cmd)) return { rule: b.name }
    for (const p of r.path) if (p.redirect.test(cmd) || p.verb.test(cmd)) return { rule: p.name }
    return null
  }
  if (e.tool === 'Write' || e.tool === 'Edit' || e.tool === 'NotebookEdit') {
    const file = normalise(e.file_path || e.notebook_path || '', root)
    if (!file) return null
    for (const p of r.path) if (p.file.test(file)) return { rule: p.name }
  }
  return null
}

// The breaker: STOP, an event, a notification - all in factory-hardblock.sh.
async function trip($, e, hit) {
  if (!root) return
  await $.process.run(
    ['bash', $.plugin.root + '/hooks/factory-hardblock.sh', 'trip', root, hit.rule, String(e.tool), String(e.agentId || '')],
    { cwd: root, timeoutMs: 10000 },
  )
}

// --- autonomy ---------------------------------------------------------------

async function runConsent($, prompt, origin) {
  const sid = await $.session.id()
  await $.process.run(['bash', $.plugin.root + '/hooks/factory-consent.sh'], {
    cwd: root,
    stdin: JSON.stringify({ prompt, cwd: root, session_id: sid, origin }),
    timeoutMs: 10000,
  })
}

// The band's picture of the level comes from the reader, which re-checks the
// consent against the transcript; the band never believes the file itself.
async function refreshBand($) {
  if (!root || !(await $.fs.exists(root + '/.factory/active'))) return
  const r = await $.process.run(['bash', $.plugin.root + '/hooks/factory-autonomy.sh'], { cwd: root, timeoutMs: 8000 })
  const level = r.stdout.trim()
  const stopped = await $.fs.exists(root + '/.factory/STOP')
  const next = { level: ['pr', 'merge'].includes(level) ? level : 'local', stopped }
  if (next.level !== band.level || next.stopped !== band.stopped) {
    band = next
    $.ui.invalidate('ui.render')
  }
}
