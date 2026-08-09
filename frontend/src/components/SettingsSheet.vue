<script setup lang="ts">
import { reactive, watch } from 'vue'
import { Eye, EyeOff, X } from '@lucide/vue'
import type { Model } from '../protocol/types'
import type { SettingsState, SshConnectionState } from '../stores/useCodexSession'

const props = defineProps<{
  open: boolean
  settings: SettingsState
  ssh: Readonly<SshConnectionState>
  models: readonly Model[]
}>()
const emit = defineEmits<{
  close: []
  save: [settings: SettingsState]
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
            <div class="connection-mode" role="group" aria-label="Codex 运行位置">
              <button type="button" :class="{ active: form.connectionMode === 'local' }" @click="form.connectionMode = 'local'">
                <b>本机</b><small>Gateway 所在机器</small>
              </button>
              <button type="button" :class="{ active: form.connectionMode === 'ssh' }" @click="form.connectionMode = 'ssh'">
                <b>SSH 服务器</b><small>远端启动 Codex</small>
              </button>
            </div>

            <label>
              <span>Gateway WebSocket 地址</span>
              <input v-model.trim="form.endpoint" required placeholder="ws://127.0.0.1:8787/ws" />
              <small>浏览器只连接 Pocket Gateway；SSH 隧道由 Gateway 在服务器侧管理。</small>
            </label>

            <label>
              <span>访问 Token</span>
              <span class="input-action">
                <input v-model="form.token" :type="ui.showToken ? 'text' : 'password'" autocomplete="current-password" placeholder="Gateway token" required />
                <button type="button" class="inside-button" :aria-label="ui.showToken ? '隐藏 Token' : '显示 Token'" @click="ui.showToken = !ui.showToken">
                  <EyeOff v-if="ui.showToken" :size="18" /><Eye v-else :size="18" />
                </button>
              </span>
            </label>

            <label class="toggle-row">
              <input v-model="form.rememberToken" type="checkbox" />
              <span><b>在此设备记住 Token</b><small>关闭时仅保存在当前浏览器会话。</small></span>
            </label>

            <section v-if="form.connectionMode === 'ssh'" class="ssh-settings">
              <div class="ssh-status" :class="{ connected: ssh.connected, error: ssh.error }">
                <i />
                <span>
                  <b>{{ ssh.connecting ? '正在通过 SSH 启动 Codex…' : ssh.connected ? `已连接 ${ssh.target}` : '等待连接 SSH 服务器' }}</b>
                  <small>{{ ssh.error || '使用 Gateway 机器现有的 SSH key、agent 与 ~/.ssh/config，不在浏览器保存私钥。' }}</small>
                </span>
              </div>

              <label>
                <span>SSH Target</span>
                <input v-model.trim="form.sshTarget" required placeholder="deploy@prod 或 ~/.ssh/config 中的 Host alias" autocomplete="off" />
              </label>
              <div class="settings-grid">
                <label>
                  <span>SSH Port</span>
                  <input v-model="form.sshPort" inputmode="numeric" placeholder="22 / config 默认" />
                </label>
                <label>
                  <span>Remote app-server Port</span>
                  <input v-model="form.sshRemotePort" inputmode="numeric" placeholder="4500" />
                </label>
              </div>
              <label>
                <span>Identity file（Gateway 本机路径，可选）</span>
                <input v-model.trim="form.sshIdentityFile" placeholder="C:\Users\gateway\.ssh\id_ed25519" autocomplete="off" />
                <small>留空时由 OpenSSH 自动使用 agent 和 SSH config。当前版本只支持 key/agent，不支持密码输入。</small>
              </label>
              <label>
                <span>远端 Codex executable</span>
                <input v-model.trim="form.sshCodexBin" placeholder="codex 或 /opt/codex/bin/codex" autocomplete="off" />
                <small>远端非交互 shell 找不到 Codex 时，请填写服务器上的绝对路径。</small>
              </label>
            </section>

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
              <input v-model.trim="form.cwd" :placeholder="form.connectionMode === 'ssh' ? '/srv/project' : 'D:\\WorkPlace\\project'" />
              <small>SSH 模式下这是远端服务器路径。</small>
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
              <button type="submit" class="button primary" :disabled="ssh.connecting">{{ ssh.connecting ? '正在连接…' : '保存并连接' }}</button>
            </div>
          </form>
        </section>
      </div>
    </Transition>
  </Teleport>
</template>
