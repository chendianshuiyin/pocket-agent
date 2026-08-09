import type { RpcFailure, RpcInbound, RpcNotification, RpcRequest, RpcSuccess, UnknownRecord } from './types'

export function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function hasRequestId(value: UnknownRecord): value is UnknownRecord & { id: string | number } {
  return typeof value.id === 'string' || typeof value.id === 'number'
}

export function isRpcRequest(value: RpcInbound): value is RpcRequest {
  return isRecord(value) && hasRequestId(value) && typeof value.method === 'string'
}

export function isRpcNotification(value: RpcInbound): value is RpcNotification {
  return isRecord(value) && !hasRequestId(value) && typeof value.method === 'string'
}

export function isRpcSuccess(value: RpcInbound): value is RpcSuccess {
  return isRecord(value) && hasRequestId(value) && 'result' in value
}

export function isRpcFailure(value: RpcInbound): value is RpcFailure {
  return isRecord(value) && hasRequestId(value) && isRecord(value.error) && typeof value.error.message === 'string'
}

export function asRecord(value: unknown): UnknownRecord {
  return isRecord(value) ? value : {}
}

export function stringField(value: unknown, key: string, fallback = ''): string {
  const record = asRecord(value)
  return typeof record[key] === 'string' ? record[key] : fallback
}
