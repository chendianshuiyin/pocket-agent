# Pocket Agent Mobile

Android / iOS 客户端：直接连接个人 Linux 服务器，分别使用 SSH 终端和
Codex app-server 任务管理。不依赖原有 Web 网关。

## 开发环境

- Flutter 3.47.1 / Dart 3.13.1。
- Android SDK；iOS 构建需要 macOS 和 Xcode。
- 远端 Linux、SSH、tmux、Codex CLI（验证基线 0.153.4）。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

## 安全边界

SSH 凭据存储在 Android Keystore / iOS Keychain 支持的安全存储中；首次连接
需要核对主机密钥指纹，后续不匹配会拒绝连接。Android 禁止备份和设备迁移。
远端 app-server 仅监听回环地址，经 SSH 隧道访问，不要把该端口暴露到公网。
Codex 登录保留在远端，不进入 App 的服务器配置。

关闭手机 App 与终止远端任务是不同操作。持久终端由 tmux 保持，
Codex 任务由独立远端 app-server 保持；服务器重启不等同于网络断开。

当前 Android 安装包用于验证，非商店签名发行。iOS 源码及安全存储配置已提供，
尚未在 Mac/Xcode 或 iPhone 上验证。不要将未验证目标标记为已发布。
