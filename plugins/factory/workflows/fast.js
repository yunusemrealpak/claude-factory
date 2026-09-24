export const meta = {
  name: 'fast',
  description: 'Factory fast lane: build every approved task with one builder each, a deterministic check per task, and one full check at the end',
  whenToUse: 'In a factory project whose task list is approved, to build the backlog without a model-driven lead loop',
  phases: [
    { title: 'Plan', detail: 'read the board and its dependency graph from disk' },
    { title: 'Build', detail: 'one builder per task: implement, fast check, land' },
    { title: 'Finish', detail: 'one full check over the whole tree, change acceptance' },
  ],
}

// Why a workflow. The old loop ran every step of every task through the lead: a
// model turn to lint, to move a file, to stamp a stage, to dispatch, to read the
// marker, to route, to dispatch the integrator - around ten turns per task on
// the session's model and effort, for decisions that are dependency arithmetic.
// Here that arithmetic is code. The only model work left is building each task;
// the lead's context receives the final tally and nothing else.
//
// args (all optional): { workers: 4, effort: { build, escalate, review } }

const PLAN = {
  type: 'object',
  required: ['ok', 'tasks'],
  properties: {
    ok: { type: 'boolean' },
    problems: { type: 'array', items: { type: 'string' } },
    warnings: { type: 'array', items: { type: 'string' } },
    workers: { type: 'number' },
    risk_review: { type: 'string', enum: ['after', 'before'] },
    audit: { type: 'boolean' },
    start_head: { type: 'string' },
    critical_path: { type: 'array', items: { type: 'string' } },
    width: { type: 'number' },
    effort: { type: 'object', properties: { build: { type: 'string' }, escalate: { type: 'string' }, review: { type: 'string' }, audit: { type: 'string' } } },
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'deps'],
        properties: { id: { type: 'string' }, title: { type: 'string' }, deps: { type: 'array', items: { type: 'string' } }, review: { type: 'boolean' } },
      },
    },
    held: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } } } },
  },
}

const RESULT = {
  type: 'object',
  required: ['id', 'status', 'summary', 'concerns'],
  properties: {
    id: { type: 'string' },
    status: { type: 'string', enum: ['landed', 'review', 'waiting', 'red', 'no_progress', 'blocked', 'error'] },
    summary: { type: 'string' },
    concerns: { type: 'array', items: { type: 'string' } },
    files: { type: 'array', items: { type: 'string' } },
    check_runs: { type: 'number' },
    risk: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

const VERDICT = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: { verdict: { type: 'string', enum: ['pass', 'fail'] }, findings: { type: 'array', items: { type: 'string' } } },
}

const LINE = {
  type: 'object',
  required: ['ok', 'line'],
  properties: { ok: { type: 'boolean' }, line: { type: 'string' } },
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
  },
}

const FINISH = {
  type: 'object',
  required: ['board', 'attention', 'full_check'],
  properties: {
    attention: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, concern: { type: 'string' } } } },
    board: {
      type: 'array',
      items: { type: 'object', properties: { id: { type: 'string' }, lane: { type: 'string' }, commit: { type: ['string', 'null'] }, reason: { type: 'string' } } },
    },
    full_check: { type: 'string', enum: ['green', 'red', 'skipped'] },
    full_output: { type: 'string' },
    changes: { type: 'array', items: { type: 'string' } },
    acceptance: { type: 'array', items: { type: 'object', properties: { change: { type: 'string' }, result: { type: 'string' } } } },
  },
}

const opts = args && typeof args === 'object' ? args : {}

phase('Plan')
const plan = await agent(
  'From the project root, run exactly: factory-plan --json --start\nIt prints one JSON object. Return that object field for field; do not summarise, reorder or drop anything.',
  { label: 'plan', phase: 'Plan', model: 'haiku', schema: PLAN },
)
if (!plan) return { error: 'the plan could not be read' }
if (!plan.ok) return { error: 'the board is not ready to build', problems: plan.problems || [] }
for (const w of plan.warnings || []) log('warning: ' + w)

const E = Object.assign({ build: 'medium', escalate: 'xhigh', review: 'high', audit: 'high' }, plan.effort || {}, opts.effort || {})
const WORKERS = Math.max(1, Math.min(8, Number(opts.workers || plan.workers || 4)))
// A task sent to review only because it touched a risk path lands first and is
// reviewed alongside the rest of the run, so nothing that depends on it waits
// on a reviewer; review: always still reviews before landing.
const RISK_REVIEW = opts.risk_review || plan.risk_review || 'after'
const postReviews = []
const tasks = plan.tasks || []
if (!tasks.length) return { landed: [], held: plan.held || [], note: 'nothing to build' }
log(`${tasks.length} task(s) to build, ${WORKERS} at a time; ${(plan.held || []).length} held` +
  (plan.critical_path ? `; longest chain ${plan.critical_path.length}, widest level ${plan.width}` : ''))

// --- a slot per worker: at most WORKERS agents of this run are open at once ---
let open = 0
const waiting = []
function pump() {
  while (open < WORKERS && waiting.length) {
    const { fn, resolve } = waiting.shift()
    open++
    fn().then(resolve, () => resolve(null)).then(() => {
      open--
      pump()
    })
  }
}
function slot(fn) {
  return new Promise(resolve => {
    waiting.push({ fn, resolve })
    pump()
  })
}

const FAILED = ['red', 'no_progress', 'error']

// --- progress: a task waiting on another task's unlanded work re-checks when
// something lands, or when nothing else is building any more ---
let building = 0
let waiters = []
function progressed() {
  const w = waiters
  waiters = []
  w.forEach(f => f())
}
function nextProgress() {
  return new Promise(resolve => (building === 0 ? resolve() : waiters.push(resolve)))
}

// The builder's work is done; its check only failed on someone else's files.
// A cheap agent re-runs the check after the next land - no builder is kept
// alive, and nothing is spent while waiting.
async function recheck(t, r) {
  for (let i = 0; i < 3; i++) {
    building--
    if (building === 0) progressed()
    await nextProgress()
    building++
    const c = await run1(
      `From the project root run: factory-check ${t.id}   (use a 10-minute timeout)\n` +
        `If and only if its last line starts with "CHECK RESULT: GREEN", also run: factory-risk ${t.id}\n` +
        'Return ok=true only when the check was GREEN; line = the check\'s last line, followed by " RISK" if factory-risk exited 1.',
      t.id + ' recheck',
    )
    if (c && c.ok) return Object.assign({}, r, { status: t.review || /RISK\s*$/.test(c.line) ? 'review' : 'green' })
    if (c && !/WAITING/.test(c.line)) return Object.assign({}, r, { status: 'red', summary: 'recheck: ' + c.line })
  }
  return Object.assign({}, r, { status: 'red', summary: 'still failing on work this task does not own after three rechecks' })
}

async function land(t, r, how) {
  const l = await run1(`From the project root run exactly: factory-land ${t.id}\nReturn ok=true if its last line starts with LANDED or LAND SKIPPED, and that line.`, t.id + ' land')
  if (l && l.ok) progressed()
  return l && l.ok
    ? Object.assign({}, r, { status: 'landed', summary: how + r.summary })
    : Object.assign({}, r, { status: 'error', summary: 'land failed: ' + (l ? l.line : 'no answer') })
}

async function settle(t, r) {
  if (r && r.status === 'waiting') {
    r = await recheck(t, r)
    if (r.status === 'green') return land(t, r, 'landed after waiting for work in flight: ')
  }
  if (r && r.status === 'landed') progressed()
  return r
}

function buildPrompt(t, previous, findings) {
  const lines = [`Build factory task ${t.id}. Start with: factory-start ${t.id} ${previous ? 'builder-retry' : 'builder'}`]
  if (previous) {
    lines.push(`This is the second attempt. The first ended "${previous.status}": ${previous.summary}${previous.notes ? ' (' + previous.notes + ')' : ''}.`)
    lines.push('Read ## Attempts in the task file first and do not repeat an approach it already ruled out.')
  }
  if (findings) {
    lines.push('A reviewer failed the change with these findings; fix exactly these, run the check, and return status "review" (do not land):')
    for (const f of findings) lines.push('- ' + f)
  } else if (t.review) {
    lines.push('This task needs review before it lands: once the check is green, return status "review" instead of landing.')
  }
  return lines.join('\n')
}

function reviewPrompt(t, r, landed) {
  return [
    landed
      ? `Review factory task ${t.id}. It has already landed: its commit is \`git log -1 --format=%h --grep '^Factory-Task: ${t.id}$'\` - read that commit's diff. The review is for risk.`
      : `Review factory task ${t.id} before it is committed. Its check is green; the review is for risk.`,
    r.risk && r.risk.length ? 'The risk check matched:\n' + r.risk.join('\n') : 'The task is marked review: always.',
    `Judge the files under "## Files touched" in tasks/${landed ? 'done' : 'in-progress'}/${t.id}.md against the task and the project CLAUDE.md. Record your review in the task file as your instructions say, and return the verdict.`,
  ].join('\n')
}

const run1 = (prompt, label) => slot(() => agent(prompt, { label, phase: 'Build', model: 'haiku', schema: LINE }))

async function block(t, reason) {
  await run1(`From the project root run exactly: factory-block ${t.id} ${JSON.stringify(reason)}\nReturn ok=true if the output starts with BLOCKED, and the output line.`, t.id + ' block')
  return { id: t.id, status: 'blocked', summary: reason }
}

async function build(t) {
  building++
  try {
    return await buildInner(t)
  } finally {
    building--
    progressed()
  }
}

async function buildInner(t) {
  let r = await settle(t, await slot(() => agent(buildPrompt(t), { agentType: 'factory:builder', effort: E.build, schema: RESULT, label: t.id, phase: 'Build' })))
  if (!r || FAILED.includes(r.status)) {
    // One escalation: a fresh builder, more reasoning, the attempts on file.
    const first = r || { status: 'error', summary: 'the builder returned nothing' }
    log(`${t.id}: ${first.status} - one more attempt at ${E.escalate} effort`)
    r = await settle(t, await slot(() => agent(buildPrompt(t, first), { agentType: 'factory:builder', effort: E.escalate, schema: RESULT, label: t.id + ' retry', phase: 'Build' })))
    if (!r || FAILED.includes(r.status)) {
      return block(t, r ? `${r.status} after an escalated retry: ${r.summary}` : 'the builder failed twice')
    }
  }
  if (r.status !== 'review') return r

  if (!t.review && RISK_REVIEW === 'after') {
    const done = await land(t, r, 'landed, risk review running alongside: ')
    if (done.status === 'landed') {
      postReviews.push(slot(() => agent(reviewPrompt(t, r, true), { agentType: 'factory:reviewer', effort: E.review, schema: VERDICT, label: `${t.id} review`, phase: 'Build' })))
    }
    return done
  }

  for (let round = 1; round <= 2; round++) {
    const v = await slot(() => agent(reviewPrompt(t, r), { agentType: 'factory:reviewer', effort: E.review, schema: VERDICT, label: `${t.id} review`, phase: 'Build' }))
    if (v && v.verdict === 'pass') return land(t, r, 'reviewed and landed: ')
    if (round === 2 || !v) return block(t, 'review failed: ' + (v ? v.findings.join('; ') : 'the reviewer returned nothing'))
    r = await slot(() => agent(buildPrompt(t, null, v.findings), { agentType: 'factory:builder', effort: E.escalate, schema: RESULT, label: t.id + ' fix', phase: 'Build' }))
    if (!r || r.status !== 'review') return r && r.status === 'blocked' ? r : block(t, 'could not address the review findings')
  }
}

// --- the dependency graph: each task starts the moment its last dependency lands ---
phase('Build')
const byId = new Map(tasks.map(t => [t.id, t]))
const started = new Map()
function schedule(id) {
  if (started.has(id)) return started.get(id)
  const t = byId.get(id)
  const p = Promise.all(t.deps.filter(d => byId.has(d)).map(schedule)).then(deps => {
    const bad = deps.find(d => !d || d.status !== 'landed')
    if (bad) return { id, status: 'skipped', summary: `waits on ${bad.id}, which ended ${bad.status}` }
    return build(t)
  })
  started.set(id, p)
  return p
}
const results = (await Promise.all(tasks.map(t => schedule(t.id)))).map((r, i) => r || { id: tasks[i].id, status: 'error', summary: 'no result' })

const landed = results.filter(r => r.status === 'landed').length
log(`${landed}/${tasks.length} landed`)

// Reviews of tasks that landed first finish before the report is written: a
// failed one is recorded in its task file, and the report reads it from there.
if (postReviews.length) {
  const verdicts = await Promise.all(postReviews)
  log(`${verdicts.filter(v => v && v.verdict === 'pass').length}/${postReviews.length} after-landing reviews passed`)
}

// The report comes from disk, not from the agents: where each task file is now,
// which commit carries it, what the builders flagged and left open. An agent's
// last sentence is written before the review, land or block that followed it.
phase('Finish')
// Every task was judged alone. The audit reads what they add up to - against the
// goal, at the seams between tasks - while the full check runs.
const auditing = landed >= 2 && plan.audit !== false && opts.audit !== false && plan.start_head
const [finish, audit] = await Promise.all([
  agent(
    `From the project root, run exactly: factory-finish --tasks ${tasks.map(t => t.id).join(',')}${landed ? '' : ' --no-full'}\n` +
      'It prints one JSON object. Return it field for field; keep every string verbatim.',
    { label: 'finish', phase: 'Finish', model: 'haiku', schema: FINISH },
  ),
  auditing
    ? agent(
        `Audit this run. It landed the commits ${plan.start_head}..HEAD, for the tasks ${tasks.map(t => t.id).join(', ')}. ` +
          'Follow your instructions, write .factory/audit.md, and return the findings.',
        { agentType: 'factory:auditor', effort: E.audit, schema: AUDIT, label: 'audit', phase: 'Finish' },
      )
    : Promise.resolve(null),
])
const seams = audit ? (audit.findings || []).filter(f => f.severity !== 'low') : []

return {
  attention: (finish ? finish.attention : []).concat(seams.map(f => ({ id: 'audit', concern: `${f.severity}: ${f.what}${f.where ? ' (' + f.where + ')' : ''}${f.fix ? ' - fix: ' + f.fix : ''}` }))),
  board: finish ? finish.board : results.map(r => ({ id: r.id, lane: 'unknown (the finish step returned nothing)', commit: null })),
  full_check: finish ? finish.full_check : 'not run',
  full_output: finish ? finish.full_output : '',
  acceptance: finish ? finish.acceptance || [] : [],
  changes: finish ? finish.changes || [] : [],
  held: plan.held || [],
  warnings: plan.warnings || [],
  report: '.factory/last-run.md',
  audit: audit ? { findings: audit.findings.length, report: '.factory/audit.md' } : auditing ? 'the auditor returned nothing' : 'not run',
  agent_notes: results.map(r => ({ id: r.id, status: r.status, summary: r.summary, notes: r.notes || undefined })),
}
