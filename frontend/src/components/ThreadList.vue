<script setup lang="ts">
import { FolderGit2, LoaderCircle, MessageSquarePlus, RefreshCw } from '@lucide/vue'
import type { Thread } from '../protocol/types'

defineProps<{ threads: readonly Thread[]; activeId: string | null; loading: boolean }>()
const emit = defineEmits<{ select: [id: string]; create: []; refresh: [] }>()

function relativeTime(timestamp: number): string {
  const seconds = Math.max(0, Date.now() / 1000 - timestamp)
  if (seconds < 60) return '刚刚'
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} 小时前`
  return new Date(timestamp * 1000).toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' })
}
</script>

<template>
  <section class="page-section threads-page">
    <header class="section-heading">
      <div><span class="eyebrow">WORKSPACE</span><h1>任务</h1></div>
      <div class="heading-actions">
        <button class="icon-button" aria-label="刷新任务" @click="emit('refresh')"><RefreshCw :size="18" :class="{ spin: loading }" /></button>
        <button class="button compact primary" @click="emit('create')"><MessageSquarePlus :size="17" />新任务</button>
      </div>
    </header>

    <div v-if="loading && !threads.length" class="empty-state"><LoaderCircle class="spin" /><p>正在读取任务…</p></div>
    <div v-else-if="!threads.length" class="empty-state"><FolderGit2 /><h2>还没有任务</h2><p>创建第一个任务，或调整工作目录筛选。</p></div>
    <div v-else class="thread-stack">
      <button v-for="thread in threads" :key="thread.id" class="thread-row" :class="{ active: activeId === thread.id }" @click="emit('select', thread.id)">
        <span class="thread-status" :class="`status-${thread.status.type}`" />
        <span class="thread-copy">
          <b>{{ thread.name || thread.preview || '未命名任务' }}</b>
          <small>{{ thread.cwd || '默认目录' }}</small>
        </span>
        <span class="thread-meta"><time>{{ relativeTime(thread.updatedAt) }}</time><em>{{ thread.modelProvider }}</em></span>
      </button>
    </div>
  </section>
</template>
