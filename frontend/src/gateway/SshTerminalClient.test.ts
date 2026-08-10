import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SshTerminalClient, terminalWebSocketUrl } from './SshTerminalClient'

class FakeSocket extends EventTarget {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  readyState = FakeSocket.CONNECTING
  sent: string[] = []

  constructor(readonly url: string, readonly protocols: string[]) { super() }

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

describe('SshTerminalClient', () => {
  const originalWebSocket = globalThis.WebSocket

  beforeEach(() => Object.defineProperty(globalThis, 'WebSocket', { configurable: true, value: FakeSocket }))
  afterEach(() => Object.defineProperty(globalThis, 'WebSocket', { configurable: true, value: originalWebSocket }))

  it('连接独立 terminal endpoint 并使用 token subprotocol', () => {
    let socket: FakeSocket | undefined
    const ready = vi.fn()
    const client = new SshTerminalClient(
      'wss://pocket.example/ws?legacy=1',
      'a token',
      { sessionId: 'term-1', target: 'deploy@prod', port: 2222, identityFile: '/keys/id', cwd: '/srv/app', rows: 24, cols: 80 },
      { onReady: ready, onOutput: vi.fn(), onExit: vi.fn(), onError: vi.fn(), onClose: vi.fn() },
      (url, protocols) => { socket = new FakeSocket(url, protocols); return socket as unknown as WebSocket },
    )
    client.connect()
    expect(socket?.url).toBe('wss://pocket.example/terminal/ws')
    expect(socket?.protocols).toEqual(['pocket-agent-token.6120746f6b656e'])
    socket!.open()
    expect(JSON.parse(socket!.sent[0]!)).toEqual({
      type: 'start', sessionId: 'term-1', target: 'deploy@prod', port: 2222, identityFile: '/keys/id', cwd: '/srv/app', rows: 24, cols: 80,
    })
    socket!.receive({ type: 'ready', sessionId: 'term-1' })
    expect(ready).toHaveBeenCalledOnce()
  })

  it('解码 ANSI 输出、发送交互输入并报告退出', () => {
    let socket: FakeSocket | undefined
    const output = vi.fn()
    const exit = vi.fn()
    const client = new SshTerminalClient(
      'ws://localhost:8787/ws', 'token',
      { sessionId: 'term-1', target: 'prod', port: null, identityFile: null, cwd: '', rows: 24, cols: 80 },
      { onReady: vi.fn(), onOutput: output, onExit: exit, onError: vi.fn(), onClose: vi.fn() },
      (url, protocols) => { socket = new FakeSocket(url, protocols); return socket as unknown as WebSocket },
    )
    client.connect()
    socket!.open()
    socket!.receive({ type: 'output', dataBase64: btoa('\u001b[32mOK\u001b[0m') })
    client.sendInput('ls\r')
    client.resize(40, 120)
    socket!.receive({ type: 'exit', exitCode: 0 })

    expect(output).toHaveBeenCalledWith('\u001b[32mOK\u001b[0m')
    expect(JSON.parse(socket!.sent[1]!)).toEqual({ type: 'input', dataBase64: btoa('ls\r') })
    expect(JSON.parse(socket!.sent[2]!)).toEqual({ type: 'resize', rows: 40, cols: 120 })
    expect(exit).toHaveBeenCalledWith(0)
  })
})

describe('terminalWebSocketUrl', () => {
  it('保留 Gateway origin 并替换路径', () => {
    expect(terminalWebSocketUrl('ws://127.0.0.1:8787/ws?token=old')).toBe('ws://127.0.0.1:8787/terminal/ws')
  })
})
