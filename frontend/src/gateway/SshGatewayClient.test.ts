import { afterEach, describe, expect, it, vi } from 'vitest'
import { configureGatewayConnection, gatewayApiUrl } from './SshGatewayClient'

afterEach(() => vi.unstubAllGlobals())

describe('SSH gateway control client', () => {
  it('derives authenticated HTTP control URLs from WebSocket endpoints', () => {
    expect(gatewayApiUrl('ws://127.0.0.1:8787/ws?token=legacy', '/api/ssh/connect'))
      .toBe('http://127.0.0.1:8787/api/ssh/connect')
    expect(gatewayApiUrl('wss://pocket.example/ws', '/api/ssh/status'))
      .toBe('https://pocket.example/api/ssh/status')
  })

  it('starts a key-based SSH session without putting the token in the URL', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      mode: 'ssh', connected: true, target: 'deploy@prod', localPort: 12345, remotePort: 4500,
    }), { status: 200, headers: { 'content-type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await configureGatewayConnection({
      mode: 'ssh',
      endpoint: 'wss://pocket.example/ws',
      token: 'secret token',
      sshTarget: 'deploy@prod',
      sshPort: '2222',
      sshIdentityFile: '/home/gateway/.ssh/prod key',
      sshRemotePort: '4500',
      sshCodexBin: '/opt/codex/bin/codex',
    })

    expect(result.connected).toBe(true)
    expect(fetchMock).toHaveBeenCalledOnce()
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('https://pocket.example/api/ssh/connect')
    expect(init.headers).toMatchObject({ 'X-Pocket-Agent-Token': 'secret token' })
    expect(JSON.parse(String(init.body))).toEqual({
      target: 'deploy@prod', port: 2222, identityFile: '/home/gateway/.ssh/prod key', remotePort: 4500, remoteCodexBin: '/opt/codex/bin/codex',
    })
  })

  it('rejects invalid ports before opening a network request', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    await expect(configureGatewayConnection({
      mode: 'ssh', endpoint: 'ws://localhost:8787/ws', token: 'token', sshTarget: 'prod',
      sshPort: '70000', sshIdentityFile: '', sshRemotePort: '', sshCodexBin: '',
    })).rejects.toThrow('SSH Port')
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
