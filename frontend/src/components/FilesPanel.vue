<script setup lang="ts">
import { File, FileImage, Folder, FolderOpen, LoaderCircle, Paperclip, RefreshCw, Upload, Undo2 } from '@lucide/vue'
import type { FileBrowserState } from '../stores/useCodexSession'
import type { FsReadDirectoryEntry } from '../protocol/types'
import { isImagePath } from '../utils/paths'

defineProps<{ files: Readonly<FileBrowserState>; connected: boolean }>()
const emit = defineEmits<{ read: []; parent: []; open: [entry: FsReadDirectoryEntry]; upload: [files: FileList] }>()

function onFiles(event: Event): void {
  const input = event.target as HTMLInputElement
  if (input.files?.length) emit('upload', input.files)
  input.value = ''
}
</script>

<template>
  <section class="page-section files-page">
    <header class="section-heading">
      <div><span class="eyebrow">HOST FILESYSTEM</span><h1>文件</h1></div>
      <label class="button compact primary" :class="{ disabled: !connected || files.uploading }">
        <LoaderCircle v-if="files.uploading" :size="17" class="spin" /><Upload v-else :size="17" />上传
        <input type="file" multiple hidden :disabled="!connected || files.uploading" @change="onFiles" />
      </label>
    </header>

    <div class="file-pathbar">
      <button class="icon-button" aria-label="上一级" @click="emit('parent')"><Undo2 :size="17" /></button>
      <FolderOpen :size="16" /><code>{{ files.path || '尚未设置 cwd' }}</code>
      <button class="icon-button" aria-label="刷新" @click="emit('read')"><RefreshCw :size="17" :class="{ spin: files.loading }" /></button>
    </div>

    <p v-if="files.error" class="inline-error">{{ files.error }}</p>
    <div v-if="files.loading && !files.entries.length" class="empty-state"><LoaderCircle class="spin" /><p>读取目录…</p></div>
    <div v-else class="file-list">
      <button v-for="entry in files.entries" :key="entry.fileName" class="file-row" @click="emit('open', entry)">
        <span class="file-icon"><Folder v-if="entry.isDirectory" :size="19" /><FileImage v-else-if="isImagePath(entry.fileName)" :size="19" /><File v-else :size="19" /></span>
        <span><b>{{ entry.fileName }}</b><small>{{ entry.isDirectory ? '目录' : (isImagePath(entry.fileName) ? '点击附加本地图片' : '点击附加到输入') }}</small></span>
        <Paperclip v-if="entry.isFile" :size="15" />
      </button>
    </div>
    <p class="panel-note">手机文件会通过 <code>fs/writeFile(dataBase64)</code> 上传到当前目录；上传图片会自动作为 <code>localImage</code> 加入输入。</p>
  </section>
</template>
