import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    vue(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['pocket-mark.svg', 'pocket-mark-192.png', 'pocket-mark-512.png'],
      manifest: {
        id: '/',
        name: 'Pocket Agent',
        short_name: 'Pocket',
        description: 'Android-first remote client for Codex app-server',
        lang: 'zh-CN',
        theme_color: '#111713',
        background_color: '#f5f1e8',
        display: 'standalone',
        orientation: 'portrait-primary',
        icons: [
          { src: '/pocket-mark-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
          { src: '/pocket-mark-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
          { src: '/pocket-mark-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
          { src: '/pocket-mark.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' }
        ]
      },
      workbox: {
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,png,svg,woff2}']
      }
    })
  ],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts']
  }
})
