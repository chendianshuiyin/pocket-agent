import { computed, reactive, readonly } from 'vue'
import type { SlashCommandName } from '../commands/slashCommands'
import { configureGatewayConnection } from '../gateway/SshGatewayClient'
import type { GatewayMode, GatewaySshStatus } from '../gateway/SshGatewayClient'
import type { ConnectionSnapshot } from '../rpc/JsonRpcClient'
import { JsonRpcClient } from '../rpc/JsonRpcClient'
import { asRecord, isRecord, stringField } from '../protocol/guards'
import type {
  AppInfo,
  ApprovalDecision,
  FsReadDirectoryEntry,
  McpServerStatus,
  Model,
  RpcNotification,
  ServerRequestEnvelope,
  SkillErrorInfo,
  SkillMetadata,
  TerminalLine,
  Thread,
  ThreadItem,
  ToolRequestUserInputParams,
  Turn,
  UnknownRecord,
  UserInput,
} from '../protocol/types'
import { decodeBase64Utf8, encodeUtf8Base64, fileToBase64 } from '../utils/encoding'
import { basename, isImagePath, joinPath, parentPath } from '../utils/paths'
import {
  MAX_TERMINAL_SESSIONS,
  appendTerminalOutput,
  createTerminalSession,
  loadTerminalManager,
  markRunningTerminalsDisconnected,
  persistTerminalManager,
  rememberTerminalCommand,
} from './terminalManager'
import type { TerminalManagerState, TerminalSession } from './terminalManager'

type MainTab = 'chat' | 'threads' | 'files' | 'terminal' | 'apps'

export interface SettingsState {
  endpoint: string
  token: string
  rememberToken: boolean
  connectionMode: GatewayMode
  sshTarget: string
  sshPort: string
  sshIdentityFile: string
  sshRemotePort: string
  sshCodexBin: string
  cwd: string
  model: string
  effort: string
  sandbox: 'read-only' | 'workspace-write' | 'danger-full-access'
  approvalPolicy: 'untrusted' | 'on-request' | 'never'
}

export interface SshConnectionState extends GatewaySshStatus {
  connecting: boolean
  error: string | null
}

export interface PendingServerRequest {
  request: ServerRequestEnvelope
  receivedAt: number
}

export interface UnknownActivity {
  id: string
  method: string
  params: unknown
  timestamp: number
}

export interface FileBrowserState {
  path: string
  entries: FsReadDirectoryEntry[]
  loading: boolean
  uploading: boolean
  error: string | null
}

interface SessionState {
  connection: ConnectionSnapshot
  settings: SettingsState
  ssh: SshConnectionState
  models: Model[]
  threads: Thread[]
  activeThread: Thread | null
  activeThreadId: string | null
  activeTurnId: string | null
  loadingThreads: boolean
  loadingConversation: boolean
  restoring: boolean
  lastError: string | null
  pendingRequests: PendingServerRequest[]
  unknownActivity: UnknownActivity[]
  terminalEvents: TerminalLine[]
  turnDiffs: Record<string, string>
  turnPlans: Record<string, { explanation: string | null; plan: UnknownRecord[] }>
  attachments: UserInput[]
  files: FileBrowserState
  terminals: TerminalManagerState
  apps: AppInfo[]
  mcpServers: McpServerStatus[]
  skills: SkillMetadata[]
  skillErrors: SkillErrorInfo[]
  loadingSkills: boolean
  loadingApps: boolean
  tab: MainTab
  settingsOpen: boolean
}

const fallbackConnection: ConnectionSnapshot = {
  phase: 'idle',
  attempt: 0,
  nextRetryMs: null,
  error: null,
  server: null,
}

function defaultEndpoint(): string {
  if (typeof window === 'undefined') return 'ws://127.0.0.1:8787/ws'
  const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${window.location.host}/ws`
}

function storageValue(key: string, fallback = ''): string {
  if (typeof window === 'undefined') return fallback
  return localStorage.getItem(key) ?? fallback
}

function initialSettings(): SettingsState {
  const rememberToken = storageValue('pocket.rememberToken', 'false') === 'true'
  const token = rememberToken ? storageValue('pocket.token') : (typeof sessionStorage === 'undefined' ? '' : sessionStorage.getItem('pocket.token') ?? '')
  const sandbox = storageValue('pocket.sandbox', 'workspace-write')
  const safeSandbox = sandbox === 'read-only' || sandbox === 'danger-full-access' ? sandbox : 'workspace-write'
  return {
    endpoint: storageValue('pocket.endpoint', defaultEndpoint()),
    token,
    rememberToken,
    connectionMode: storageValue('pocket.connectionMode') === 'ssh' ? 'ssh' : 'local',
    sshTarget: storageValue('pocket.sshTarget'),
    sshPort: storageValue('pocket.sshPort'),
    sshIdentityFile: storageValue('pocket.sshIdentityFile'),
    sshRemotePort: storageValue('pocket.sshRemotePort', '4500'),
    sshCodexBin: storageValue('pocket.sshCodexBin', 'codex'),
    cwd: storageValue('pocket.cwd'),
    model: storageValue('pocket.model'),
    effort: storageValue('pocket.effort'),
    sandbox: safeSandbox,
    approvalPolicy: 'on-request',
  }
}

const settings = initialSettings()
const state = reactive<SessionState>({
  connection: fallbackConnection,
  settings,
  ssh: { mode: 'local', connected: false, connecting: false, error: null },
  models: [],
  threads: [],
  activeThread: null,
  activeThreadId: storageValue('pocket.activeThread') || null,
  activeTurnId: null,
  loadingThreads: false,
  loadingConversation: false,
  restoring: false,
  lastError: null,
  pendingRequests: [],
  unknownActivity: [],
  terminalEvents: [],
  turnDiffs: {},
  turnPlans: {},
  attachments: [],
  files: { path: '', entries: [], loading: false, uploading: false, error: null },
  terminals: loadTerminalManager(typeof localStorage === 'undefined' ? undefined : localStorage, settings.cwd, makeId),
  apps: [],
  mcpServers: [],
  skills: [],
  skillErrors: [],
  loadingSkills: false,
  loadingApps: false,
  tab: 'chat',
  settingsOpen: false,
})

let client: JsonRpcClient | null = null
let initialized = false
let openThreadGeneration = 0
const TOKEN_REQUIRED_MESSAGE = '请先在连接设置中填写访问 Token'

export const ALL_INTERACTIVE_SOURCE_KINDS = [
  'cli', 'vscode', 'exec', 'appServer', 'subAgent', 'subAgentReview', 'subAgentCompact',
  'subAgentThreadSpawn', 'subAgentOther', 'unknown',
] as const

function createClient(): JsonRpcClient {
  const rpc = new JsonRpcClient({ url: state.settings.endpoint, token: state.settings.token })
  rpc.onState((connection) => {
    const leftReadyState = state.connection.phase === 'ready' && connection.phase !== 'ready'
    state.connection = { ...connection }
    if (leftReadyState) {
      state.pendingRequests.splice(0)
      markRunningTerminalsDisconnected(state.terminals)
      saveTerminalMetadata()
    }
  })
  rpc.onNotification(handleNotification)
  rpc.onServerRequest(handleServerRequest)
  rpc.onUnhandled((payload) => {
    appendEvent('rpc/unhandled', '无法识别的 RPC 消息', payload, 'warn')
    addUnknown('rpc/unhandled', payload)
  })
  rpc.onReady(restoreWorkspace)
  return rpc
}

function ensureClient(): JsonRpcClient {
  if (!client) client = createClient()
  return client
}

async function connect(): Promise<void> {
  if (!hasGatewayToken(state.settings.token)) {
    stopForMissingToken()
    return
  }
  state.lastError = null
  try {
    await prepareGatewayConnection()
    await ensureClient().connect()
  } catch (error) {
    state.lastError = errorMessage(error)
  }
}

async function reconnect(): Promise<boolean> {
  if (!hasGatewayToken(state.settings.token)) {
    stopForMissingToken()
    return false
  }
  const rpc = ensureClient()
  rpc.updateConfig({ url: state.settings.endpoint, token: state.settings.token })
  try {
    rpc.disconnect()
    await prepareGatewayConnection()
    await rpc.reconnectNow()
    return true
  } catch (error) {
    state.lastError = errorMessage(error)
    return false
  }
}

function disconnect(): void {
  client?.disconnect()
}

function stopForMissingToken(): void {
  client?.disconnect()
  state.connection = {
    phase: 'closed',
    attempt: 0,
    nextRetryMs: null,
    error: TOKEN_REQUIRED_MESSAGE,
    server: null,
  }
  state.lastError = TOKEN_REQUIRED_MESSAGE
  state.settingsOpen = true
}

async function saveSettings(next: SettingsState): Promise<void> {
  Object.assign(state.settings, next)
  localStorage.setItem('pocket.endpoint', next.endpoint)
  localStorage.setItem('pocket.rememberToken', String(next.rememberToken))
  localStorage.setItem('pocket.connectionMode', next.connectionMode)
  localStorage.setItem('pocket.sshTarget', next.sshTarget)
  localStorage.setItem('pocket.sshPort', next.sshPort)
  localStorage.setItem('pocket.sshIdentityFile', next.sshIdentityFile)
  localStorage.setItem('pocket.sshRemotePort', next.sshRemotePort)
  localStorage.setItem('pocket.sshCodexBin', next.sshCodexBin)
  localStorage.setItem('pocket.cwd', next.cwd)
  localStorage.setItem('pocket.model', next.model)
  localStorage.setItem('pocket.effort', next.effort)
  localStorage.setItem('pocket.sandbox', next.sandbox)
  if (next.rememberToken) {
    localStorage.setItem('pocket.token', next.token)
    sessionStorage.removeItem('pocket.token')
  } else {
    localStorage.removeItem('pocket.token')
    sessionStorage.setItem('pocket.token', next.token)
  }
  if (!hasGatewayToken(next.token)) {
    stopForMissingToken()
    return
  }
  state.settingsOpen = !(await reconnect())
}

async function prepareGatewayConnection(): Promise<void> {
  state.ssh.connecting = true
  state.ssh.error = null
  try {
    const status = await configureGatewayConnection({
      mode: state.settings.connectionMode,
      endpoint: state.settings.endpoint,
      token: state.settings.token,
      sshTarget: state.settings.sshTarget,
      sshPort: state.settings.sshPort,
      sshIdentityFile: state.settings.sshIdentityFile,
      sshRemotePort: state.settings.sshRemotePort,
      sshCodexBin: state.settings.sshCodexBin,
    })
    Object.assign(state.ssh, {
      target: undefined,
      localPort: undefined,
      remotePort: undefined,
    }, status, { error: null })
  } catch (error) {
    const message = errorMessage(error)
    state.ssh.error = message
    const prefix = state.settings.connectionMode === 'ssh' ? 'SSH 连接失败' : 'Gateway 准备失败'
    throw new Error(`${prefix}：${message}`)
  } finally {
    state.ssh.connecting = false
  }
}

async function restoreWorkspace(): Promise<void> {
  if (state.restoring) return
  state.restoring = true
  // Server request ids are connection-scoped; approvals from a dead socket can no longer be answered.
  state.pendingRequests.splice(0)
  appendEvent('connection/ready', '已连接并完成 initialize/initialized', state.connection.server)
  try {
    const remembered = state.activeThreadId
    const discovery = Promise.allSettled([refreshModels(), refreshThreads()])
    if (remembered) await openThread(remembered, true)
    await discovery
    void Promise.allSettled([refreshIntegrations(), refreshSkills()])
  } finally {
    state.restoring = false
  }
}

async function refreshModels(): Promise<void> {
  try {
    const response = await ensureClient().call('model/list', { limit: 100 })
    state.models = response.data
    if (!state.settings.model) {
      const preferred = response.data.find((model) => model.isDefault) ?? response.data[0]
      if (preferred) state.settings.model = preferred.model
    }
  } catch (error) {
    appendEvent('model/list', errorMessage(error), error, 'warn')
  }
}

async function refreshThreads(): Promise<void> {
  state.loadingThreads = true
  try {
    const params: { limit: number; sortKey: string; sortDirection: string; sourceKinds: string[]; cwd?: string } = {
      limit: 100,
      sortKey: 'updated_at',
      sortDirection: 'desc',
      sourceKinds: [...ALL_INTERACTIVE_SOURCE_KINDS],
    }
    if (state.settings.cwd) params.cwd = state.settings.cwd
    const response = await ensureClient().call('thread/list', params)
    state.threads = response.data
  } catch (error) {
    state.lastError = errorMessage(error)
  } finally {
    state.loadingThreads = false
  }
}

async function openThread(threadId: string, isRestore = false): Promise<void> {
  const generation = ++openThreadGeneration
  state.loadingConversation = true
  try {
    const read = await ensureClient().call('thread/read', { threadId, includeTurns: true })
    const resumed = await ensureClient().call('thread/resume', { threadId })
    if (generation !== openThreadGeneration) return

    const nextThread = resumed.thread.turns.length ? resumed.thread : read.thread
    state.activeThreadId = threadId
    state.activeThread = nextThread
    localStorage.setItem('pocket.activeThread', threadId)
    state.settings.cwd = resumed.cwd || nextThread.cwd || state.settings.cwd
    state.settings.model = resumed.model || state.settings.model
    state.files.path = state.settings.cwd
    syncActiveTurn()
    if (!isRestore) void refreshSkills()
    if (!isRestore) state.tab = 'chat'
  } catch (error) {
    if (generation === openThreadGeneration) {
      state.lastError = errorMessage(error)
      appendEvent('thread/resume', state.lastError, { threadId }, 'error')
    }
  } finally {
    if (generation === openThreadGeneration) state.loadingConversation = false
  }
}

async function startThread(): Promise<void> {
  const generation = ++openThreadGeneration
  state.loadingConversation = true
  try {
    const params: { model?: string; cwd?: string; approvalPolicy: 'untrusted' | 'on-request' | 'never'; sandbox: 'read-only' | 'workspace-write' | 'danger-full-access' } = {
      approvalPolicy: state.settings.approvalPolicy,
      // ThreadStartParams/SandboxMode is intentionally kebab-case in app-server 0.144.0.
      sandbox: state.settings.sandbox,
    }
    if (state.settings.model) params.model = state.settings.model
    if (state.settings.cwd) params.cwd = state.settings.cwd
    const response = await ensureClient().call('thread/start', params)
    if (generation !== openThreadGeneration) return
    state.activeThread = response.thread
    state.activeThreadId = response.thread.id
    localStorage.setItem('pocket.activeThread', response.thread.id)
    state.settings.cwd = response.cwd || state.settings.cwd
    upsertThread(response.thread)
    state.tab = 'chat'
    void refreshSkills()
  } catch (error) {
    if (generation === openThreadGeneration) state.lastError = errorMessage(error)
  } finally {
    if (generation === openThreadGeneration) state.loadingConversation = false
  }
}

async function sendMessage(text: string): Promise<void> {
  const trimmed = text.trim()
  const input: UserInput[] = []
  if (trimmed) input.push({ type: 'text', text: trimmed, text_elements: [] })
  input.push(...state.attachments)
  if (!input.length) return
  if (!state.activeThreadId) await startThread()
  const threadId = state.activeThreadId
  if (!threadId) return

  const clientUserMessageId = makeId()
  const activeTurn = findActiveTurn()
  state.attachments = []
  try {
    if (activeTurn) {
      await ensureClient().call('turn/steer', { threadId, expectedTurnId: activeTurn.id, clientUserMessageId, input })
      appendEvent('turn/steer', '已把消息追加到当前 turn', { threadId, turnId: activeTurn.id })
      return
    }
    const params = {
      threadId,
      clientUserMessageId,
      input,
      ...(state.settings.cwd ? { cwd: state.settings.cwd } : {}),
      ...(state.settings.model ? { model: state.settings.model } : {}),
      ...(state.settings.effort ? { effort: state.settings.effort } : {}),
    }
    const response = await ensureClient().call('turn/start', params)
    upsertTurn(response.turn)
    state.activeTurnId = response.turn.status === 'inProgress' ? response.turn.id : null
  } catch (error) {
    state.lastError = errorMessage(error)
    appendEvent('turn/start', state.lastError, { input }, 'error')
  }
}

async function interruptTurn(): Promise<void> {
  if (!state.activeThreadId || !state.activeTurnId) return
  try {
    await ensureClient().call('turn/interrupt', { threadId: state.activeThreadId, turnId: state.activeTurnId })
  } catch (error) {
    state.lastError = errorMessage(error)
  }
}

function addAttachment(input: UserInput): void {
  const signature = JSON.stringify(input)
  if (!state.attachments.some((item) => JSON.stringify(item) === signature)) state.attachments.push(input)
}

function attachSkill(skill: SkillMetadata): void {
  addAttachment({ type: 'skill', name: skill.name, path: skill.path })
}

function removeAttachment(index: number): void {
  state.attachments.splice(index, 1)
}

async function attachBrowserImage(file: File): Promise<void> {
  const target = state.files.path || state.settings.cwd
  if (!target) {
    state.files.error = '请先设置工作目录，浏览器图片需要上传到 host 后才能附加'
    state.tab = 'files'
    return
  }
  const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, '_').slice(-96) || 'image.png'
  const path = joinPath(target, `pocket-${Date.now()}-${safeName}`)
  try {
    await ensureClient().call('fs/writeFile', { path, dataBase64: await fileToBase64(file) })
    addAttachment({ type: 'localImage', path, detail: 'auto' })
    appendEvent('fs/writeFile', `已上传并附加 ${file.name}`, { path, size: file.size })
  } catch (error) {
    state.files.error = errorMessage(error)
    state.lastError = state.files.error
  }
}

function attachHostPath(path: string): void {
  if (isImagePath(path)) addAttachment({ type: 'localImage', path, detail: 'auto' })
  else addAttachment({ type: 'mention', name: basename(path), path })
}

async function readDirectory(path = state.files.path || state.settings.cwd): Promise<void> {
  if (!path) {
    state.files.error = '请先在设置中填写服务器工作目录'
    return
  }
  state.files.loading = true
  state.files.error = null
  try {
    const response = await ensureClient().call('fs/readDirectory', { path })
    state.files.path = path
    state.files.entries = [...response.entries].sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.fileName.localeCompare(b.fileName))
  } catch (error) {
    state.files.error = errorMessage(error)
  } finally {
    state.files.loading = false
  }
}

async function openFileEntry(entry: FsReadDirectoryEntry): Promise<void> {
  const path = joinPath(state.files.path, entry.fileName)
  if (entry.isDirectory) await readDirectory(path)
  else attachHostPath(path)
}

async function goParentDirectory(): Promise<void> {
  await readDirectory(parentPath(state.files.path))
}

async function uploadFiles(files: FileList | File[]): Promise<void> {
  const target = state.files.path || state.settings.cwd
  if (!target) {
    state.files.error = '请先设置工作目录'
    return
  }
  state.files.uploading = true
  state.files.error = null
  try {
    for (const file of Array.from(files)) {
      const path = joinPath(target, file.name)
      await ensureClient().call('fs/writeFile', { path, dataBase64: await fileToBase64(file) })
      if (file.type.startsWith('image/') || isImagePath(path)) addAttachment({ type: 'localImage', path, detail: 'auto' })
      appendEvent('fs/writeFile', `已上传 ${file.name}`, { path, size: file.size })
    }
    await readDirectory(target)
  } catch (error) {
    state.files.error = errorMessage(error)
  } finally {
    state.files.uploading = false
  }
}

function findTerminal(sessionId: string): TerminalSession | undefined {
  return state.terminals.sessions.find((session) => session.id === sessionId)
}

function saveTerminalMetadata(): void {
  persistTerminalManager(state.terminals, typeof localStorage === 'undefined' ? undefined : localStorage)
}

function addTerminal(): void {
  if (state.terminals.sessions.length >= MAX_TERMINAL_SESSIONS) return
  const session = createTerminalSession(makeId(), state.terminals.sessions.length + 1, state.settings.cwd)
  state.terminals.sessions.push(session)
  state.terminals.activeSessionId = session.id
  saveTerminalMetadata()
}

function selectTerminal(sessionId: string): void {
  if (!findTerminal(sessionId)) return
  state.terminals.activeSessionId = sessionId
  saveTerminalMetadata()
}

function updateTerminal(sessionId: string, patch: Partial<Pick<TerminalSession, 'name' | 'command' | 'cwd'>>): void {
  const session = findTerminal(sessionId)
  if (!session) return
  if (typeof patch.name === 'string') session.name = patch.name.trim().slice(0, 40) || session.name
  if (typeof patch.command === 'string') session.command = patch.command
  if (typeof patch.cwd === 'string') session.cwd = patch.cwd
  saveTerminalMetadata()
}

function closeTerminal(sessionId: string): void {
  const session = findTerminal(sessionId)
  if (!session || session.running || state.terminals.sessions.length === 1) return
  const index = state.terminals.sessions.indexOf(session)
  state.terminals.sessions.splice(index, 1)
  if (state.terminals.activeSessionId === sessionId) {
    state.terminals.activeSessionId = state.terminals.sessions[Math.min(index, state.terminals.sessions.length - 1)]!.id
  }
  saveTerminalMetadata()
}

function clearTerminal(sessionId: string): void {
  const session = findTerminal(sessionId)
  if (!session) return
  Object.assign(session, { output: '', exitCode: null, error: null, stale: false })
}

async function runTerminal(sessionId = state.terminals.activeSessionId, command?: string): Promise<void> {
  const session = findTerminal(sessionId)
  const nextCommand = command ?? session?.command ?? ''
  if (!session || !nextCommand.trim() || session.running) return
  const processId = `pocket-${makeId()}`
  const isWindows = state.connection.server?.platformFamily === 'windows' || state.connection.server?.platformOs === 'windows'
  const streamOutput = terminalSupportsStreaming(isWindows, state.settings.sandbox)
  const argv = isWindows
    ? ['powershell.exe', '-NoLogo', '-NoProfile', '-Command', nextCommand]
    : ['/bin/sh', '-lc', nextCommand]
  const cwd = session.cwd || state.settings.cwd
  const sandboxPolicy = terminalSandboxPolicy(state.settings.sandbox, cwd)
  rememberTerminalCommand(session, nextCommand)
  Object.assign(session, {
    command: nextCommand,
    processId,
    interactive: streamOutput,
    running: true,
    stale: false,
    output: '',
    exitCode: null,
    error: null,
    startedAt: Date.now(),
    completedAt: null,
  })
  saveTerminalMetadata()
  appendEvent('command/exec', nextCommand, { processId, cwd, sandboxPolicy }, 'info', 'out')
  try {
    if (!streamOutput) appendEvent('command/exec', 'Windows sandbox 使用 buffered terminal；stdin/terminate 仅在 PTY 模式可用', undefined, 'warn')
    const response = await ensureClient().call('command/exec', streamOutput
      ? {
          command: argv,
          processId,
          tty: true,
          streamStdin: true,
          streamStdoutStderr: true,
          cwd: cwd || null,
          disableTimeout: true,
          size: { rows: session.rows, cols: session.cols },
          sandboxPolicy,
        }
      : {
          command: argv,
          processId,
          cwd: cwd || null,
          timeoutMs: 120_000,
          sandboxPolicy,
        }, { timeoutMs: streamOutput ? null : 135_000 })
    if (session.processId !== processId) return
    if (response.stdout) appendTerminalOutput(session, response.stdout)
    if (response.stderr) appendTerminalOutput(session, response.stderr)
    session.exitCode = response.exitCode
  } catch (error) {
    if (session.processId === processId) session.error = errorMessage(error)
  } finally {
    if (session.processId === processId) {
      session.running = false
      session.interactive = false
      session.completedAt = Date.now()
      saveTerminalMetadata()
    }
  }
}

async function writeTerminal(sessionId = state.terminals.activeSessionId, value?: string, closeStdin = false): Promise<void> {
  const session = findTerminal(sessionId)
  const nextValue = value ?? session?.stdin ?? ''
  if (!session?.processId || !session.interactive || (!nextValue && !closeStdin)) return
  try {
    await ensureClient().call('command/exec/write', {
      processId: session.processId,
      ...(nextValue ? { deltaBase64: encodeUtf8Base64(`${nextValue}\n`) } : {}),
      closeStdin,
    })
    session.stdin = ''
  } catch (error) {
    session.error = errorMessage(error)
  }
}

async function resizeTerminal(sessionId: string, rows: number, cols: number): Promise<void> {
  const session = findTerminal(sessionId)
  const size = { rows: Math.max(4, Math.min(200, Math.round(rows))), cols: Math.max(20, Math.min(400, Math.round(cols))) }
  if (!session || (session.rows === size.rows && session.cols === size.cols)) return
  Object.assign(session, size)
  if (!session.processId || !session.running || !session.interactive) return
  try {
    await ensureClient().call('command/exec/resize', { processId: session.processId, size })
  } catch (error) {
    session.error = errorMessage(error)
  }
}

async function terminateTerminal(sessionId = state.terminals.activeSessionId): Promise<void> {
  const session = findTerminal(sessionId)
  if (!session?.processId || !session.running) return
  try {
    await ensureClient().call('command/exec/terminate', { processId: session.processId })
  } catch (error) {
    session.error = errorMessage(error)
  }
}

async function refreshIntegrations(forceRefetch = false): Promise<void> {
  state.loadingApps = true
  try {
    const threadId = state.activeThreadId
    const [apps, mcp] = await Promise.allSettled([
      ensureClient().call('app/list', { limit: 100, threadId, forceRefetch }),
      ensureClient().call('mcpServerStatus/list', { limit: 100, detail: 'full', threadId }),
    ])
    if (apps.status === 'fulfilled') state.apps = apps.value.data
    else appendEvent('app/list', errorMessage(apps.reason), apps.reason, 'warn')
    if (mcp.status === 'fulfilled') state.mcpServers = mcp.value.data
    else appendEvent('mcpServerStatus/list', errorMessage(mcp.reason), mcp.reason, 'warn')
  } finally {
    state.loadingApps = false
  }
}

async function refreshSkills(forceReload = false): Promise<void> {
  state.loadingSkills = true
  try {
    const cwd = state.settings.cwd
    const response = await ensureClient().call('skills/list', {
      ...(cwd ? { cwds: [cwd] } : {}),
      forceReload,
    })
    const entry = (cwd ? response.data.find((candidate) => candidate.cwd === cwd) : undefined) ?? response.data[0]
    state.skills = entry?.skills ?? []
    state.skillErrors = entry?.errors ?? []
    for (const error of state.skillErrors) appendEvent('skills/list', error.message, error, 'warn')
  } catch (error) {
    appendEvent('skills/list', errorMessage(error), error, 'warn')
  } finally {
    state.loadingSkills = false
  }
}

async function executeSlashCommand(name: SlashCommandName): Promise<void> {
  switch (name) {
    case 'new':
      await startThread()
      return
    case 'threads':
      state.tab = 'threads'
      void refreshThreads()
      return
    case 'files':
      state.tab = 'files'
      return
    case 'terminal':
      state.tab = 'terminal'
      return
    case 'apps':
      state.tab = 'apps'
      void refreshIntegrations()
      return
    case 'model':
    case 'status':
      state.settingsOpen = true
      return
    case 'skills':
      await refreshSkills(true)
      return
    case 'compact':
      await compactActiveThread()
      return
    case 'review':
      await reviewActiveThread()
  }
}

async function compactActiveThread(): Promise<void> {
  if (!state.activeThreadId) {
    state.lastError = '请先打开一个任务再压缩上下文'
    return
  }
  try {
    await ensureClient().call('thread/compact/start', { threadId: state.activeThreadId })
    appendEvent('thread/compact/start', '已开始压缩当前任务上下文', { threadId: state.activeThreadId }, 'info', 'out')
  } catch (error) {
    state.lastError = errorMessage(error)
    appendEvent('thread/compact/start', state.lastError, error, 'error')
  }
}

async function reviewActiveThread(): Promise<void> {
  if (!state.activeThreadId) {
    state.lastError = '请先打开一个任务再开始 Review'
    return
  }
  try {
    const response = await ensureClient().call('review/start', {
      threadId: state.activeThreadId,
      target: { type: 'uncommittedChanges' },
      delivery: 'inline',
    })
    upsertTurn(response.turn)
    state.activeTurnId = response.turn.status === 'inProgress' ? response.turn.id : null
    appendEvent('review/start', '已开始 Review 未提交变更', { threadId: state.activeThreadId }, 'info', 'out')
  } catch (error) {
    state.lastError = errorMessage(error)
    appendEvent('review/start', state.lastError, error, 'error')
  }
}

function respondApproval(index: number, decision: ApprovalDecision): void {
  const pending = state.pendingRequests[index]
  if (!pending) return
  ensureClient().respond(pending.request.id, { decision })
  appendEvent(`${pending.request.method}/response`, decision, { id: pending.request.id }, 'info', 'out')
  state.pendingRequests.splice(index, 1)
}

function respondUserInput(index: number, answers: Record<string, string[]>): void {
  const pending = state.pendingRequests[index]
  if (!pending) return
  const mapped = Object.fromEntries(Object.entries(answers).map(([id, values]) => [id, { answers: values }]))
  ensureClient().respond(pending.request.id, { answers: mapped })
  appendEvent(`${pending.request.method}/response`, '已提交补充信息', { id: pending.request.id }, 'info', 'out')
  state.pendingRequests.splice(index, 1)
}

function rejectUnsupportedRequest(index: number): void {
  const pending = state.pendingRequests[index]
  if (!pending) return
  ensureClient().respondError(pending.request.id, -32601, `Pocket Agent 暂不支持 ${pending.request.method}`)
  state.pendingRequests.splice(index, 1)
}

function handleServerRequest(request: ServerRequestEnvelope): void {
  state.pendingRequests.push({ request, receivedAt: Date.now() })
  appendEvent(request.method, request.method, request.params, 'warn')
}

function handleNotification(notification: RpcNotification): void {
  const params = asRecord(notification.params)
  appendEvent(notification.method, eventSummary(notification.method, params), notification.params, eventLevel(notification.method))

  if (!shouldApplyScopedNotification(state.activeThreadId, notification.method, params)) return

  switch (notification.method) {
    case 'skills/changed':
      void refreshSkills(true)
      return
    case 'app/list/updated':
      if (Array.isArray(params.data)) state.apps = params.data.filter(isAppInfo)
      return
    case 'mcpServer/startupStatus/updated': {
      const server = state.mcpServers.find((candidate) => candidate.name === stringField(params, 'name'))
      if (server) {
        server.startupStatus = params.status
        server.startupError = params.error
        server.startupFailureReason = params.failureReason
      }
      return
    }
    case 'thread/started': {
      const thread = params.thread
      if (isThread(thread)) upsertThread(thread)
      return
    }
    case 'thread/status/changed': {
      const threadId = stringField(params, 'threadId')
      const status = params.status
      for (const thread of state.threads) if (thread.id === threadId && isRecord(status)) thread.status = status as Thread['status']
      if (state.activeThread?.id === threadId && isRecord(status)) state.activeThread.status = status as Thread['status']
      return
    }
    case 'turn/started': {
      const turn = params.turn
      if (isTurn(turn)) {
        upsertTurn(turn)
        state.activeTurnId = turn.id
      }
      return
    }
    case 'serverRequest/resolved': {
      const requestId = params.requestId
      if (typeof requestId === 'string' || typeof requestId === 'number') removeResolvedRequest(requestId)
      return
    }
    case 'turn/completed': {
      const turn = params.turn
      if (isTurn(turn)) upsertTurn(turn)
      state.activeTurnId = null
      return
    }
    case 'item/started':
    case 'item/completed': {
      if (isRecord(params.item) && typeof params.item.type === 'string') upsertItem(stringField(params, 'turnId'), params.item as ThreadItem)
      return
    }
    case 'item/agentMessage/delta':
      appendItemString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'agentMessage', 'text', stringField(params, 'delta'))
      return
    case 'item/plan/delta':
      appendItemString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'plan', 'text', stringField(params, 'delta'))
      return
    case 'item/reasoning/summaryTextDelta':
      appendIndexedString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'summary', Number(params.summaryIndex ?? 0), stringField(params, 'delta'))
      return
    case 'item/reasoning/textDelta':
      appendIndexedString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'content', Number(params.contentIndex ?? 0), stringField(params, 'delta'))
      return
    case 'item/commandExecution/outputDelta':
      appendItemString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'commandExecution', 'aggregatedOutput', stringField(params, 'delta'))
      return
    case 'item/fileChange/outputDelta':
      appendItemString(stringField(params, 'turnId'), stringField(params, 'itemId'), 'fileChange', 'output', stringField(params, 'delta'))
      return
    case 'item/fileChange/patchUpdated': {
      const item = findItem(stringField(params, 'turnId'), stringField(params, 'itemId'))
      if (item && Array.isArray(params.changes)) item.changes = params.changes
      return
    }
    case 'turn/diff/updated':
      state.turnDiffs[stringField(params, 'turnId')] = stringField(params, 'diff')
      return
    case 'turn/plan/updated':
      state.turnPlans[stringField(params, 'turnId')] = {
        explanation: typeof params.explanation === 'string' ? params.explanation : null,
        plan: Array.isArray(params.plan) ? params.plan.filter(isRecord) : [],
      }
      return
    case 'command/exec/outputDelta': {
      const session = state.terminals.sessions.find((candidate) => candidate.processId === stringField(params, 'processId'))
      if (!session) return
      try {
        appendTerminalOutput(session, decodeBase64Utf8(stringField(params, 'deltaBase64')))
      } catch {
        appendTerminalOutput(session, '[无法解码的输出]')
      }
      return
    }
    case 'error':
    case 'warning':
    case 'configWarning':
      state.lastError = eventSummary(notification.method, params)
      return
    default:
      if (stringField(params, 'threadId') === state.activeThreadId || notification.method.startsWith('item/')) {
        addUnknown(notification.method, notification.params)
      }
  }
}

function upsertThread(thread: Thread): void {
  const index = state.threads.findIndex((candidate) => candidate.id === thread.id)
  if (index >= 0) state.threads[index] = thread
  else state.threads.unshift(thread)
}

function upsertTurn(turn: Turn): void {
  if (!state.activeThread) return
  const index = state.activeThread.turns.findIndex((candidate) => candidate.id === turn.id)
  if (index >= 0) state.activeThread.turns[index] = turn
  else state.activeThread.turns.push(turn)
}

function upsertItem(turnId: string, item: ThreadItem): void {
  if (!state.activeThread) return
  let turn = state.activeThread.turns.find((candidate) => candidate.id === turnId)
  if (!turn) {
    turn = { id: turnId, items: [], status: 'inProgress', error: null, startedAt: null, completedAt: null, durationMs: null }
    state.activeThread.turns.push(turn)
  }
  mergeLifecycleItem(turn.items, item)
}

function findItem(turnId: string, itemId: string): ThreadItem | undefined {
  return state.activeThread?.turns.find((turn) => turn.id === turnId)?.items.find((item) => item.id === itemId)
}

function appendItemString(turnId: string, itemId: string, type: string, field: string, delta: string): void {
  let item = findItem(turnId, itemId)
  if (!item) {
    item = { type, id: itemId, [field]: '' }
    upsertItem(turnId, item)
  }
  const current = typeof item[field] === 'string' ? item[field] : ''
  item[field] = current + delta
}

function appendIndexedString(turnId: string, itemId: string, field: 'summary' | 'content', index: number, delta: string): void {
  let item = findItem(turnId, itemId)
  if (!item) {
    item = { type: 'reasoning', id: itemId, summary: [], content: [] }
    upsertItem(turnId, item)
  }
  const values = Array.isArray(item[field]) ? [...item[field]] : []
  values[index] = `${typeof values[index] === 'string' ? values[index] : ''}${delta}`
  item[field] = values
}

function syncActiveTurn(): void {
  state.activeTurnId = findActiveTurn()?.id ?? null
}

function findActiveTurn(): Turn | undefined {
  return [...(state.activeThread?.turns ?? [])].reverse().find((turn) => turn.status === 'inProgress')
}

function appendEvent(method: string, summary: string, payload?: unknown, level: TerminalLine['level'] = 'info', direction: TerminalLine['direction'] = 'in'): void {
  state.terminalEvents.push({ id: makeId(), timestamp: Date.now(), method, direction, level, summary, payload })
  if (state.terminalEvents.length > 500) state.terminalEvents.splice(0, state.terminalEvents.length - 500)
}

function addUnknown(method: string, params: unknown): void {
  state.unknownActivity.push({ id: makeId(), method, params, timestamp: Date.now() })
  if (state.unknownActivity.length > 80) state.unknownActivity.shift()
}

function eventSummary(method: string, params: UnknownRecord): string {
  if (typeof params.message === 'string') return params.message
  if (typeof params.error === 'string') return params.error
  const shortMethod = method.split('/').pop() ?? method
  const itemType = isRecord(params.item) && typeof params.item.type === 'string' ? ` · ${params.item.type}` : ''
  return `${shortMethod}${itemType}`
}

function eventLevel(method: string): TerminalLine['level'] {
  if (method === 'error') return 'error'
  if (/warning|failed|deprecated/i.test(method)) return 'warn'
  return 'info'
}

function isThread(value: unknown): value is Thread {
  return isRecord(value) && typeof value.id === 'string' && Array.isArray(value.turns)
}

function isAppInfo(value: unknown): value is AppInfo {
  return isRecord(value) && typeof value.id === 'string' && typeof value.name === 'string'
}

function isTurn(value: unknown): value is Turn {
  return isRecord(value) && typeof value.id === 'string' && Array.isArray(value.items)
}

function makeId(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

const conversationItems = computed(() => state.activeThread?.turns.flatMap((turn) => turn.items.map((item) => ({ turnId: turn.id, turnStatus: turn.status, item }))) ?? [])
const requestCount = computed(() => state.pendingRequests.length)

function threadLabel(threadId: string): string {
  if (!threadId) return '未标识任务'
  const thread = state.activeThread?.id === threadId
    ? state.activeThread
    : state.threads.find((candidate) => candidate.id === threadId)
  return thread?.name?.trim() || thread?.preview?.trim() || threadId
}

export function useCodexSession() {
  if (!initialized) initialized = true
  return {
    state: readonly(state),
    mutableState: state,
    conversationItems,
    requestCount,
    threadLabel,
    connect,
    reconnect,
    disconnect,
    saveSettings,
    refreshModels,
    refreshThreads,
    openThread,
    startThread,
    sendMessage,
    interruptTurn,
    addAttachment,
    removeAttachment,
    attachSkill,
    attachBrowserImage,
    attachHostPath,
    readDirectory,
    openFileEntry,
    goParentDirectory,
    uploadFiles,
    addTerminal,
    selectTerminal,
    updateTerminal,
    closeTerminal,
    clearTerminal,
    runTerminal,
    writeTerminal,
    resizeTerminal,
    terminateTerminal,
    refreshIntegrations,
    refreshSkills,
    executeSlashCommand,
    respondApproval,
    respondUserInput,
    rejectUnsupportedRequest,
  }
}

export function __resetSessionForTests(): void {
  client?.destroy()
  client = null
  initialized = false
  openThreadGeneration = 0
}

export function createThreadStartSandboxParams(sandbox: SettingsState['sandbox']): { sandbox: SettingsState['sandbox'] } {
  return { sandbox }
}

export function hasGatewayToken(token: string): boolean {
  return token.length > 0
}

export function mergeLifecycleItem(items: ThreadItem[], completed: ThreadItem): void {
  const index = items.findIndex((candidate) => candidate.id === completed.id)
  if (index >= 0) items[index] = completed
  else items.push(completed)
}

export function removeResolvedRequest(requestId: string | number): void {
  const remaining = filterResolvedRequests(state.pendingRequests, requestId)
  state.pendingRequests.splice(0, state.pendingRequests.length, ...remaining)
}

export function filterResolvedRequests<T extends { request: { id: string | number } }>(requests: readonly T[], requestId: string | number): T[] {
  return requests.filter((pending) => pending.request.id !== requestId)
}

export function asUserInputRequest(params: UnknownRecord): ToolRequestUserInputParams | null {
  if (!Array.isArray(params.questions)) return null
  return params as ToolRequestUserInputParams
}

export function shouldApplyScopedNotification(activeThreadId: string | null, method: string, params: UnknownRecord): boolean {
  if (!/^(?:turn\/|item\/|rawResponseItem\/)/.test(method)) return true
  const threadId = typeof params.threadId === 'string' ? params.threadId : null
  return !threadId || (!!activeThreadId && threadId === activeThreadId)
}

export function terminalSupportsStreaming(isWindows: boolean, sandbox: SettingsState['sandbox']): boolean {
  return !isWindows || sandbox === 'danger-full-access'
}

export function terminalSandboxPolicy(sandbox: SettingsState['sandbox'], cwd: string): UnknownRecord {
  if (sandbox === 'danger-full-access') return { type: 'dangerFullAccess' }
  if (sandbox === 'read-only') return { type: 'readOnly', networkAccess: false }
  return {
    type: 'workspaceWrite',
    writableRoots: cwd ? [cwd] : [],
    networkAccess: false,
    excludeTmpdirEnvVar: false,
    excludeSlashTmp: false,
  }
}
