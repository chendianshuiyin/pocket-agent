<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { Bot, ChevronDown, Files, FolderKanban, MessageCircle, MoreHorizontal, Plus, Settings2, Sparkles, TerminalSquare, Unplug, Workflow } from '@lucide/vue'
import AppsPanel from './components/AppsPanel.vue'
import ApprovalCard from './components/ApprovalCard.vue'
import ComposerBox from './components/ComposerBox.vue'
import ConnectionBadge from './components/ConnectionBadge.vue'
import FilesPanel from './components/FilesPanel.vue'
import ItemCard from './components/ItemCard.vue'
import SettingsSheet from './components/SettingsSheet.vue'
import TerminalPanel from './components/TerminalPanel.vue'
import ThreadList from './components/ThreadList.vue'
import { useCodexSession } from './stores/useCodexSession'

const session = useCodexSession()
const { state, mutableState } = session
const feed = ref<HTMLElement>()

const connected = computed(() => state.connection.phase === 'ready')
const needsConnectionSettings = computed(() => !state.settings.token || state.connection.phase === 'closed')
const connectionTitle = computed(() => {
  if (!state.settings.token) return '需要连接凭据'
  if (state.connection.phase === 'offline') return '设备处于离线状态'
  if (state.connection.phase === 'closed') return '连接已暂停'
  return '正在建立安全连接'
})
const running = computed(() => !!state.activeTurnId)
const taskTitle = computed(() => state.activeThread?.name || state.activeThread?.preview || '新任务')
const remoteLabel = computed(() => state.settings.connectionMode === 'ssh'
  ? state.ssh.connected ? `SSH · ${state.ssh.target}` : `SSH · ${state.settings.sshTarget || '未连接'}`
  : 'LOCAL')
const navItems = [
  { id: 'chat', label: '对话', icon: MessageCircle },
  { id: 'threads', label: '任务', icon: FolderKanban },
  { id: 'files', label: '文件', icon: Files },
  { id: 'terminal', label: '终端', icon: TerminalSquare },
  { id: 'apps', label: '扩展', icon: Workflow },
] as const

onMounted(() => {
  void session.connect()
})

watch(() => session.conversationItems.value.length, async () => {
  await nextTick()
  if (feed.value) feed.value.scrollTop = feed.value.scrollHeight
})

watch(() => state.tab, (tab) => {
  if (tab === 'files' && !state.files.entries.length) void session.readDirectory()
  if (tab === 'apps' && !state.apps.length && !state.mcpServers.length) void session.refreshIntegrations()
})
</script>

<template>
  <div class="app-shell">
    <header class="topbar">
      <button class="brand" @click="mutableState.tab = 'chat'">
        <span class="brand-mark"><span>P</span></span>
        <span class="brand-copy"><b>Pocket</b><small>AGENT</small></span>
      </button>
      <div class="topbar-actions">
        <span class="host-badge" :class="{ remote: state.settings.connectionMode === 'ssh' }">{{ remoteLabel }}</span>
        <ConnectionBadge :connection="state.connection" />
        <button class="icon-button" aria-label="连接设置" @click="mutableState.settingsOpen = true"><Settings2 :size="19" /></button>
      </div>
    </header>

    <aside class="desktop-rail">
      <nav>
        <button v-for="nav in navItems" :key="nav.id" :class="{ active: state.tab === nav.id }" @click="mutableState.tab = nav.id">
          <component :is="nav.icon" :size="19" /><span>{{ nav.label }}</span>
          <em v-if="nav.id === 'chat' && session.requestCount.value">{{ session.requestCount.value }}</em>
        </button>
      </nav>
      <div class="rail-context">
        <span>CURRENT WORKSPACE</span>
        <b>{{ state.settings.cwd || '未设置目录' }}</b>
        <small>{{ state.settings.model || '默认模型' }}</small>
        <em>{{ remoteLabel }}</em>
      </div>
    </aside>

    <main class="main-stage">
      <section v-if="state.tab === 'chat'" class="chat-page">
        <header class="chat-heading">
          <button class="task-context" @click="mutableState.tab = 'threads'">
            <span><small>ACTIVE TASK</small><b>{{ taskTitle }}</b></span><ChevronDown :size="17" />
          </button>
          <button class="icon-button desktop-only" aria-label="新任务" @click="session.startThread"><Plus :size="19" /></button>
        </header>

        <div ref="feed" class="conversation-feed">
          <div v-if="!connected" class="connection-callout">
            <Unplug :size="20" /><span><b>{{ connectionTitle }}</b><small>{{ state.connection.error || '连接 app-server 后会自动恢复当前任务。' }}</small></span>
            <button @click="needsConnectionSettings ? mutableState.settingsOpen = true : session.reconnect()">{{ needsConnectionSettings ? '检查设置' : '重试' }}</button>
          </div>

          <ApprovalCard
            v-for="(pending, index) in state.pendingRequests"
            :key="`${pending.request.id}-${pending.request.method}`"
            :pending="pending"
            :index="index"
            :active-thread-id="state.activeThreadId"
            :thread-label="session.threadLabel(typeof pending.request.params.threadId === 'string' ? pending.request.params.threadId : '')"
            @decide="session.respondApproval"
            @answer="session.respondUserInput"
            @unsupported="session.rejectUnsupportedRequest"
          />

          <div v-if="!state.activeThread && !state.loadingConversation" class="welcome-state">
            <span class="welcome-orbit"><Bot :size="31" /><i /><i /></span>
            <span class="eyebrow">CODEX IN YOUR POCKET</span>
            <h1>把电脑上的工作，<br />带到手边。</h1>
            <p>选择已有任务继续，或直接发一条消息创建任务。连接中断后会自动恢复。</p>
            <button class="button primary" @click="session.startThread"><Sparkles :size="17" />创建空白任务</button>
          </div>

          <template v-else>
            <ItemCard
              v-for="entry in session.conversationItems.value"
              :key="`${entry.turnId}-${entry.item.id || entry.item.type}`"
              :item="entry.item"
              :turn-id="entry.turnId"
              :turn-status="entry.turnStatus"
              :diff="state.turnDiffs[entry.turnId]"
              :plan="mutableState.turnPlans[entry.turnId]"
            />
          </template>

          <details v-for="activity in state.unknownActivity.slice(-8)" :key="activity.id" class="activity-card unknown-card">
            <summary><MoreHorizontal :size="17" /><span>未知事件：{{ activity.method }}</span><small>未丢弃</small><ChevronDown :size="15" /></summary>
            <pre class="raw-block">{{ JSON.stringify(activity.params, null, 2) }}</pre>
          </details>

          <div v-if="running" class="working-indicator"><i /><i /><i /><span>Codex 正在工作</span></div>
          <div class="feed-spacer" />
        </div>

        <ComposerBox
          :attachments="mutableState.attachments"
          :running="running"
          :disabled="!connected"
          @send="session.sendMessage"
          @interrupt="session.interruptTurn"
          @image="session.attachBrowserImage"
          @host-path="session.attachHostPath"
          @remove="session.removeAttachment"
        />
      </section>

      <ThreadList
        v-else-if="state.tab === 'threads'"
        :threads="mutableState.threads"
        :active-id="state.activeThreadId"
        :loading="state.loadingThreads"
        @select="session.openThread"
        @create="session.startThread"
        @refresh="session.refreshThreads"
      />
      <FilesPanel
        v-else-if="state.tab === 'files'"
        :files="mutableState.files"
        :connected="connected"
        @read="session.readDirectory()"
        @parent="session.goParentDirectory"
        @open="session.openFileEntry"
        @upload="session.uploadFiles"
      />
      <TerminalPanel
        v-else-if="state.tab === 'terminal'"
        :shell="mutableState.shell"
        :events="mutableState.terminalEvents"
        :connected="connected"
        @run="session.runTerminal"
        @write="session.writeTerminal"
        @terminate="session.terminateTerminal"
      />
      <AppsPanel
        v-else
        :apps="mutableState.apps"
        :servers="mutableState.mcpServers"
        :loading="state.loadingApps"
        @refresh="session.refreshIntegrations(true)"
      />
    </main>

    <nav class="bottom-nav">
      <button v-for="nav in navItems" :key="nav.id" :class="{ active: state.tab === nav.id }" @click="mutableState.tab = nav.id">
        <span><component :is="nav.icon" :size="20" /><em v-if="nav.id === 'chat' && session.requestCount.value">{{ session.requestCount.value }}</em></span>
        {{ nav.label }}
      </button>
    </nav>

    <SettingsSheet
      :open="state.settingsOpen"
      :settings="mutableState.settings"
      :ssh="state.ssh"
      :models="mutableState.models"
      @close="mutableState.settingsOpen = false"
      @save="session.saveSettings"
    />
  </div>
</template>
