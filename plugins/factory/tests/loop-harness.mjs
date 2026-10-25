// Runs workflows/loop.js under node with a fake agent(), the way the workflow
// runtime would: the body is an async function of args, agent, log and phase,
// with Date.now and Math.random taken away as the runtime takes them away.
//
// A scenario answers each agent call by its label. An answer is a value, a
// function (prompt, opts, n) -> value, or a list taken in order (the last one
// repeats). `{ delay: k, value }` answers after k turns of the event loop, which
// is how a test makes one builder finish after another.
import { readFileSync } from 'node:fs'

const SRC = readFileSync(new URL('../workflows/loop.js', import.meta.url), 'utf8')
const BODY = SRC.replace(/^export const meta = \{[\s\S]*?\n\}\n/, '')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

const tick = k => new Promise(r => (k <= 0 ? setImmediate(r) : setImmediate(() => tick(k - 1).then(r))))

export async function runLoop(args, answers) {
  const calls = []
  const logs = []
  const seen = {}
  const agent = async (prompt, opts) => {
    const label = (opts && opts.label) || ''
    calls.push({ label, prompt, opts })
    let a = answers[label]
    if (a === undefined) {
      const key = Object.keys(answers).find(k => k.startsWith('/') && new RegExp(k.slice(1, -1)).test(label))
      a = key ? answers[key] : undefined
    }
    const n = (seen[label] = (seen[label] || 0) + 1)
    if (Array.isArray(a)) a = a[Math.min(n, a.length) - 1]
    if (typeof a === 'function') a = a(prompt, opts, n)
    if (a && typeof a === 'object' && 'delay' in a) {
      await tick(a.delay)
      a = a.value
    }
    if (a instanceof Error) throw a
    return a === undefined ? null : a
  }
  const guardedDate = { now: () => { throw new Error('Date.now() is not available in a workflow') } }
  const guardedMath = Object.assign(Object.create(Math), { random: () => { throw new Error('Math.random() is not available') } })
  const fn = new AsyncFunction('args', 'agent', 'log', 'phase', 'Date', 'Math', BODY)
  const result = await fn(args, agent, m => logs.push(m), () => {}, guardedDate, guardedMath)
  return { result, calls, logs, labels: calls.map(c => c.label) }
}
