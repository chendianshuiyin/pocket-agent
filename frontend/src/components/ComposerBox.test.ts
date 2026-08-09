import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ComposerBox from './ComposerBox.vue'
import type { SkillMetadata } from '../protocol/types'

const skill: SkillMetadata = {
  name: 'release-check',
  description: 'Run the release verification workflow',
  path: '/home/deploy/.codex/skills/release-check/SKILL.md',
  scope: 'user',
  enabled: true,
}

function mountComposer() {
  return mount(ComposerBox, {
    props: { attachments: [], skills: [skill], skillsLoading: false, running: false, disabled: false },
  })
}

describe('ComposerBox command palette', () => {
  it('shows slash commands and emits native command actions', async () => {
    const wrapper = mountComposer()
    await wrapper.get('textarea').setValue('/comp')
    expect(wrapper.text()).toContain('/compact')
    await wrapper.get('[data-kind="command"]').trigger('click')
    expect(wrapper.emitted('command')).toEqual([['compact']])
  })

  it('selects a remote skill and prepares the protocol marker', async () => {
    const wrapper = mountComposer()
    await wrapper.get('textarea').setValue('/skills')
    await wrapper.get('[data-kind="command"]').trigger('click')
    expect(wrapper.emitted('command')).toEqual([['skills']])
    expect(wrapper.text()).toContain('$release-check')

    await wrapper.get('[data-kind="skill"]').trigger('click')
    expect(wrapper.emitted('skill')).toEqual([[skill]])
    expect((wrapper.get('textarea').element as HTMLTextAreaElement).value).toBe('$release-check ')
  })

  it('sends unknown slash text as an ordinary Codex prompt', async () => {
    const wrapper = mountComposer()
    await wrapper.get('textarea').setValue('/custom do something')
    await wrapper.get('textarea').trigger('keydown', { key: 'Enter', ctrlKey: true })
    expect(wrapper.emitted('send')).toEqual([['/custom do something']])
    expect(wrapper.emitted('command')).toBeUndefined()
  })
})
