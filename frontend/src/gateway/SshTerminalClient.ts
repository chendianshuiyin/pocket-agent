export interface SshTerminalStart {
  sessionId: string
  target: string
  port: number | null
  identityFile: string | null
  cwd: string
  rows: number
  cols: number
}

export interface SshTerminalCallbacks {
  onReady(): void
  onOutput(data: string): void
  onExit(exitCode: number): void
  onError(message: string): void
  onClose(intentional: boolean): void
}

interface ServerMessage {
  type?: unknown
  sessionId?: unknown
  dataBase64?: unknown
  exitCode?: unknown
  message?: unknown
}

type SocketFactory = (url: string, protocols: string[]) => WebSocket

export class SshTerminalClient {
  private socket: WebSocket | null = null
  private readonly decoder = new TextDecoder()
  private intentionalClose = false
  private exited = false

  constructor(
    private readonly endpoint: string,
    private readonly token: string,
    private readonly start: SshTerminalStart,
    private readonly callbacks: SshTerminalCallbacks,
    private readonly socketFactory: SocketFactory = (url, protocols) => new WebSocket(url, protocols),
  ) {}

  connect(): void {
    this.close()
    this.intentionalClose = false
    this.exited = false
    const socket = this.socketFactory(terminalWebSocketUrl(this.endpoint), [tokenSubprotocol(this.token)])
    this.socket = socket
    socket.addEventListener('open', () => {
      if (this.socket !== socket) return
      socket.send(JSON.stringify({ type: 'start', ...this.start }))
    })
    socket.addEventListener('message', (event) => {
      if (this.socket !== socket || typeof event.data !== 'string') return
      this.handleMessage(event.data)
    })
    socket.addEventListener('error', () => {
      if (this.socket === socket) this.callbacks.onError('SSH terminal WebSocket 连接失败')
    })
    socket.addEventListener('close', () => {
      if (this.socket !== socket) return
      this.socket = null
      const tail = this.decoder.decode()
      if (tail) this.callbacks.onOutput(tail)
      this.callbacks.onClose(this.intentionalClose || this.exited)
    })
  }

  sendInput(data: string): void {
    this.sendBytes(new TextEncoder().encode(data))
  }

  sendBinary(data: string): void {
    this.sendBytes(Uint8Array.from(data, (character) => character.charCodeAt(0)))
  }

  resize(rows: number, cols: number): void {
    this.send({ type: 'resize', rows, cols })
  }

  close(): void {
    const socket = this.socket
    if (!socket) return
    this.intentionalClose = true
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'close' }))
    socket.close(1000, 'terminal closed')
  }

  private sendBytes(bytes: Uint8Array): void {
    this.send({ type: 'input', dataBase64: bytesToBase64(bytes) })
  }

  private send(message: Record<string, unknown>): void {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(message))
  }

  private handleMessage(raw: string): void {
    let message: ServerMessage
    try {
      message = JSON.parse(raw) as ServerMessage
    } catch {
      this.callbacks.onError('SSH terminal 返回了无效消息')
      return
    }
    switch (message.type) {
      case 'ready':
        if (message.sessionId !== this.start.sessionId) this.callbacks.onError('SSH terminal sessionId 不匹配')
        else this.callbacks.onReady()
        break
      case 'output':
        if (typeof message.dataBase64 !== 'string') this.callbacks.onError('SSH terminal 输出格式无效')
        else {
          try {
            this.callbacks.onOutput(this.decoder.decode(base64ToBytes(message.dataBase64), { stream: true }))
          } catch {
            this.callbacks.onError('SSH terminal 输出无法解码')
          }
        }
        break
      case 'exit':
        if (typeof message.exitCode !== 'number') this.callbacks.onError('SSH terminal exitCode 无效')
        else {
          this.exited = true
          this.callbacks.onExit(message.exitCode)
        }
        break
      case 'error':
        this.callbacks.onError(typeof message.message === 'string' ? message.message : 'SSH terminal 未知错误')
        break
      default:
        this.callbacks.onError('SSH terminal 返回了未知消息')
    }
  }
}

export function terminalWebSocketUrl(endpoint: string): string {
  const url = new URL(endpoint)
  if (url.protocol !== 'ws:' && url.protocol !== 'wss:') throw new Error('Gateway 地址必须使用 ws:// 或 wss://')
  url.pathname = '/terminal/ws'
  url.search = ''
  url.hash = ''
  return url.toString()
}

function tokenSubprotocol(token: string): string {
  const encoded = Array.from(new TextEncoder().encode(token), (byte) => byte.toString(16).padStart(2, '0')).join('')
  return `pocket-agent-token.${encoded}`
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000))
  }
  return btoa(binary)
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value)
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}
