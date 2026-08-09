<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import { ArrowUp, ImagePlus, Link2, Paperclip, Square, X } from '@lucide/vue'
import type { UserInput } from '../protocol/types'
import { basename } from '../utils/paths'

const props = defineProps<{ attachments: readonly UserInput[]; running: boolean; disabled: boolean }>()
const emit = defineEmits<{
  send: [text: string]
  interrupt: []
  image: [file: File]
  hostPath: [path: string]
  remove: [index: number]
}>()

const text = ref('')
const pathInput = ref('')
const addingPath = ref(false)
const textarea = ref<HTMLTextAreaElement>()
const canSend = computed(() => !props.disabled && (!!text.value.trim() || props.attachments.length > 0))

function submit(): void {
  if (!canSend.value) return
  emit('send', text.value)
  text.value = ''
  void nextTick(() => resize())
}

function addPath(): void {
  if (!pathInput.value.trim()) return
  emit('hostPath', pathInput.value.trim())
  pathInput.value = ''
  addingPath.value = false
}

function pickImage(event: Event): void {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (file) emit('image', file)
  input.value = ''
}

function resize(): void {
  if (!textarea.value) return
  textarea.value.style.height = '0'
  textarea.value.style.height = `${Math.min(textarea.value.scrollHeight, 180)}px`
}

function attachmentLabel(item: UserInput): string {
  if (item.type === 'localImage' || item.type === 'mention') return basename(item.path)
  if (item.type === 'image') return item.url.startsWith('data:') ? '本地图片' : '网络图片'
  return item.type
}
</script>

<template>
  <div class="composer-wrap">
    <Transition name="fade">
      <form v-if="addingPath" class="path-adder" @submit.prevent="addPath">
        <Link2 :size="16" /><input v-model="pathInput" autofocus placeholder="服务器上的图片或文件绝对路径" /><button class="text-button">附加</button>
      </form>
    </Transition>
    <div v-if="attachments.length" class="attachment-strip">
      <span v-for="(attachment, index) in attachments" :key="index" class="attachment-chip">
        <ImagePlus v-if="attachment.type === 'image' || attachment.type === 'localImage'" :size="14" /><Paperclip v-else :size="14" />
        {{ attachmentLabel(attachment) }}
        <button aria-label="移除附件" @click="emit('remove', index)"><X :size="13" /></button>
      </span>
    </div>
    <div class="composer">
      <textarea ref="textarea" v-model="text" rows="1" :disabled="disabled" placeholder="告诉 Codex 接下来做什么…" @input="resize" @keydown.ctrl.enter.prevent="submit" @keydown.meta.enter.prevent="submit" />
      <div class="composer-toolbar">
        <div>
          <label class="tool-button" title="选择图片"><ImagePlus :size="18" /><input type="file" accept="image/*" hidden @change="pickImage" /></label>
          <button class="tool-button" title="附加服务器路径" @click="addingPath = !addingPath"><Link2 :size="18" /></button>
        </div>
        <button v-if="running" class="send-button stop" aria-label="停止" @click="emit('interrupt')"><Square :size="15" fill="currentColor" /></button>
        <button v-else class="send-button" :disabled="!canSend" aria-label="发送" @click="submit"><ArrowUp :size="20" /></button>
      </div>
    </div>
    <small class="composer-hint">{{ running ? '发送会 steer 当前 turn；停止可中断执行' : 'Ctrl + Enter 发送' }}</small>
  </div>
</template>
