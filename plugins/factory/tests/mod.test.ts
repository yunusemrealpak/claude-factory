// Tests for hooks/register.js, the factory's hooks module: the observers, the
// hard blocks for subagents and the consent record.
// Run with `claude plugin test` from plugins/factory (no session, no network).
import { describe, expect, test } from 'claude-code/testing'

// 2026-10-08 00:00 UTC; the week below resets 2026-10-12 00:00 UTC, so 3 of
// its 7 days are gone and the even-spend line is 42.9%.
const NOW = Date.parse('2026-10-08T00:00:00Z')
const LIMITS = [
  { kind: 'five_hour', percentUsed: 23.5, resetsAt: '2026-10-08T03:00:00Z' },
  { kind: 'seven_day', percentUsed: 41, resetsAt: '2026-10-12T00:00:00Z' },
]

// A cut of hooks/hard-blocks.txt, in its own format.
const RULES = [
  'hard_blocks_version: 1',
  'bash ## git-push ## (^|[^[:alnum:]_.-])git([[:space:]]+-[A-Za-z-]+)*[[:space:]]+push([[:space:];&|)]|$)',
  'path ## env-file ## any ## \\.env(\\.[^/[:space:]]*)?',
  'path ## autonomy-consent ## root ## \\.factory/autonomy.*',
  'deny ## Bash(git push *)',
].join('\n')

// Answers every call the module makes in Claude Code's place and records the
// processes it starts. `active` is whether the factory is open in /proj.
function world(on, { active = true, runFails = false, files = {}, level = '', limits = [] } = {}) {
  const runs = []
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: '/proj' }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('clock.now', () => ({ value: NOW }))
  on('env.get', () => ({ value: '/home/u' }))
  on('fs.exists', (_$, e) => ({ value: e.path.endsWith('/.factory/active') ? active : e.path in files }))
  on('fs.read', (_$, e) => ({ value: e.path.endsWith('/hard-blocks.txt') ? RULES : files[e.path] }))
  on('fs.list', () => ({ value: [{ name: 'T1.md', kind: 'file', size: 1, isLink: false }] }))
  on('agent.list', () => ({ value: [] }))
  on('session.id', () => ({ value: 's1' }))
  on('prompt.submit', (_$, e) => ({ text: e.text }))
  on('session.usage', () => ({ value: { context: {}, rateLimits: limits } }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('agent.spawn', () => ({ model: 'claude-haiku-5-5', agentId: 'a1' }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('process.run', (_$, e) => {
    runs.push(e)
    if (runFails) return { deny: 'no processes in this test' }
    if (level && JSON.stringify(e).includes('factory-autonomy.sh')) return { value: { exitCode: 0, stdout: level + '\n', stderr: '' } }
    return { value: { exitCode: 0, stdout: 'READY T1 api Add login\n', stderr: '' } }
  })
  return runs
}

const start = ($) => $.session.start({ cwd: '/proj', surface: null, isInteractive: false })

const turn = (over = {}) => ({
  answer: 'done',
  durationMs: 1200,
  isAborted: false,
  turnId: 't1',
  reason: 'answer',
  usage: {
    model: 'claude-haiku-5-5',
    input_tokens: 10,
    output_tokens: 20,
    cache_read_input_tokens: 300,
    cache_creation_input_tokens: 40,
  },
  ...over,
})

describe('quota', () => {
  test('a rate-limit change writes the quota file in the status line shape', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.session.measure({ context: {}, rateLimits: LIMITS, changed: ['rateLimits'] })
    expect(runs).toHaveLength(1)
    expect(runs[0].argv.at(-1)).toBe('/home/u/.claude/.factory-quota.json')
    const saved = JSON.parse(runs[0].init.stdin)
    expect(saved).toEqual({
      ts: NOW / 1000,
      source: 'mod',
      five_hour: { used_percentage: 23.5, resets_at: Date.parse('2026-10-08T03:00:00Z') / 1000 },
      seven_day: { used_percentage: 41, resets_at: Date.parse('2026-10-12T00:00:00Z') / 1000, even_line: 42.9 },
    })
  })

  test('a measurement without a rate-limit change writes nothing', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.session.measure({ context: {}, rateLimits: LIMITS, changed: ['context'] })
    expect(runs).toHaveLength(0)
  })

  test('a failing write never stops the measurement', async ($, on) => {
    world(on, { runFails: true })
    await start($)
    const r = await $.session.measure({ context: {}, rateLimits: LIMITS, changed: ['rateLimits'] })
    expect(r.changed).toEqual(['rateLimits'])
  })
})

describe('usage metering', () => {
  test('an agent turn appends one line with the spawn label', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.agent.spawn({ prompt: 'build T1', description: 'T1 build', subagentType: 'factory:builder' })
    await $.turn.complete(turn({ agentId: 'a1' }))
    const append = runs.find((r) => r.argv.at(-1) === '/proj/.factory/usage.jsonl')
    expect(append).toBeDefined()
    expect(append.init.stdin.endsWith('\n')).toBe(true)
    expect(JSON.parse(append.init.stdin)).toEqual({
      ts: NOW / 1000,
      turn: 't1',
      agent: 'a1',
      type: 'factory:builder',
      label: 'T1 build',
      model: 'claude-haiku-5-5',
      input: 10,
      output: 20,
      cache_read: 300,
      cache_write: 40,
      ms: 1200,
      reason: 'answer',
    })
  })

  test('a main-loop turn is recorded as main', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.turn.complete(turn())
    const append = runs.find((r) => r.argv.at(-1) === '/proj/.factory/usage.jsonl')
    expect(JSON.parse(append.init.stdin)).toMatchObject({ agent: 'main', type: 'main', label: null })
  })

  test('nothing is metered where the factory is not open', async ($, on) => {
    const runs = world(on, { active: false })
    await start($)
    await $.turn.complete(turn())
    expect(runs.filter((r) => r.argv.at(-1) === '/proj/.factory/usage.jsonl')).toHaveLength(0)
  })

  test('a turn with no usage is not metered and still completes', async ($, on) => {
    const runs = world(on)
    await start($)
    const r = await $.turn.complete(turn({ usage: undefined }))
    expect(r.text).toBe('done')
    expect(runs.filter((x) => x.argv.at(-1) === '/proj/.factory/usage.jsonl')).toHaveLength(0)
  })

  test('a failing append never stops the turn', async ($, on) => {
    world(on, { runFails: true })
    await start($)
    const r = await $.turn.complete(turn())
    expect(r.text).toBe('done')
  })
})

describe('/factory-board', () => {
  test('prints lane counts, the ready list and the quota with no model call', async ($, on) => {
    world(on, {
      files: {
        '/proj/tasks/backlog': true,
        '/home/u/.claude/.factory-quota.json': JSON.stringify({
          ts: NOW / 1000 - 120,
          seven_day: { used_percentage: 41, even_line: 42.9 },
        }),
      },
    })
    await start($)
    const r = await $.command.run({ command: 'factory-board', args: '', origin: { kind: 'user' } })
    expect(r.text).toBe(
      'backlog=1  in-progress=0  blocked=0  done=0\n' +
        'READY T1 api Add login\n' +
        'quota: 7-day 41% (even-spend line 42.9%), read 2 min ago',
    )
  })

  test('says so where the factory is not open', async ($, on) => {
    world(on, { active: false })
    await start($)
    const r = await $.command.run({ command: 'factory-board', args: '', origin: { kind: 'user' } })
    expect(r.text).toBe('factory is not initialised in this project')
  })
})

describe('hard blocks', () => {
  const call = ($, tool, input, agentId) => $.tool.call({ tool, ...input, ...(agentId ? { agentId } : {}) })

  test('a subagent git push is refused and the run is stopped', async ($, on) => {
    const runs = world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: 'git push origin main' }, 'a1')
    expect(JSON.stringify(r)).toContain('git-push')
    expect(runs.some((x) => JSON.stringify(x).includes('hard-blocks') || JSON.stringify(x).includes('trip'))).toBe(true)
  })

  test('the same push in the main session is not this hook\'s to refuse', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: 'git push origin main' })
    expect(JSON.stringify(r)).not.toContain('hard block')
  })

  test('a subagent write to .env is refused', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Write', { file_path: '/proj/.env', content: 'K=1' }, 'a1')
    expect(JSON.stringify(r)).toContain('env-file')
  })

  test('a clean subagent command goes through', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: 'git status' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('hard block')
  })

  test('nothing is judged where the factory is not open', async ($, on) => {
    world(on, { active: false })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: 'git push' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('hard block')
  })
})

describe('autonomy consent', () => {
  test('the phrase typed by the developer is handed to factory-consent.sh', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.prompt.submit({ text: 'auto devam et', origin: { kind: 'composer' } })
    expect(runs.some((x) => JSON.stringify(x).includes('factory-consent.sh'))).toBe(true)
  })

  test('the phrase with other words is not handed over', async ($, on) => {
    const runs = world(on)
    await start($)
    await $.prompt.submit({ text: 'yarın auto devam et', origin: { kind: 'composer' } })
    expect(runs.some((x) => JSON.stringify(x).includes('factory-consent.sh'))).toBe(false)
  })
})

describe('quota breaker on agent.spawn', () => {
  // elapsed is 42.9%, so 60% is past the line plus the margin of 10
  const LIMITS = [{ kind: 'seven_day', percentUsed: 60, resetsAt: '2026-10-12T00:00:00Z' }]
  const spawn = ($, type) => $.agent.spawn({ subagentType: type, description: 'T1', prompt: 'go' })

  test('a builder past the even line at level merge is refused', async ($, on) => {
    world(on, { level: 'merge', limits: LIMITS })
    await start($)
    await $.turn.complete(turn())
    const r = await spawn($, 'factory:builder')
    expect(JSON.stringify(r)).toContain('quota breaker')
  })

  test('the same spawn is allowed at level pr', async ($, on) => {
    world(on, { level: 'pr', limits: LIMITS })
    await start($)
    await $.turn.complete(turn())
    const r = await spawn($, 'factory:builder')
    expect(JSON.stringify(r)).not.toContain('quota breaker')
  })

  test('a reviewer is never gated', async ($, on) => {
    world(on, { level: 'merge', limits: LIMITS })
    await start($)
    await $.turn.complete(turn())
    const r = await spawn($, 'factory:reviewer')
    expect(JSON.stringify(r)).not.toContain('quota breaker')
  })

  test('no live reading lets the builder go', async ($, on) => {
    world(on, { level: 'merge', limits: [] })
    await start($)
    await $.turn.complete(turn())
    const r = await spawn($, 'factory:builder')
    expect(JSON.stringify(r)).not.toContain('quota breaker')
  })
})
