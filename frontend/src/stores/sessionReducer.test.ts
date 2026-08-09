import { describe, expect, it } from 'vitest'
import type { ThreadItem } from '../protocol/types'
import { ALL_INTERACTIVE_SOURCE_KINDS, createThreadStartSandboxParams, filterResolvedRequests, hasGatewayToken, mergeLifecycleItem, shouldApplyScopedNotification, terminalSandboxPolicy, terminalSupportsStreaming } from './useCodexSession'

describe('Codex session protocol regressions', () => {
  it('空 Token 不应启动网关连接', () => {
    expect(hasGatewayToken('')).toBe(false)
    expect(hasGatewayToken('secret')).toBe(true)
  })

  it('thread/start 使用 app-server 要求的 kebab-case SandboxMode', () => {
    expect(createThreadStartSandboxParams('workspace-write')).toEqual({ sandbox: 'workspace-write' })
  })

  it('thread/list 显式包含 appServer 与 sub-agent sources', () => {
    expect(ALL_INTERACTIVE_SOURCE_KINDS).toContain('appServer')
    expect(ALL_INTERACTIVE_SOURCE_KINDS).toContain('subAgentThreadSpawn')
  })

  it('completed item 覆盖此前聚合的 delta 临时 item', () => {
    const items: ThreadItem[] = [{ type: 'agentMessage', id: 'item-1', text: 'partial' }]
    mergeLifecycleItem(items, { type: 'agentMessage', id: 'item-1', text: 'final response', phase: 'final_answer' })
    expect(items).toEqual([{ type: 'agentMessage', id: 'item-1', text: 'final response', phase: 'final_answer' }])
  })

  it('serverRequest/resolved 清理同 requestId 的 stale 请求', () => {
    const pending = [
      { request: { id: 1, method: 'item/tool/requestUserInput' } },
      { request: { id: 2, method: 'item/fileChange/requestApproval' } },
    ]
    expect(filterResolvedRequests(pending, 1)).toEqual([pending[1]])
  })

  it('忽略其他已 resume thread 的 turn/item/delta 通知', () => {
    expect(shouldApplyScopedNotification('thread-a', 'item/agentMessage/delta', { threadId: 'thread-b' })).toBe(false)
    expect(shouldApplyScopedNotification('thread-a', 'turn/completed', { threadId: 'thread-a' })).toBe(true)
    expect(shouldApplyScopedNotification(null, 'item/started', { threadId: 'old-thread' })).toBe(false)
    expect(shouldApplyScopedNotification('thread-a', 'command/exec/outputDelta', { processId: 'p' })).toBe(true)
  })

  it('Windows 安全 sandbox 使用 buffered terminal，并保持精确 SandboxPolicy wire format', () => {
    expect(terminalSupportsStreaming(true, 'workspace-write')).toBe(false)
    expect(terminalSupportsStreaming(true, 'danger-full-access')).toBe(true)
    expect(terminalSupportsStreaming(false, 'workspace-write')).toBe(true)
    expect(terminalSandboxPolicy('workspace-write', 'D:\\repo')).toEqual({
      type: 'workspaceWrite',
      writableRoots: ['D:\\repo'],
      networkAccess: false,
      excludeTmpdirEnvVar: false,
      excludeSlashTmp: false,
    })
    expect(terminalSandboxPolicy('read-only', '')).toEqual({ type: 'readOnly', networkAccess: false })
    expect(terminalSandboxPolicy('danger-full-access', '')).toEqual({ type: 'dangerFullAccess' })
  })
})
