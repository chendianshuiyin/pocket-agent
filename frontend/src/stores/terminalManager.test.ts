import { describe, expect, it } from 'vitest'
import {
  MAX_TERMINAL_HISTORY,
  MAX_TERMINAL_OUTPUT_CHARS,
  TERMINAL_STORAGE_KEY,
  appendTerminalOutput,
  createTerminalManager,
  loadTerminalManager,
  markRunningTerminalsDisconnected,
  persistTerminalManager,
  rememberTerminalCommand,
} from './terminalManager'

describe('terminal manager', () => {
  it('首次使用会创建一个终端会话', () => {
    const manager = createTerminalManager('/repo', () => 'term-1')
    expect(manager.activeSessionId).toBe('term-1')
    expect(manager.sessions[0]).toMatchObject({ name: 'Terminal 1', cwd: '/repo', running: false })
  })

  it('只持久化终端元数据和历史，不持久化输出', () => {
    const storage = new MapStorage()
    const manager = createTerminalManager('/repo', () => 'term-1')
    const session = manager.sessions[0]!
    Object.assign(session, { command: 'npm test', output: 'secret output', running: true, processId: 'process-1' })
    rememberTerminalCommand(session, 'npm test')
    persistTerminalManager(manager, storage)

    const raw = storage.getItem(TERMINAL_STORAGE_KEY)!
    expect(raw).not.toContain('secret output')
    expect(raw).not.toContain('process-1')

    const restored = loadTerminalManager(storage, '/fallback', () => 'unused')
    expect(restored.sessions[0]).toMatchObject({ command: 'npm test', output: '', running: false, stale: true })
    expect(restored.sessions[0]!.error).toContain('原 PTY 已由服务器终止')
  })

  it('命令历史去重并限制长度', () => {
    const session = createTerminalManager('', () => 'term-1').sessions[0]!
    for (let index = 0; index < MAX_TERMINAL_HISTORY + 5; index += 1) rememberTerminalCommand(session, `command-${index}`)
    rememberTerminalCommand(session, 'command-10')
    expect(session.commandHistory).toHaveLength(MAX_TERMINAL_HISTORY)
    expect(session.commandHistory[0]).toBe('command-10')
    expect(session.commandHistory.filter((value) => value === 'command-10')).toHaveLength(1)
  })

  it('限制单会话内存输出并保留最新内容', () => {
    const session = createTerminalManager('', () => 'term-1').sessions[0]!
    appendTerminalOutput(session, 'a'.repeat(MAX_TERMINAL_OUTPUT_CHARS))
    appendTerminalOutput(session, 'LATEST')
    expect(session.output.length).toBe(MAX_TERMINAL_OUTPUT_CHARS)
    expect(session.output).toContain('较早的终端输出已截断')
    expect(session.output.endsWith('LATEST')).toBe(true)
  })

  it('断线时只把运行中的终端标记为 stale', () => {
    const manager = createTerminalManager('', () => 'term-1')
    const session = manager.sessions[0]!
    Object.assign(session, { running: true, interactive: true, processId: 'process-1' })
    markRunningTerminalsDisconnected(manager, 123)
    expect(session).toMatchObject({ running: false, interactive: false, processId: null, stale: true, completedAt: 123 })
  })
})

class MapStorage {
  private readonly values = new Map<string, string>()

  getItem(key: string): string | null {
    return this.values.get(key) ?? null
  }

  setItem(key: string, value: string): void {
    this.values.set(key, value)
  }
}
