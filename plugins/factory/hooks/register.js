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
//   - turn.step / tool.call: a builder's budget (config.json fast.budget):
//     its model requests and tokens are counted, at 80% it is told once, and
//     at the ceiling every call but its way out (factory-settle, the task
//     file) is refused. Judged after the hard blocks, and it FAILS OPEN.
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
// One builder's budget when config.json has no fast.budget: its model
// requests (each one a turn, as maxTurns counts them) and the tokens they
// cost - input, output and cache writes; cache reads are cheap and grow with
// every turn, so they are left out.
const BUDGET = { turns: 150, tokens: 3000000 }
// agents/builder.md stops a builder outright at maxTurns: 250. A ceiling is
// kept below that, so the builder always has turns left to settle.
const TURN_CAP = 230
const BUDGET_WARN = 0.8

// Per load: a reload runs register again and starts these over.
let root = null
let agents = {}
let spent = {}
let quotaWrittenAt = 0
let rules = null
let band = { level: 'local', stopped: false, publish: '' }
let bashExe = null

export function register(on) {
  root = null
  bashExe = null
  agents = {}
  spent = {}
  quotaWrittenAt = 0
  rules = null
  band = { level: 'local', stopped: false, publish: '' }

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
  // The quota breaker: above the week's even-spend line a new builder does not
  // start while the level is merge - a run that publishes unattended must not
  // be the thing that empties the week. Live figures only; where none exist
  // (an API key, no subscription) the spawn goes on, and factory-plan --start
  // has its own check on the saved file.
  on('agent.spawn', async ($, e, next) => {
    try {
      const why = await quotaGate($, e)
      if (why) return { deny: why }
    } catch {}
    const r = await next(e)
    try {
      if (r && r.agentId) agents[r.agentId] = { type: e.subagentType, label: e.description }
    } catch {}
    return r
    // An observer: whatever fails in here, the spawn goes on (next is
    // replay-safe, so a spawn already made is not made twice).
  }).catch(($, e, next) => next(e))

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

  // A subagent's run is one turn and its turn.complete comes at the end, so
  // a builder's budget is counted here, one model request at a time.
  on('turn.step', async function* ($, e, next) {
    const r = yield* next(e)
    try {
      if (e.agentId && r && r.usage) await spend($, e.agentId, r.usage)
    } catch {}
    return r
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
    if (!hit) return withinBudget($, e, next)
    // A tool the factory cannot judge is refused, but it is not a ban the
    // agent broke: the run goes on.
    if (hit.rule === 'unjudged-tool') {
      return { deny: 'Factory: ' + hit.why + '. Use Read, Grep, Glob, Bash, Write or Edit instead.' }
    }
    // A test HEAD has: read-only for this task, and not a ban broken.
    if (hit.level === READONLY) {
      return {
        deny:
          'Factory: ' + hit.path + ' is a test the project already has, and existing tests are read-only for this task - a test that was green is the evidence the code works. ' +
          'Write a new test file for what the task adds. If the task truly has to change this test, do not get around it: say so in your result; the developer approves it with modifies_tests in the task file. The run goes on.',
      }
    }
    // Inline code that writes and names a protected path: a guess, so only
    // this call is refused.
    if (hit.level === 'soft') {
      return {
        deny:
          'Factory: inline code that writes files and names a protected path (' + hit.rule + ') is refused - the factory cannot tell what it writes. ' +
          'Read protected files with the Read tool; if the task has to change one, say so in your result. The run goes on.',
      }
    }
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
      if (!root || (band.level === 'local' && !band.stopped && !band.publish)) return next(e)
      const { Box, Text, Button } = $.ui.resolve(e)
      const label =
        (band.stopped ? 'factory: STOPPED (.factory/STOP)' : 'factory autonomy: ' + band.level) +
        (band.publish ? ' | delivery: ' + band.publish : '')
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
  const home = await homeDir($)
  if (!home) return
  // Same rename-over the status line does, under its own temp name.
  await $.process.run(
    [await bashPath($), '-c', 'cat > "$1.mod.tmp" && mv -f "$1.mod.tmp" "$1"', 'sh', home + '/.claude/.factory-quota.json'],
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
  const who = e.agentId ? await whoIs($, e.agentId) : agents[id]
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
  await $.process.run([await bashPath($), '-c', 'cat >> "$1"', 'sh', root + '/.factory/usage.jsonl'], {
    stdin: line + '\n',
    timeoutMs: 5000,
  })
}

// The type and label of a subagent: from its spawn when this module saw it,
// else from the session's list of agents.
async function whoIs($, id) {
  if (!agents[id]) {
    const found = (await $.agent.list()).find((a) => a.id === id)
    agents[id] = found ? { type: found.type, label: found.description } : { type: null, label: null }
  }
  return agents[id]
}

// --- a builder's budget -------------------------------------------------------

// fast.budget: {turns, tokens}. A missing or unusable value is the default;
// 0 lifts that one limit; false lifts the budget. Read once per builder, at
// its first request, so a change applies to the next builder.
async function budgetLimits($) {
  let b
  try {
    const cfg = JSON.parse(await $.fs.read(root + '/.factory/config.json'))
    b = cfg && cfg.fast ? cfg.fast.budget : undefined
  } catch {}
  if (b === false) return null
  const pick = (v, d) => (v === 0 ? Infinity : typeof v === 'number' && v > 0 ? v : d)
  const o = b && typeof b === 'object' ? b : {}
  return { turns: Math.min(pick(o.turns, BUDGET.turns), TURN_CAP), tokens: pick(o.tokens, BUDGET.tokens) }
}

// Only a factory builder has a budget: a reviewer, a runner and the main
// session are never limited here. The task is the first word of its label
// ("C2-01 retry" builds C2-01).
async function spend($, id, u) {
  let b = spent[id]
  if (!b) {
    spent[id] = { off: true }
    const who = await whoIs($, id)
    if (!who || who.type !== 'factory:builder') return
    if (!root) root = await $.session.root()
    if (!(await $.fs.exists(root + '/.factory/active'))) return
    const lim = await budgetLimits($)
    if (!lim) return
    const task = String(who.label || '').trim().split(/\s+/)[0] || '<task-id>'
    b = spent[id] = { off: false, task, lim, turns: 0, tokens: 0, warned: false, full: false }
  }
  if (b.off) return
  b.turns++
  b.tokens += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0)
}

const fmtTokens = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'k' : String(n))
const fmtLimit = (n, f) => (n === Infinity ? 'no limit' : f(n))
const usedText = (b) =>
  b.turns + ' of ' + fmtLimit(b.lim.turns, String) + ' turns, ' + fmtTokens(b.tokens) + ' of ' + fmtLimit(b.lim.tokens, fmtTokens) + ' tokens'

// A builder's way out once its budget is full: factory-settle, factory-block
// or factory-ask run on their own, the task file and decisions.md, and its
// structured answer.
const EXIT_CMD = /^\s*([^\s]*\/)?factory-(settle|block|ask)(\.py|\.sh)?(\s|$)/
const EXIT_FILE = /^(\.\/)?(tasks\/.+\.md|decisions\.md)$/i

// The command with every quoted span emptied, or null when a span runs a
// command ($( ) or backticks inside double quotes) or a quote does not close.
function unquoted(c) {
  let out = ''
  let q = ''
  for (let i = 0; i < c.length; i++) {
    const ch = c[i]
    if (q === "'") {
      if (ch === "'") q = ''
      continue
    }
    if (q === '"') {
      if (ch === '\\') i++
      else if (ch === '"') q = ''
      else if (ch === '`' || (ch === '$' && c[i + 1] === '(')) return null
      continue
    }
    if (ch === '\\') {
      i++
      out += '_'
    } else if (ch === "'" || ch === '"') {
      q = ch
      out += '_'
    } else out += ch
  }
  return q ? null : out
}

function budgetExit(e) {
  // The structured answer is how the builder returns `budget` to the loop.
  if (e.tool === 'StructuredOutput') return true
  if (SHELL_TOOLS.has(e.tool)) {
    const bare = unquoted(String(e.command || ''))
    return bare !== null && EXIT_CMD.test(bare) && !/[;&|`<>\n]|\$\(/.test(bare)
  }
  if (FILE_TOOLS.has(e.tool) || e.tool === 'Read') {
    return EXIT_FILE.test(normalise(String(e.file_path || e.notebook_path || ''), root))
  }
  return false
}

// null, or what this call meets: a full budget (deny) or the 80% line (warn).
function budgetCheck(e) {
  const b = spent[e.agentId]
  if (!b || b.off) return null
  if (b.turns >= b.lim.turns || b.tokens >= b.lim.tokens) {
    if (budgetExit(e)) return null
    return {
      b,
      deny:
        'Factory budget full for ' + b.task + ': ' + usedText(b) + '. Stop working on the code. The way out: ' +
        '(1) add an entry to ## Attempts in the task file (### Attempt <n> - <UTC time> - budget: what you tried, what is left, what to rule out); ' +
        '(2) run, on its own: factory-settle ' + b.task + ' "budget: ' + b.turns + ' turns, ' + fmtTokens(b.tokens) + ' tokens"; ' +
        '(3) return status budget with the line it printed as settle. ' +
        'Only that is allowed now: factory-settle, factory-block or factory-ask run alone, and reading or editing the task file and decisions.md.',
    }
  }
  const warm = b.turns >= b.lim.turns * BUDGET_WARN || b.tokens >= b.lim.tokens * BUDGET_WARN
  if (b.warned || !warm) return null
  return {
    b,
    warn:
      'Factory budget: ' + b.task + ' has used ' + usedText(b) + ' (past 80%). Finish the smallest change that meets the acceptance criteria and run the check now. ' +
      'At the ceiling every call is refused but factory-settle, factory-block, factory-ask and the task file.',
  }
}

// Runs after the hard blocks found nothing. It never refuses on a failure of
// its own: an error here lets the call through.
async function withinBudget($, e, next) {
  let c = null
  try {
    c = budgetCheck(e)
  } catch {}
  if (c && c.deny) {
    if (!c.b.full) {
      c.b.full = true
      await budgetEvent($, c.b, 'full').catch(() => {})
    }
    return { deny: c.deny }
  }
  const r = await next(e)
  if (!c || !c.warn || !r || r.deny) return r
  try {
    c.b.warned = true
    await budgetEvent($, c.b, 'warn').catch(() => {})
    return { ...r, context: [...(r.context || []), c.warn] }
  } catch {
    return r
  }
}

async function budgetEvent($, b, level) {
  const now = await $.clock.now()
  const line = JSON.stringify({
    ts: new Date(now).toISOString().replace(/\.\d+Z$/, 'Z'),
    epoch: Math.floor(now / 1000),
    kind: 'budget',
    level,
    task: b.task,
    turns: b.turns,
    tokens: b.tokens,
    limit_turns: b.lim.turns === Infinity ? null : b.lim.turns,
    limit_tokens: b.lim.tokens === Infinity ? null : b.lim.tokens,
  })
  await $.process.run([await bashPath($), '-c', 'cat >> "$1"', 'sh', root + '/.factory/events.jsonl'], {
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
  const ready = await $.process.run([await bashPath($), $.plugin.root + '/bin/factory-plan', '--ready'], { cwd: root, timeoutMs: 15000 })
  const lines = ready.stdout.trim()
  out.push(lines || '(nothing ready or waiting)')
  const home = await homeDir($)
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
//
// The same algorithm as hooks/factory-hardblock.py, which the PreToolUse guard
// runs; tests/hardblock-cases.txt holds both to one list of cases.

// hard-blocks.txt writes [:space:] and [:alnum:]; JavaScript knows neither.
const js = (re) => re.replace(/\[:space:\]/g, '\\s').replace(/\[:alnum:\]/g, 'A-Za-z0-9')
// Letter case does not protect anything: macOS and Windows file systems ignore
// it, and so does their command lookup. Every rule is matched without it.
const rx = (re) => new RegExp(js(re), 'i')
const TERM = '([\\s;&|)"\'>]|$)'
const HARD = 'hard'
const SOFT = 'soft'
const READONLY = 'readonly'
// A call that may write a test file or test infrastructure. Which of those HEAD
// has and no task in progress may change is factory-hardblock.py's to say
// (factory-check's readonly_tests): this only spares the process for the calls
// that name nothing of the kind.
const TEST_HINT = /test|spec|conftest|pytest|jest|vitest|karma|mocharc|playwright|cypress|phpunit|workflows/i
// What writes, moves or removes a file. The short PowerShell and cmd aliases
// count only where one of those shells runs: in bash they are words of prose
// ("copy the key into .env").
const WRITE_SH =
  'tee|cp|mv|install|ln|rsync|truncate|touch|chmod|chown|dd|set-content|add-content|out-file|new-item|copy-item|move-item|rename-item|clear-content|(sed|perl)\\s+([^;&|]*\\s)?-[A-Za-z]*i'
const WRITE_PS = 'copy|move|ren|rni|cpi|mi|ni|sc|ac'
const DELETE_SH = 'rm|shred|unlink|remove-item|rmdir'
const DELETE_PS = 'ri|del|erase|rd'
const WINSHELL = /(^|[;&|(`"'\s/])(pwsh|powershell|cmd)(\.exe)?([\s;&|)"']|$)/i
// Inline code (python -c, node -e, a heredoc) that names a protected path and
// calls a write is refused - softly: it is a guess, so only the call is
// refused and the run goes on.
const INTERP = /(^|[;&|(`"'\s/])(python[0-9.]*|py|node|nodejs|deno|bun|perl|ruby|php|pwsh|powershell|osascript|cmd)(\.exe)?([\s;&|)"']|$)/i
const WRITEISH = new RegExp(
  'write|append|open\\s*\\([^)]*["\'][rwab]*[wax+]|open\\s*\\([^)]*["\'][+]?>|rename|unlink|remove|rmtree|shutil|fileutils|copy|move|mkdir|symlink|truncate|chmod|touch|put_contents|createwritestream|rmsync|delete|set-content|add-content|out-file|new-item|(^|[^A-Za-z0-9_])(del|erase|rd|ren|mklink)([^A-Za-z0-9_]|$)',
  'i',
)
// Commands that only read or print: their quoted free text is data, not a
// command, when nothing in the line runs code.
const DATA_CMD = /^(([^\s;&|<>()]*\/)?factory-[A-Za-z0-9_-]+(\.sh|\.py)?|echo|printf|grep|egrep|fgrep|rg|ag|ack|head|tail|wc|cut|cat|sort|true|false|:|test|\[)$/i
const HEREDOC_DATA = ['cat', 'tee']
const PLAN_START = /(^|[^A-Za-z0-9_.-])factory-plan(\.py)?([\s"'][^;&|]*)?\s["']?--start(["'\s;&|)]|$)/i
// Every way a command names the project root without spelling it.
const ROOT_VARS = /(\$\{PWD\}|\$PWD|\$\(pwd\)|`pwd`|~\+|\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR|\$\{env:CLAUDE_PROJECT_DIR\}|\$env:CLAUDE_PROJECT_DIR|\$\(get-location\)|\(get-location\))\//gi
// A backslash before a quote, $ or ` escapes it; it is never a folder separator.
const ESCAPED = /\\(?=["'$`])/g
const NOT_SEG = '/\\s;&|"\'<>=(),`'
const DOTDOT = new RegExp('(^|[' + NOT_SEG + '])(?!\\.\\.?/)[^' + NOT_SEG + ']+/\\.\\./', 'g')
const LITERAL_SEG = /^([A-Za-z0-9_-]|\\\.)+$/
const UP = '(\\./|(\\.\\./)+)?'

function pathRule(name, anchor, x, createOnly) {
  const X = js(x)
  const isRoot = anchor === 'root'
  const lead = isRoot ? UP : '([^\\s;&|"\']*/)?'
  const pre = isRoot ? '[\\s"\'=<>]' : '[\\s/"\'=<>]'
  const vlead = isRoot ? UP : ''
  const cache = new Map()
  return {
    name,
    anchor,
    x,
    createOnly,
    file: new RegExp((isRoot ? '^(\\./)?(' : '(^|/)(') + X + ')$', 'i'),
    redirect: new RegExp('>>?[|]?\\s*["\']?' + lead + '(' + X + ')' + TERM, 'i'),
    mention: new RegExp(
      isRoot
        ? '(^|[^A-Za-z0-9_./-])' + UP + '(' + X + ')([^A-Za-z0-9_./-]|$)'
        : '(^|[^A-Za-z0-9_.-])([^\\s;&|"\'()]*/)?(' + X + ')([^A-Za-z0-9_.-]|$)',
      'i',
    ),
    verb(verbs) {
      if (!cache.has(verbs)) cache.set(verbs, new RegExp('(^|[^A-Za-z0-9_.-])(' + verbs + ')\\s+([^;&|]*' + pre + ')?' + vlead + '(' + X + ')' + TERM, 'i'))
      return cache.get(verbs)
    },
  }
}

// A directory that holds protected files: writing into it, moving it or
// removing it reaches them without naming one.
function dirRule(anchor, x, full) {
  const r = pathRule('protected-dir', anchor, x, !full)
  const X = js(x)
  const isRoot = anchor === 'root'
  const pre = isRoot ? '[\\s"\'=<>]' : '[\\s/"\'=<>]'
  const vlead = isRoot ? UP : ''
  const cache = new Map()
  r.mention = new RegExp(
    isRoot
      ? '(^|[^A-Za-z0-9_./-])' + UP + '(' + X + ')/?([^A-Za-z0-9_./-]|$)'
      : '(^|[^A-Za-z0-9_.-])([^\\s;&|"\'()]*/)?(' + X + ')/?([^A-Za-z0-9_.-]|$)',
    'i',
  )
  r.verb = (verbs) => {
    if (!cache.has(verbs)) cache.set(verbs, new RegExp('(^|[^A-Za-z0-9_.-])(' + verbs + ')\\s+([^;&|]*' + pre + ')?' + vlead + '(' + X + ')(/(\\.|\\*)?)?' + TERM, 'i'))
    return cache.get(verbs)
  }
  return r
}

// The directories named by the literal start of the path rules:
// \.factory/verified/.* gives .factory and .factory/verified. A directory only
// create-only rules name is protected against writes, not removal.
function dirsOf(paths) {
  const out = new Map()
  for (const p of paths) {
    const segs = p.x.split('/')
    for (let k = 1; k < segs.length; k++) {
      if (!segs.slice(0, k).every((s) => LITERAL_SEG.test(s))) break
      const key = p.anchor + '\n' + segs.slice(0, k).join('/')
      out.set(key, (out.get(key) || false) || !p.createOnly)
    }
  }
  return [...out].map(([key, full]) => {
    const [anchor, d] = key.split('\n')
    return dirRule(anchor, d, full)
  })
}

// The tools a subagent may call while a factory is open, beside the ones
// judged below. Anything else - an MCP tool, a tool added after this list -
// is refused: what it does cannot be judged here.
const READ_ONLY_TOOLS = new Set([
  'Read', 'Grep', 'Glob', 'LS', 'NotebookRead', 'WebFetch', 'WebSearch', 'ToolSearch', 'StructuredOutput',
  'TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet', 'Skill',
  'ListMcpResourcesTool', 'ReadMcpResourceTool', 'ReadMcpResourceDirTool',
  // Starting or messaging an agent writes nothing; that agent's own calls are
  // judged here.
  'Agent', 'Task', 'TaskOutput', 'TaskStop', 'SendMessage',
])
const SHELL_TOOLS = new Set(['Bash', 'PowerShell'])
const FILE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])

async function loadRules($) {
  if (rules) return rules
  const text = await $.fs.read($.plugin.root + '/hooks/hard-blocks.txt')
  const out = { bash: [], path: [], groups: {} }
  // A checkout with CRLF line ends must not leave a CR at the end of every
  // rule: a regex ending in CR matches nothing.
  for (const line of text.split(/\r?\n/)) {
    const f = line.split(' ## ')
    if (f[0] === 'member' && f.length === 4 && f[2] !== 'deny') (out.groups[f[1]] = out.groups[f[1]] || []).push(f[3])
    if (f[0] === 'bash' && f.length === 3) out.bash.push({ name: f[1], re: rx(f[2]) })
    if (f[0] === 'path' && (f.length === 4 || f.length === 5)) out.path.push(pathRule(f[1], f[2], f[3], f[4] === 'create-only'))
  }
  if (!out.bash.length || !out.path.length) throw new Error('hard-blocks.txt holds no rules')
  rules = out
  return out
}

// --- one file, one spelling ---------------------------------------------------

// The ways Windows and its shells write one root: C:\p, C:/p, /c/p,
// /cygdrive/c/p. Matched without letter case.
function spellings(dir) {
  const r = String(dir || '').replace(/\\/g, '/').replace(/\/+$/, '')
  if (!r) return []
  const m = r.match(/^([A-Za-z]):(\/.*)?$/) || r.match(/^\/cygdrive\/([A-Za-z])(\/.*)?$/) || r.match(/^\/([A-Za-z])(\/.*)?$/)
  if (!m) return [r]
  const rest = m[2] || ''
  return [r, m[1] + ':' + rest, '/' + m[1] + rest, '/cygdrive/' + m[1] + rest]
}

function stripAll(t, prefix) {
  const lp = prefix.toLowerCase()
  let out = ''
  let low = t.toLowerCase()
  for (let i = low.indexOf(lp); i >= 0; i = low.indexOf(lp)) {
    out += t.slice(0, i)
    t = t.slice(i + prefix.length)
    low = low.slice(i + prefix.length)
  }
  return out + t
}

function collapse(t) {
  t = t.replace(/\/\/+/g, '/')
  while (t.includes('/./')) t = t.split('/./').join('/')
  for (;;) {
    const t2 = t.replace(DOTDOT, '$1')
    if (t2 === t) return t
    t = t2
  }
}

// \" is ", \ reads as / (Windows takes either), $PWD and its kin are the root,
// dir/../ is nothing, and the root is removed in every spelling - so no
// spelling of a protected path stays outside a root-relative rule.
function normalise(text, dir) {
  let t = collapse(String(text).replace(ESCAPED, '').replace(/\\/g, '/').replace(ROOT_VARS, ''))
  for (const r of spellings(dir)) t = stripAll(t, r + '/')
  return collapse(t)
}

// --- what in a bash command is data -------------------------------------------

// Words, commands, quoted spans, heredoc bodies and comments of a bash command,
// or null when its quoting does not close (bash would not run it).
function lex(t) {
  const n = t.length
  const words = []
  const spans = []
  const heredocs = []
  const comments = []
  const cmds = [[]]
  const pipes = [0]
  let active = false
  let complex = false
  let cur = null
  let target = false
  let pid = 0
  let pending = []
  const start = (at) => {
    if (cur === null) {
      cur = [at, at, '', target]
      target = false
    }
  }
  const end = (at) => {
    if (cur !== null) {
      cur[1] = at
      words.push(cur)
      cmds[cmds.length - 1].push(words.length - 1)
      cur = null
    }
  }
  const sep = (kind) => {
    if (kind === 'list') pid += 1
    cmds.push([])
    pipes.push(pid)
  }
  let i = 0
  while (i < n) {
    const c = t[i]
    if (c === '\\') {
      start(i)
      cur[2] += t.slice(i + 1, i + 2)
      i += 2
      continue
    }
    if (c === "'") {
      start(i)
      const j = t.indexOf("'", i + 1)
      if (j < 0) return null
      spans.push([i, j + 1, 'sq', t.slice(i + 1, j), words.length])
      cur[2] += t.slice(i + 1, j)
      i = j + 1
      continue
    }
    if (c === '$' && t[i + 1] === "'") {
      start(i)
      let j = i + 2
      while (j < n && t[j] !== "'") j += t[j] === '\\' ? 2 : 1
      if (j >= n) return null
      spans.push([i, j + 1, 'ansi', t.slice(i + 2, j), words.length])
      cur[2] += t.slice(i + 2, j)
      i = j + 1
      continue
    }
    if (c === '"') {
      start(i)
      let j = i + 1
      while (j < n && t[j] !== '"') {
        if (t[j] === '\\') {
          j += 2
          continue
        }
        if (t[j] === '`' || t.startsWith('$(', j)) active = true
        j += 1
      }
      if (j >= n) return null
      spans.push([i, j + 1, 'dq', t.slice(i + 1, j), words.length])
      cur[2] += t.slice(i + 1, j).replace(/\\(["\\$`])/g, '$1')
      i = j + 1
      continue
    }
    if (c === '`' || t.startsWith('$(', i)) {
      active = true
      start(i)
      cur[2] += c
      i += 1
      continue
    }
    if (c === ' ' || c === '\t' || c === '\r') {
      end(i)
      i += 1
      continue
    }
    if (c === '#' && cur === null) {
      let j = t.indexOf('\n', i)
      if (j < 0) j = n
      comments.push([i, j])
      i = j
      continue
    }
    if (c === '\n') {
      end(i)
      i += 1
      for (const h of pending) {
        h.s = i
        for (;;) {
          const e = t.indexOf('\n', i)
          const le = e < 0 ? n : e
          const line = t.slice(i, le)
          if ((h.strip ? line.replace(/^\t+/, '') : line) === h.delim) {
            h.e = i
            i = Math.min(le + 1, n)
            break
          }
          if (e < 0) {
            h.e = n
            i = n
            break
          }
          i = e + 1
        }
        if (!h.quoted && /\$\(|`/.test(t.slice(h.s, h.e))) active = true
        heredocs.push(h)
      }
      pending = []
      sep('list')
      continue
    }
    if (c === ';' || c === '&' || c === '|') {
      end(i)
      const two = t.slice(i, i + 2)
      if (two === '&&' || two === '||' || two === ';;') {
        i += 2
        sep('list')
        continue
      }
      if (two === '|&') {
        i += 2
        sep('pipe')
        continue
      }
      if (two === '&>') {
        i += t[i + 2] === '>' ? 3 : 2
        target = true
        continue
      }
      i += 1
      sep(c === '|' ? 'pipe' : 'list')
      continue
    }
    if (c === '(' || c === ')') {
      end(i)
      complex = true
      i += 1
      sep('list')
      continue
    }
    if (c === '<' || c === '>') {
      if (cur !== null && /^[0-9]+$/.test(t.slice(cur[0], i))) cur = null
      else end(i)
      if (t.startsWith('<<', i) && !t.startsWith('<<<', i)) {
        let j = i + 2
        const strip = t[j] === '-'
        if (strip) j += 1
        while (j < n && (t[j] === ' ' || t[j] === '\t')) j += 1
        let k = j
        let delim = ''
        let quoted = false
        while (k < n && !' \t\n;&|<>()'.includes(t[k])) {
          if (t[k] === "'" || t[k] === '"') {
            const e = t.indexOf(t[k], k + 1)
            if (e < 0) return null
            delim += t.slice(k + 1, e)
            quoted = true
            k = e + 1
          } else if (t[k] === '\\') {
            delim += t.slice(k + 1, k + 2)
            quoted = true
            k += 2
          } else {
            delim += t[k]
            k += 1
          }
        }
        pending.push({ cmd: cmds.length - 1, delim, quoted, strip, s: n, e: n })
        i = k
        continue
      }
      if (t.startsWith('<(', i) || t.startsWith('>(', i)) {
        active = complex = true
        i += 1
        continue
      }
      let j = i + 1
      while (j < n && '<>&|'.includes(t[j])) j += 1
      i = j
      if (t[j - 1] === '&') {
        const m = t.slice(j).match(/^([0-9]+|-)/)
        if (m) {
          i = j + m[0].length
          continue
        }
      }
      target = true
      continue
    }
    start(i)
    cur[2] += c
    i += 1
  }
  end(n)
  for (const h of pending) heredocs.push(h)
  return { words, spans, heredocs, comments, cmds, pipes, active, complex }
}

const namesOf = (lx, ws) => ws.filter((w) => !lx.words[w][3]).map((w) => lx.words[w][2])

function isData(names) {
  if (!names.length) return true
  const first = names[0].toLowerCase()
  if (DATA_CMD.test(names[0])) {
    if (first === 'sort' && names.slice(1).some((x) => /^(-[A-Za-z]*o|--output)/.test(x))) return false
    return true
  }
  if (first === 'git' && names.length > 1 && ['grep', 'log'].includes(names[1].toLowerCase())) {
    return !names.slice(2).some((x) => x.startsWith('-O') || x.toLowerCase().startsWith('--open-files'))
  }
  return false
}

function applyEdits(t, edits) {
  let out = ''
  let at = 0
  for (const [s, e, rep] of [...edits].sort((a, b) => a[0] - b[0] || a[1] - b[1])) {
    if (s < at) continue
    out += t.slice(at, s) + rep
    at = e
  }
  return out + t.slice(at)
}

// The command as it is, with what is only data taken out, and the same with
// the quotes of single words dropped (g''it "push" is git push). A rule that
// matches either is hit.
function variants(t) {
  const lx = lex(t)
  if (!lx) return [t]
  const edits = []
  if (!lx.active) for (const [s, e] of lx.comments) edits.push([s, e, ''])
  let keptBodies = 0
  for (const h of lx.heredocs) {
    const alone = lx.pipes.filter((p) => p === lx.pipes[h.cmd]).length === 1
    const names = namesOf(lx, lx.cmds[h.cmd])
    if (!lx.active && alone && names.length && HEREDOC_DATA.includes(names[0].toLowerCase())) edits.push([h.s, h.e, ''])
    else keptBodies += 1
  }
  if (!lx.active && !lx.complex && !keptBodies) {
    const all = lx.cmds.flatMap((ws) => namesOf(lx, ws))
    if (lx.cmds.every((ws) => isData(namesOf(lx, ws))) && !all.some((x) => /^--(pre|output)/i.test(x))) {
      for (const [s, e, , inner, wi] of lx.spans) if (/\s/.test(inner) && !lx.words[wi][3]) edits.push([s, e, "''"])
    }
  }
  const a = applyEdits(t, edits)
  const deq = [...edits]
  for (const [s, e, kind, inner] of lx.spans) {
    if (kind !== 'ansi' && !/\s/.test(inner) && !edits.some(([ts, te]) => s < te && ts < e)) deq.push([s, e, inner])
  }
  const b = applyEdits(t, deq)
  return b === a ? [a] : [a, b]
}

// The optional bans this project allows (config.json hard_blocks.allow): the
// rule names of those groups. Read on every call, so /factory:bans takes effect
// without a restart; a config that cannot be read lifts nothing.
async function lifted($, r) {
  try {
    const cfg = JSON.parse(await $.fs.read(root + '/.factory/config.json'))
    const allow = cfg && cfg.hard_blocks && Array.isArray(cfg.hard_blocks.allow) ? cfg.hard_blocks.allow : []
    return new Set(allow.flatMap((g) => r.groups[g] || []))
  } catch {
    return new Set()
  }
}

function judgeText(kind, text, dir, r) {
  if (kind === 'bash' || kind === 'powershell') {
    const t = String(text).replace(/\\\n/g, '')
    const vs = (kind === 'bash' ? variants(t) : [t]).map((v) => normalise(v, dir).replace(/\n/g, ';'))
    const winsh = kind === 'powershell' || vs.some((v) => WINSHELL.test(v))
    const wv = WRITE_SH + (winsh ? '|' + WRITE_PS : '')
    const dv = DELETE_SH + (winsh ? '|' + DELETE_PS : '')
    for (const b of r.bash) if (vs.some((v) => b.re.test(v))) return { rule: b.name, level: HARD }
    const all = [...r.path, ...dirsOf(r.path)]
    for (const p of all) {
      const verb = p.verb(p.createOnly ? wv : wv + '|' + dv)
      if (vs.some((v) => p.redirect.test(v) || verb.test(v))) return { rule: p.name, level: HARD }
    }
    const inline = (kind === 'powershell' || vs.some((v) => INTERP.test(v))) && vs.some((v) => WRITEISH.test(v))
    if (inline) for (const p of all) if (vs.some((v) => p.mention.test(v))) return { rule: p.name, level: SOFT }
    return null
  }
  const file = normalise(text, dir)
  if (!file) return null
  for (const p of r.path) if (p.file.test(file)) return { rule: p.name, level: HARD }
  return null
}

async function judge($, e) {
  if (!root) root = await $.session.root()
  if (!(await $.fs.exists(root + '/.factory/active'))) return null
  if (READ_ONLY_TOOLS.has(e.tool)) return null
  const loaded = await loadRules($)
  const off = await lifted($, loaded)
  const r = off.size
    ? { ...loaded, bash: loaded.bash.filter((b) => !off.has(b.name)), path: loaded.path.filter((p) => !off.has(p.name)) }
    : loaded
  if (SHELL_TOOLS.has(e.tool)) {
    // A run's starting point - the board snapshot that anchors every approval,
    // the digest of the gate - is recorded once, by the workflow's runner. A
    // builder that ran it again mid-run would re-anchor what it changed.
    const a = agents[e.agentId]
    if (a && a.type && !/(^|:)runner$/.test(a.type) && PLAN_START.test(String(e.command || ''))) {
      return { rule: 'plan-start', level: HARD, why: 'only the run itself records where it starts (factory-plan --start)' }
    }
    const kind = e.tool === 'PowerShell' ? 'powershell' : 'bash'
    return judgeText(kind, String(e.command || ''), root, r) || (await headTests($, kind, String(e.command || '')))
  }
  if (FILE_TOOLS.has(e.tool)) {
    const file = String(e.file_path || e.notebook_path || '')
    return judgeText('path', file, root, r) || (await headTests($, 'path', file))
  }
  return {
    rule: 'unjudged-tool',
    why: 'a subagent of a factory run may only use tools the factory can judge, and ' + String(e.tool) + ' is not one of them',
  }
}

// A write to a test HEAD has that no task in progress may change. This guard
// refuses one call and never halts the run, so a failure to decide lets the
// call through: the PreToolUse hook asks the same question again.
async function headTests($, kind, text) {
  if (!text || !TEST_HINT.test(text)) return null
  try {
    const res = await $.process.run([await bashPath($), $.plugin.root + '/hooks/factory-hardblock.sh', 'tests', root, kind], {
      cwd: root,
      stdin: text,
      timeoutMs: 15000,
    })
    if (res.exitCode !== 6) return null
    return { rule: 'head-tests', level: READONLY, path: String(res.stdout || '').trim().replace(/^head-tests /, '') }
  } catch {
    return null
  }
}

// The breaker: STOP, an event, a notification - all in factory-hardblock.sh.
async function trip($, e, hit) {
  if (!root) return
  await $.process.run(
    [await bashPath($), $.plugin.root + '/hooks/factory-hardblock.sh', 'trip', root, hit.rule, String(e.tool), String(e.agentId || '')],
    { cwd: root, timeoutMs: 10000 },
  )
}

// --- delivery ---------------------------------------------------------------

const QUOTA_MARGIN = 10
const STEP = { new: 'starting', classified: 'push', pushed: 'PR', pr_open: 'CI', checks_green: 'merge', merged: 'sync', main_ci: 'main CI', done: 'merged', pr_only: 'PR open', reverted: 'REVERTED' }

// "C2 CI, C3 held" from .factory/publish/*.json; terminal ones that are merged
// quietly drop off, a revert and a PR waiting for a person stay.
async function publishLine($) {
  const dir = root + '/.factory/publish'
  if (!(await $.fs.exists(dir))) return ''
  const out = []
  for (const f of await $.fs.list(dir)) {
    if (f.kind !== 'file' || !f.name.endsWith('.json')) continue
    try {
      const st = JSON.parse(await $.fs.read(dir + '/' + f.name))
      if (st.state === 'done' || st.state === 'abandoned') continue
      out.push(st.change + ' ' + (st.held ? 'held' : STEP[st.state] || st.state))
    } catch {}
  }
  return out.join(', ')
}

// The shell every script of the plugin is written for. On Windows a bare
// "bash" can resolve to WSL's launcher in System32, and "sh" is often not on
// PATH at all: the Git Bash Claude Code itself uses is the one to run.
async function bashPath($) {
  if (bashExe) return bashExe
  let p = ''
  try {
    p = (await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) || ''
  } catch {}
  if (!p && /^[A-Za-z]:[\\/]/.test(String($.plugin.root || ''))) {
    let local = ''
    try {
      local = (await $.env.get('LOCALAPPDATA')) || ''
    } catch {}
    const tries = ['C:/Program Files/Git/bin/bash.exe', 'C:/Program Files (x86)/Git/bin/bash.exe']
    if (local) tries.push(local.replace(/\\/g, '/') + '/Programs/Git/bin/bash.exe')
    for (const c of tries) {
      try {
        if (await $.fs.exists(c)) {
          p = c
          break
        }
      } catch {}
    }
  }
  bashExe = p || 'bash'
  return bashExe
}

// HOME is not always set for a native Windows process; USERPROFILE is.
async function homeDir($) {
  const h = (await $.env.get('HOME')) || (await $.env.get('USERPROFILE')) || ''
  return h.replace(/\\/g, '/')
}

async function quotaGate($, e) {
  if (e.subagentType !== 'factory:builder') return null
  if (!root) root = await $.session.root()
  if (band.level !== 'merge' || !(await $.fs.exists(root + '/.factory/active'))) return null
  const usage = await $.session.usage()
  const week = (usage.rateLimits || []).find((w) => w.kind === 'seven_day')
  if (!week || !week.resetsAt || typeof week.percentUsed !== 'number') return null
  const now = await $.clock.now()
  const left = Date.parse(week.resetsAt) - now
  const elapsed = Math.max(0, Math.min(1, 1 - left / WEEK_MS)) * 100
  if (week.percentUsed <= elapsed + QUOTA_MARGIN) return null
  return (
    'Factory quota breaker: the 7-day window is at ' + Math.round(week.percentUsed) + '%, past the even-spend line ' +
    Math.round(elapsed) + '% + ' + QUOTA_MARGIN + ' points, and the level is merge. No new builder starts; ' +
    'finish what is running and stop. The window resets ' + week.resetsAt + '.'
  )
}

// --- autonomy ---------------------------------------------------------------

async function runConsent($, prompt, origin) {
  const sid = await $.session.id()
  await $.process.run([await bashPath($), $.plugin.root + '/hooks/factory-consent.sh'], {
    cwd: root,
    stdin: JSON.stringify({ prompt, cwd: root, session_id: sid, origin }),
    timeoutMs: 10000,
  })
}

// The band's picture of the level comes from the reader, which re-checks the
// consent against the transcript; the band never believes the file itself.
async function refreshBand($) {
  if (!root || !(await $.fs.exists(root + '/.factory/active'))) return
  const r = await $.process.run([await bashPath($), $.plugin.root + '/hooks/factory-autonomy.sh'], { cwd: root, timeoutMs: 8000 })
  const level = r.stdout.trim()
  const stopped = await $.fs.exists(root + '/.factory/STOP')
  const next = { level: ['pr', 'merge'].includes(level) ? level : 'local', stopped, publish: await publishLine($) }
  if (next.level !== band.level || next.stopped !== band.stopped || next.publish !== band.publish) {
    band = next
    $.ui.invalidate('ui.render')
  }
}
