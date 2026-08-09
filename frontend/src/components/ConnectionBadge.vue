<script setup lang="ts">
import { computed } from 'vue'
import { CloudOff, LoaderCircle, Radio } from '@lucide/vue'
import type { ConnectionSnapshot } from '../rpc/JsonRpcClient'

const props = defineProps<{ connection: ConnectionSnapshot }>()

const label = computed(() => {
  switch (props.connection.phase) {
    case 'ready': return '在线'
    case 'offline': return '离线'
    case 'reconnecting': return `重连 ${props.connection.attempt}`
    case 'initializing': return '同步中'
    case 'connecting': return '连接中'
    case 'closed': return '已断开'
    default: return '待连接'
  }
})
</script>

<template>
  <div class="connection-badge" :class="`is-${connection.phase}`" :title="connection.error ?? undefined">
    <Radio v-if="connection.phase === 'ready'" :size="13" />
    <CloudOff v-else-if="connection.phase === 'offline' || connection.phase === 'closed'" :size="13" />
    <LoaderCircle v-else :size="13" class="spin" />
    <span>{{ label }}</span>
  </div>
</template>
