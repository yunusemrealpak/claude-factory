// Runs tests/hardblock-cases.txt through register.js's tool.call hook - the
// JavaScript half of the hard-block judge - and prints one line per case that
// does not come out as the file says, then "cases=N wrong=M".
// Usage: node tests/hb-cases.mjs [cases file]
import fs from 'fs'
import os from 'os'
import path from 'path'
import url from 'url'

const here = path.dirname(url.fileURLToPath(import.meta.url))
const plugin = path.join(here, '..')
// register.js is an ES module without a package.json saying so: node reads it
// under its own name only as .mjs.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hb-'))
fs.copyFileSync(path.join(plugin, 'hooks', 'register.js'), path.join(tmp, 'register.mjs'))
const { register } = await import(url.pathToFileURL(path.join(tmp, 'register.mjs')).href)
const rulesText = fs.readFileSync(path.join(plugin, 'hooks', 'hard-blocks.txt'), 'utf8')
const ROOT = '/home/u/proj'
const TOOL = { bash: 'Bash', powershell: 'PowerShell', path: 'Write' }

async function judge(kind, root, text) {
  const handlers = {}
  const on = (name, a, b) => {
    const chain = { catch: () => chain }
    handlers[name] = typeof a === 'function' ? a : b
    return chain
  }
  register(on)
  const $ = {
    session: { root: async () => root },
    fs: {
      exists: async (p) => /\/\.factory\/active$/.test(String(p).replace(/\\/g, '/')),
      read: async (p) => (/hard-blocks\.txt$/.test(String(p)) ? rulesText : '{}'),
      list: async () => [],
    },
    plugin: { root: plugin },
    env: { get: async () => '' },
    process: { run: async () => ({ exitCode: 0, stdout: '', stderr: '' }) },
  }
  const e = { agentId: 'a1', tool: TOOL[kind] }
  if (kind === 'path') e.file_path = text
  else e.command = text
  const r = await handlers['tool.call']($, e, () => 'ALLOW')
  if (r === 'ALLOW') return 'clean'
  const d = String((r && r.deny) || '')
  let m = d.match(/^Factory hard block \(([^)]+)\)/)
  if (m) return 'hard:' + m[1]
  m = d.match(/^Factory: inline code .*?\(([^)]+)\)/)
  if (m) return 'soft:' + m[1]
  return 'other:' + d.slice(0, 80)
}

const file = process.argv[2] || path.join(here, 'hardblock-cases.txt')
let n = 0
let wrong = 0
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  if (!line || line.startsWith('#')) continue
  const [expect, kind, rootField, raw] = line.split('\t')
  const root = rootField === '-' ? ROOT : rootField
  const text = raw.split('{R}').join(root).split('{NL}').join('\n')
  const got = await judge(kind, root, text)
  n += 1
  if (got !== expect) {
    wrong += 1
    console.log('WRONG ' + kind + ' ' + JSON.stringify(text) + ': expected ' + expect + ', got ' + got)
  }
}
fs.rmSync(tmp, { recursive: true, force: true })
console.log('cases=' + n + ' wrong=' + wrong)
process.exit(wrong ? 1 : 0)
