<script setup lang="ts">
import { Boxes, CheckCircle2, CircleOff, PlugZap, RefreshCw, ServerCog, Wrench } from '@lucide/vue'
import type { AppInfo, McpServerStatus } from '../protocol/types'

defineProps<{ apps: readonly AppInfo[]; servers: readonly McpServerStatus[]; loading: boolean }>()
const emit = defineEmits<{ refresh: [] }>()
</script>

<template>
  <section class="page-section apps-page">
    <header class="section-heading">
      <div><span class="eyebrow">EXTENSIONS</span><h1>Apps & MCP</h1></div>
      <button class="button compact secondary" @click="emit('refresh')"><RefreshCw :size="17" :class="{ spin: loading }" />刷新</button>
    </header>

    <div class="subsection-heading"><PlugZap :size="17" /><h2>Connectors</h2><span>{{ apps.length }}</span></div>
    <div v-if="apps.length" class="integration-grid">
      <details v-for="app in apps" :key="app.id" class="integration-card">
        <summary>
          <span class="integration-logo"><img v-if="app.logoUrl" :src="app.logoUrl" alt="" /><Boxes v-else :size="20" /></span>
          <span><b>{{ app.name }}</b><small>{{ app.description || app.id }}</small></span>
          <CheckCircle2 v-if="app.isAccessible && app.isEnabled" :size="17" class="success" /><CircleOff v-else :size="17" class="muted" />
        </summary>
        <div class="integration-details">
          <span class="status-chip" :class="{ on: app.isEnabled }">{{ app.isEnabled ? 'enabled' : 'disabled' }}</span>
          <span class="status-chip" :class="{ on: app.isAccessible }">{{ app.isAccessible ? 'accessible' : 'unavailable' }}</span>
          <pre>{{ JSON.stringify(app, null, 2) }}</pre>
        </div>
      </details>
    </div>
    <div v-else class="mini-empty"><Boxes :size="22" /><span>服务器未返回可用 Apps</span></div>

    <div class="subsection-heading spaced"><ServerCog :size="17" /><h2>MCP Servers</h2><span>{{ servers.length }}</span></div>
    <div v-if="servers.length" class="integration-grid">
      <details v-for="server in servers" :key="server.name" class="integration-card">
        <summary>
          <span class="integration-logo server"><ServerCog :size="20" /></span>
          <span><b>{{ server.name }}</b><small>{{ Object.keys(server.tools).length }} tools · {{ server.authStatus }}</small></span>
          <CheckCircle2 v-if="server.authStatus !== 'notLoggedIn'" :size="17" class="success" /><CircleOff v-else :size="17" class="muted" />
        </summary>
        <div class="integration-details">
          <div class="tool-tags"><span v-for="(_, name) in server.tools" :key="name"><Wrench :size="12" />{{ name }}</span></div>
          <pre>{{ JSON.stringify(server, null, 2) }}</pre>
        </div>
      </details>
    </div>
    <div v-else class="mini-empty"><ServerCog :size="22" /><span>服务器未返回 MCP 状态</span></div>
  </section>
</template>
