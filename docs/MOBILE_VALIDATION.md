# Pocket Agent 移动端验证记录

日期：2026-09-06。状态：个人测试版已完成本轮真实模型与 Android 验证；这不是上线或商店发布声明。

## 环境与边界

- Windows；Flutter 3.47.1 / Dart 3.13.1。
- Android 模拟器：API 36.1，1080 × 2400、density 420；applicationId `dev.pocketagent.pocket_agent`。
- 远端：Linux / Ubuntu 24.04，tmux，Codex CLI 0.153.4 官方完整发行包。
- Android/iOS 共用 Flutter 代码；iOS 没有 Mac、Xcode 或真机环境，尚未构建和验证。
- ARM64 APK 已核查 manifest、ABI 与 APK v2 signature，但尚未在 ARM64 真机运行。
- 多服务器隔离由 fake transport 回归覆盖，不冒充多台真实 VPS 同时在线测试。
- 商店签名、平台隐私申报与真机交付要求见 [平台交付基线](MOBILE_PLATFORMS.md)。

## 2026-09-06 当前证据

| 验证项 | 结果与边界 |
| --- | --- |
| 静态检查与本地测试 | 删除一次性诊断工具后，主模型串行复跑 `flutter analyze` 无问题；完整本地套件连同预览、登录安全测试共 130 通过，6 个显式 live 用例因没有 fixture 跳过。跳过项不计成功 |
| 多服务器隔离 | 7 项回归覆盖同时连接、切换视图、同名 tmux、后台事件、编辑、删除与全局关闭；证据来自 fake transport |
| 验证脚本 | 27 个 Python 测试通过，覆盖认证文件部分写入失败、目录与 token 归属、runtime 启动后失败、fixture 清理、tmux 窗格归属与隔离 WebSocket probe |
| SSH 与 app-server | 已验证主机 pin 拒绝错误指纹、PTY I/O/resize、tmux 重连、SSH forward、WebSocket initialize、model/thread RPC，以及 capability token 缺失/错误/正确时的 401/401/101 |
| 无登录链路 | `live_ssh_vps_test.dart` 通过生产 runtime 认证 probe 并得到 `readAccount=signedOut`；未上传账号凭据，也未发送模型请求 |
| 官方登录与真实模型 | 隔离 fixture 上的新设备登录由真实 `account/read` 确认为已认证；`live_vps_test.dart` 检查对应 turn 的 `agentMessage.text`、任务列表与重连后同一 turn 回复，均真实通过；结束后显式注销并确认未认证 |
| 恢复、interrupt 与审批 | 断线前确认目标命令正在执行，重连后恢复同一 turn 的真实输出和退出码；真实 interrupt 得到 `interrupted`；command approval 以有限 allowlist 验证 resolved、命令完成、exit 0、精确输出与 turn 完成 |
| 用户输入 | 表单、过期请求与连接隔离具有 mock、生产 Port 和 widget 证据；未宣称真实模型主动请求用户输入已经验证 |
| Android 真实 SSH | `app_ssh_vps_test.dart` 在模拟器经真实 VPS 验证 SSH 命令、分段中文、tmux 恢复、客户端重建、Codex 初始化与未登录提示；输入来自 xterm `TextInputClient` 测试通道，不等同于物理键盘 |
| Android 真实模型 | `app_vps_test.dart` 在模拟器验证 SSH、模型选择、唯一标记回复、任务刷新和历史打开，以及重建客户端后找到同一任务；不等同于真实 skill 执行或 ARM64 真机验证 |
| Android UI 与图标 | x86_64 release-mode APK 已安装并检查首页、添加服务器导航、前台进程与定向错误日志；当前无耳机银白发 v2 图标已接入 Android legacy/adaptive 与 iOS AppIcon，并通过资源校验和 Android launcher 实装检查。视觉仍需迭代，不代表用户已定稿或所有 OEM/iOS 外框已验证 |
| 凭据与资源清理 | 验证后已注销、停止隔离 runtime，并核查隔离目录、SSH 用户/root auth、transport token 与 owner marker；本地 fixture、监听端口与 adb reverse 已清理，本机 auth 未修改 |

真实验收曾用只读诊断确认：任务由当前 runtime 记录为 `source=vscode`、
`ephemeral=false` 且 cwd 精确匹配，因此生产列表兼容 `appServer + vscode`；恢复命令则以
`/bin/bash -lc` 包装且内部反斜杠双写，恢复/中断测试的命令校验已兼容这一完整精确形式。对应问题已经修复，
一次性诊断 probe 不再作为长期测试保留；生产、live/integration、单元回归和安全 fixture
辅助仍保留。

## 当前个人测试包（v5）

- 源码基线：`cbddba9`，包含 `ec3a7c3` 的任务列表兼容修复。
- 构建命令：`flutter build apk --release --split-per-abi --build-number=5`，三个 ABI 当时均构建成功。
- ARM64 副本：`artifacts/Pocket-Agent-0.3.0-android-arm64-verified-v5.apk`，21,331,203 bytes。
- SHA-256：`7a7666067da06c4145b00d753a6a7c91d29d13eb0cb776e2c0abdf4ddddbe469`。
- 使用普通 `lib/main.dart` 入口和无耳机 v2 图标；ARM64 versionCode 2005，min API 24、target API 36。
- APK v2 signature 有效，但仍是 Android Debug certificate，不是商店签名包；文件名中的 `verified` 表示对应源码在本轮经过验证，不表示 ARM64 真机通过。
- x86_64 release-mode APK（versionCode 4005）曾通过 `adb install -r` 保留数据安装；切换 split/universal 包前须检查 versionCode，不得为绕过降级失败而自动卸载或清除用户数据。

## 可复现命令

本地命令应串行运行，避免 Flutter SDK 并发命令互相干扰：

```sh
cd mobile
flutter analyze
flutter test test tool/workspace_preview_test.dart tool/remote_login_test.dart --reporter expanded
flutter build apk --debug
flutter build apk --release --split-per-abi --build-number=5
```

Python 辅助工具回归：

```sh
python -B -m unittest discover -s scripts -p 'test_*.py'
```

`mobile/tool/workspace_preview.dart` 是隔离 UI 预览入口，复用真实工作区 UI，但只使用内存
fake ports，不访问网络或安全存储。它及其 widget test 是可复用验证工具，不是生产入口，
也不能替代真实模型或设备验收：

```sh
cd mobile
flutter test tool/workspace_preview_test.dart
flutter run -t tool/workspace_preview.dart
```

视觉评审后必须恢复普通 `lib/main.dart` 入口，不得把预览 APK 当作实装交付。

## 私有 fixture 与 live 验证

只有获得明确授权并启动私有 fixture 后才能运行。不得把 SSH 密码、Codex token 或认证
文件写入源码、Dart define、聊天、日志归档或提交。设备登录 code 仅在当次官方登录交互中
临时展示，不保存到文档或日志。define 只允许引用短期本地 fixture token；生成文件位于
被忽略的 `artifacts`。

```sh
cd mobile
flutter test test/live_vps_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test test/live_codex_recovery_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test test/live_codex_approval_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test integration_test/app_vps_test.dart -d emulator-5554 --no-uninstall --dart-define-from-file=../artifacts/validation-defines.json
```

使用 `--without-codex-auth` 启动、且尚未完成设备登录的 fixture 时，可运行无登录测试：

```sh
adb -s emulator-5554 reverse tcp:18089 tcp:18089
flutter test test/live_ssh_vps_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test integration_test/app_ssh_vps_test.dart -d emulator-5554 --no-uninstall --dart-define-from-file=../artifacts/validation-defines.json
```

`live_codex_approval_test.dart` 必须真实收到 command approval，且只能批准完整 allowlist
中的无副作用 `printf` 命令，再检查对应 resolved、实际输出和终态。恢复/中断测试另外
校验预期的 sleep 命令：追加命令、缺少 sleep、提前完成、错误 thread/turn/item 或仅有
模型文字回复都不能算执行中恢复成功。

### 主模型代办设备登录

`mobile/tool/remote_login_test.dart` 通过私有 fixture 和 SSH tunnel 使用已有 app-server，
支持 `status`、`login`、`logout` 三个显式动作。默认没有 fixture 时只运行本地安全测试；
已有认证的远端拒绝重新登录，CI 环境也拒绝交互式登录。

```sh
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=status
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=login --dart-define=POCKET_DEVICE_LOGIN_INTERACTIVE=true
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=logout
```

登录成功必须由 `account/read` 复核；请求创建或本地状态测试不等于登录成功。真实模型验证后
先执行 `logout`，再结束 fixture。

## 清理要求

- 正常结束必须调用 fixture 的 `/finish`，确认 helper、runtime、临时终端、transport token、owner marker 和本地 defines 已清理，并撤销 `adb reverse`。
- 异常终止按 [运维说明](MOBILE_OPERATIONS.md#凭据清理与复测) 使用匹配模式的 `--cleanup-only`；`--without-codex-auth` fixture 清理时也必须带同名参数。
- 清理逻辑只处理通过归属检查的隔离资源；未知 auth、token 或进程必须保留并报告，不能放宽校验后删除。
- 未获明确授权时，不读取、复制或删除本机默认 `CODEX_HOME` 认证缓存；不要用卸载 App、清除数据或删除用户 SSH 配置代替测试清理。
- 每次复测分别记录本地、mock、真实 SSH、真实模型、模拟器与真机证据；跳过项不计成功，清理后的通过/跳过数以新的串行复跑为准。

本次仓库整理已删除一次性诊断脚本和被否定的耳机旧稿，保留正式代码、回归测试、
可复用工具、当前图标和画风参考；历史代码与旧稿仍可从 Git 恢复。

2026-09-06 切换为可请求审批的会话模式后，经正式命令审批完成本地清理：
`target/`、`mobile/build/`、`mobile/.dart_tool/`、`mobile/android/.gradle/`、
`mobile/android/.kotlin/`、`mobile/ios/Flutter/ephemeral/`、`frontend/dist/`、
`scripts/__pycache__/`、`mobile/.flutter-plugins-dependencies`，以及 `artifacts/`
中的 50 项旧 APK、截图、UI dump、协议导出和验证/设计评审临时产物。
删除前已确认所有目标都在工作区内、不受 Git 跟踪，且路径及内容不含 reparse point；
文件大小合计 8,084,555,592 bytes（约 7.53 GiB），删除后逐项确认目标不存在。

`artifacts/` 仅保留上方列出的最新 v5 APK，删除后 SHA-256 再次匹配。
没有删除 `.env`、正常开发依赖、用户配置、正式图标或回归测试。
本轮只清理缓存和旧产物，未重新构建或重跑 Flutter 测试，避免立即重建已清理缓存；
前述测试结果仍对应代码整理后的验证，不冒充本次新测试。
缓存可在后续构建时重建；已永久删除的未跟踪旧测试包和截图不能直接从 Git 恢复。
