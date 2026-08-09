import { describe, expect, it } from 'vitest'
import { joinPath, parentPath } from './paths'

describe('host paths', () => {
  it('保留 Windows 分隔符与盘符根目录', () => {
    expect(joinPath('D:\\Work', 'image.png')).toBe('D:\\Work\\image.png')
    expect(parentPath('D:\\Work')).toBe('D:\\')
  })

  it('支持 Unix 路径', () => {
    expect(joinPath('/work/app/', '/src')).toBe('/work/app/src')
    expect(parentPath('/work/app')).toBe('/work')
  })
})
