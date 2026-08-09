<script setup lang="ts">
import { computed } from 'vue'
import { Bot, Box, Brain, CheckCircle2, ChevronRight, CircleDotDashed, FileDiff, Globe2, Image, ListChecks, Sparkles, TerminalSquare, UserRound, Wrench } from '@lucide/vue'
import { asRecord } from '../protocol/guards'
import type { ThreadItem } from '../protocol/types'

const props = defineProps<{ item: ThreadItem; turnId: string; turnStatus: string; diff?: string | undefined; plan?: { explanation: string | null; plan: Record<string, unknown>[] } | undefined }>()

const textContent = computed(() => {
  if (props.item.type === 'userMessage') {
    const content = Array.isArray(props.item.content) ? props.item.content : []
    return content.map((part) => {
      const value = asRecord(part)
      if (value.type === 'text') return String(value.text ?? '')
      if (value.type === 'localImage') return `📷 ${value.path ?? ''}`
      if (value.type === 'image') return '📷 图片'
      if (value.type === 'mention') return `📎 ${value.name ?? value.path ?? ''}`
      if (value.type === 'skill') return ''
      return JSON.stringify(part)
    }).filter(Boolean).join('\n')
  }
  if (props.item.type === 'agentMessage' || props.item.type === 'plan') return String(props.item.text ?? '')
  return ''
})

const skillInputs = computed(() => {
  if (props.item.type !== 'userMessage' || !Array.isArray(props.item.content)) return []
  return props.item.content.map(asRecord).filter((part) => part.type === 'skill')
})

const reasoning = computed(() => {
  const summary = Array.isArray(props.item.summary) ? props.item.summary.filter((value): value is string => typeof value === 'string') : []
  const content = Array.isArray(props.item.content) ? props.item.content.filter((value): value is string => typeof value === 'string') : []
  return [...summary, ...content].join('\n\n')
})

const changes = computed(() => Array.isArray(props.item.changes) ? props.item.changes.map(asRecord) : [])

const isKnown = computed(() => [
  'userMessage', 'agentMessage', 'reasoning', 'plan', 'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall',
  'webSearch', 'imageView', 'imageGeneration', 'collabAgentToolCall', 'subAgentActivity', 'contextCompaction', 'sleep',
].includes(props.item.type))
</script>

<template>
  <article v-if="item.type === 'userMessage'" class="message-card user-message">
    <div class="avatar user"><UserRound :size="17" /></div>
    <div class="message-body">
      <span class="message-label">YOU</span>
      <div v-if="skillInputs.length" class="skill-call-list">
        <span v-for="skill in skillInputs" :key="String(skill.path)"><Sparkles :size="14" /><b>${{ skill.name }}</b><small>{{ skill.path }}</small></span>
      </div>
      <p v-if="textContent">{{ textContent }}</p>
    </div>
  </article>

  <article v-else-if="item.type === 'agentMessage'" class="message-card agent-message">
    <div class="avatar agent"><Bot :size="18" /></div>
    <div class="message-body"><span class="message-label">CODEX</span><p>{{ textContent }}<i v-if="turnStatus === 'inProgress'" class="stream-caret" /></p></div>
  </article>

  <details v-else-if="item.type === 'reasoning'" class="activity-card reasoning-card">
    <summary><Brain :size="17" /><span>推理过程</span><small>{{ reasoning ? '查看详情' : '思考中…' }}</small><ChevronRight :size="16" /></summary>
    <div class="activity-content prose">{{ reasoning || '正在组织思路…' }}</div>
  </details>

  <article v-else-if="item.type === 'plan'" class="activity-card plan-card">
    <header><ListChecks :size="17" /><b>执行计划</b></header>
    <p v-if="textContent">{{ textContent }}</p>
    <p v-if="plan?.explanation" class="muted-line">{{ plan.explanation }}</p>
    <ol v-if="plan?.plan.length" class="plan-list">
      <li v-for="(step, index) in plan.plan" :key="index" :class="`plan-${step.status}`">
        <CheckCircle2 v-if="step.status === 'completed'" :size="15" /><CircleDotDashed v-else :size="15" />
        <span>{{ step.step }}</span>
      </li>
    </ol>
  </article>

  <details v-else-if="item.type === 'commandExecution'" class="activity-card command-card" open>
    <summary><TerminalSquare :size="17" /><span class="mono ellipsis">{{ item.command }}</span><small>{{ item.status }}</small><ChevronRight :size="16" /></summary>
    <div class="terminal-output"><div class="terminal-title"><i /><i /><i /><span>{{ item.cwd }}</span></div><pre>{{ item.aggregatedOutput || '等待输出…' }}</pre></div>
  </details>

  <details v-else-if="item.type === 'fileChange'" class="activity-card file-card">
    <summary><FileDiff :size="17" /><span>{{ changes.length }} 个文件变更</span><small>{{ item.status }}</small><ChevronRight :size="16" /></summary>
    <div class="change-list">
      <div v-for="(change, index) in changes" :key="index" class="change-item">
        <b>{{ change.path }}</b><em>{{ asRecord(change.kind).type }}</em><pre>{{ change.diff }}</pre>
      </div>
      <pre v-if="diff" class="unified-diff">{{ diff }}</pre>
    </div>
  </details>

  <details v-else-if="item.type === 'mcpToolCall' || item.type === 'dynamicToolCall'" class="activity-card tool-card">
    <summary><Wrench :size="17" /><span>{{ item.type === 'mcpToolCall' ? `${item.server} / ${item.tool}` : `${item.namespace || 'tool'} / ${item.tool}` }}</span><small>{{ item.status }}</small><ChevronRight :size="16" /></summary>
    <pre class="raw-block">{{ JSON.stringify(item, null, 2) }}</pre>
  </details>

  <details v-else-if="item.type === 'webSearch'" class="activity-card compact-card">
    <summary><Globe2 :size="17" /><span>Web Search</span><small>查看</small><ChevronRight :size="16" /></summary><pre class="raw-block">{{ JSON.stringify(item, null, 2) }}</pre>
  </details>
  <details v-else-if="item.type === 'imageView' || item.type === 'imageGeneration'" class="activity-card compact-card">
    <summary><Image :size="17" /><span>{{ item.type }}</span><small>{{ item.path || '' }}</small><ChevronRight :size="16" /></summary><pre class="raw-block">{{ JSON.stringify(item, null, 2) }}</pre>
  </details>
  <details v-else-if="item.type === 'collabAgentToolCall' || item.type === 'subAgentActivity'" class="activity-card compact-card">
    <summary><Box :size="17" /><span>{{ item.type }}</span><small>{{ item.status || item.kind }}</small><ChevronRight :size="16" /></summary><pre class="raw-block">{{ JSON.stringify(item, null, 2) }}</pre>
  </details>
  <div v-else-if="item.type === 'contextCompaction' || item.type === 'sleep'" class="system-divider"><span>{{ item.type === 'sleep' ? `等待 ${item.durationMs}ms` : '上下文已压缩' }}</span></div>

  <details v-else-if="!isKnown" class="activity-card unknown-card">
    <summary><Box :size="17" /><span>未知 item: {{ item.type }}</span><small>原始数据已保留</small><ChevronRight :size="16" /></summary>
    <pre class="raw-block">{{ JSON.stringify(item, null, 2) }}</pre>
  </details>
</template>
