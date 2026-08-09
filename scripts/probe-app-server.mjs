const endpoint = process.env.CODEX_APP_SERVER_URL ?? 'ws://127.0.0.1:4500'
const gatewayToken = process.env.POCKET_AGENT_TOKEN ?? ''
const tokenProtocol = gatewayToken
  ? `pocket-agent-token.${Buffer.from(gatewayToken, 'utf8').toString('hex')}`
  : undefined
const socket = new WebSocket(endpoint, tokenProtocol ? [tokenProtocol] : undefined)
const pending = new Map()
let nextId = 0

const hardTimeout = setTimeout(() => {
  console.error('app-server probe timed out')
  process.exit(2)
}, 30_000)

function request(method, params, timeoutMs = 15_000) {
  const id = ++nextId
  socket.send(JSON.stringify({ method, id, params }))
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id)
      reject(new Error(`${method} timed out`))
    }, timeoutMs)
    pending.set(id, { resolve, reject, timeout })
  })
}

socket.addEventListener('message', async (event) => {
  const raw = typeof event.data === 'string' ? event.data : await event.data.text()
  const message = JSON.parse(raw)
  if (message.id === undefined) return

  const entry = pending.get(message.id)
  if (!entry) return
  clearTimeout(entry.timeout)
  pending.delete(message.id)

  if (message.error) {
    const error = new Error(message.error.message)
    error.code = message.error.code
    error.data = message.error.data
    entry.reject(error)
  } else {
    entry.resolve(message.result)
  }
})

socket.addEventListener('open', async () => {
  try {
    const initialize = await request('initialize', {
      clientInfo: {
        name: 'pocket_agent_probe',
        title: 'Pocket Agent Protocol Probe',
        version: '0.2.0',
      },
      capabilities: {
        experimentalApi: false,
        requestAttestation: false,
      },
    })
    socket.send(JSON.stringify({ method: 'initialized' }))

    const models = await request('model/list', { limit: 5 })

    let rejectedLegacySandbox = false
    try {
      await request('thread/start', {
        ephemeral: true,
        sandbox: 'workspaceWrite',
      })
    } catch (error) {
      rejectedLegacySandbox = error.code === -32600
    }
    if (!rejectedLegacySandbox) {
      throw new Error('legacy thread/start sandbox value was not rejected')
    }

    const started = await request('thread/start', {
      ephemeral: true,
      sandbox: 'workspace-write',
    })

    console.log(JSON.stringify({
      endpoint,
      userAgent: initialize.userAgent,
      platformFamily: initialize.platformFamily,
      models: models.data?.map((model) => model.model) ?? [],
      threadId: started.thread?.id,
      sandbox: started.sandbox?.type,
      rejectedLegacySandbox,
    }, null, 2))

    clearTimeout(hardTimeout)
    socket.close()
    setTimeout(() => process.exit(0), 100)
  } catch (error) {
    clearTimeout(hardTimeout)
    console.error(error.stack ?? error.message)
    socket.close()
    setTimeout(() => process.exit(1), 100)
  }
})

socket.addEventListener('error', () => {
  console.error(`could not connect to ${endpoint}`)
})
