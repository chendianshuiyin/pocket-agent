import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import { createTerminalManager, createTerminalSession } from '../stores/terminalManager'
import TerminalPanel from './TerminalPanel.vue'

describe('TerminalPanel', () => {
  it('显示多个会话，并把命令发送到当前会话', async () => {
    const manager = createTerminalManager('/repo', () => 'term-1')
    manager.sessions.push(createTerminalSession('term-2', 2, '/other'))
    manager.activeSessionId = 'term-2'
    const wrapper = mountPanel(manager)

    expect(wrapper.text()).toContain('2 个会话')
    const command = wrapper.find('.command-launcher input')
    await command.setValue('npm test')
    await wrapper.find('.command-launcher').trigger('submit')

    expect(wrapper.emitted('run')).toEqual([['term-2', 'npm test']])
  })

  it('运行中的会话显示状态且不能关闭', () => {
    const manager = createTerminalManager('/repo', () => 'term-1')
    Object.assign(manager.sessions[0]!, { running: true, interactive: true, processId: 'process-1' })
    const wrapper = mountPanel(manager)

    expect(wrapper.text()).toContain('1 个运行中')
    expect(wrapper.text()).toContain('远端 PTY 在线')
    expect(wrapper.find('.terminal-tab-close').attributes('disabled')).toBeDefined()
    expect(wrapper.find('.stdin-row input').attributes('disabled')).toBeUndefined()
  })

  it('从最近命令恢复输入，并支持清空当前会话', async () => {
    const manager = createTerminalManager('/repo', () => 'term-1')
    manager.sessions[0]!.commandHistory = ['cargo test', 'git status']
    const wrapper = mountPanel(manager)

    await wrapper.find('.terminal-history button').trigger('click')
    expect((wrapper.find('.command-launcher input').element as HTMLInputElement).value).toBe('cargo test')
    await wrapper.find('.terminal-title button').trigger('click')
    expect(wrapper.emitted('clear')).toEqual([['term-1']])
  })
})

function mountPanel(manager: ReturnType<typeof createTerminalManager>) {
  return mount(TerminalPanel, {
    props: { manager, events: [], remoteReady: true, remoteTarget: 'deploy@prod' },
    global: { stubs: { TerminalCanvas: true } },
  })
}
