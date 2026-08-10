<script setup lang="ts">
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps<{ output: string; active: boolean; connected: boolean }>()
const emit = defineEmits<{ input: [data: string]; binary: [data: string]; resize: [rows: number, cols: number] }>()
const host = ref<HTMLElement>()
let terminal: Terminal | null = null
let fitAddon: FitAddon | null = null
let resizeObserver: ResizeObserver | null = null
let rendered = ''

onMounted(() => {
  if (!host.value) return
  terminal = new Terminal({
    allowProposedApi: false,
    convertEol: false,
    cursorBlink: true,
    cursorStyle: 'bar',
    fontFamily: '"DM Mono", "Cascadia Code", Consolas, monospace',
    fontSize: 11,
    lineHeight: 1.25,
    scrollback: 5000,
    theme: {
      background: '#121713',
      foreground: '#d9dfd9',
      cursor: '#dce968',
      cursorAccent: '#121713',
      selectionBackground: '#52634f',
      black: '#121713',
      red: '#e4857d',
      green: '#8dc596',
      yellow: '#e1c66c',
      blue: '#8eaec2',
      magenta: '#bd96bd',
      cyan: '#83bfc0',
      white: '#d9dfd9',
      brightBlack: '#7d877f',
      brightRed: '#f09a91',
      brightGreen: '#a7d7ad',
      brightYellow: '#ecd77f',
      brightBlue: '#a7c3d5',
      brightMagenta: '#d1acd0',
      brightCyan: '#9ed3d3',
      brightWhite: '#f5f5ef',
    },
  })
  fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.open(host.value)
  terminal.onData((data) => emit('input', data))
  terminal.onBinary((data) => emit('binary', data))
  terminal.onResize(({ rows, cols }) => emit('resize', rows, cols))
  syncOutput(props.output)
  fitAndFocus()
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(() => fitAndFocus(false))
    resizeObserver.observe(host.value)
  }
})

watch(() => props.output, syncOutput)
watch(() => props.active, (active) => {
  if (active) void nextTick(() => fitAndFocus())
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  terminal?.dispose()
})

function syncOutput(next: string): void {
  if (!terminal) return
  if (!next) {
    terminal.reset()
    rendered = ''
    return
  }
  if (next.startsWith(rendered)) terminal.write(next.slice(rendered.length))
  else {
    terminal.reset()
    terminal.write(next)
  }
  rendered = next
}

function fitAndFocus(focus = true): void {
  if (!props.active || !host.value || !terminal || !fitAddon || host.value.clientWidth === 0) return
  try {
    fitAddon.fit()
    if (focus && props.connected) terminal.focus()
  } catch {
    // A hidden tab can briefly report zero geometry while switching sessions.
  }
}
</script>

<template>
  <div ref="host" class="xterm-host" :class="{ disconnected: !connected }" />
</template>
