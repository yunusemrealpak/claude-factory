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

// What one model request of a subagent costs in the tests: 2,000 tokens that
// count, and cache reads that do not.
const STEP_USAGE = {
  model: 'claude-haiku-5-5',
  input_tokens: 500,
  output_tokens: 1000,
  cache_read_input_tokens: 90000,
  cache_creation_input_tokens: 500,
}

// A cut of hooks/hard-blocks.txt, in its own format.
const RULE_LINES = [
  'hard_blocks_version: 2',
  'bash ## git-push ## (^|[^[:alnum:]_.-])git([[:space:]]+-[A-Za-z-]+)*[[:space:]]+push([[:space:];&|)]|$)',
  'bash ## git-tree-write ## (^|[^[:alnum:]_.-])git([[:space:]]+-[A-Za-z-]+)*[[:space:]]+(add|commit|stash|reset|checkout|restore)([[:space:];&|)]|$)',
  'path ## env-file ## any ## \\.env(\\.[^/[:space:]]*)?',
  'path ## gates-dir ## root ## gates/.*',
  'path ## factory-config ## root ## \\.factory/config\\.json',
  'path ## autonomy-consent ## root ## \\.factory/autonomy.*',
  'path ## factory-verified ## root ## \\.factory/verified/.* ## create-only',
  'deny ## Bash(git push *)',
]
const RULES = RULE_LINES.join('\n')

// The engine hands a file noun the path in the host's own spelling: on Windows
// /proj/x arrives as C:\proj\x. The mocks compare it in one spelling.
const P = (p) => String(p).replace(/\\/g, '/').replace(/^[A-Za-z]:/, '')

// Answers every call the module makes in Claude Code's place and records the
// processes it starts. `active` is whether the factory is open in /proj.
function world(on, { active = true, runFails = false, files = {}, level = '', limits = [], rootPath = '/proj', rules = RULES, env = { HOME: '/home/u' }, readonly = '', step = STEP_USAGE, lists = {} } = {}) {
  const runs = []
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.root', () => ({ value: rootPath }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('clock.now', () => ({ value: NOW }))
  on('env.get', (_$, e) => ({ value: env[e.name] }))
  on('fs.exists', (_$, e) => ({ value: P(e.path).endsWith('/.factory/active') ? active : P(e.path) in files }))
  on('fs.read', (_$, e) => ({ value: P(e.path).endsWith('/hard-blocks.txt') ? rules : files[P(e.path)] }))
  on('fs.list', (_$, e) => ({ value: lists[P(e.path)] || [{ name: 'T1.md', kind: 'file', size: 1, isLink: false }] }))
  on('agent.list', () => ({ value: [] }))
  on('session.id', () => ({ value: 's1' }))
  on('prompt.submit', (_$, e) => ({ text: e.text }))
  on('session.usage', () => ({ value: { context: {}, rateLimits: limits } }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('agent.spawn', () => ({ model: 'claude-haiku-5-5', agentId: 'a1' }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  // Every model request answers with one tool call and costs `step`.
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'tool_use', usage: step }
  })
  on('process.run', (_$, e) => {
    runs.push(e)
    if (runFails) return { deny: 'no processes in this test' }
    if (level && JSON.stringify(e).includes('factory-autonomy.sh')) return { value: { exitCode: 0, stdout: level + '\n', stderr: '' } }
    if (readonly && JSON.stringify(e).includes('factory-hardblock.sh","tests')) return { value: { exitCode: 6, stdout: 'head-tests ' + readonly + '\n', stderr: '' } }
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

describe('the shell it runs', () => {
  test('the Git Bash Claude Code was pointed at is the one every script runs in', async ($, on) => {
    const runs = world(on, { env: { HOME: '/home/u', CLAUDE_CODE_GIT_BASH_PATH: 'D:/Git/bin/bash.exe' } })
    await start($)
    await $.session.measure({ context: {}, rateLimits: LIMITS, changed: ['rateLimits'] })
    expect(runs[0].argv[0]).toBe('D:/Git/bin/bash.exe')
  })

  test('with no HOME, as a native Windows process may have, USERPROFILE is home', async ($, on) => {
    const runs = world(on, { env: { USERPROFILE: 'C:\\Users\\u' } })
    await start($)
    await $.session.measure({ context: {}, rateLimits: LIMITS, changed: ['rateLimits'] })
    expect(runs[0].argv.at(-1)).toBe('C:/Users/u/.claude/.factory-quota.json')
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

  // Each case: [what, tool, input, rule or null for a clean call, options]
  const CASES = [
    ['a Windows path inside the root', 'Write', { file_path: 'C:\\proj\\gates\\verify.sh' }, 'gates-dir', { rootPath: 'C:\\proj' }],
    ['the /c/ spelling in a command', 'Bash', { command: 'echo {} > /c/proj/.factory/config.json' }, 'factory-config', { rootPath: 'C:\\proj' }],
    ['the root in another letter case', 'Write', { file_path: 'c:/PROJ/.factory/config.json' }, 'factory-config', { rootPath: 'C:\\proj' }],
    ['a folder in another letter case', 'Write', { file_path: '/proj/GATES/x.sh' }, 'gates-dir'],
    ['dir/../ inside the root', 'Write', { file_path: '/proj/src/../gates/verify.sh' }, 'gates-dir'],
    ['../ from a subfolder', 'Bash', { command: 'cd src && echo x > ../gates/verify.sh' }, 'gates-dir'],
    ['PowerShell Set-Content', 'PowerShell', { command: 'Set-Content gates\\verify.sh x' }, 'gates-dir'],
    ['MultiEdit', 'MultiEdit', { file_path: '/proj/.factory/config.json' }, 'factory-config'],
    ['python -c writing a marker', 'Bash', { command: "python3 -c \"open('.factory/verified/T1','w').write('ok')\"" }, 'factory-verified'],
    ['python reading the config', 'Bash', { command: "python3 -c \"print(open('.factory/config.json').read())\"" }, null],
    ['removing a marker', 'Bash', { command: 'rm -f .factory/verified/T1' }, null],
    ['git checkout on the shared tree', 'Bash', { command: 'git checkout -- src/a.txt' }, 'git-tree-write'],
    ['git diff', 'Bash', { command: 'git diff --stat' }, null],
    ['a nested gates/ folder', 'Write', { file_path: '/proj/src/gates/x.ts' }, null],
  ]
  for (const [what, tool, input, rule, opts] of CASES) {
    test((rule ? 'refused: ' : 'passes: ') + what, async ($, on) => {
      world(on, opts || {})
      on('tool.call', () => ({ result: 'ran' }))
      await start($)
      const r = JSON.stringify(await call($, tool, input, 'a1'))
      if (rule) expect(r).toContain('(' + rule + ')')
      else expect(r).not.toContain('hard block')
    })
  }

  test('a rules file with CRLF line ends still refuses', async ($, on) => {
    world(on, { rules: RULE_LINES.join('\r\n') })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: 'git push origin main' }, 'a1')
    expect(JSON.stringify(r)).toContain('git-push')
  })

  test('a tool the factory cannot judge is refused without halting the run', async ($, on) => {
    const runs = world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'mcp__github__merge_pull_request', { pullNumber: 3 }, 'a1')
    expect(JSON.stringify(r)).toContain('tools the factory can judge')
    expect(runs.some((x) => JSON.stringify(x).includes('trip'))).toBe(false)
  })

  test('inline code that writes a protected path is refused without halting the run', async ($, on) => {
    const runs = world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Bash', { command: `python3 -c "open('.factory/config.json','w').write('{}')"` }, 'a1')
    expect(JSON.stringify(r)).toContain('inline code')
    expect(JSON.stringify(r)).toContain('factory-config')
    expect(runs.some((x) => JSON.stringify(x).includes('trip'))).toBe(false)
  })

  test('a builder that records the run start again is refused and the run is stopped', async ($, on) => {
    const runs = world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await $.agent.spawn({ subagentType: 'factory:builder', description: 'T1', prompt: 'go' })
    const r = await call($, 'Bash', { command: 'factory-plan --json --start' }, 'a1')
    expect(JSON.stringify(r)).toContain('plan-start')
    expect(runs.some((x) => JSON.stringify(x).includes('trip'))).toBe(true)
  })

  test('the runner records the run start', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await $.agent.spawn({ subagentType: 'factory:runner', description: 'plan', prompt: 'go' })
    const r = await call($, 'Bash', { command: 'factory-plan --json --start' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('hard block')
  })

  test('an edit of a test HEAD has is refused without halting the run', async ($, on) => {
    const runs = world(on, { readonly: 'tests/test_a.py' })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Edit', { file_path: '/proj/tests/test_a.py' }, 'a1')
    expect(JSON.stringify(r)).toContain('tests/test_a.py is a test the project already has')
    expect(runs.some((x) => JSON.stringify(x).includes('trip'))).toBe(false)
  })

  test('a call that names no test asks nothing about tests', async ($, on) => {
    const runs = world(on, { readonly: 'tests/test_a.py' })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Write', { file_path: '/proj/src/app.py' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('deny')
    expect(runs.some((x) => JSON.stringify(x).includes('factory-hardblock.sh","tests'))).toBe(false)
  })

  test('a read-only check that cannot run lets the call through', async ($, on) => {
    world(on, { runFails: true })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Edit', { file_path: '/proj/tests/test_a.py' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('read-only')
  })

  test('a read-only tool goes through', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    const r = await call($, 'Read', { file_path: '/proj/.factory/config.json' }, 'a1')
    expect(JSON.stringify(r)).not.toContain('deny')
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

describe('builder budget', () => {
  const call = ($, tool, input, agentId = 'a1') => $.tool.call({ tool, ...input, ...(agentId ? { agentId } : {}) })
  const cfg = (budget) => ({ '/proj/.factory/config.json': JSON.stringify({ fast: { budget } }) })
  const spawn = ($, type = 'factory:builder', description = 'T1') => $.agent.spawn({ subagentType: type, description, prompt: 'go' })
  async function steps($, n, agentId = 'a1') {
    for (let i = 0; i < n; i++) {
      const s = $.turn.step({ turnId: 'tb', index: i, model: 'claude-haiku-5-5', messageCount: 1 + i, ...(agentId ? { agentId } : {}) })
      for await (const _c of s) {
      }
      await s.result
    }
  }
  const budgetLines = (runs) =>
    runs.filter((r) => r.argv.at(-1) === '/proj/.factory/events.jsonl').map((r) => JSON.parse(r.init.stdin))

  test('a builder past its turn ceiling is refused, and told the way out', async ($, on) => {
    world(on, { files: cfg({ turns: 3 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($, 'factory:builder', 'C2-01 retry')
    await steps($, 3)
    const r = JSON.stringify(await call($, 'Bash', { command: 'npm test' }))
    expect(r).toContain('budget full for C2-01')
    expect(r).toContain('factory-settle C2-01 \\"budget: 3 turns, 6k tokens\\"')
    expect(r).not.toContain('"ran"')
  })

  test('below the ceiling the same call runs', async ($, on) => {
    world(on, { files: cfg({ turns: 3 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 2)
    const r = JSON.stringify(await call($, 'Bash', { command: 'npm test' }))
    expect(r).toContain('ran')
    expect(r).not.toContain('budget full')
  })

  test('past the ceiling factory-settle, factory-block and factory-ask still run', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 1)
    for (const command of [
      'factory-settle T1 "budget: 1 turns, 2k tokens"',
      "factory-block T1 'needs a decision; the budget ran out'",
      '/opt/p/bin/factory-ask T1 "which one?"',
    ]) {
      expect(JSON.stringify(await call($, 'Bash', { command }))).toContain('ran')
    }
  })

  test('a way out chained to another command is refused', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 1)
    for (const command of [
      'factory-settle T1 x && npm test',
      'factory-settle T1 "$(npm test)"',
      'factory-settle T1 x | tee log',
      'echo factory-settle T1',
    ]) {
      expect(JSON.stringify(await call($, 'Bash', { command }))).toContain('budget full')
    }
  })

  test('past the ceiling the task file and decisions.md may be read and written, nothing else', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 1)
    expect(JSON.stringify(await call($, 'Read', { file_path: '/proj/tasks/in-progress/T1.md' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'Edit', { file_path: '/proj/tasks/in-progress/T1.md', old_string: 'a', new_string: 'b' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'Write', { file_path: '/proj/decisions.md', content: '- T1: x' }))).toContain('ran')
    // A builder in its own checkout (fast.isolation) has its task file there.
    expect(JSON.stringify(await call($, 'Edit', { file_path: '/proj/.factory-worktrees/task-T1/tasks/in-progress/T1.md', old_string: 'a', new_string: 'b' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'Write', { file_path: '/proj/.factory-worktrees/task-T1/src/a.ts', content: 'x' }))).toContain('budget full')
    expect(JSON.stringify(await call($, 'StructuredOutput', { status: 'budget' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'Write', { file_path: '/proj/src/a.ts', content: 'x' }))).toContain('budget full')
    expect(JSON.stringify(await call($, 'Write', { file_path: '/proj/tasks/../src/a.ts', content: 'x' }))).toContain('budget full')
    expect(JSON.stringify(await call($, 'Grep', { pattern: 'x' }))).toContain('budget full')
  })

  test('the hard blocks are judged first, past the ceiling too', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 1)
    const r = JSON.stringify(await call($, 'Bash', { command: 'git push origin main' }))
    expect(r).toContain('git-push')
    expect(r).not.toContain('budget full')
  })

  test('tokens count input, output and cache writes, never cache reads', async ($, on) => {
    world(on, { files: cfg({ turns: 1000, tokens: 5000 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 2)
    // 2 x 2,000 = 4,000 of 5,000: past 80%, not full (cache reads would be 180k)
    const below = await call($, 'Bash', { command: 'npm test' })
    expect(JSON.stringify(below)).toContain('ran')
    await steps($, 1)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).toContain('budget full')
  })

  test('at 80% the call runs and the builder is told once', async ($, on) => {
    world(on, { files: cfg({ turns: 10 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 7)
    const before = await call($, 'Bash', { command: 'ls' })
    expect(before.context || []).toHaveLength(0)
    await steps($, 1)
    const first = await call($, 'Bash', { command: 'ls' })
    expect(JSON.stringify(first)).toContain('ran')
    expect(first.context).toHaveLength(1)
    expect(first.context[0]).toContain('8 of 10 turns')
    const second = await call($, 'Bash', { command: 'ls' })
    expect(JSON.stringify(second)).toContain('ran')
    expect(second.context || []).toHaveLength(0)
  })

  test('a full budget and the 80% line are each recorded in events.jsonl once', async ($, on) => {
    const runs = world(on, { files: cfg({ turns: 5 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 4)
    await call($, 'Bash', { command: 'ls' })
    await call($, 'Bash', { command: 'ls' })
    await steps($, 1)
    await call($, 'Bash', { command: 'ls' })
    await call($, 'Bash', { command: 'ls' })
    const lines = budgetLines(runs)
    expect(lines.map((l) => l.level)).toEqual(['warn', 'full'])
    expect(lines[1]).toMatchObject({ kind: 'budget', task: 'T1', turns: 5, tokens: 10000, limit_turns: 5, limit_tokens: 3000000, epoch: NOW / 1000 })
  })

  test('a reviewer is never limited', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($, 'factory:reviewer', 'T1 review')
    await steps($, 5)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('budget')
  })

  test('the main session is never limited', async ($, on) => {
    world(on, { files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await steps($, 5, null)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }, null))).not.toContain('budget')
  })

  test('with no fast.budget a builder has 150 turns', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 149)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).toContain('ran')
    await steps($, 1)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).toContain('150 of 150 turns')
  })

  test('a turn limit past maxTurns is held below it', async ($, on) => {
    world(on, { files: cfg({ turns: 1000 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 230)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).toContain('230 of 230 turns')
  })

  test('fast.budget false lifts the budget', async ($, on) => {
    world(on, { files: cfg(false) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 240)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('budget')
  })

  test('where the factory is not open nothing is limited', async ($, on) => {
    world(on, { active: false, files: cfg({ turns: 1 }) })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 3)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('budget')
  })

  test('a config that cannot be read is the default budget', async ($, on) => {
    world(on, { files: { '/proj/.factory/config.json': '{ not json' } })
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    await steps($, 150)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).toContain('150 of 150 turns')
  })
})

describe('stuck builder (fast.stuck)', () => {
  const call = ($, tool, input, agentId = 'a1') => $.tool.call({ tool, ...input, ...(agentId ? { agentId } : {}) })
  const cfg = (fast) => ({ '/proj/.factory/config.json': JSON.stringify({ fast }) })
  const spawn = ($, type = 'factory:builder', description = 'T1') => $.agent.spawn({ subagentType: type, description, prompt: 'go' })
  const stuckLines = (runs) =>
    runs.filter((r) => r.argv.at(-1) === '/proj/.factory/events.jsonl').map((r) => JSON.parse(r.init.stdin)).filter((l) => l.kind === 'stuck')
  // A failing test run, its time different every run.
  let n = 0
  const red = () => ({ result: 'Exit code 1\nFAIL tests/a.test.ts\nTime: ' + (++n) + '.2 s, at 2026-10-08T00:00:0' + (n % 10) + 'Z' })

  test('the same failure 3 times is told once, a second time sends the builder out', async ($, on) => {
    const runs = world(on, { files: cfg({ stuck: true }) })
    on('tool.call', (_$, e) => (/^\s*npm\s+test\s*$/.test(e.command || '') ? red() : { result: 'ran' }))
    await start($)
    await spawn($, 'factory:builder', 'C2-01 retry')
    const a = await call($, 'Bash', { command: 'npm test' })
    const b = await call($, 'Bash', { command: 'npm  test ' })
    expect((a.context || []).length + (b.context || []).length).toBe(0)
    const c = await call($, 'Bash', { command: 'npm test' })
    expect(c.context).toHaveLength(1)
    expect(c.context[0]).toContain('failed the same way 3 times')
    expect(c.context[0]).toContain('factory-settle C2-01 "no_progress: npm test failed the same way 3 times in a row"')
    // The reminder starts the count again: the next two runs go by.
    await call($, 'Bash', { command: 'npm test' })
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('stuck')
    const f = await call($, 'Bash', { command: 'npm test' })
    expect(f.context[0]).toContain('second time')
    const g = JSON.stringify(await call($, 'Bash', { command: 'ls src' }))
    expect(g).toContain('C2-01 is stuck')
    expect(g).not.toContain('"ran"')
    expect(JSON.stringify(await call($, 'Edit', { file_path: '/proj/src/a.ts', old_string: 'a', new_string: 'b' }))).toContain('is stuck')
    for (const command of ['factory-settle C2-01 "no_progress: npm test failed the same way 3 times in a row"', "factory-block C2-01 'stuck'"]) {
      expect(JSON.stringify(await call($, 'Bash', { command }))).toContain('ran')
    }
    expect(JSON.stringify(await call($, 'Edit', { file_path: '/proj/tasks/in-progress/C2-01.md', old_string: 'a', new_string: 'b' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'StructuredOutput', { status: 'no_progress' }))).toContain('ran')
    expect(stuckLines(runs).map((l) => [l.outcome, l.task, l.pattern])).toEqual([
      ['warn', 'C2-01', 'error'],
      ['exit', 'C2-01', 'error'],
    ])
  })

  test('the same call with the same answer 4 times is told', async ($, on) => {
    world(on, { files: cfg({ stuck: true }) })
    on('tool.call', () => ({ result: 'same file' }))
    await start($)
    await spawn($)
    for (let i = 0; i < 3; i++) expect(await call($, 'Read', { file_path: '/proj/src/a.ts' })).not.toHaveProperty('context')
    const d = await call($, 'Read', { file_path: '/proj/src/a.ts' })
    expect(d.context[0]).toContain('Read src/a.ts gave the same result 4 times in a row')
  })

  test('two calls taking turns 6 times are told', async ($, on) => {
    world(on, { files: cfg({ stuck: true }) })
    on('tool.call', (_$, e) => (e.tool === 'Bash' ? red() : { result: 'edited' }))
    await start($)
    await spawn($)
    let last = null
    for (let i = 0; i < 3; i++) {
      await call($, 'Edit', { file_path: '/proj/src/a.ts', old_string: 'x', new_string: 'y' })
      last = await call($, 'Bash', { command: 'npm test' })
    }
    expect(last.context[0]).toContain('Edit src/a.ts and npm test took turns 6 times')
  })

  test('an answer that changes is progress, not a loop', async ($, on) => {
    world(on, { files: cfg({ stuck: true }) })
    let k = 0
    on('tool.call', () => ({ result: 'Exit code 1\n' + (10 - ++k) + ' tests failed' }))
    await start($)
    await spawn($)
    for (let i = 0; i < 8; i++) expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('stuck')
  })

  test('polling is never counted', async ($, on) => {
    world(on, { files: cfg({ stuck: true }) })
    on('tool.call', () => ({ result: 'nothing yet' }))
    await start($)
    await spawn($)
    for (const command of ['sleep 30', 'git status', 'git log --oneline -5', 'git status 2>&1', 'ls -la src', 'date']) {
      for (let i = 0; i < 6; i++) expect(JSON.stringify(await call($, 'Bash', { command }))).not.toContain('stuck')
    }
    for (let i = 0; i < 6; i++) expect(JSON.stringify(await call($, 'TaskOutput', { task_id: 'b1' }))).not.toContain('stuck')
  })

  test('off by default', async ($, on) => {
    world(on)
    on('tool.call', () => red())
    await start($)
    await spawn($)
    for (let i = 0; i < 10; i++) expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('stuck')
  })

  test('a reviewer and the main session are never limited', async ($, on) => {
    world(on, { files: cfg({ stuck: true }) })
    on('tool.call', () => red())
    await start($)
    await spawn($, 'factory:reviewer', 'T1 review')
    for (let i = 0; i < 10; i++) expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('stuck')
    for (let i = 0; i < 10; i++) expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }, null))).not.toContain('stuck')
  })

  test('where the factory is not open nothing is watched', async ($, on) => {
    world(on, { active: false, files: cfg({ stuck: true }) })
    on('tool.call', () => red())
    await start($)
    await spawn($)
    for (let i = 0; i < 10; i++) expect(JSON.stringify(await call($, 'Bash', { command: 'npm test' }))).not.toContain('stuck')
  })
})

describe('project rules (.factory/rules)', () => {
  const call = ($, tool, input, agentId = 'a1') => $.tool.call({ tool, ...input, ...(agentId ? { agentId } : {}) })
  const spawn = ($, type = 'factory:builder', description = 'T1') => $.agent.spawn({ subagentType: type, description, prompt: 'go' })
  const D = '/proj/.factory/rules'
  const rule = (name, match, pattern, action, message) =>
    ['# Factory rule, applied by factory-retro-apply (2026-10-20/P2).', 'name: ' + name, 'match: ' + match, 'pattern: ' + pattern, 'action: ' + action,
      'message: ' + message, 'evidence: C2-03, sig-abcdef123456', 'added: 2026-10-20T00:00:00Z'].join('\n') + '\n'
  function withRules(rs) {
    const files = { [D]: '' }
    const lists = { [D]: [] }
    for (const [name, ...r] of rs) {
      files[D + '/' + name + '.rule'] = rule(name, ...r)
      lists[D].push({ name: name + '.rule', kind: 'file', size: 100, isLink: false })
    }
    lists[D].push({ name: 'notes.md', kind: 'file', size: 1, isLink: false })
    return { files, lists }
  }
  const ruleLines = (runs) =>
    runs.filter((r) => r.argv.at(-1) === '/proj/.factory/events.jsonl').map((r) => JSON.parse(r.init.stdin)).filter((l) => l.kind === 'lesson_rule')

  test('a warn rule lets the call run and reminds the builder', async ($, on) => {
    const runs = world(on, withRules([['pnpm-only', 'bash', '(^|[\\s;&|])npm\\s+(install|i)(\\s|$)', 'warn', 'This repo uses pnpm; npm install rewrites the lockfile.']]))
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    const r = await call($, 'Bash', { command: 'cd web && NPM install left-pad' })
    expect(JSON.stringify(r)).toContain('ran')
    expect(r.context).toEqual(['Factory rule pnpm-only (a lesson from C2-03, sig-abcdef123456): This repo uses pnpm; npm install rewrites the lockfile.'])
    expect(await call($, 'Bash', { command: 'pnpm install' })).not.toHaveProperty('context')
    expect(ruleLines(runs).map((l) => [l.rule, l.outcome, l.task])).toEqual([['pnpm-only', 'warn', 'T1']])
  })

  test('a block rule refuses the call and does not halt the run', async ($, on) => {
    const runs = world(on, withRules([
      ['no-legacy', 'path', '^src/legacy/', 'block', 'src/legacy is frozen; add new code under src/core.'],
      ['no-console', 'content', 'console\\.log\\(', 'warn', 'Use the logger, not console.log.'],
    ]))
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    const r = JSON.stringify(await call($, 'Write', { file_path: '/proj/src/legacy/a.ts', content: 'x' }))
    expect(r).toContain('Factory rule no-legacy')
    expect(r).toContain('src/legacy is frozen')
    expect(r).not.toContain('"ran"')
    const e = await call($, 'Edit', { file_path: '/proj/src/core/a.ts', old_string: 'a', new_string: 'console.log(1)' })
    expect(JSON.stringify(e)).toContain('ran')
    expect(e.context[0]).toContain('Use the logger')
    expect(runs.some((x) => JSON.stringify(x).includes('"trip"'))).toBe(false)
    expect(ruleLines(runs).map((l) => [l.rule, l.outcome])).toEqual([['no-legacy', 'block'], ['no-console', 'warn']])
  })

  test('a rule never stops a factory command or a task file write', async ($, on) => {
    world(on, withRules([
      ['no-settle', 'bash', 'settle|check|block', 'block', 'never'],
      ['no-tasks', 'path', '.*', 'block', 'never'],
      ['no-words', 'content', 'red', 'block', 'never'],
    ]))
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    for (const command of ['factory-settle T1 "red: check failed"', 'factory-check T1 2>&1 | tail -20', '/opt/p/hooks/factory-block.sh T1 x']) {
      const r = await call($, 'Bash', { command })
      expect(JSON.stringify(r)).toContain('ran')
      expect(r).not.toHaveProperty('context')
    }
    for (const file_path of ['/proj/tasks/in-progress/T1.md', '/proj/decisions.md']) {
      expect(JSON.stringify(await call($, 'Edit', { file_path, old_string: 'a', new_string: 'went red' }))).toContain('ran')
    }
  })

  test('no rules, no change', async ($, on) => {
    world(on)
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    const r = await call($, 'Bash', { command: 'npm install left-pad' })
    expect(JSON.stringify(r)).toContain('ran')
    expect(r).not.toHaveProperty('context')
  })

  test('rules are for builders only', async ($, on) => {
    world(on, withRules([['pnpm-only', 'bash', 'npm install', 'block', 'pnpm']]))
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($, 'factory:reviewer', 'T1 review')
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm install' }))).toContain('ran')
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm install' }, null))).toContain('ran')
  })

  test('a rule JavaScript cannot read is left out, and the others still apply', async ($, on) => {
    world(on, withRules([
      ['broken', 'bash', '(unclosed', 'block', 'x'],
      ['pnpm-only', 'bash', 'npm install', 'block', 'pnpm'],
    ]))
    on('tool.call', () => ({ result: 'ran' }))
    await start($)
    await spawn($)
    expect(JSON.stringify(await call($, 'Bash', { command: 'npm install' }))).toContain('Factory rule pnpm-only')
    expect(JSON.stringify(await call($, 'Bash', { command: 'make build' }))).toContain('ran')
  })
})
