export const meta = {
  name: 'loop',
  description: 'Factory loop: one fresh builder per approved task, a deterministic check and settle per task, one full check at the end',
  whenToUse: 'Started by /factory:run with the plan factory-preflight printed; typed by itself it runs the preflight first',
  phases: [
    { title: 'Plan', detail: 'the plan /factory:run passed, or factory-preflight when there is none' },
    { title: 'Build', detail: 'one builder per task: start, implement, check, settle' },
    { title: 'Finish', detail: 'one full check, acceptance and delivery; the audit alongside' },
  ],
}

// The model decides in four places: the builder, the reviewer, the auditor and
// the retro. Everything else is a script, and this file is only the schedule:
// which task starts when, and what to do with the line a script printed.
//
// What happened to a task is decided on disk. A builder ends with
// factory-settle, which lands it, sends it to review, records an attempt or
// blocks it; the builder only reports the line settle printed. When a builder
// did not settle, a runner does - so a builder's account of its own work never
// moves the board.
//
// args: the plan factory-preflight printed - { ok, tasks: [{id, deps, review, area?}],
// workers, attempts, risk_review, audit, start_head, change, effort, owed,
// area_lease, monitor, ... }.
// Without one (the workflow typed by itself), a runner runs the preflight.
//
// An agent that comes back with nothing is infrastructure, not the task: in
// `claude -p` a usage limit ends the agent instead of pausing it. The same task
// is tried once more; a second empty answer halts the run - no new task
// starts, nothing is blocked, and the next /factory:run continues from the same
// base.

const LINE = {
  type: 'object',
  required: ['ok', 'line'],
  properties: { ok: { type: 'boolean' }, line: { type: 'string' }, report: { type: 'string' } },
}

const RESULT = {
  type: 'object',
  required: ['id', 'status', 'summary', 'settle', 'concerns'],
  properties: {
    id: { type: 'string' },
    status: {
      type: 'string',
      enum: ['landed', 'review', 'waiting', 'red', 'no_progress', 'blocked', 'halted', 'error', 'spec_conflict', 'refused', 'budget'],
    },
    summary: { type: 'string' },
    settle: { type: 'string' },
    concerns: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const REVIEWED = {
  type: 'object',
  required: ['line', 'findings'],
  properties: {
    line: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string' },
          confidence: { type: 'number' },
          file: { type: 'string' },
          line: { type: 'number' },
          quote: { type: 'string' },
          category: { type: 'string' },
          what: { type: 'string' },
          fix: { type: 'string' },
        },
      },
    },
  },
}

const MONITORED = {
  type: 'object',
  required: ['line'],
  properties: {
    line: { type: 'string' },
    verdict: { type: 'string', enum: ['cheat', 'clear'] },
    evidence: {
      type: 'array',
      items: { type: 'object', properties: { file: { type: 'string' }, line: { type: 'number' }, quote: { type: 'string' }, why: { type: 'string' } } },
    },
  },
}

const AUDIT = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['severity', 'what'],
        properties: { severity: { type: 'string', enum: ['high', 'medium', 'low'] }, where: { type: 'string' }, what: { type: 'string' }, fix: { type: 'string' } },
      },
    },
    delivery: { type: 'string' },
  },
}

const RUNNER = 'factory:runner'
const shq = s => "'" + String(s).replace(/'/g, "'\\''") + "'"
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.floor(Number(v) || lo)))
const changeOf = id => (/^(C[0-9]+)-/.exec(id) || [null, 'C1'])[1]

let opts = args
if (typeof opts === 'string') {
  try {
    opts = JSON.parse(opts)
  } catch {
    opts = {}
  }
}
opts = opts && typeof opts === 'object' ? opts : {}

// --- the plan ---------------------------------------------------------------
let plan = Array.isArray(opts.tasks) ? opts : null
if (!plan) {
  phase('Plan')
  const p = await agent(
    'From the project root, run exactly: factory-preflight --json' + (opts.change ? ' --change ' + shq(opts.change) : '') +
      '\nIt prints one JSON object on one line. Return ok = its "ok" field, line = that whole line, verbatim, and report = "".',
    { agentType: RUNNER, label: 'preflight', phase: 'Plan', schema: LINE },
  )
  if (!p) return { line: 'LOOP HALTED: infra - the preflight returned nothing; run /factory:run again', halted: 'infra' }
  try {
    plan = JSON.parse(p.line.slice(p.line.indexOf('{')))
  } catch {
    return { line: 'LOOP STOPPED: the preflight printed no plan', detail: String(p.line).slice(0, 300) }
  }
}
if (!plan.ok) return { line: 'LOOP STOPPED: ' + (plan.problems || ['the board is not ready']).join('; '), problems: plan.problems || [] }
for (const w of plan.warnings || []) log('warning: ' + w)
for (const n of plan.notes || []) log(n)

const E = Object.assign({ build: 'medium', escalate: 'high', review: 'high', audit: 'high' }, plan.effort || {}, opts.effort || {})
const ATTEMPTS = clamp(plan.attempts || 2, 1, 4)
const WORKERS = clamp(opts.workers || plan.workers || 4, 1, 8)
const tasks = plan.tasks || []
const AREA_LEASE = plan.area_lease === true || opts.area_lease === true
const owed = (plan.owed || []).filter(id => typeof id === 'string')
if (!tasks.length && !owed.length) return { line: 'LOOP: nothing to build', held: (plan.held || []).map(h => h.id + ' ' + h.reason) }
log(`${tasks.length} task(s), ${WORKERS} at a time, ${ATTEMPTS} attempt(s) each; ${(plan.held || []).length} held` +
  (plan.chain ? `; longest chain ${plan.chain}, widest level ${plan.width}` : ''))

// --- slots: at most WORKERS agents of this run at once ------------------------
// A builder that was queued when the run halted never starts: the check is made
// when its slot opens, not when it was queued.
let open = 0
const queue = []
let halted = null
function pump() {
  while (open < WORKERS && queue.length) {
    const { fn, resolve, gated } = queue.shift()
    if (gated && halted) {
      resolve({ halted: true })
      continue
    }
    open++
    Promise.resolve()
      .then(fn)
      .then(resolve, () => resolve(null))
      .then(() => {
        open--
        pump()
      })
  }
}
const slot = (fn, gated) => new Promise(resolve => {
  queue.push({ fn, resolve, gated })
  pump()
})
function halt(why) {
  if (!halted) {
    halted = why || 'halted'
    log('halted: ' + halted + ' - no new task starts')
  }
  progressed()
}

const run1 = (prompt, label) => slot(() => agent(prompt, { agentType: RUNNER, label, phase: 'Build', schema: LINE }), false)

// --- areas: with fast.area_lease, one task of an area builds at a time ------
// Builders share one working tree, and a task's commit takes exactly its listed
// files: two tasks working in the same part of the code at once overwrite each
// other's fixes, and one lands the other's half-done edit. A task holds its
// area from its first builder until it settles - landed, blocked or halted -
// and the next task of that area starts then. A task with no area holds none.
const leases = new Map()
async function lease(t) {
  const area = AREA_LEASE && t.area ? String(t.area) : null
  if (!area) return null
  let told = false
  while (leases.has(area)) {
    if (!told) {
      log(`${t.id}: waits for area ${area}, which ${leases.get(area).holder} is working in`)
      told = true
    }
    await new Promise(r => leases.get(area).waiting.push(r))
  }
  leases.set(area, { holder: t.id, waiting: [] })
  return area
}
function unlease(area) {
  if (!area) return
  const l = leases.get(area)
  leases.delete(area)
  for (const r of (l && l.waiting) || []) r()
}

// --- progress: who is building, who has finished ----------------------------
let building = 0
let finishes = 0
const finished = new Set()
let waiters = []
function progressed() {
  const w = waiters
  waiters = []
  for (const f of w) if (!f()) waiters.push(f)
}
// Resolves when a task this one waits on has finished since `seen`, or - when
// it is not known which - any task has, or when nothing else is building.
function nextEvent(on, seen, seenCount) {
  return new Promise(resolve => {
    const ready = () => {
      const moved = on.length ? on.some(id => finished.has(id) && !seen.has(id)) : finishes > seenCount
      if (halted || building === 0 || moved) {
        resolve()
        return true
      }
      return false
    }
    if (!ready()) waiters.push(ready)
  })
}

// --- what a settle line says ------------------------------------------------
function verdict(text) {
  const lines = String(text || '').split('\n').filter(l => /SETTLED \S+ /.test(l))
  const m = /SETTLED (\S+) (LANDED|REVIEW|WAITING|RETRY|BLOCKED|UNCOMMITTED|HALTED|REFUSED)\b:?\s*(.*)$/.exec(lines.pop() || '')
  return m ? { kind: m[2], rest: m[3].trim(), line: m[0] } : null
}

// The builder did not settle (or its line was lost): a runner settles, so the
// disk decides, not the builder's word. A builder whose budget ran out is
// settled as an attempt that ended on its budget.
async function settleBy(t, r) {
  const said = (r && r.summary) || 'the builder did not settle'
  const why = shq((r && r.status === 'budget' && !/^budget\b/i.test(said) ? 'budget: ' + said : said).slice(0, 300))
  const how = r && r.status === 'refused' ? `--refused ${why}` : r && r.status === 'spec_conflict' ? `--conflict ${why}` : why
  const s = await run1(
    `From the project root run exactly, with a 10-minute Bash timeout (with fast.isolation it checks the project tree again): factory-settle ${t.id} ${how}\nReturn ok=true if its last line starts with SETTLED, and that last line.`,
    t.id + ' settle',
  )
  return s ? verdict(s.line) : null
}

function buildPrompt(t, previous, findings, attempt, owner) {
  const lines = [
    'Build one factory task, following your instructions: start it, implement it, check it, and end with factory-settle.',
    'Put the last line factory-settle printed, verbatim, in `settle`.',
  ]
  if (previous) {
    lines.push(`This is attempt ${attempt}. The one before it ended "${previous.status}": ${previous.summary}${previous.notes ? ' (' + previous.notes + ')' : ''}.`)
    lines.push('Read ## Attempts in the task file first and do not repeat an approach it already ruled out.')
    if (previous.status === 'budget') lines.push('It used up its turn and token budget: take the smallest change that meets the criteria, and check early.')
  }
  if (findings && findings.length) {
    lines.push('A reviewer failed the change with these findings (the ## Review section of the task file has them too). Fix exactly these, run the check, and settle:')
    for (const f of findings) lines.push('- ' + f)
  }
  lines.push(`Task: ${t.id}   Owner: ${owner}`)
  return lines.join('\n')
}

function reviewPrompt(t, landed) {
  return [
    'Review one factory task, following your instructions, and submit your findings with factory-review-submit.',
    'Put the last line factory-review-submit printed, verbatim, in `line`, and your findings in `findings`.',
    landed
      ? `The task has landed: read its commit (git log -1 --format=%H --grep '^Factory-Task: ${t.id}$') and submit with --landed.`
      : 'The task is green in tasks/in-progress and not committed: read the diff of its "## Files touched".',
    `Task: ${t.id}`,
  ].join('\n')
}

const reviewer = (t, landed) =>
  slot(() => agent(reviewPrompt(t, landed), { agentType: 'factory:reviewer', effort: E.review, schema: REVIEWED, label: `${t.id} review`, phase: 'Build' }), true)

// review.monitor: the check left a cheat-type reason (settle says REVIEW
// MONITOR). One narrow question goes first, to a fresh agent: does this diff
// make the checks pass without doing what the task asks? A cheat verdict blocks
// the task and asks the developer (factory-monitor-submit) - it is never handed
// back to a builder as a target to work around. Anything else goes on to the
// reviewer as usual.
function monitorPrompt(t) {
  return [
    'Monitor one factory task, following your instructions, and submit your verdict with factory-monitor-submit.',
    'Put the last line factory-monitor-submit printed, verbatim, in `line`, and your verdict and evidence in `verdict` and `evidence`.',
    'The task is green in tasks/in-progress and not committed: read the diff of its "## Files touched".',
    `Task: ${t.id}`,
  ].join('\n')
}
const monitor = t =>
  slot(() => agent(monitorPrompt(t), { agentType: 'factory:monitor', effort: E.review, schema: MONITORED, label: `${t.id} monitor`, phase: 'Build' }), true)

const postReviews = []
const haltedTask = t => ({ id: t.id, status: 'halted', summary: halted || 'halted' })

async function buildTask(t) {
  if (halted) return haltedTask(t)
  const area = await lease(t)
  if (halted) {
    unlease(area)
    return haltedTask(t)
  }
  building++
  try {
    return await buildInner(t)
  } finally {
    building--
    unlease(area)
    finished.add(t.id)
    finishes++
    progressed()
  }
}

async function buildInner(t) {
  let previous = null
  let findings = null
  let attempt = 1
  let nulls = 0
  for (let guard = 0; guard < ATTEMPTS + 6; guard++) {
    const escalate = attempt > 1 || findings
    const label = findings ? `${t.id} fix` : attempt === 1 ? t.id : attempt === 2 ? `${t.id} retry` : `${t.id} retry ${attempt - 1}`
    const prompt = buildPrompt(t, previous, findings, attempt, attempt === 1 && !findings ? 'builder' : 'builder-retry')
    const r = await slot(() => agent(prompt, { agentType: 'factory:builder', effort: escalate ? E.escalate : E.build, schema: RESULT, label, phase: 'Build' }), true)
    if (r && r.halted === true) return haltedTask(t)
    if (!r) {
      nulls++
      if (nulls >= 2) {
        halt('infra - two builders of ' + t.id + ' returned nothing (a usage limit, or the API)')
        return { id: t.id, status: 'halted', summary: 'infra' }
      }
      log(`${t.id}: the builder returned nothing - the same attempt once more`)
      continue
    }
    if (r.status === 'halted' && !verdict(r.settle)) {
      halt(r.summary || '.factory/STOP is set')
      return { id: t.id, status: 'halted', summary: r.summary }
    }
    let v = verdict(r.settle)
    if (!v) v = await settleBy(t, r)
    if (!v) {
      halt('infra - ' + t.id + ' could not be settled')
      return { id: t.id, status: 'halted', summary: 'infra' }
    }
    findings = null
    const base = { id: t.id, concerns: r.concerns || [], notes: r.notes || undefined }

    if (v.kind === 'WAITING') {
      v = await waitFor(t, v)
      if (!v) return haltedTask(t)
    }
    switch (v.kind) {
      case 'LANDED':
        if (/REVIEW-AFTER/.test(v.rest)) postReviews.push(reviewer(t, true))
        return Object.assign(base, { status: 'landed', summary: v.line })
      case 'REVIEW': {
        if (/^MONITOR\b/.test(v.rest)) {
          const mv = await monitor(t)
          if (mv && mv.halted === true) return haltedTask(t)
          const ml = (mv && mv.line) || ''
          if (/^MONITOR CHEAT/.test(ml)) return Object.assign(base, { status: 'blocked', summary: ml })
          log(`${t.id}: ${/^MONITOR CLEAR/.test(ml) ? 'the monitor found no cheat' : 'the monitor gave no verdict'} - the review goes ahead`)
        }
        const rv = await reviewer(t, false)
        if (rv && rv.halted === true) return haltedTask(t)
        const line = (rv && rv.line) || ''
        if (/^REVIEW PASS/.test(line)) {
          const status = /LANDED|LAND SKIPPED/.test(line) ? 'landed' : /LAND UNCOMMITTED/.test(line) ? 'blocked' : 'error'
          return Object.assign(base, { status, summary: line })
        }
        if (/^REVIEW FAIL \S+ BLOCKED/.test(line)) return Object.assign(base, { status: 'blocked', summary: line })
        if (/^REVIEW FAIL/.test(line)) {
          findings = (rv.findings || []).map(f => `[${f.severity || '?'}] ${f.file || '?'}${f.line ? ':' + f.line : ''} ${f.what || ''}${f.fix ? ' -> ' + f.fix : ''}`)
          if (!findings.length) findings = [line]
          log(`${t.id}: review failed - a fresh builder fixes the findings`)
          continue
        }
        // No verdict was submitted: the task stays green in tasks/in-progress,
        // and the next run reviews it again. Nothing is blocked on a guess.
        return Object.assign(base, { status: 'review_missing', summary: 'the reviewer submitted no verdict' + (line ? ': ' + line : '') })
      }
      case 'RETRY':
        previous = { status: r.status, summary: v.rest || r.summary, notes: r.notes }
        attempt++
        log(`${t.id}: ${v.rest} - attempt ${attempt} at ${E.escalate} effort`)
        continue
      case 'BLOCKED':
        return Object.assign(base, { status: 'blocked', summary: v.rest })
      case 'UNCOMMITTED':
        return Object.assign(base, { status: 'blocked', summary: 'done, but its commit was refused - what depends on it cannot start: ' + v.rest })
      case 'HALTED':
        halt(v.rest)
        return Object.assign(base, { status: 'halted', summary: v.rest })
      case 'REFUSED':
        return Object.assign(base, { status: 'refused', summary: v.rest })
    }
  }
  return { id: t.id, status: 'error', summary: 'settle never ended the task' }
}

// The builder's work is done; its check only failed on another task's files.
// Nobody is kept alive while it waits: one runner re-checks it when a task it
// waits on has settled, or when nothing else is building.
async function waitFor(t, v) {
  for (let round = 0; round < 4; round++) {
    const on = v.rest.replace(/^on\s+/, '').split(',').map(s => s.trim()).filter(id => byId.has(id))
    const seen = new Set(on.filter(id => finished.has(id)))
    const count = finishes
    building--
    progressed()
    await nextEvent(on, seen, count)
    building++
    if (halted) return null
    const alone = building === 1
    const c = await run1(
      `From the project root run: factory-check ${t.id} ; factory-settle ${t.id}${alone ? ' --no-wait' : ''} ${shq('re-checked after a wait')}   (a 10-minute Bash timeout)\n` +
        'Return ok=true if the last line starts with SETTLED, and that last line.',
      t.id + ' recheck',
    )
    const next = c ? verdict(c.line) : null
    if (!next) {
      halt('infra - the re-check of ' + t.id + ' returned nothing')
      return null
    }
    if (next.kind !== 'WAITING') return next
    v = next
  }
  return { kind: 'BLOCKED', rest: 'still waiting on work in flight after four re-checks', line: '' }
}

// --- the dependency graph: each task starts the moment its last dependency lands
phase('Build')
const byId = new Map(tasks.map(t => [t.id, t]))
for (const id of owed) postReviews.push(reviewer({ id }, true))
const started = new Map()
function schedule(id) {
  if (started.has(id)) return started.get(id)
  const t = byId.get(id)
  const p = Promise.all(t.deps.filter(d => byId.has(d)).map(schedule)).then(deps => {
    const bad = deps.find(d => !d || d.status !== 'landed')
    if (halted) return haltedTask(t)
    if (bad) return { id, status: 'skipped', summary: `waits on ${bad.id}, which ended ${bad.status}` }
    return buildTask(t)
  })
  started.set(id, p)
  return p
}
const results = (await Promise.all(tasks.map(t => schedule(t.id)))).map((r, i) => r || { id: tasks[i].id, status: 'error', summary: 'no result' })
const landed = results.filter(r => r.status === 'landed').length
log(`${landed}/${tasks.length} landed`)

// Reviews of what landed first finish before the end: a failed one holds the
// change's delivery, and the report reads it from .factory/reviews/.
if (postReviews.length) {
  const verdicts = await Promise.all(postReviews)
  log(`${verdicts.filter(v => v && /^REVIEW PASS/.test(v.line || '')).length}/${postReviews.length} after-landing reviews passed`)
}

// --- finish: the whole tree once, the audit alongside -----------------------
phase('Finish')
const ids = tasks.map(t => t.id)
const changes = [...new Set(ids.map(changeOf))]
const auditing = landed >= 2 && plan.audit !== false && opts.audit !== false && !!plan.start_head && !halted
const [fin, audit] = await Promise.all([
  agent(
    `From the project root run exactly: factory-finish --tasks ${ids.join(',') || '-'}${landed ? '' : ' --no-full'}${auditing ? ' --audit' : ''}${halted ? ' --halted ' + shq(halted) : ''}   (a 10-minute Bash timeout: it runs the project's whole check)\n` +
      'Return ok=true if its last line starts with FINISH, line = that last line, verbatim, and report = ".factory/last-run.md".',
    { agentType: RUNNER, label: 'finish', phase: 'Finish', schema: LINE },
  ),
  auditing
    ? agent(
        `Audit this run, following your instructions. It landed the commits ${plan.start_head}..HEAD for the tasks ${ids.join(', ')}, ` +
          `of the change(s) ${changes.join(', ')}. Write .factory/audit/<change>.md for each of them, run factory-deliver --if-ready, and return the findings.`,
        { agentType: 'factory:auditor', effort: E.audit, schema: AUDIT, label: 'audit', phase: 'Finish' },
      )
    : Promise.resolve(null),
])

// A retrospective that is due runs by itself only where the project said so
// (retro.mode: full); factory-retro-apply decides what may change.
const retroRun = fin && /retro due/.test(fin.line || '') && plan.retro_mode === 'full'
  ? await agent('A retrospective is due. Follow your instructions: collect the evidence, write the report and the proposals file, then apply it with factory-retro-apply. Report one line.', {
      agentType: 'factory:retro', effort: 'high', label: 'retro', phase: 'Finish',
    })
  : null

const seams = audit ? (audit.findings || []).filter(f => f.severity === 'high').length : 0
return {
  line: fin ? fin.line : `LOOP ${landed}/${tasks.length} landed; the finish step returned nothing${halted ? ' (halted: ' + halted + ')' : ''} - run factory-finish`,
  report: '.factory/last-run.md',
  halted: halted || undefined,
  audit: audit ? `${audit.findings.length} finding(s), ${seams} high (.factory/audit/)` : auditing ? 'the auditor returned nothing: delivery waits (factory-deliver --if-ready --skip-audit hands it on)' : undefined,
  retro: retroRun ? 'ran' : undefined,
  tasks: results.map(r => `${r.id} ${r.status}`).join(', '),
}
