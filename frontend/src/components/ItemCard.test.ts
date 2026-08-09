import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import ItemCard from './ItemCard.vue'

describe('ItemCard skill calls', () => {
  it('renders explicit skill input instead of hiding it in raw JSON', () => {
    const wrapper = mount(ItemCard, {
      props: {
        item: {
          type: 'userMessage',
          id: 'item-1',
          content: [
            { type: 'text', text: '$release-check verify this build', text_elements: [] },
            { type: 'skill', name: 'release-check', path: '/srv/.codex/skills/release-check/SKILL.md' },
          ],
        },
        turnId: 'turn-1',
        turnStatus: 'completed',
      },
    })

    expect(wrapper.text()).toContain('$release-check')
    expect(wrapper.text()).toContain('/srv/.codex/skills/release-check/SKILL.md')
    expect(wrapper.text()).toContain('verify this build')
  })
})
