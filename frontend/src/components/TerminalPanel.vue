<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import {
  ChevronDown,
  CircleStop,
  CornerDownLeft,
  Eraser,
  FolderOpen,
  LoaderCircle,
  Plus,
  RadioTower,
  Send,
  X,
} from '@lucide/vue'
import type { TerminalLine } from '../protocol/types'
import { MAX_TERMINAL_SESSIONS } from '../stores/terminalManager'
import type { TerminalManagerState, TerminalSession } from '../stores/terminalManager'

const props = defineProps<{ manager: TerminalManagerState; events: readonly TerminalLine[]; connected: boolean }>()
const emit = defineEmits<{
  add: []
  select: [sessionId: string]
  update: [sessionId: string, patch: Partial<Pick<TerminalSession, 'name' | 'command' | 'cwd'>>]
  close: [sessionId: string]
  clear: [sessionId: string]
  run: [sessionId: string, command: string]
  write: [sessionId: string, value: string]
  resize: [sessionId: string, rows: number, cols: number]
  terminate: [sessionId: string]
}>()

const mode = ref<'shell' | 'events'>('shell')
const output = ref<HTMLElement>()
const command = ref('')
const cwd = ref('')
const name = ref('')
const stdin = ref('')
const historyIndex = ref(-1)
const expanded = ref<Record<string, boolean>>({})
const active = computed(() => props.manager.sessions.find((session) => session.id === props.manager.activeSessionId) ?? props.manager.sessions[0]!)
const runningCount = computed(() => props.manager.sessions.filter((session) => session.running).length)
const recentEvents = computed(() => [...props.events].reverse())
let resizeObserver: ResizeObserver | null = null

watch(() => props.manager.activeSessionId, syncActiveEditor, { immediate: true })
watch(() => active.value.output, async () => {
  await nextTick()
  if (output.value) output.value.scrollTop = output.value.scrollHeight
})

onMounted(() => {
  if (typeof ResizeObserver === 'undefined') return
  resizeObserver = new ResizeObserver(([entry]) => {
    if (!entry) return
    const rows = Math.floor(Math.max(80, entry.contentRect.height - 22) / 16)
    const cols = Math.floor(Math.max(160, entry.contentRect.width - 22) / 6.2)
    emit('resize', active.value.id, rows, cols)
  })
  if (output.value) resizeObserver.observe(output.value)
})

onBeforeUnmount(() => resizeObserver?.disconnect())

function syncActiveEditor(): void {
  command.value = active.value.command
  cwd.value = active.value.cwd
  name.value = active.value.name
  stdin.value = ''
  historyIndex.value = -1
  void nextTick(() => {
    if (output.value) output.value.scrollTop = output.value.scrollHeight
  })
}

function select(sessionId: string): void {
  emit('select', sessionId)
}

function run(): void {
  if (!command.value.trim()) return
  historyIndex.value = -1
  emit('run', active.value.id, command.value)
}

function write(): void {
  if (!stdin.value) return
  emit('write', active.value.id, stdin.value)
  stdin.value = ''
}

function saveMetadata(): void {
  emit('update', active.value.id, { name: name.value, command: command.value, cwd: cwd.value })
}

function cycleHistory(direction: 1 | -1): void {
  const history = active.value.commandHistory
  if (!history.length) return
  if (direction === -1) historyIndex.value = Math.min(history.length - 1, historyIndex.value + 1)
  else historyIndex.value = Math.max(-1, historyIndex.value - 1)
  command.value = historyIndex.value < 0 ? '' : history[historyIndex.value] ?? ''
}

function statusLabel(session: TerminalSession): string {
  if (session.running) return session.interactive ? 'PTY 运行中' : '执行中'
  if (session.stale) return '连接已失效'
  if (session.exitCode !== null) return `exit ${session.exitCode}`
  return '就绪'
}
</script>

<template>
  <section class="page-section terminal-page">
    <header class="section-heading terminal-heading">
      <div>
        <span class="eyebrow">SESSION MANAGER</span>
        <h1>Terminal</h1>
        <small>{{ manager.sessions.length }} 个会话 · {{ runningCount }} 个运行中</small>
      </div>
      <div class="segmented">
        <button :class="{ active: mode === 'shell' }" @click="mode = 'shell'">Sessions <em>{{ runningCount }}</em></button>
        <button :class="{ active: mode === 'events' }" @click="mode = 'events'">Events <em>{{ events.length }}</em></button>
      </div>
    </header>

    <template v-if="mode === 'shell'">
      <div class="terminal-session-strip">
        <div class="terminal-tabs" role="tablist" aria-label="终端会话">
          <div v-for="session in manager.sessions" :key="session.id" class="terminal-tab" :class="{ active: session.id === active.id }">
            <button class="terminal-tab-main" role="tab" :aria-selected="session.id === active.id" @click="select(session.id)">
              <i :class="{ running: session.running, stale: session.stale, failed: session.exitCode !== null && session.exitCode !== 0 }" />
              <span>{{ session.name }}</span>
              <LoaderCircle v-if="session.running" :size="12" class="spin" />
            </button>
            <button
              class="terminal-tab-close"
              :disabled="session.running || manager.sessions.length === 1"
              :aria-label="`关闭 ${session.name}`"
              @click="emit('close', session.id)"
            ><X :size="12" /></button>
          </div>
        </div>
        <button class="terminal-add" :disabled="manager.sessions.length >= MAX_TERMINAL_SESSIONS" aria-label="新建终端" @click="emit('add')">
          <Plus :size="17" />
        </button>
      </div>

      <div class="terminal-session-meta">
        <label>
          <span>Name</span>
          <input v-model="name" maxlength="40" @change="saveMetadata" />
        </label>
        <label class="terminal-cwd">
          <FolderOpen :size="14" />
          <span>CWD</span>
          <input v-model="cwd" placeholder="继承连接设置中的工作目录" @change="saveMetadata" />
        </label>
      </div>

      <form class="command-launcher" @submit.prevent="run">
        <span class="prompt-mark">›_</span>
        <input
          v-model="command"
          :disabled="!connected || active.running"
          placeholder="输入 PowerShell / shell 命令"
          autocomplete="off"
          @change="saveMetadata"
          @keydown.up.prevent="cycleHistory(-1)"
          @keydown.down.prevent="cycleHistory(1)"
        />
        <button v-if="!active.running" class="run-button" :disabled="!connected || !command.trim()" aria-label="运行命令">
          <CornerDownLeft :size="18" />
        </button>
        <button v-else type="button" class="run-button danger" aria-label="终止命令" @click="emit('terminate', active.id)">
          <CircleStop :size="18" />
        </button>
      </form>

      <div v-if="active.commandHistory.length" class="terminal-history">
        <span>RECENT</span>
        <button v-for="item in active.commandHistory.slice(0, 4)" :key="item" :title="item" @click="command = item">{{ item }}</button>
      </div>

      <div class="live-terminal" :class="{ stale: active.stale }">
        <div class="terminal-title">
          <i /><i /><i />
          <span>{{ active.processId || active.name }} · {{ statusLabel(active) }}</span>
          <LoaderCircle v-if="active.running" :size="14" class="spin" />
          <button aria-label="清空输出" title="清空输出" @click="emit('clear', active.id)"><Eraser :size="14" /></button>
        </div>
        <pre ref="output">{{ active.output || (active.running ? '正在启动…' : '运行命令后，输出会保留在当前会话中。') }}</pre>
        <footer>
          <span>{{ active.cwd || 'server cwd' }}</span>
          <span v-if="active.error" class="error-text">{{ active.error }}</span>
          <span v-else>{{ statusLabel(active) }}</span>
        </footer>
      </div>

      <form class="stdin-row" @submit.prevent="write">
        <CornerDownLeft :size="16" />
        <input v-model="stdin" :disabled="!active.running || !active.interactive" placeholder="向当前 PTY 写入 stdin" />
        <button :disabled="!active.running || !active.interactive || !stdin" aria-label="发送 stdin"><Send :size="16" /></button>
      </form>
      <p class="panel-note">每个标签独立运行并按 <code>processId</code> 路由输出；可同时保留最多 {{ MAX_TERMINAL_SESSIONS }} 个会话。会话元数据与命令历史会保存，终端输出不会写入浏览器存储。</p>
    </template>

    <div v-else class="event-stream">
      <div v-if="!events.length" class="empty-state"><RadioTower /><h2>等待事件</h2><p>连接后的所有通知都会保留在这里。</p></div>
      <article v-for="event in recentEvents" v-else :key="event.id" class="event-row" :class="`level-${event.level}`">
        <button @click="expanded[event.id] = !expanded[event.id]">
          <span class="event-direction">{{ event.direction === 'in' ? '←' : event.direction === 'out' ? '→' : '•' }}</span>
          <span class="event-main"><b>{{ event.method }}</b><small>{{ event.summary }}</small></span>
          <time>{{ new Date(event.timestamp).toLocaleTimeString('zh-CN', { hour12: false }) }}</time>
          <ChevronDown :size="15" :class="{ rotated: expanded[event.id] }" />
        </button>
        <pre v-if="expanded[event.id]">{{ JSON.stringify(event.payload, null, 2) }}</pre>
      </article>
    </div>
  </section>
</template>
