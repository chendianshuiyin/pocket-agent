<script setup lang="ts">
import { reactive, watch } from 'vue'
import { Eye, EyeOff, RotateCw, X } from '@lucide/vue'
import type { Model } from '../protocol/types'
import type { SettingsState } from '../stores/useCodexSession'

const props = defineProps<{
  open: boolean
  settings: SettingsState
  models: readonly Model[]
}>()
const emit = defineEmits<{
  close: []
  save: [settings: SettingsState]
  reconnect: []
}>()

const form = reactive<SettingsState>({ ...props.settings })
const ui = reactive({ showToken: false })

watch(() => props.open, (open) => {
  if (open) Object.assign(form, props.settings)
})
</script>

<template>
  <Teleport to="body">
    <Transition name="sheet">
      <div v-if="open" class="sheet-backdrop" @click.self="emit('close')">
        <section class="settings-sheet" aria-modal="true" role="dialog" aria-labelledby="settings-title">
          <div class="sheet-handle" />
          <header class="sheet-header">
            <div>
              <span class="eyebrow">CONNECTION</span>
              <h2 id="settings-title">连接与运行设置</h2>
            </div>
            <button class="icon-button" aria-label="关闭" @click="emit('close')"><X :size="20" /></button>
          </header>

          <form class="settings-form" @submit.prevent="emit('save', { ...form })">
            <label>
              <span>WebSocket 地址</span>
              <input v-model.trim="form.endpoint" required placeholder="ws://127.0.0.1:8787/ws" />
              <small>默认使用当前站点的 <code>/ws</code>，也可填写完整地址。</small>
            </label>

            <label>
              <span>访问 Token</span>
              <span class="input-action">
                <input v-model="form.token" :type="ui.showToken ? 'text' : 'password'" autocomplete="current-password" placeholder="Gateway token" />
                <button type="button" class="inside-button" :aria-label="ui.showToken ? '隐藏 Token' : '显示 Token'" @click="ui.showToken = !ui.showToken">
                  <EyeOff v-if="ui.showToken" :size="18" /><Eye v-else :size="18" />
                </button>
              </span>
            </label>

            <label class="toggle-row">
              <input v-model="form.rememberToken" type="checkbox" />
              <span><b>在此设备记住 Token</b><small>关闭时仅保存在当前浏览器会话。</small></span>
            </label>

            <div class="settings-grid">
              <label>
                <span>Model</span>
                <select v-model="form.model">
                  <option value="">服务器默认</option>
                  <option v-for="model in models" :key="model.id" :value="model.model">{{ model.displayName }}</option>
                </select>
              </label>
              <label>
                <span>Reasoning</span>
                <select v-model="form.effort">
                  <option value="">模型默认</option>
                  <option v-for="effort in ['low', 'medium', 'high', 'xhigh']" :key="effort" :value="effort">{{ effort }}</option>
                </select>
              </label>
            </div>

            <label>
              <span>服务器工作目录</span>
              <input v-model.trim="form.cwd" placeholder="D:\\WorkPlace\\project" />
            </label>

            <div class="settings-grid">
              <label>
                <span>Sandbox</span>
                <select v-model="form.sandbox">
                  <option value="read-only">read-only</option>
                  <option value="workspace-write">workspace-write</option>
                  <option value="danger-full-access">danger-full-access</option>
                </select>
              </label>
              <label>
                <span>Approvals</span>
                <select v-model="form.approvalPolicy">
                  <option value="untrusted">untrusted</option>
                  <option value="on-request">on-request</option>
                  <option value="never">never</option>
                </select>
              </label>
            </div>

            <div class="sheet-actions">
              <button type="button" class="button secondary" @click="emit('reconnect')"><RotateCw :size="17" />立即重连</button>
              <button type="submit" class="button primary">保存并连接</button>
            </div>
          </form>
        </section>
      </div>
    </Transition>
  </Teleport>
</template>
