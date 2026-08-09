import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ApprovalCard from './ApprovalCard.vue'
import type { PendingServerRequest } from '../stores/useCodexSession'

describe('ApprovalCard requestUserInput', () => {
  it('对 secret 与 options:null 提供自由 password 输入且只向父组件提交答案', async () => {
    const pending: PendingServerRequest = {
      receivedAt: Date.now(),
      request: {
        id: 9,
        method: 'item/tool/requestUserInput',
        params: {
          threadId: 'thread', turnId: 'turn', itemId: 'item', autoResolutionMs: 10_000,
          questions: [{ id: 'password', header: 'Secret', question: 'Token?', isOther: false, isSecret: true, options: null }],
        },
      },
    }
    const wrapper = mount(ApprovalCard, { props: { pending, index: 0 } })
    const input = wrapper.get('input[type="password"]')
    await input.setValue('sensitive-value')
    await wrapper.get('form').trigger('submit')
    expect(wrapper.emitted('answer')?.[0]).toEqual([0, { password: ['sensitive-value'] }])
    expect(wrapper.text()).not.toContain('sensitive-value')
    expect(wrapper.text()).toContain('服务器可能在')
    wrapper.unmount()
  })

  it('清楚标记来自其他 thread 的后台审批', () => {
    const pending: PendingServerRequest = {
      receivedAt: Date.now(),
      request: {
        id: 10,
        method: 'item/commandExecution/requestApproval',
        params: { threadId: 'thread-background-123', turnId: 'turn', itemId: 'item', command: 'git status', cwd: 'D:\\repo' },
      },
    }
    const wrapper = mount(ApprovalCard, {
      props: { pending, index: 0, activeThreadId: 'thread-active', threadLabel: '后台构建任务' },
    })
    expect(wrapper.get('.request-context').classes()).toContain('background')
    expect(wrapper.text()).toContain('后台任务')
    expect(wrapper.text()).toContain('后台构建任务')
    expect(wrapper.text()).toContain('D:\\repo')
    wrapper.unmount()
  })
})
