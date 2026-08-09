export type GatewayMode = 'local' | 'ssh'

export interface GatewaySshSettings {
  mode: GatewayMode
  endpoint: string
  token: string
  sshTarget: string
  sshPort: string
  sshIdentityFile: string
  sshRemotePort: string
  sshCodexBin: string
}

export interface GatewaySshStatus {
  mode: GatewayMode
  connected: boolean
  target?: string
  localPort?: number
  remotePort?: number
}

export function gatewayApiUrl(websocketEndpoint: string, path: string): string {
  const url = new URL(websocketEndpoint)
  if (url.protocol === 'ws:') url.protocol = 'http:'
  else if (url.protocol === 'wss:') url.protocol = 'https:'
  else throw new Error('Gateway 地址必须使用 ws:// 或 wss://')
  url.pathname = path
  url.search = ''
  url.hash = ''
  return url.toString()
}

export async function configureGatewayConnection(settings: GatewaySshSettings): Promise<GatewaySshStatus> {
  const remote = settings.mode === 'ssh'
  const request: RequestInit = {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Pocket-Agent-Token': settings.token,
    },
  }
  if (remote) request.body = JSON.stringify(compactRequest({
    target: settings.sshTarget.trim(),
    port: optionalPort(settings.sshPort, 'SSH Port'),
    identityFile: optionalText(settings.sshIdentityFile),
    remotePort: optionalPort(settings.sshRemotePort, 'Remote app-server Port'),
    remoteCodexBin: optionalText(settings.sshCodexBin),
  }))

  const response = await fetch(gatewayApiUrl(
    settings.endpoint,
    remote ? '/api/ssh/connect' : '/api/ssh/disconnect',
  ), request)

  const payload = await readJson(response)
  if (!response.ok) {
    const message = typeof payload.error === 'string' ? payload.error : `Gateway 返回 HTTP ${response.status}`
    throw new Error(message)
  }
  if (payload.mode !== 'local' && payload.mode !== 'ssh') throw new Error('Gateway 返回了无法识别的连接状态')
  return payload as unknown as GatewaySshStatus
}

function optionalPort(value: string, label: string): number | undefined {
  if (!value.trim()) return undefined
  const port = Number(value)
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`${label} 必须是 1-65535`)
  return port
}

function optionalText(value: string): string | undefined {
  return value.trim() || undefined
}

function compactRequest(input: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(input).filter(([, value]) => value !== undefined))
}

async function readJson(response: Response): Promise<Record<string, unknown>> {
  try {
    const value: unknown = await response.json()
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
  } catch {
    return {}
  }
}
