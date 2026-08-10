export const TERMINAL_STORAGE_KEY = 'pocket.terminals.v1'
export const MAX_TERMINAL_SESSIONS = 8
export const MAX_TERMINAL_HISTORY = 40
export const MAX_TERMINAL_OUTPUT_CHARS = 512 * 1024

export interface TerminalSession {
  id: string
  name: string
  command: string
  commandHistory: string[]
  cwd: string
  stdin: string
  processId: string | null
  interactive: boolean
  running: boolean
  stale: boolean
  output: string
  exitCode: number | null
  error: string | null
  startedAt: number | null
  completedAt: number | null
  rows: number
  cols: number
}

export interface TerminalManagerState {
  sessions: TerminalSession[]
  activeSessionId: string
}

interface PersistedTerminalSession {
  id: string
  name: string
  command: string
  commandHistory: string[]
  cwd: string
  wasRunning: boolean
  exitCode: number | null
  startedAt: number | null
  completedAt: number | null
}

interface PersistedTerminalManager {
  version: 1
  activeSessionId: string
  sessions: PersistedTerminalSession[]
}

type TerminalStorage = Pick<Storage, 'getItem' | 'setItem'>

export function createTerminalSession(id: string, index: number, cwd = ''): TerminalSession {
  return {
    id,
    name: `Terminal ${index}`,
    command: '',
    commandHistory: [],
    cwd,
    stdin: '',
    processId: null,
    interactive: false,
    running: false,
    stale: false,
    output: '',
    exitCode: null,
    error: null,
    startedAt: null,
    completedAt: null,
    rows: 28,
    cols: 100,
  }
}

export function createTerminalManager(cwd: string, createId: () => string): TerminalManagerState {
  const session = createTerminalSession(createId(), 1, cwd)
  return { sessions: [session], activeSessionId: session.id }
}

export function loadTerminalManager(storage: TerminalStorage | undefined, cwd: string, createId: () => string): TerminalManagerState {
  if (!storage) return createTerminalManager(cwd, createId)
  try {
    const parsed = JSON.parse(storage.getItem(TERMINAL_STORAGE_KEY) ?? '') as Partial<PersistedTerminalManager>
    if (parsed.version !== 1 || !Array.isArray(parsed.sessions) || parsed.sessions.length === 0) {
      return createTerminalManager(cwd, createId)
    }
    const sessions = parsed.sessions.slice(0, MAX_TERMINAL_SESSIONS).flatMap((value, index) => {
      if (!isPersistedSession(value)) return []
      const session = createTerminalSession(value.id, index + 1, value.cwd || cwd)
      Object.assign(session, {
        name: value.name.trim() || `Terminal ${index + 1}`,
        command: value.command,
        commandHistory: value.commandHistory.filter((item) => typeof item === 'string').slice(0, MAX_TERMINAL_HISTORY),
        exitCode: value.exitCode,
        startedAt: value.startedAt,
        completedAt: value.completedAt,
        stale: value.wasRunning,
        error: value.wasRunning ? '页面重载或连接中断，原 PTY 已由服务器终止' : null,
      })
      return [session]
    })
    if (sessions.length === 0) return createTerminalManager(cwd, createId)
    const activeSessionId = sessions.some((session) => session.id === parsed.activeSessionId)
      ? String(parsed.activeSessionId)
      : sessions[0]!.id
    return { sessions, activeSessionId }
  } catch {
    return createTerminalManager(cwd, createId)
  }
}

export function persistTerminalManager(manager: TerminalManagerState, storage: TerminalStorage | undefined): void {
  if (!storage) return
  const persisted: PersistedTerminalManager = {
    version: 1,
    activeSessionId: manager.activeSessionId,
    sessions: manager.sessions.map((session) => ({
      id: session.id,
      name: session.name,
      command: session.command,
      commandHistory: session.commandHistory.slice(0, MAX_TERMINAL_HISTORY),
      cwd: session.cwd,
      wasRunning: session.running,
      exitCode: session.exitCode,
      startedAt: session.startedAt,
      completedAt: session.completedAt,
    })),
  }
  try {
    storage.setItem(TERMINAL_STORAGE_KEY, JSON.stringify(persisted))
  } catch {
    // Terminal metadata is helpful but should never make command execution fail.
  }
}

export function appendTerminalOutput(session: TerminalSession, chunk: string): void {
  const next = session.output + chunk
  if (next.length <= MAX_TERMINAL_OUTPUT_CHARS) {
    session.output = next
    return
  }
  const marker = '[较早的终端输出已截断]\n'
  session.output = marker + next.slice(-(MAX_TERMINAL_OUTPUT_CHARS - marker.length))
}

export function rememberTerminalCommand(session: TerminalSession, command: string): void {
  const trimmed = command.trim()
  if (!trimmed) return
  session.commandHistory = [trimmed, ...session.commandHistory.filter((item) => item !== trimmed)].slice(0, MAX_TERMINAL_HISTORY)
}

export function markRunningTerminalsDisconnected(manager: TerminalManagerState, completedAt = Date.now()): void {
  for (const session of manager.sessions) {
    if (!session.running) continue
    Object.assign(session, {
      processId: null,
      interactive: false,
      running: false,
      stale: true,
      completedAt,
      error: '连接已断开，服务器已终止此 PTY',
    })
  }
}

function isPersistedSession(value: unknown): value is PersistedTerminalSession {
  if (!value || typeof value !== 'object') return false
  const session = value as Record<string, unknown>
  return typeof session.id === 'string'
    && typeof session.name === 'string'
    && typeof session.command === 'string'
    && Array.isArray(session.commandHistory)
    && typeof session.cwd === 'string'
    && typeof session.wasRunning === 'boolean'
    && (session.exitCode === null || typeof session.exitCode === 'number')
    && (session.startedAt === null || typeof session.startedAt === 'number')
    && (session.completedAt === null || typeof session.completedAt === 'number')
}
