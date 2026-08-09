export function pathSeparator(path: string): '\\' | '/' {
  return path.includes('\\') ? '\\' : '/'
}

export function joinPath(parent: string, child: string): string {
  const separator = pathSeparator(parent)
  return `${parent.replace(/[\\/]+$/, '')}${separator}${child.replace(/^[\\/]+/, '')}`
}

export function parentPath(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, '')
  const separator = pathSeparator(trimmed)
  const index = trimmed.lastIndexOf(separator)
  if (index < 0) return trimmed
  if (separator === '\\' && index === 2 && /^[A-Za-z]:/.test(trimmed)) return `${trimmed.slice(0, 2)}\\`
  return index === 0 ? separator : trimmed.slice(0, index)
}

export function basename(path: string): string {
  return path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() ?? path
}

export function isImagePath(path: string): boolean {
  return /\.(?:avif|bmp|gif|jpe?g|png|webp)$/i.test(path)
}
