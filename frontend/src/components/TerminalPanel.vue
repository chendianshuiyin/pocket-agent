<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { ChevronDown, CircleStop, CornerDownLeft, LoaderCircle, Play, RadioTower, Send, Trash2 } from '@lucide/vue'
import type { ShellState } from '../stores/useCodexSession'
import type { TerminalLine } from '../protocol/types'

const props = defineProps<{ shell: Readonly<ShellState>; events: readonly TerminalLine[]; connected: boolean }>()
const emit = defineEmits<{ run: [command: string]; write: [value: string]; terminate: [] }>()
const mode = ref<'shell' | 'events'>('shell')
const output = ref<HTMLElement>()
const command = ref('')
const stdin = ref('')
const expanded = ref<Record<string, boolean>>({})

watch(() => props.shell.output, async () => {
  await nextTick()
  if (output.value) output.value.scrollTop = output.value.scrollHeight
})

const recentEvents = computed(() => [...props.events].reverse())

function run(): void {
  if (!command.value.trim()) return
  emit('run', command.value)
}

function write(): void {
  if (!stdin.value) return
  emit('write', stdin.value)
  stdin.value = ''
}
</script>

<template>
  <section class="page-section terminal-page">
    <header class="section-heading">
      <div><span class="eyebrow">LIVE CHANNEL</span><h1>Terminal</h1></div>
      <div class="segmented">
        <button :class="{ active: mode === 'shell' }" @click="mode = 'shell'">Shell</button>
        <button :class="{ active: mode === 'events' }" @click="mode = 'events'">Events <em>{{ events.length }}</em></button>
      </div>
    </header>

    <template v-if="mode === 'shell'">
      <form class="command-launcher" @submit.prevent="run">
        <span class="prompt-mark">›_</span><input v-model="command" :disabled="!connected || shell.running" placeholder="输入 PowerShell / shell 命令" />
        <button v-if="!shell.running" class="run-button" :disabled="!connected || !command.trim()"><Play :size="17" fill="currentColor" /></button>
        <button v-else type="button" class="run-button danger" @click="emit('terminate')"><CircleStop :size="18" /></button>
      </form>

      <div class="live-terminal">
        <div class="terminal-title"><i /><i /><i /><span>{{ shell.processId || 'pocket terminal' }}</span><LoaderCircle v-if="shell.running" :size="14" class="spin" /></div>
        <pre ref="output">{{ shell.output || (shell.running ? '正在启动…' : '执行 command/exec 后，PTY 输出将在这里实时显示。') }}</pre>
        <footer v-if="shell.exitCode !== null || shell.error"><span v-if="shell.exitCode !== null">exit {{ shell.exitCode }}</span><span v-if="shell.error" class="error-text">{{ shell.error }}</span></footer>
      </div>

      <form class="stdin-row" @submit.prevent="write">
        <CornerDownLeft :size="16" /><input v-model="stdin" :disabled="!shell.running || !shell.interactive" placeholder="向正在运行的 PTY 写入 stdin" />
        <button :disabled="!shell.running || !shell.interactive || !stdin"><Send :size="16" /></button>
      </form>
      <p class="panel-note">Unix 与显式 <code>danger-full-access</code> 使用 PTY；Windows 安全 sandbox 会自动改用 buffered terminal。PTY 进程在连接断开时由服务器终止。</p>
    </template>

    <div v-else class="event-stream">
      <div v-if="!events.length" class="empty-state"><RadioTower /><h2>等待事件</h2><p>连接后的所有通知都会保留在这里。</p></div>
      <article v-for="event in recentEvents" v-else :key="event.id" class="event-row" :class="`level-${event.level}`">
        <button @click="expanded[event.id] = !expanded[event.id]">
          <span class="event-direction">{{ event.direction === 'in' ? '←' : event.direction === 'out' ? '→' : '•' }}</span>
          <span class="event-main"><b>{{ event.method }}</b><small>{{ event.summary }}</small></span>
          <time>{{ new Date(event.timestamp).toLocaleTimeString('zh-CN', { hour12: false }) }}</time><ChevronDown :size="15" :class="{ rotated: expanded[event.id] }" />
        </button>
        <pre v-if="expanded[event.id]">{{ JSON.stringify(event.payload, null, 2) }}</pre>
      </article>
    </div>
  </section>
</template>
