export type SlashCommandName =
  | 'new'
  | 'threads'
  | 'skills'
  | 'model'
  | 'files'
  | 'terminal'
  | 'apps'
  | 'compact'
  | 'review'
  | 'status'

export interface SlashCommand {
  name: SlashCommandName
  description: string
  group: 'navigate' | 'codex'
}

export const SLASH_COMMANDS: readonly SlashCommand[] = [
  { name: 'new', description: '创建一个新的 Codex 任务', group: 'navigate' },
  { name: 'threads', description: '打开远端任务列表', group: 'navigate' },
  { name: 'skills', description: '选择并调用服务器上的 Skill', group: 'codex' },
  { name: 'model', description: '打开 Model 与 Reasoning 设置', group: 'navigate' },
  { name: 'files', description: '浏览服务器工作目录', group: 'navigate' },
  { name: 'terminal', description: '打开服务器终端', group: 'navigate' },
  { name: 'apps', description: '查看 Apps 与 MCP 状态', group: 'navigate' },
  { name: 'compact', description: '压缩当前任务的上下文', group: 'codex' },
  { name: 'review', description: '审查当前未提交的变更', group: 'codex' },
  { name: 'status', description: '查看 Gateway、SSH 与 Codex 状态', group: 'navigate' },
] as const
