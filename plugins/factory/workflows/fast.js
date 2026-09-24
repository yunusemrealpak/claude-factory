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
    effort: { type: 'object', properties: { build: { type: 'string' }, escalate: { type: 'string' }, review: { type: 'string' } } },
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
    status: { type: 'string', enum: ['landed', 'review', 'red', 'no_progress', 'blocked', 'error'] },
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

const E = Object.assign({ build: 'medium', escalate: 'xhigh', review: 'high' }, plan.effort || {}, opts.effort || {})
const WORKERS = Math.max(1, Math.min(8, Number(opts.workers || plan.workers || 4)))
const tasks = plan.tasks || []
if (!tasks.length) return { landed: [], held: plan.held || [], note: 'nothing to build' }
log(`${tasks.length} task(s) to build, ${WORKERS} at a time; ${(plan.held || []).length} held`)

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

function reviewPrompt(t, r) {
  return [
    `Review factory task ${t.id} before it is committed. Its check is green; the review is for risk.`,
    r.risk && r.risk.length ? 'The risk check matched:\n' + r.risk.join('\n') : 'The task is marked review: always.',
    'Judge the files under "## Files touched" in tasks/in-progress/' + t.id + '.md against the task and the project CLAUDE.md. Record your review in the task file as your instructions say, and return the verdict.',
  ].join('\n')
}

const run1 = (prompt, label) => slot(() => agent(prompt, { label, phase: 'Build', model: 'haiku', schema: LINE }))

async function block(t, reason) {
  await run1(`From the project root run exactly: factory-block ${t.id} ${JSON.stringify(reason)}\nReturn ok=true if the output starts with BLOCKED, and the output line.`, t.id + ' block')
  return { id: t.id, status: 'blocked', summary: reason }
}

async function build(t) {
  let r = await slot(() => agent(buildPrompt(t), { agentType: 'factory:builder', effort: E.build, schema: RESULT, label: t.id, phase: 'Build' }))
  if (!r || FAILED.includes(r.status)) {
    // One escalation: a fresh builder, more reasoning, the attempts on file.
    const first = r || { status: 'error', summary: 'the builder returned nothing' }
    log(`${t.id}: ${first.status} - one more attempt at ${E.escalate} effort`)
    r = await slot(() => agent(buildPrompt(t, first), { agentType: 'factory:builder', effort: E.escalate, schema: RESULT, label: t.id + ' retry', phase: 'Build' }))
    if (!r || FAILED.includes(r.status)) {
      return block(t, r ? `${r.status} after an escalated retry: ${r.summary}` : 'the builder failed twice')
    }
  }
  if (r.status !== 'review') return r

  for (let round = 1; round <= 2; round++) {
    const v = await slot(() => agent(reviewPrompt(t, r), { agentType: 'factory:reviewer', effort: E.review, schema: VERDICT, label: `${t.id} review`, phase: 'Build' }))
    if (v && v.verdict === 'pass') {
      const l = await run1(`From the project root run exactly: factory-land ${t.id}\nReturn ok=true if its last line starts with LANDED or LAND SKIPPED, and that line.`, t.id + ' land')
      return l && l.ok
        ? Object.assign({}, r, { status: 'landed', summary: 'reviewed and landed: ' + r.summary })
        : Object.assign({}, r, { status: 'error', summary: 'land failed: ' + (l ? l.line : 'no answer') })
    }
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

// The report comes from disk, not from the agents: where each task file is now,
// which commit carries it, what the builders flagged and left open. An agent's
// last sentence is written before the review, land or block that followed it.
phase('Finish')
const finish = await agent(
  `From the project root, run exactly: factory-finish --tasks ${tasks.map(t => t.id).join(',')}${landed ? '' : ' --no-full'}\n` +
    'It prints one JSON object. Return it field for field; keep every string verbatim.',
  { label: 'finish', phase: 'Finish', model: 'haiku', schema: FINISH },
)

return {
  attention: finish ? finish.attention : [],
  board: finish ? finish.board : results.map(r => ({ id: r.id, lane: 'unknown (the finish step returned nothing)', commit: null })),
  full_check: finish ? finish.full_check : 'not run',
  full_output: finish ? finish.full_output : '',
  acceptance: finish ? finish.acceptance || [] : [],
  changes: finish ? finish.changes || [] : [],
  held: plan.held || [],
  warnings: plan.warnings || [],
  report: '.factory/last-run.md',
  agent_notes: results.map(r => ({ id: r.id, status: r.status, summary: r.summary, notes: r.notes || undefined })),
}
