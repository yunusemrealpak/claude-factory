// The loop workflow's schedule, case by case, under a fake agent(). Run by
// suite13.sh; prints one "ok"/"FAIL" line per check and a total.
import { runLoop } from './loop-harness.mjs'

let passed = 0
let failed = 0
function check(name, cond, detail) {
  if (cond) {
    passed++
    console.log('ok   ' + name)
  } else {
    failed++
    console.log('FAIL ' + name + (detail ? '\n     ' + String(detail).slice(0, 600) : ''))
  }
}

const landed = (id, extra = '') => ({ id, status: 'landed', summary: 'ok', settle: `SETTLED ${id} LANDED abc${extra}`, concerns: [] })
const FINISH = { ok: true, line: 'FINISH 1/1 landed; full check green - report .factory/last-run.md' }
const runners = r => r.calls.filter(c => c.opts.agentType === 'factory:runner')
const plan = (tasks, extra = {}) => Object.assign({ ok: true, tasks, workers: 4, attempts: 2 }, extra)
const T = (id, deps = [], review = false) => ({ id, deps, review })

// 1. the happy path: the graph, one builder per task, no runner but finish
{
  const r = await runLoop(plan([T('A'), T('B', ['A']), T('C', ['A']), T('D', ['B', 'C'], true)], { start_head: 'abc' }), {
    A: landed('A'), B: landed('B'), C: landed('C'),
    D: { id: 'D', status: 'review', summary: 'green', settle: 'SETTLED D REVIEW', concerns: [] },
    'D review': { line: 'REVIEW PASS D: LANDED D abc1', findings: [] },
    finish: FINISH,
    audit: { findings: [] },
  })
  const L = r.labels.join(',')
  check('dependents start only after what they need has landed', /^A,(B,C|C,B),D,D review,(finish,audit|audit,finish)$/.test(L), L)
  check('on the happy path the only runner is the finish', runners(r).length === 1 && runners(r)[0].label === 'finish', L)
  check('a review that passes lands the task through factory-review-submit', /D landed/.test(r.result.tasks), r.result.tasks)
  check('the result is small: a line, the report path, one word per task',
    Object.keys(r.result).every(k => ['line', 'report', 'audit', 'tasks', 'halted', 'retro'].includes(k)) && r.result.report === '.factory/last-run.md', JSON.stringify(r.result))
  check('finish is told every task, and that an audit runs alongside', /factory-finish --tasks A,B,C,D --audit/.test(r.calls.find(c => c.label === 'finish').prompt))
  check('the auditor is told the range and the changes, and to deliver', /abc\.\.HEAD/.test(r.calls.find(c => c.label === 'audit').prompt) && /C1/.test(r.calls.find(c => c.label === 'audit').prompt) && /factory-deliver --if-ready/.test(r.calls.find(c => c.label === 'audit').prompt))
  check('a builder prompt keeps the fixed text first and the task id last', /^Build one factory task[\s\S]*Task: A {3}Owner: builder$/.test(r.calls[0].prompt), r.calls[0].prompt)
  check('every runner uses the one schema', runners(r).every(c => JSON.stringify(Object.keys(c.opts.schema.properties)) === '["ok","line","report"]'))
}

// 2. red, then blocked by settle: no block runner, dependents skipped
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: { id: 'A', status: 'red', summary: 'x', settle: 'SETTLED A RETRY 1/2: red - the test fails', concerns: [] },
    'A retry': { id: 'A', status: 'red', summary: 'still', settle: 'SETTLED A BLOCKED: red after 2 attempt(s), the limit: still', concerns: [] },
    finish: FINISH,
  })
  check('a red task is retried at escalated effort, then blocked by settle - no block runner',
    r.labels.join(',') === 'A,A retry,finish' && r.calls[1].opts.effort === 'high', r.labels.join(','))
  check('the retry is told what the attempt before it ended with', /attempt 2[\s\S]*1\/2: red - the test fails/.test(r.calls[1].prompt), r.calls[1].prompt)
  check('what depends on a blocked task is skipped', r.result.tasks === 'A blocked, B skipped', r.result.tasks)
  check('nothing landed: finish runs without a full check', /--no-full/.test(r.calls.find(c => c.label === 'finish').prompt))
}

// 3. a builder that did not settle: a runner settles, and its line decides
{
  const r = await runLoop(plan([T('A')]), {
    A: { id: 'A', status: 'landed', summary: 'I landed it', settle: '', concerns: [] },
    'A settle': { ok: true, line: 'SETTLED A RETRY 1/2: red - the check did not go green' },
    'A retry': landed('A'),
    finish: FINISH,
  })
  check('a builder that did not settle is settled by a runner - its own word does not land it',
    r.labels.join(',') === 'A,A settle,A retry,finish', r.labels.join(','))
  check('the settle runner passes the builder summary as one quoted word', /factory-settle A 'I landed it'/.test(r.calls[1].prompt), r.calls[1].prompt)
}

// 4. waiting: one recheck when the task it waits on has settled
{
  const r = await runLoop(plan([T('X'), T('Y')]), {
    X: { id: 'X', status: 'waiting', summary: 'built', settle: 'SETTLED X WAITING on Y', concerns: [] },
    Y: { delay: 5, value: landed('Y') },
    'X recheck': { ok: true, line: 'SETTLED X LANDED abc' },
    finish: FINISH,
  })
  check('a waiting task is re-checked once, after the task it waits on settles', r.labels.join(',') === 'X,Y,X recheck,finish' && /X landed/.test(r.result.tasks), r.labels.join(',') + ' / ' + r.result.tasks)
  check('runner calls are the finish plus one per wait', runners(r).length === 2)
  const rc = r.calls.find(c => c.label === 'X recheck').prompt
  check('the recheck runs the check and then settle', /factory-check X ; factory-settle X /.test(rc), rc)
}

// 5. waiting with nothing else building: the recheck says so (--no-wait)
{
  const r = await runLoop(plan([T('X')]), {
    X: { id: 'X', status: 'waiting', summary: 'built', settle: 'SETTLED X WAITING on src/y.py', concerns: [] },
    'X recheck': { ok: true, line: 'SETTLED X RETRY 1/2: red - it waited on work that will not land' },
    'X retry': landed('X'),
    finish: FINISH,
  })
  check('a task waiting with nothing else building is re-checked at once, and the wait counts', r.labels.join(',') === 'X,X recheck,X retry,finish' && /--no-wait/.test(r.calls[1].prompt), r.labels.join(','))
}

// 6. one empty answer: the same attempt again; it is not counted
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: [null, landed('A')],
    B: landed('B'),
    finish: FINISH,
  })
  check('a builder that returns nothing is tried once more, as the same attempt', r.labels.join(',') === 'A,A,B,finish' && r.calls[1].opts.effort === 'medium', r.labels.join(','))
}

// 7. two empty answers: halted (infra), nothing blocked, no new task starts
{
  const r = await runLoop(plan([T('A'), T('B', ['A']), T('C')], { workers: 1 }), {
    A: null,
    C: { delay: 50, value: landed('C') },
    finish: FINISH,
  })
  const fin = r.calls.find(c => c.label === 'finish')
  check('two empty answers halt the run as infra, and block nothing', r.result.halted && /infra/.test(r.result.halted) && !/blocked/.test(r.result.tasks), JSON.stringify(r.result))
  check('the finish is told the run halted, so the base is kept', fin && /--halted '.*infra/.test(fin.prompt), fin && fin.prompt)
  check('no block or settle runner ran for an infrastructure failure', !r.labels.some(l => / (block|settle)$/.test(l)), r.labels.join(','))
}

// 8. STOP: a builder that finds it halts the run
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: { id: 'A', status: 'halted', summary: 'START REFUSED for A: HALTED - .factory/STOP is set', settle: '', concerns: [] },
    finish: FINISH,
  })
  check('a halted builder stops the run; what waited is halted, not blocked', r.result.tasks === 'A halted, B halted' && r.labels.join(',') === 'A,finish', r.labels.join(',') + ' / ' + r.result.tasks)
}

// 9. the stop race: a builder queued for a slot when the run halts never starts
{
  const r = await runLoop(plan([T('A'), T('B'), T('C')], { workers: 1 }), {
    A: { delay: 3, value: { id: 'A', status: 'halted', summary: 'STOP', settle: 'SETTLED A HALTED: .factory/STOP is set (x)', concerns: [] } },
    B: landed('B'),
    C: landed('C'),
    finish: FINISH,
  })
  check('a builder waiting for a slot when the run halts is never started', !r.labels.includes('B') && !r.labels.includes('C') && r.result.tasks === 'A halted, B halted, C halted', r.labels.join(',') + ' / ' + r.result.tasks)
}

// 10. spec conflict: settled by the builder (blocked and asked), not retried
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: { id: 'A', status: 'spec_conflict', summary: 'criteria 2 and 3 cannot both hold', settle: 'SETTLED A BLOCKED: spec conflict, asked Q1: criteria 2 and 3 cannot both hold', concerns: [] },
    finish: FINISH,
  })
  check('a spec conflict is asked, not retried, and holds what depends on it', r.labels.join(',') === 'A,finish' && r.result.tasks === 'A blocked, B skipped', r.labels.join(','))
}
{
  const r = await runLoop(plan([T('A')]), {
    A: { id: 'A', status: 'spec_conflict', summary: "which wins: 'a' or b?", settle: '', concerns: [] },
    'A settle': { ok: true, line: 'SETTLED A BLOCKED: spec conflict, asked Q1: which wins' },
    finish: FINISH,
  })
  check('a spec conflict the builder did not settle is settled with --conflict', /factory-settle A --conflict 'which wins: '\\''a'\\'' or b\?'/.test(r.calls[1].prompt), r.calls[1].prompt)
}

// 11. refused at start: the board is left as it is; a landed earlier attempt lands
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: { id: 'A', status: 'refused', summary: 'START REFUSED for A: it is in done/A.md', settle: 'SETTLED A LANDED (already in tasks/done)', concerns: [] },
    B: landed('B'),
    finish: FINISH,
  })
  check('a task an earlier attempt landed counts as landed, and its dependents run', r.labels.join(',') === 'A,B,finish' && r.result.tasks === 'A landed, B landed', r.labels.join(','))
}

// 12. review before landing: fail, a fresh builder fixes, pass
{
  const r = await runLoop(plan([T('D', [], true)]), {
    D: { id: 'D', status: 'review', summary: 'green', settle: 'SETTLED D REVIEW', concerns: [] },
    'D review': [
      { line: 'REVIEW FAIL D round 1: 1 blocking finding(s) - a fresh builder fixes exactly these', findings: [{ severity: 'P1', file: 'src/a.py', line: 3, what: 'tenant filter missing', fix: 'add it' }] },
      { line: 'REVIEW PASS D: LANDED D abc2', findings: [] },
    ],
    'D fix': { id: 'D', status: 'review', summary: 'fixed', settle: 'SETTLED D REVIEW', concerns: [] },
    finish: FINISH,
  })
  check('a failed review sends the findings to a fresh builder, then reviews again', r.labels.join(',') === 'D,D review,D fix,D review,finish' && /landed/.test(r.result.tasks), r.labels.join(','))
  check('the fix builder gets exactly the findings', /\[P1\] src\/a\.py:3 tenant filter missing -> add it/.test(r.calls[2].prompt), r.calls[2].prompt)
  check('the reviewer is told to submit before landing', /factory-review-submit/.test(r.calls[1].prompt) && !/--landed/.test(r.calls[1].prompt))
}
{
  const r = await runLoop(plan([T('D', [], true)]), {
    D: { id: 'D', status: 'review', summary: 'green', settle: 'SETTLED D REVIEW', concerns: [] },
    'D review': { line: 'REVIEW FAIL D BLOCKED: review failed twice: x', findings: [] },
    finish: FINISH,
  })
  check('a review that blocks the task ends it', r.result.tasks === 'D blocked', r.result.tasks)
}
{
  const r = await runLoop(plan([T('D', [], true)]), {
    D: { id: 'D', status: 'review', summary: 'green', settle: 'SETTLED D REVIEW', concerns: [] },
    'D review': { line: 'I think it is fine', findings: [] },
    finish: FINISH,
  })
  check('a reviewer that submitted nothing leaves the task green and unlanded, not blocked', r.result.tasks === 'D review_missing', r.result.tasks)
}

// 13. review after landing: what depends on it does not wait
{
  const r = await runLoop(plan([T('E'), T('F', ['E'])]), {
    E: landed('E', ' REVIEW-AFTER'),
    'E review': { delay: 20, value: { line: 'REVIEW PASS E (landed)', findings: [] } },
    F: landed('F'),
    finish: FINISH,
  })
  const L = r.labels.join(',')
  check('a risk-path task lands first; its review runs alongside and does not hold back what depends on it', /^E,(E review,F|F,E review),finish$/.test(L), L)
  check('the after-landing reviewer reads the commit and submits with --landed', /--landed/.test(r.calls.find(c => c.label === 'E review').prompt))
  check('the finish waits for the after-landing review', r.labels.indexOf('finish') > r.labels.indexOf('E review'))
}

// 14. reviews owed by an earlier run are run first
{
  const r = await runLoop(plan([T('A')], { owed: ['Z-09'] }), {
    A: landed('A'),
    'Z-09 review': { line: 'REVIEW PASS Z-09 (landed)', findings: [] },
    finish: FINISH,
  })
  check('a review an earlier run owed is run in this one', r.labels.includes('Z-09 review') && /--landed/.test(r.calls.find(c => c.label === 'Z-09 review').prompt), r.labels.join(','))
}

// 15. the plan: from args, as a string, or from the preflight runner
{
  const r = await runLoop(JSON.stringify(plan([T('A')])), { A: landed('A'), finish: FINISH })
  check('a plan passed as a JSON string is read', r.labels.join(',') === 'A,finish', r.labels.join(','))
}
{
  const p = JSON.stringify(plan([T('A')]))
  const r = await runLoop(undefined, { preflight: { ok: true, line: p }, A: landed('A'), finish: FINISH })
  check('without a plan, the preflight runs first (the workflow typed by itself)', r.labels.join(',') === 'preflight,A,finish' && /factory-preflight --json/.test(r.calls[0].prompt), r.labels.join(','))
}
{
  const r = await runLoop({ change: 'C2' }, { preflight: { ok: true, line: JSON.stringify(plan([])) }, finish: FINISH })
  check('the preflight is given the change', /factory-preflight --json --change 'C2'/.test(r.calls[0].prompt), r.calls[0].prompt)
}
{
  const r = await runLoop({ ok: false, tasks: [], problems: ['HALTED: .factory/STOP is set (x)'] }, {})
  check('a plan that is not ok starts nothing', r.calls.length === 0 && /^LOOP STOPPED: HALTED/.test(r.result.line), JSON.stringify(r.result))
}
{
  const r = await runLoop(undefined, { preflight: null })
  check('a preflight that returns nothing halts as infra', r.result.halted === 'infra')
}

// 16. the attempt limit comes from the plan
{
  const r = await runLoop(plan([T('A')], { attempts: 3 }), {
    A: { id: 'A', status: 'red', summary: 'no', settle: 'SETTLED A RETRY 1/3: red - no', concerns: [] },
    'A retry': { id: 'A', status: 'red', summary: 'no', settle: 'SETTLED A RETRY 2/3: red - no', concerns: [] },
    'A retry 2': { id: 'A', status: 'red', summary: 'no', settle: 'SETTLED A BLOCKED: red after 3 attempt(s), the limit: no', concerns: [] },
    finish: FINISH,
  })
  check('retry_limit 3 is the build and two escalated retries, then settle blocks', r.labels.join(',') === 'A,A retry,A retry 2,finish', r.labels.join(','))
}

// 17. what a runner is asked is one quoted shell word
{
  const r = await runLoop(plan([T('A')]), {
    A: { id: 'A', status: 'red', summary: "it's $(whoami) \"x\" `id`", settle: '', concerns: [] },
    'A settle': { ok: true, line: 'SETTLED A BLOCKED: x' },
    finish: FINISH,
  })
  const p = r.calls[1].prompt
  check('a reason is passed as one single-quoted shell word', p.includes("factory-settle A 'it'\\''s $(whoami) \"x\" `id`'"), p)
  check('every command-only step goes to factory:runner with no model override', runners(r).length === 2 && r.calls.every(c => !c.opts.model))
}

// 18. a builder whose budget ran out: its settle line decides, like any other
{
  const r = await runLoop(plan([T('A'), T('B', ['A'])]), {
    A: { id: 'A', status: 'budget', summary: 'budget full', settle: 'SETTLED A RETRY 1/2: red - budget: 150 turns, 2.1M tokens', concerns: [] },
    'A retry': landed('A'),
    B: { id: 'B', status: 'budget', summary: 'budget full', settle: 'SETTLED B BLOCKED: red after 2 attempt(s), the limit: budget: 150 turns', concerns: [] },
    finish: FINISH,
  })
  check('budget with a RETRY line is retried at escalated effort, with no runner',
    r.labels.join(',') === 'A,A retry,B,finish' && r.calls[1].opts.effort === 'high', r.labels.join(','))
  check('the retry is told the one before it ran out of budget', /ended "budget"[\s\S]*budget: 150 turns[\s\S]*smallest change/.test(r.calls[1].prompt), r.calls[1].prompt)
  check('budget with a BLOCKED line is blocked', r.result.tasks === 'A landed, B blocked', r.result.tasks)
}

// 19. a builder whose budget ran out and did not settle: a runner settles it as budget
{
  const r = await runLoop(plan([T('A')]), {
    A: { id: 'A', status: 'budget', summary: '150 turns, 2.1M tokens', settle: '', concerns: [] },
    'A settle': { ok: true, line: 'SETTLED A RETRY 1/2: red - budget: 150 turns, 2.1M tokens' },
    'A retry': landed('A'),
    finish: FINISH,
  })
  const p = (r.calls.find(c => c.label === 'A settle') || {}).prompt || ''
  check('an unsettled budget is settled by a runner, with budget as the reason', /factory-settle A 'budget: 150 turns, 2\.1M tokens'/.test(p), p)
  check('the runner\'s RETRY line then retries it', r.labels.join(',') === 'A,A settle,A retry,finish' && r.result.tasks === 'A landed', r.labels.join(',') + ' | ' + r.result.tasks)
}

console.log(`loop: passed=${passed} failed=${failed}`)
process.exit(failed ? 1 : 0)
