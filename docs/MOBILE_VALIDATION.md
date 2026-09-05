# Pocket Agent 移动端验证记录

日期：2026-09-05。状态：开发验证中，不是上线或商店发布声明。

## 环境与范围

- Windows；Flutter 3.47.1 / Dart 3.13.1。
- Android 模拟器：API 36.1，1080 × 2400、density 420；applicationId `dev.pocketagent.pocket_agent`。触控尺寸以物理像素 / 2.625 计算 dp，不以缩略截图像素计算。
- 远端：Linux / Ubuntu 24.04，tmux，Codex CLI 0.153.4 完整官方发行包。
- Android/iOS 共用 Flutter 代码；iOS 无 Mac/Xcode/真机环境，未构建、未验证。
- 《明日方舟》仅作为 App icon 的绘画参考；应用 UI 不采用游戏界面风格。

## 当前证据

| 验证项 | 结果与边界 |
| --- | --- |
| 静态检查与本地测试 | 主模型复跑 `flutter analyze` 无问题；`flutter test test`：70 通过、4 个显式 live 测试跳过，跳过不计成功 |
| 验证脚本异常清理 | 主模型复跑 16 个 Python 测试通过，包含认证文件部分写入失败、chmod 失败、runtime 启动后失败、本地 fixture 清理与 tmux 窗格归属校验 |
| SSH 真实连接 | 已验证主机 pin 拒绝错误指纹、PTY 输入/输出/resize、tmux 断开重接 |
| 真实 app-server 传输 | 已验证 SSH forward、回环 tunnel `/readyz` 200、WebSocket initialize 和 model/thread RPC |
| 无登录真实链路 | 独立 `live_ssh_vps_test.dart` 已通过：真实 readyz 与 `readAccount=signedOut`；未上传凭据、未发送模型请求 |
| 真实模型回复 | 尚未通过：服务返回 refresh token revoked；不是模型成功回复 |
| 执行中断线恢复、真实 interrupt | 测试代码已编写，尚待有效登录完成实测 |
| 审批/用户输入 | 有模拟协议与 widget 测试；尚未通过真实远端模型完整流程 |
| Android 构建安装 | `flutter build apk --debug` 成功，adb 安装并启动成功 |
| Android 真实 SSH 工作流 | `app_ssh_vps_test.dart` 使用真实 VPS 完整通过：命令、分段中文、创建 tmux、完整客户端重建、恢复同一终端内的环境变量、真实 Codex 初始化与未登录提示。输入通过 xterm 的 TextInputClient 测试通道驱动，不是物理键盘测试 |
| Android 真实模型工作流 | 尚待有效登录；`app_vps_test.dart` 的 skipped integration 不算通过 |
| 四屏视觉 | 首页与连接设置完成两轮 Android 独立评审；第二轮质量/原创/工艺/功能为 7/6/7/8，键盘与 48dp 热区通过，整体仍需迭代；SSH/Codex 页面尚未完成独立视觉验收 |
| App icon | 用户认可非 Q 版头像画风，Agent 身份表达仍在细化；尚未导出最终 launcher assets |
| 远端凭据清理 | 已停止授权与后续无认证测试 runtime；检查隔离目录、SSH 用户标准目录与 root 标准目录的 auth 文件不存在；删除临时本地 fixture 票据、撤销 adb reverse；本机 auth 未删除 |

本记录区分单元测试、模拟服务、真实 SSH、真实模型与设备验证，任何一项不能替代另一项。

普通 Android debug APK 已重新构建、安装并启动。独立副本位于被忽略的
`artifacts/Pocket-Agent-0.3.0-android-debug.apk`，SHA-256：
`5abb2199f12cd405d2e28e3faadfb13f873d2463aaddd6e952d7a9308298e360`。
这是包含调试运行时的测试包，尚未完成商店签名、发行体积优化和最终图标替换。

### 真实模型验证的剩余条件

此前真实 turn 返回 `authentication_refresh_revoked`。继续验证前需要用户完成新的
Codex 登录；重复复制原失效缓存不能视作解决。可在本机运行 `codex login`，或在
远端采用用户亲自完成的 `codex login --device-auth`。仅在已获授权的临时测试中
通过 SSH 传输缓存，测试结束再次退出并验证清理；不要在聊天或仓库中提供认证文件。
参见 [OpenAI 官方身份验证文档](https://learn.chatgpt.com/docs/auth)。

## 可复现命令

```sh
cd mobile
flutter analyze
flutter test
flutter build apk --debug
```

只有获得明确授权、启动私有 fixture 后才能运行远端测试；不要把密码或 Codex token
写成 Dart define。define 仅允许短期本地 fixture token，生成文件在被忽略的 artifacts 中。

```sh
flutter test test/live_vps_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test test/live_codex_recovery_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test integration_test/app_vps_test.dart -d emulator-5554 --dart-define-from-file=../artifacts/validation-defines.json
```

使用 `--without-codex-auth` 启动 fixture 时，只运行明确的无登录测试：

```sh
adb -s emulator-5554 reverse tcp:18089 tcp:18089
flutter test test/live_ssh_vps_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test integration_test/app_ssh_vps_test.dart -d emulator-5554 --dart-define-from-file=../artifacts/validation-defines.json
```

后者覆盖原生 SSH 输入、分段 UTF-8、完整客户端重建后的同一 tmux 会话恢复和
Codex 未登录提示，不替代 `app_vps_test.dart` 的真实模型执行验证。

测试结束必须调用 fixture 的 `/finish` 并检查退出结果；异常终止后按
[运维说明](MOBILE_OPERATIONS.md) 执行匹配模式的 `--cleanup-only`。
当前测试 APK 非商店签名包。源代码和静态配置存在不能证明 iOS 可发布。
