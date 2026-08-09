import { isRpcFailure, isRpcNotification, isRpcRequest, isRpcSuccess } from '../protocol/guards'
import type {
  InitializeParams,
  InitializeResponse,
  KnownClientMethod,
  ParamsOf,
  RequestId,
  ResultOf,
  RpcInbound,
  RpcNotification,
  ServerRequestEnvelope,
  UnknownRecord,
} from '../protocol/types'

export type ConnectionPhase = 'idle' | 'connecting' | 'initializing' | 'ready' | 'reconnecting' | 'offline' | 'closed'

export interface ConnectionSnapshot {
  phase: ConnectionPhase
  attempt: number
  nextRetryMs: number | null
  error: string | null
  server: InitializeResponse | null
}

export interface JsonRpcClientOptions {
  url: string
  token?: string
  requestTimeoutMs?: number
  reconnectBaseMs?: number
  reconnectMaxMs?: number
  random?: () => number
  socketFactory?: (url: string, protocols?: string[]) => WebSocket
}

export const GATEWAY_TOKEN_PROTOCOL_PREFIX = 'pocket-agent-token.'

export function gatewayTokenProtocol(token: string): string {
  const bytes = new TextEncoder().encode(token)
  const encoded = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  return `${GATEWAY_TOKEN_PROTOCOL_PREFIX}${encoded}`
}

interface PendingRequest {
  method: string
  resolve: (value: unknown) => void
  reject: (reason: Error) => void
  timeout: ReturnType<typeof setTimeout> | null
}

export class RpcError extends Error {
  constructor(
    message: string,
    readonly code: number,
    readonly data?: unknown,
  ) {
    super(message)
    this.name = 'RpcError'
  }
}

export class JsonRpcClient {
  private socket: WebSocket | null = null
  private pending = new Map<RequestId, PendingRequest>()
  private sequence = 0
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private manuallyClosed = false
  private connectPromise: Promise<void> | null = null
  private config: JsonRpcClientOptions
  private notificationListeners = new Set<(notification: RpcNotification) => void>()
  private requestListeners = new Set<(request: ServerRequestEnvelope) => void>()
  private stateListeners = new Set<(state: ConnectionSnapshot) => void>()
  private unhandledListeners = new Set<(payload: unknown) => void>()
  private readyListeners = new Set<() => void | Promise<void>>()
  private snapshot: ConnectionSnapshot = {
    phase: 'idle',
    attempt: 0,
    nextRetryMs: null,
    error: null,
    server: null,
  }

  constructor(options: JsonRpcClientOptions) {
    this.config = { requestTimeoutMs: 30_000, reconnectBaseMs: 700, reconnectMaxMs: 20_000, ...options }
    if (typeof window !== 'undefined') {
      window.addEventListener('online', this.handleOnline)
      window.addEventListener('offline', this.handleOffline)
    }
  }

  get state(): Readonly<ConnectionSnapshot> {
    return this.snapshot
  }

  updateConfig(options: Pick<JsonRpcClientOptions, 'url' | 'token'>): void {
    this.config = { ...this.config, ...options }
  }

  onNotification(listener: (notification: RpcNotification) => void): () => void {
    this.notificationListeners.add(listener)
    return () => this.notificationListeners.delete(listener)
  }

  onServerRequest(listener: (request: ServerRequestEnvelope) => void): () => void {
    this.requestListeners.add(listener)
    return () => this.requestListeners.delete(listener)
  }

  onState(listener: (state: ConnectionSnapshot) => void): () => void {
    this.stateListeners.add(listener)
    listener(this.snapshot)
    return () => this.stateListeners.delete(listener)
  }

  onUnhandled(listener: (payload: unknown) => void): () => void {
    this.unhandledListeners.add(listener)
    return () => this.unhandledListeners.delete(listener)
  }

  onReady(listener: () => void | Promise<void>): () => void {
    this.readyListeners.add(listener)
    return () => this.readyListeners.delete(listener)
  }

  async connect(): Promise<void> {
    if (this.snapshot.phase === 'ready') return
    if (this.connectPromise) return this.connectPromise
    this.manuallyClosed = false
    this.clearReconnectTimer()
    const connection = this.openSocket()
    this.connectPromise = connection
    const clearCurrentConnection = (): void => {
      if (this.connectPromise === connection) this.connectPromise = null
    }
    void connection.then(clearCurrentConnection, clearCurrentConnection)
    return connection
  }

  disconnect(): void {
    this.manuallyClosed = true
    this.clearReconnectTimer()
    this.rejectPending(new Error('连接已关闭'))
    this.socket?.close(1000, 'client disconnect')
    this.socket = null
    this.setState({ phase: 'closed', nextRetryMs: null })
  }

  reconnectNow(): Promise<void> {
    this.manuallyClosed = false
    this.clearReconnectTimer()
    const superseded = this.socket
    this.socket = null
    this.connectPromise = null
    this.rejectPending(new Error('连接已替换'))
    superseded?.close(4000, 'reconnect')
    this.setState({ phase: 'reconnecting', attempt: 0, nextRetryMs: 0, error: null })
    return this.connect()
  }

  destroy(): void {
    this.disconnect()
    if (typeof window !== 'undefined') {
      window.removeEventListener('online', this.handleOnline)
      window.removeEventListener('offline', this.handleOffline)
    }
    this.notificationListeners.clear()
    this.requestListeners.clear()
    this.stateListeners.clear()
    this.unhandledListeners.clear()
    this.readyListeners.clear()
  }

  call<M extends KnownClientMethod>(method: M, params: ParamsOf<M>, options?: { timeoutMs?: number | null }): Promise<ResultOf<M>> {
    return this.request(method, params, options?.timeoutMs) as Promise<ResultOf<M>>
  }

  callUnknown<T = unknown>(method: string, params?: unknown): Promise<T> {
    return this.request(method, params) as Promise<T>
  }

  notify(method: string, params?: unknown): void {
    const envelope: UnknownRecord = { method }
    if (params !== undefined) envelope.params = params
    this.send(envelope)
  }

  respond(id: RequestId, result: unknown): void {
    this.send({ id, result })
  }

  respondError(id: RequestId, code: number, message: string, data?: unknown): void {
    const error: UnknownRecord = { code, message }
    if (data !== undefined) error.data = data
    this.send({ id, error })
  }

  private async openSocket(): Promise<void> {
    const online = typeof navigator === 'undefined' || navigator.onLine
    if (!online) {
      this.setState({ phase: 'offline', nextRetryMs: null })
      return
    }

    const isRetry = this.snapshot.attempt > 0 || this.snapshot.phase === 'reconnecting'
    this.setState({ phase: isRetry ? 'reconnecting' : 'connecting', nextRetryMs: null, error: null })

    await new Promise<void>((resolve, reject) => {
      const factory = this.config.socketFactory ?? ((url: string, protocols?: string[]) => new WebSocket(url, protocols))
      const protocols = this.config.token ? [gatewayTokenProtocol(this.config.token)] : undefined
      const socket = factory(this.connectionUrl(), protocols)
      this.socket = socket
      let settled = false

      const rejectIfUnsettled = (error: Error): void => {
        if (settled) return
        settled = true
        reject(error)
      }

      socket.addEventListener('open', () => {
        if (this.socket !== socket) {
          socket.close(4000, 'superseded')
          rejectIfUnsettled(new Error('WebSocket 连接已替换'))
          return
        }
        void this.initialize().then(() => {
          if (this.socket !== socket) {
            rejectIfUnsettled(new Error('WebSocket 连接已替换'))
            return
          }
          settled = true
          resolve()
        }).catch((error: unknown) => {
          const failure = error instanceof Error ? error : new Error(String(error))
          if (this.socket !== socket) {
            rejectIfUnsettled(new Error('WebSocket 连接已替换'))
            return
          }
          this.setState({ error: failure.message })
          socket.close(1011, 'initialize failed')
          rejectIfUnsettled(failure)
        })
      })

      socket.addEventListener('message', (event) => {
        if (this.socket === socket) this.handleMessage(event.data)
      })
      socket.addEventListener('error', () => {
        if (this.socket === socket) this.setState({ error: 'WebSocket 连接失败' })
      })
      socket.addEventListener('close', (event) => {
        // A superseded socket may deliver close after a replacement is ready.
        // It must not reject the replacement's requests or start a second retry loop.
        if (this.socket !== socket) {
          rejectIfUnsettled(new Error('WebSocket 连接已替换'))
          return
        }
        this.socket = null
        this.rejectPending(new Error(`连接中断 (${event.code})`))
        rejectIfUnsettled(new Error(event.reason || `WebSocket 已关闭 (${event.code})`))
        if (!this.manuallyClosed) this.scheduleReconnect(event.reason || `连接中断 (${event.code})`)
      })
    })
  }

  private async initialize(): Promise<void> {
    this.setState({ phase: 'initializing' })
    const params: InitializeParams = {
      clientInfo: { name: 'pocket-agent', title: 'Pocket Agent', version: '0.1.0' },
      capabilities: {
        experimentalApi: false,
        requestAttestation: false,
      },
    }
    const server = await this.call('initialize', params)
    this.notify('initialized')
    this.setState({ phase: 'ready', attempt: 0, nextRetryMs: null, error: null, server })
    for (const listener of this.readyListeners) void listener()
  }

  private request(method: string, params: unknown, timeoutOverride?: number | null): Promise<unknown> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('尚未连接到 app-server'))
    }
    const id = ++this.sequence
    return new Promise((resolve, reject) => {
      const timeoutMs = timeoutOverride === undefined ? this.config.requestTimeoutMs : timeoutOverride
      const timeout = timeoutMs === null ? null : setTimeout(() => {
          this.pending.delete(id)
          reject(new Error(`${method} 请求超时`))
        }, timeoutMs)
      this.pending.set(id, { method, resolve, reject, timeout })
      this.send({ id, method, params })
    })
  }

  private send(payload: UnknownRecord): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error('WebSocket 未连接')
    this.socket.send(JSON.stringify(payload))
  }

  private handleMessage(raw: unknown): void {
    if (typeof raw !== 'string') {
      this.emitUnhandled(raw)
      return
    }
    let message: RpcInbound
    try {
      message = JSON.parse(raw) as RpcInbound
    } catch {
      this.emitUnhandled(raw)
      return
    }

    if (isRpcSuccess(message) || isRpcFailure(message)) {
      const pending = this.pending.get(message.id)
      if (!pending) {
        this.emitUnhandled(message)
        return
      }
      if (pending.timeout) clearTimeout(pending.timeout)
      this.pending.delete(message.id)
      if (isRpcFailure(message)) pending.reject(new RpcError(message.error.message, message.error.code, message.error.data))
      else pending.resolve(message.result)
      return
    }

    if (isRpcRequest(message)) {
      for (const listener of this.requestListeners) listener(message as ServerRequestEnvelope)
      return
    }

    if (isRpcNotification(message)) {
      for (const listener of this.notificationListeners) listener(message)
      return
    }
    this.emitUnhandled(message)
  }

  private scheduleReconnect(reason: string): void {
    this.clearReconnectTimer()
    const attempt = this.snapshot.attempt + 1
    const base = this.config.reconnectBaseMs ?? 700
    const cap = this.config.reconnectMaxMs ?? 20_000
    const exponential = base * 2 ** Math.min(attempt - 1, 7)
    const random = this.config.random?.() ?? Math.random()
    const delay = Math.min(cap, Math.round(exponential * (0.75 + random * 0.5)))
    this.setState({ phase: 'reconnecting', attempt, nextRetryMs: delay, error: reason })
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      void this.connect().catch(() => undefined)
    }, delay)
  }

  private connectionUrl(): string {
    const url = new URL(this.config.url, typeof window !== 'undefined' ? window.location.href : 'http://localhost')
    return url.toString()
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
  }

  private rejectPending(error: Error): void {
    for (const request of this.pending.values()) {
      if (request.timeout) clearTimeout(request.timeout)
      request.reject(error)
    }
    this.pending.clear()
  }

  private setState(update: Partial<ConnectionSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...update }
    for (const listener of this.stateListeners) listener(this.snapshot)
  }

  private emitUnhandled(payload: unknown): void {
    for (const listener of this.unhandledListeners) listener(payload)
  }

  private handleOnline = (): void => {
    if (this.manuallyClosed || this.snapshot.phase === 'ready') return
    this.setState({ phase: 'reconnecting', nextRetryMs: 0, error: null })
    void this.connect().catch(() => undefined)
  }

  private handleOffline = (): void => {
    this.clearReconnectTimer()
    this.setState({ phase: 'offline', nextRetryMs: null, error: '设备当前离线' })
  }
}
