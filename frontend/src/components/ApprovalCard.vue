<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { AlertTriangle, Ban, Check, CheckCheck, CircleHelp, FilePenLine, ShieldAlert, X } from '@lucide/vue'
import { asRecord } from '../protocol/guards'
import type { PendingServerRequest } from '../stores/useCodexSession'
import { asUserInputRequest } from '../stores/useCodexSession'

const props = defineProps<{
  pending: PendingServerRequest
  index: number
  activeThreadId?: string | null
  threadLabel?: string
}>()
const emit = defineEmits<{
  decide: [index: number, decision: 'accept' | 'acceptForSession' | 'decline' | 'cancel']
  answer: [index: number, answers: Record<string, string[]>]
  unsupported: [index: number]
}>()

const params = computed(() => asRecord(props.pending.request.params))
const requestThreadId = computed(() => typeof params.value.threadId === 'string' ? params.value.threadId : '')
const isBackgroundRequest = computed(() => !!requestThreadId.value && requestThreadId.value !== props.activeThreadId)
const requestThreadLabel = computed(() => props.threadLabel || requestThreadId.value || '未标识任务')
const inputRequest = computed(() => asUserInputRequest(params.value))
const answers = reactive<Record<string, string>>({})
const now = ref(Date.now())
let timer: ReturnType<typeof setInterval> | null = null

const kind = computed(() => {
  if (props.pending.request.method === 'item/commandExecution/requestApproval') return 'command'
  if (props.pending.request.method === 'item/fileChange/requestApproval') return 'file'
  if (props.pending.request.method === 'item/tool/requestUserInput') return 'question'
  return 'unknown'
})

const title = computed(() => ({ command: '命令需要确认', file: '文件变更需要确认', question: 'Codex 需要你的选择', unknown: '新的服务端请求' })[kind.value])
const expiresIn = computed(() => {
  const duration = inputRequest.value?.autoResolutionMs
  if (duration === null || duration === undefined) return null
  return Math.max(0, Math.ceil((props.pending.receivedAt + duration - now.value) / 1000))
})

onMounted(() => { timer = setInterval(() => { now.value = Date.now() }, 1000) })
onBeforeUnmount(() => { if (timer) clearInterval(timer) })

function submitAnswers(): void {
  const result: Record<string, string[]> = {}
  for (const question of inputRequest.value?.questions ?? []) {
    const value = answers[question.id]?.trim()
    result[question.id] = value ? [value] : []
  }
  emit('answer', props.index, result)
}
</script>

<template>
  <article class="approval-card" :class="`approval-${kind}`">
    <header>
      <span class="approval-icon">
        <ShieldAlert v-if="kind === 'command'" :size="19" />
        <FilePenLine v-else-if="kind === 'file'" :size="19" />
        <CircleHelp v-else-if="kind === 'question'" :size="19" />
        <AlertTriangle v-else :size="19" />
      </span>
      <span><small>APP-SERVER REQUEST</small><b>{{ title }}</b></span>
    </header>

    <p class="request-context" :class="{ background: isBackgroundRequest }">
      <span>{{ isBackgroundRequest ? '后台任务' : '当前任务' }}</span>
      <b>{{ requestThreadLabel }}</b>
      <code v-if="requestThreadId" :title="requestThreadId">{{ requestThreadId.slice(0, 12) }}</code>
    </p>

    <template v-if="kind === 'command'">
      <p v-if="params.reason" class="approval-reason">{{ params.reason }}</p>
      <p v-if="asRecord(params.networkApprovalContext).host" class="network-context">
        Network · {{ asRecord(params.networkApprovalContext).protocol || 'unknown' }}://{{ asRecord(params.networkApprovalContext).host }}
      </p>
      <pre class="command-preview"><code>{{ params.command || '未提供命令文本' }}</code></pre>
      <p v-if="params.cwd" class="muted-line">运行于 {{ params.cwd }}</p>
      <details v-if="params.commandActions || params.proposedExecpolicyAmendment || params.proposedNetworkPolicyAmendments" class="raw-details">
        <summary>查看 parsed actions / proposed policy</summary>
        <pre>{{ JSON.stringify({ commandActions: params.commandActions, proposedExecpolicyAmendment: params.proposedExecpolicyAmendment, proposedNetworkPolicyAmendments: params.proposedNetworkPolicyAmendments }, null, 2) }}</pre>
      </details>
    </template>

    <template v-else-if="kind === 'file'">
      <p class="approval-reason">{{ params.reason || 'Codex 请求写入工作区。' }}</p>
      <p v-if="params.grantRoot" class="path-pill">{{ params.grantRoot }}</p>
    </template>

    <form v-else-if="kind === 'question' && inputRequest" class="question-form" @submit.prevent="submitAnswers">
      <p v-if="expiresIn !== null" class="resolution-clock" :class="{ expired: expiresIn === 0 }">{{ expiresIn > 0 ? `服务器可能在 ${expiresIn}s 后自动处理` : '服务器自动处理时间已到，等待 resolved 通知' }}</p>
      <fieldset v-for="question in inputRequest.questions" :key="question.id">
        <legend><small>{{ question.header }}</small>{{ question.question }}</legend>
        <label v-for="option in question.options ?? []" :key="option.label" class="choice-row">
          <input v-model="answers[question.id]" type="radio" :name="question.id" :value="option.label" />
          <span><b>{{ option.label }}</b><small>{{ option.description }}</small></span>
        </label>
        <input v-if="question.isOther || !question.options?.length" v-model="answers[question.id]" :type="question.isSecret ? 'password' : 'text'" class="other-answer" :placeholder="question.isSecret ? '输入保密回答' : '输入回答…'" />
      </fieldset>
      <button class="button primary full" type="submit">提交回答</button>
    </form>

    <template v-else>
      <p class="approval-reason">Pocket Agent 尚未内置此请求类型，原始内容仍完整保留。</p>
      <details class="raw-details"><summary>{{ pending.request.method }}</summary><pre>{{ JSON.stringify(pending.request.params, null, 2) }}</pre></details>
      <button class="button secondary full" @click="emit('unsupported', index)">返回 method not found</button>
    </template>

    <div v-if="kind === 'command' || kind === 'file'" class="approval-actions">
      <button class="decision session" @click="emit('decide', index, 'acceptForSession')"><CheckCheck :size="17" /><span>本次会话允许</span></button>
      <button class="decision accept" @click="emit('decide', index, 'accept')"><Check :size="17" /><span>允许一次</span></button>
      <button class="decision decline" @click="emit('decide', index, 'decline')"><Ban :size="17" /><span>拒绝</span></button>
      <button class="decision cancel" @click="emit('decide', index, 'cancel')"><X :size="17" /><span>取消</span></button>
    </div>
  </article>
</template>
