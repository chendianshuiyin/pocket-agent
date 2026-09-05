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
| 静态检查与本地测试 | 主模型复跑 `flutter analyze` 无问题；`flutter test test tool/workspace_preview_test.dart`：103 通过（含 2 个隔离预览测试）、5 个显式 live 测试跳过，跳过不计成功 |
| 多服务器隔离 | 新增并由主模型复跑 7 项回归测试：同时连接、切换视图、同名 tmux、后台事件、编辑、删除与全局关闭；fake transport 验证客户端隔离，不冒充多台真实 VPS 并发测试 |
| 验证脚本异常清理 | 主模型复跑 16 个 Python 测试通过，包含认证文件部分写入失败、chmod 失败、runtime 启动后失败、本地 fixture 清理与 tmux 窗格归属校验 |
| SSH 真实连接 | 已验证主机 pin 拒绝错误指纹、PTY 输入/输出/resize、tmux 断开重接 |
| 真实 app-server 传输 | 已验证 SSH forward、回环 tunnel `/readyz` 200、WebSocket initialize 和 model/thread RPC |
| 无登录真实链路 | 独立 `live_ssh_vps_test.dart` 已通过：真实 readyz 与 `readAccount=signedOut`；未上传凭据、未发送模型请求 |
| 真实模型回复 | 尚未通过：服务返回 refresh token revoked；不是模型成功回复 |
| 执行中断线恢复、真实 interrupt | 测试代码已编写，尚待有效登录完成实测 |
| 审批/用户输入 | 模拟协议与真实生产 Port 测试验证：任务结束/中断/断线使旧请求失效，重连复用 request id 不能让旧对象批准新请求，resolved 通知清理当前提示；widget 测试验证全文和表单。尚未通过真实远端模型完整流程 |
| Android 构建安装 | debug 与 `flutter build apk --release --split-per-abi` 均成功；x86_64 release-mode APK 安装后前台进程、首页和添加服务器导航正常，未见应用错误日志；ARM64 APK 的 manifest、ABI、APK v2 signature 已核查，但尚未在 ARM64 真机运行 |
| Android 真实 SSH 工作流 | `app_ssh_vps_test.dart` 使用真实 VPS 完整通过：命令、分段中文、创建 tmux、完整客户端重建、恢复同一终端内的环境变量、真实 Codex 初始化与未登录提示。输入通过 xterm 的 TextInputClient 测试通道驱动，不是物理键盘测试 |
| Android 真实模型工作流 | 尚待有效登录；`app_vps_test.dart` 的 skipped integration 不算通过 |
| 四屏视觉 | 首页与连接设置完成两轮 Android 独立评审；第二轮质量/原创/工艺/功能为 7/6/7/8。SSH 与 Codex 完成两轮独立评审，第二轮分别为 6/6/7/7 与 7/6/8/6；大字体、明暗主题、键盘、审批全文和必填反馈均实际检查，整体仍需迭代，不代表用户已确认最终视觉 |
| App icon | 用户认可非 Q 版头像画风，Agent 身份表达仍在细化；尚未导出最终 launcher assets |
| 远端凭据清理 | 已停止授权与后续无认证测试 runtime；检查隔离目录、SSH 用户标准目录与 root 标准目录的 auth 文件不存在；删除临时本地 fixture 票据、撤销 adb reverse；本机 auth 未删除 |

本记录区分单元测试、模拟服务、真实 SSH、真实模型与设备验证，任何一项不能替代另一项。

此前普通 Android debug APK 已构建、安装并启动。旧基线 `7ecb30a` 的独立副本位于被忽略的
`artifacts/Pocket-Agent-0.3.0-android-debug.apk`，SHA-256：
`5abb2199f12cd405d2e28e3faadfb13f873d2463aaddd6e952d7a9308298e360`。
这是包含调试运行时的大体积测试包，不是商店签名或最终图标版本。

另提供较小的 ARM64 个人测试包：
`artifacts/Pocket-Agent-0.3.0-android-arm64-test.apk`，20,631,366 bytes，SHA-256：
`be617e49585565ac31e5f96375f29ed68ebfda1c24f008a22a8971eea6c3c493`。
该副本使用普通 `lib/main.dart` 入口，源码基线为 `df691d6`，不是模拟预览；
属于 release-mode 编译、debug certificate 签名，非商店发布包。最低 Android API 24、
target API 36，ARM64 versionCode 2001；x86_64 split 为 4001。切换 split/universal
测试包时须注意版本号，不能因降级被拒就自动卸载用户数据。
正式签名与 iOS 的逐项验证要求见 [平台交付基线](MOBILE_PLATFORMS.md)。

### 隔离的界面预览

`mobile/tool/workspace_preview.dart` 复用真实工作区 UI，以内存 fake ports 提供 SSH、
任务列表、对话/工具、审批、用户输入与错误六个状态。顶部持续显示“设计预览 · 模拟数据”，
不访问网络或安全存储，普通 `main.dart` 不引用该入口。主模型复跑其 2 个 widget tests
通过，包括 320px / 2× 字体下预览控制栏布局；这不是生产全屏或真实模型验收。

```sh
cd mobile
flutter test tool/workspace_preview_test.dart
flutter run -t tool/workspace_preview.dart
```

设备视觉评审结束后须恢复普通入口，不能把模拟预览 APK 作为实装交付。

SSH/Codex 第三轮仅做定向功能复核：默认和 1.6× 字体的 active tab Delete
均为 126×126px，即 48×48dp；中断后审批决策与用户输入卡从界面和 AX 树消失；
未发现 overflow 或 ScrollController 异常。此轮通过功能回归，未改变整体视觉仍需
迭代的结论。随后已安装 `df691d6` 普通入口的 x86_64 release-mode APK，复查
前台进程、正常首页、添加服务器导航与错误日志；当前设备已退出模拟预览。

最终 release 重建曾出现一次 Flutter SDK `Could not determine engine revision`。
检查 SDK 版本和 engine stamp 正常，停止并行 Flutter 命令后串行重建三个 ABI 成功；
未修改 SDK 或以失败产物交付。

### 工作区交互回归

- 输入草稿与 skill 选择按任务隔离；切换任务、服务器或连接实例后，旧异步选择框不能向新任务注入内容。
- 中断按钮独立于不可编辑的输入框；终端标签至少 48dp，选中项在窄屏和重命名后保持可见。
- 审批保留摘要并可打开可滚动的完整内容；用户输入表单对必填空值显示明确错误。
- 旧审批和用户输入响应需匹配当前 unresolved 请求对象；中断响应还校验连接 generation 与当前任务，避免旧异步操作误清新状态。`turn/completed` 仅清理对应 turn，`serverRequest/resolved` 同步移除对应提示。
- 审批、用户输入和任务运行状态仍须区分模拟协议验证与真实模型验证，不能由预览成功推断真实远端执行成功。

请求生命周期依据 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)：
`turn/interrupt` 的空响应确认请求成功，最终状态由 `turn/completed` 给出；
审批按 thread/turn 归属，`serverRequest/resolved` 表示请求已回答或清理。

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
flutter test test/live_codex_approval_test.dart --dart-define-from-file=../artifacts/validation-defines.json
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

`live_codex_approval_test.dart` 的远端用例必须真实收到 command approval，才可批准
一个完整 allowlist 内的无副作用 `printf` 命令；它检查对应请求 resolved、对应命令
item 的退出码与精确输出，以及 turn 完成。额外命令或权限请求会取消并失败。
模型没有发出审批请求、协议 command 渲染不在有限 allowlist 内，均不能算通过。
测试中的本地 guard/mock 验证与被跳过的远端用例分别记录，不以模型文字回复
或本地 mock 成功代替真实审批链路。

该文件的 2 个 allowlist 测试与 1 个本地 WebSocket mock 测试已由主模型复跑通过；
mock 覆盖非法命令实际发出 cancel response，以及合法审批后的 resolved、item 和
turn 通知。新增内容仅为测试与记录，未改变普通 App 或重新生成 APK；上方测试包
仍对应 `df691d6`。尚未进行新的浏览器登录，本轮没有上传或尝试复用失效认证缓存。

测试结束必须调用 fixture 的 `/finish` 并检查退出结果；异常终止后按
[运维说明](MOBILE_OPERATIONS.md) 执行匹配模式的 `--cleanup-only`。
当前测试 APK 非商店签名包。源代码和静态配置存在不能证明 iOS 可发布。
