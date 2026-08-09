/**
 * Focused bindings for the public app-server surface used by Pocket Agent.
 * Field names mirror `codex app-server generate-ts`; index signatures preserve
 * forward compatibility without weakening the known request/response shapes.
 */
export type JsonPrimitive = string | number | boolean | null
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue }
export type UnknownRecord = Record<string, unknown>
export type RequestId = number | string

export interface InitializeParams {
  clientInfo: { name: string; title: string | null; version: string }
  capabilities: {
    experimentalApi: boolean
    requestAttestation: boolean
    mcpServerOpenaiFormElicitation?: boolean
    optOutNotificationMethods?: string[] | null
  } | null
}

export interface InitializeResponse extends UnknownRecord {
  userAgent: string
  codexHome: string
  platformFamily: string
  platformOs: string
}

export interface ReasoningEffortOption extends UnknownRecord {
  reasoningEffort?: string
  description?: string
}

export interface Model extends UnknownRecord {
  id: string
  model: string
  displayName: string
  description: string
  hidden: boolean
  isDefault: boolean
  defaultReasoningEffort: string
  supportedReasoningEfforts: ReasoningEffortOption[]
  inputModalities: string[]
}

export type ThreadStatus =
  | { type: 'notLoaded' }
  | { type: 'idle' }
  | { type: 'systemError' }
  | { type: 'active'; activeFlags: string[] }
  | ({ type: string } & UnknownRecord)

export interface ThreadItem extends UnknownRecord {
  type: string
  id?: string
}

export type TurnStatus = 'completed' | 'interrupted' | 'failed' | 'inProgress' | string

export interface Turn extends UnknownRecord {
  id: string
  items: ThreadItem[]
  itemsView?: string
  status: TurnStatus
  error: UnknownRecord | null
  startedAt: number | null
  completedAt: number | null
  durationMs: number | null
}

export interface Thread extends UnknownRecord {
  id: string
  sessionId: string
  preview: string
  modelProvider: string
  createdAt: number
  updatedAt: number
  recencyAt: number | null
  status: ThreadStatus
  cwd: string
  name: string | null
  turns: Turn[]
}

export type ImageDetail = 'low' | 'high' | 'auto' | 'original'
export type UserInput =
  | { type: 'text'; text: string; text_elements: TextElement[] }
  | { type: 'image'; url: string; detail?: ImageDetail }
  | { type: 'localImage'; path: string; detail?: ImageDetail }
  | { type: 'skill'; name: string; path: string }
  | { type: 'mention'; name: string; path: string }

export interface TextElement extends UnknownRecord {
  byteRange?: { start: number; end: number }
  placeholder?: string
}

export interface ThreadStartParams extends UnknownRecord {
  model?: string | null
  cwd?: string | null
  approvalPolicy?: string | null
  sandbox?: string | null
  ephemeral?: boolean | null
}

export interface ThreadResumeParams extends ThreadStartParams {
  threadId: string
}

export interface TurnStartParams extends UnknownRecord {
  threadId: string
  clientUserMessageId?: string | null
  input: UserInput[]
  cwd?: string | null
  model?: string | null
  effort?: string | null
}

export interface TurnSteerParams {
  threadId: string
  clientUserMessageId?: string | null
  input: UserInput[]
  expectedTurnId: string
}

export interface FileUpdateChange extends UnknownRecord {
  path: string
  kind: { type: 'add' | 'delete' } | { type: 'update'; move_path: string | null }
  diff: string
}

export interface FsReadDirectoryEntry {
  fileName: string
  isDirectory: boolean
  isFile: boolean
}

export interface CommandExecParams extends UnknownRecord {
  command: string[]
  processId?: string | null
  tty?: boolean
  streamStdin?: boolean
  streamStdoutStderr?: boolean
  cwd?: string | null
  disableTimeout?: boolean
  size?: { rows: number; cols: number } | null
  sandboxPolicy?: UnknownRecord | null
}

export interface AppInfo extends UnknownRecord {
  id: string
  name: string
  description: string | null
  logoUrl: string | null
  logoUrlDark: string | null
  isAccessible: boolean
  isEnabled: boolean
  pluginDisplayNames: string[]
}

export interface McpServerStatus extends UnknownRecord {
  name: string
  serverInfo: UnknownRecord | null
  tools: Record<string, UnknownRecord>
  resources: UnknownRecord[]
  resourceTemplates: UnknownRecord[]
  authStatus: 'unsupported' | 'notLoggedIn' | 'bearerToken' | 'oAuth' | string
}

export interface ClientMethodMap {
  initialize: { params: InitializeParams; result: InitializeResponse }
  'model/list': { params: { cursor?: string | null; limit?: number | null; includeHidden?: boolean | null }; result: { data: Model[]; nextCursor: string | null } }
  'thread/list': { params: { cursor?: string | null; limit?: number | null; sortKey?: string | null; sortDirection?: string | null; cwd?: string | string[] | null; searchTerm?: string | null; sourceKinds?: string[] | null }; result: { data: Thread[]; nextCursor: string | null; backwardsCursor: string | null } }
  'thread/read': { params: { threadId: string; includeTurns?: boolean }; result: { thread: Thread } }
  'thread/resume': { params: ThreadResumeParams; result: { thread: Thread; model: string; cwd: string; [key: string]: unknown } }
  'thread/start': { params: ThreadStartParams; result: { thread: Thread; model: string; cwd: string; [key: string]: unknown } }
  'turn/start': { params: TurnStartParams; result: { turn: Turn } }
  'turn/steer': { params: TurnSteerParams; result: UnknownRecord }
  'turn/interrupt': { params: { threadId: string; turnId: string }; result: UnknownRecord }
  'app/list': { params: { cursor?: string | null; limit?: number | null; threadId?: string | null; forceRefetch?: boolean }; result: { data: AppInfo[]; nextCursor: string | null } }
  'mcpServerStatus/list': { params: { cursor?: string | null; limit?: number | null; detail?: 'full' | 'toolsAndAuthOnly' | null; threadId?: string | null }; result: { data: McpServerStatus[]; nextCursor: string | null } }
  'fs/readDirectory': { params: { path: string }; result: { entries: FsReadDirectoryEntry[] } }
  'fs/writeFile': { params: { path: string; dataBase64: string }; result: UnknownRecord }
  'command/exec': { params: CommandExecParams; result: { exitCode: number; stdout: string; stderr: string } }
  'command/exec/write': { params: { processId: string; deltaBase64?: string | null; closeStdin?: boolean }; result: UnknownRecord }
  'command/exec/terminate': { params: { processId: string }; result: UnknownRecord }
}

export type KnownClientMethod = keyof ClientMethodMap
export type ParamsOf<M extends KnownClientMethod> = ClientMethodMap[M]['params']
export type ResultOf<M extends KnownClientMethod> = ClientMethodMap[M]['result']

export interface RpcRequest<M extends string = string, P = unknown> {
  id: RequestId
  method: M
  params: P
}

export interface RpcNotification<M extends string = string, P = unknown> {
  method: M
  params?: P
}

export interface RpcSuccess<R = unknown> {
  id: RequestId
  result: R
}

export interface RpcErrorShape extends UnknownRecord {
  code: number
  message: string
  data?: unknown
}

export interface RpcFailure {
  id: RequestId
  error: RpcErrorShape
}

export type RpcInbound = RpcRequest | RpcNotification | RpcSuccess | RpcFailure

export interface ItemLifecycleParams extends UnknownRecord {
  threadId: string
  turnId: string
  item: ThreadItem
}

export interface ItemDeltaParams extends UnknownRecord {
  threadId: string
  turnId: string
  itemId: string
  delta: string
}

export type ApprovalDecision = 'accept' | 'acceptForSession' | 'decline' | 'cancel'

export interface ToolRequestUserInputOption {
  label: string
  description: string
}

export interface ToolRequestUserInputQuestion {
  id: string
  header: string
  question: string
  isOther: boolean
  isSecret: boolean
  options: ToolRequestUserInputOption[] | null
}

export interface ToolRequestUserInputParams extends UnknownRecord {
  threadId: string
  turnId: string
  itemId: string
  questions: ToolRequestUserInputQuestion[]
  autoResolutionMs: number | null
}

export type ServerRequestKind =
  | 'item/commandExecution/requestApproval'
  | 'item/fileChange/requestApproval'
  | 'item/tool/requestUserInput'
  | 'mcpServer/elicitation/request'
  | 'item/permissions/requestApproval'
  | string

export interface ServerRequestEnvelope extends RpcRequest<ServerRequestKind, UnknownRecord> {}

export interface TerminalLine {
  id: string
  timestamp: number
  method: string
  direction: 'in' | 'out' | 'system'
  level: 'info' | 'warn' | 'error'
  summary: string
  payload?: unknown
}
