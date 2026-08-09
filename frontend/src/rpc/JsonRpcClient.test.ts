import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { JsonRpcClient } from './JsonRpcClient'

class FakeSocket extends EventTarget {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  readyState = FakeSocket.CONNECTING
  sent: string[] = []

  constructor(readonly url: string) { super() }

  open(): void {
    this.readyState = FakeSocket.OPEN
    this.dispatchEvent(new Event('open'))
  }

  receive(payload: unknown): void {
    this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(payload) }))
  }

  send(payload: string): void { this.sent.push(payload) }

  close(code = 1000, reason = ''): void {
    this.readyState = FakeSocket.CLOSED
    this.dispatchEvent(new CloseEvent('close', { code, reason }))
  }
}

const server = { userAgent: 'codex/0.144.0', codexHome: 'C:\\Users\\test\\.codex', platformFamily: 'windows', platformOs: 'windows' }

function lastMessage(socket: FakeSocket): Record<string, unknown> {
  return JSON.parse(socket.sent.at(-1) ?? '{}') as Record<string, unknown>
}

async function ready(client: JsonRpcClient, sockets: FakeSocket[]): Promise<void> {
  const connecting = client.connect()
  const socket = sockets[0]!
  socket.open()
  const initialize = lastMessage(socket)
  socket.receive({ id: initialize.id, result: server })
  await connecting
}

describe('JsonRpcClient', () => {
  const originalWebSocket = globalThis.WebSocket

  beforeEach(() => {
    Object.defineProperty(globalThis, 'WebSocket', { configurable: true, value: FakeSocket })
  })

  afterEach(() => {
    Object.defineProperty(globalThis, 'WebSocket', { configurable: true, value: originalWebSocket })
    vi.useRealTimers()
  })

  it('执行 initialize/initialized，并通过 query token 连接网关', async () => {
    const sockets: FakeSocket[] = []
    const client = new JsonRpcClient({
      url: 'ws://127.0.0.1:8787/ws',
      token: 'a token',
      socketFactory: (url) => { const socket = new FakeSocket(url); sockets.push(socket); return socket as unknown as WebSocket },
    })
    const promise = client.connect()
    const socket = sockets[0]!
    expect(socket.url).toBe('ws://127.0.0.1:8787/ws?token=a+token')
    socket.open()
    const initialize = lastMessage(socket)
    expect(initialize.method).toBe('initialize')
    expect(initialize.params).toMatchObject({ capabilities: { experimentalApi: false } })
    socket.receive({ id: initialize.id, result: server })
    await promise
    expect(lastMessage(socket)).toEqual({ method: 'initialized' })
    expect(client.state.phase).toBe('ready')
    client.destroy()
  })

  it('忽略被替换 socket 的迟到 close，不干扰新连接 pending request', async () => {
    const sockets: FakeSocket[] = []
    const client = new JsonRpcClient({
      url: 'ws://localhost/ws',
      socketFactory: (url) => { const socket = new FakeSocket(url); sockets.push(socket); return socket as unknown as WebSocket },
    })
    await ready(client, sockets)
    const oldSocket = sockets[0]!
    // Prevent close() itself from emitting; deliver the stale close after replacement is active.
    oldSocket.close = () => { oldSocket.readyState = FakeSocket.CLOSED }
    const reconnecting = client.reconnectNow()
    const newSocket = sockets[1]!
    newSocket.open()
    const initialize = lastMessage(newSocket)
    newSocket.receive({ id: initialize.id, result: server })
    await reconnecting

    const request = client.callUnknown('custom/ping', {})
    const ping = lastMessage(newSocket)
    oldSocket.dispatchEvent(new CloseEvent('close', { code: 1006, reason: 'late close' }))
    newSocket.receive({ id: ping.id, result: { pong: true } })
    await expect(request).resolves.toEqual({ pong: true })
    expect(sockets).toHaveLength(2)
    expect(client.state.phase).toBe('ready')
    client.destroy()
  })

  it('对重连指数延迟施加 jitter', async () => {
    vi.useFakeTimers()
    const sockets: FakeSocket[] = []
    const client = new JsonRpcClient({
      url: 'ws://localhost/ws', reconnectBaseMs: 100, random: () => 0,
      socketFactory: (url) => { const socket = new FakeSocket(url); sockets.push(socket); return socket as unknown as WebSocket },
    })
    await ready(client, sockets)
    sockets[0]!.close(1006, 'network')
    expect(client.state).toMatchObject({ phase: 'reconnecting', attempt: 1, nextRetryMs: 75 })
    await vi.advanceTimersByTimeAsync(74)
    expect(sockets).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(sockets).toHaveLength(2)
    client.destroy()
  })

  it('允许 command/exec 显式关闭客户端请求超时', async () => {
    vi.useFakeTimers()
    const sockets: FakeSocket[] = []
    const client = new JsonRpcClient({
      url: 'ws://localhost/ws', requestTimeoutMs: 30_000,
      socketFactory: (url) => { const socket = new FakeSocket(url); sockets.push(socket); return socket as unknown as WebSocket },
    })
    const connected = client.connect()
    sockets[0]!.open()
    const initialize = lastMessage(sockets[0]!)
    sockets[0]!.receive({ id: initialize.id, result: server })
    await connected
    const running = client.call('command/exec', { command: ['pwsh'], processId: 'pty', tty: true }, { timeoutMs: null })
    const command = lastMessage(sockets[0]!)
    await vi.advanceTimersByTimeAsync(120_000)
    sockets[0]!.receive({ id: command.id, result: { exitCode: 0, stdout: '', stderr: '' } })
    await expect(running).resolves.toMatchObject({ exitCode: 0 })
    client.destroy()
  })
})
