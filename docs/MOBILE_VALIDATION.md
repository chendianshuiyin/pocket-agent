# Pocket Agent 移动端验证记录

日期：2026-09-06。状态：个人测试版已完成本轮真实模型与 Android 验证，不是上线或商店发布声明。

当前结论以“当前证据”和“2026-09-06 真实模型验收”两节为准。下方带旧源码基线、
旧包名的记录保留历史过程，其中的登录阻塞已在本轮解除。

## 环境与范围

- Windows；Flutter 3.47.1 / Dart 3.13.1。
- Android 模拟器：API 36.1，1080 × 2400、density 420；applicationId `dev.pocketagent.pocket_agent`。触控尺寸以物理像素 / 2.625 计算 dp，不以缩略截图像素计算。
- 远端：Linux / Ubuntu 24.04，tmux，Codex CLI 0.153.4 完整官方发行包。
- Android/iOS 共用 Flutter 代码；iOS 无 Mac/Xcode/真机环境，未构建、未验证。
- 《明日方舟》仅作为 App icon 的绘画参考；应用 UI 不采用游戏界面风格。

## 当前证据

| 验证项 | 结果与边界 |
| --- | --- |
| 静态检查与本地测试 | 主模型复跑全项目 `flutter analyze` 无问题；完整本地套件加预览、登录和两个只读探针：130 通过、8 个显式 live 用例因无 fixture 跳过，跳过不计成功 |
| 多服务器隔离 | 新增并由主模型复跑 7 项回归测试：同时连接、切换视图、同名 tmux、后台事件、编辑、删除与全局关闭；fake transport 验证客户端隔离，不冒充多台真实 VPS 并发测试 |
| 验证脚本异常清理 | 主模型复跑 27 个 Python 测试通过，包含认证文件部分写入失败、目录与 token 归属、runtime 启动后失败、本地 fixture 清理与 tmux 窗格归属校验，以及隔离 WebSocket 探针 |
| SSH 真实连接 | 已验证主机 pin 拒绝错误指纹、PTY 输入/输出/resize、tmux 断开重接 |
| 真实 app-server 传输 | 已验证 SSH forward、WebSocket initialize 和 model/thread RPC；本轮新增真实缺失/错误/正确 capability token 的 401/401/101 探针，不再用 `/readyz` 200 代替认证 |
| 无登录真实链路 | 本轮新认证实现下 `live_ssh_vps_test.dart` 通过：生产 runtime 认证探针与 `readAccount=signedOut`；未上传账号凭据、未发送模型请求 |
| 真实模型回复 | `live_vps_test.dart` 真实通过：只检查对应 turn 的 `agentMessage.text`，任务列表能找到新任务，重连后恢复同一 turn 的模型回复；不再把 user prompt 中的标记当成功 |
| 官方设备登录 | 新设备登录请求完成后真实 `account/read` 确认 `authenticated=true`，随后真实模型请求成功；本轮未读取或上传本机 auth 缓存。结束后显式注销并确认 `authenticated=false` |
| 执行中断线恢复、真实 interrupt | 两项真实通过：断开前核验目标 thread/turn/item 的预期 sleep 命令仍在执行；关闭 RPC、隧道和 SSH 后重新连接，同一 turn 完成且实际命令输出、退出码正确。interrupt 取得真实 `interrupted` 终态 |
| 审批/用户输入 | 真实 command approval 全流程通过：有限 allowlist、resolved、对应命令完成/exit 0/精确输出及 turn 完成。用户输入表单、过期请求与连接隔离仍是 mock/生产 Port/widget 证据，未宣称真实模型主动请求用户输入已验证 |
| Android 构建安装 | debug 与 `flutter build apk --release --split-per-abi` 均成功；x86_64 release-mode APK 安装后前台进程、首页和添加服务器导航正常，未见应用错误日志；ARM64 APK 的 manifest、ABI、APK v2 signature 已核查，但尚未在 ARM64 真机运行 |
| Android 真实 SSH 工作流 | 本轮新认证实现下 `app_ssh_vps_test.dart` 使用真实 VPS 完整复跑通过：命令、分段中文、创建 tmux、完整客户端重建、恢复同一终端内的环境变量、真实 Codex 初始化与未登录提示。输入通过 xterm 的 TextInputClient 测试通道驱动，不是物理键盘测试 |
| Android 真实模型工作流 | `app_vps_test.dart` 在模拟器真实通过：SSH 命令、选择模型、唯一标记的模型回复、任务刷新、历史打开、命令/技能菜单可见、完整客户端重建后找到同一任务；不等同于真实 skill 执行或 ARM64 真机验证 |
| 四屏视觉 | 首页与连接设置完成两轮 Android 独立评审；第二轮质量/原创/工艺/功能为 7/6/7/8。SSH 与 Codex 完成两轮独立评审，第二轮分别为 6/6/7/7 与 7/6/8/6；大字体、明暗主题、键盘、审批全文和必填反馈均实际检查，整体仍需迭代，不代表用户已确认最终视觉 |
| App icon | 耳机版已被否定，当前使用无耳机银白发 v2，已接入 Android legacy/adaptive 与 iOS AppIcon；主模型通过资源校验和 Android 实装圆形桌面图标、点击启动检查。仍是当前迭代，不代表用户已定稿或所有 OEM/iOS 外框已验证 |
| 远端凭据清理 | 本轮真实注销后停止隔离 runtime；独立 SSH 核查隔离、SSH 用户及 root 的 auth 文件均不存在，transport token/owner marker 不存在；本地 fixture 已删除、18089 无监听、adb reverse 已撤销。本机 auth 未修改 |

本记录区分单元测试、模拟服务、真实 SSH、真实模型与设备验证，任何一项不能替代另一项。

### 2026-09-06 真实模型验收

使用此前的 `--without-codex-auth` 隔离 fixture 创建新的设备登录请求，完成后真实
RPC 返回已认证；该 runtime 随后是已登录测试环境，不再称为 signed-out。浏览器
自动化连接仍曾失败，不能把最终登录成功描述为已修复全部内置浏览器或代理问题。

真实基础测试首先发现列表缺失。只读探针比较 cwd 有/无、`appServer`、`cli/vscode`
及全部官方来源，三个新建任务均为 `source=vscode`、`ephemeral=false`，cwd 精确
匹配；`appServer` 单独过滤返回零项。`ec3a7c3` 最小兼容 `appServer + vscode`，
随后基础测试通过。来源字段不是任务所有权，边界见运维说明。

恢复与中断测试增加了真实执行证据检查。安全只读探针确认当前 runtime 的命令
展示为 `/bin/bash -lc` 包装，内部反斜杠双写；仅把这一完整精确形式加入 allowlist，
追加命令、缺少 sleep、提前完成、错误 thread/turn/item 仍被拒绝。最终
`live_codex_recovery_test.dart` 与 `live_codex_approval_test.dart` 串行运行 6 项通过，
其中 3 项真实远端、3 项本地审批 guard/mock。重连时任务可以仍运行或已完成，
但必须证明断开前确实执行中，并恢复原 turn 的真实结果。

Android 首次重跑暴露测试点到了加载中禁用的按钮；第二次任务已成功但旧测试精确
匹配“已完成”，漏掉带模型名的状态栏。修正为等待控件可操作、以稳定 status key
识别终态，并使用每轮唯一的回复标记避免选到旧任务。第三次完整 UI 流程 1 项通过。
测试使用 `--no-uninstall` 和临时 build number 4004，保留数据安装；pubspec 已恢复。

测试结束后 `remote_login_test.dart` 显式 logout 6 项通过（5 本地 + 1 真实 RPC），
返回 `authenticated=false`；`/finish` 返回 204，helper 正常退出并确认 runtime 与
transport token 清理。独立 SSH 再次核查隔离、用户、root 认证与 token/owner 均不存在。
未将 SSH 密码、账号 token 或设备登录 code 写入提交或本报告。

本轮主模型复跑：

```sh
flutter analyze
flutter test test tool/workspace_preview_test.dart tool/remote_login_test.dart tool/thread_list_probe_test.dart tool/command_shape_probe_test.dart --reporter expanded
```

结果为无静态问题、130 通过 / 8 live 跳过；Python 验证脚本 27 项通过。未验证
iOS 构建/真机、Android ARM64 真机及多台真实 VPS 同时在线；多服务器隔离有本地
回归证据。商店签名、平台隐私申报和真实设备验收仍按平台交付清单执行。

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

### 当前个人测试包（v5）

源码基线 `cbddba9`，含 `ec3a7c3` 的任务列表修复。主模型执行
`flutter build apk --release --split-per-abi --build-number=5`，三个 ABI 全部成功。
ARM64 独立副本为 `artifacts/Pocket-Agent-0.3.0-android-arm64-verified-v5.apk`，
21,331,203 bytes，SHA-256：
`7a7666067da06c4145b00d753a6a7c91d29d13eb0cb776e2c0abdf4ddddbe469`。

普通 `lib/main.dart` 入口，保留无耳机 v2 图标。ARM64 versionCode 2005，
min API 24、target API 36；APK v2 signature 有效，仍为 Android Debug certificate，
不是商店签名包。文件名的 verified 指本轮验证过的源码，不代表 ARM64 真机已测试。

模拟器通过 `adb install -r` 恢复普通 x86_64 release-mode APK，versionCode 4005。
本轮测试前后 firstInstallTime 均为 `2026-09-05 09:25:34`，没有卸载或清除数据；
验证结束已删除测试用服务器配置。主模型检查正常空首页、添加服务器表单、返回与
进程存活，定向日志未见崩溃、Unhandled Exception 或布局溢出。ignored 证据为
`pocket-v5-main.xml`、`pocket-v5-main.jpg` 和 `pocket-v5-add-server.xml`。
旧包均保留；iOS 与 ARM64 真机验证边界不变。

### 历史连接认证修复测试包（v4）

生产源码基线 `d6e62ea`，验证辅助工具后续提交为 `9a1e84c`。主模型执行
`flutter build apk --release --split-per-abi --build-number=4`，三个 ABI 全部成功。
ARM64 独立副本为 `artifacts/Pocket-Agent-0.3.0-android-arm64-auth-v4.apk`，
21,331,203 bytes，SHA-256：
`9b93f0931aa88bd4858af8e2b3087fce7ddb18da12f28230082d6bb99a69aaf3`。
普通 `lib/main.dart` 入口，保留无耳机 v2 图标；ARM64 versionCode 2004、
min API 24、target API 36。APK v2 signature 有效，仍为 Android Debug certificate，
不是商店发布包，也未验证 ARM64 真机。

本轮主模型复跑全项目 analyze、118 项本地测试及 27 项 Python 测试通过；
6 项显式 live 测试因未配置 fixture 跳过，不计通过。认证回归包括缺失/错误
token 必须返回明确 401/403、网络错误与超时不得冒充认证拒绝、超时后晚到
socket 回收、重连继续携带 headers，以及旧 runtime 不被替换。

### 真实 WebSocket 连接认证

主模型运行 `scripts/vps_ws_auth_probe.py`，在真实 VPS 的独立临时目录、
独立 `CODEX_HOME`、随机回环端口启动官方 Codex CLI 0.153.4。实测结果：
缺失 token 返回 401，错误 token 返回 401，正确 token 返回 101。
进程、监听、临时 token、隔离 `CODEX_HOME` 与临时目录均已确认清理。
该探针不登录、不发送模型请求，不等同于真实模型验收。

随后启动 `--without-codex-auth` fixture，复跑 `live_ssh_vps_test.dart` 通过：
生产 `RemoteRuntimeManager` 经 SSH 读取 token 并验证认证，连接真实 app-server，
`readAccount` 返回 `authenticated=false; kind=signedOut`。未读取或上传本机
Codex 登录文件。fixture helper 仅接入预启动服务，不会自行启动默认账号目录。

Android `app_ssh_vps_test.dart` 的真实 SSH、中文分段输出、tmux 恢复、Codex
初始化及未登录 UI 全部通过。随后显式运行 `remote_login_test.dart` 的 `logout`
动作，6 项通过且真实 RPC 确认 `authenticated=false`；没有发起新的设备登录。
通过 `/finish` 停止隔离 runtime，确认 transport token 与 owner marker 已删除、
临时终端已由测试回收；再次 SSH 核查隔离、用户与 root 的 Codex auth 文件均不存在。
本地 defines 已删除、18089 listener 为 0、adb reverse 已撤销，本机 auth 未修改。

模拟器恢复普通 `lib/main.dart` x86_64 release-mode APK，versionCode 4004。
主模型检查正常空首页、添加服务器表单与返回，进程存活；AX 证据为 ignored
`pocket-auth-v4-main.xml` 与 `pocket-auth-v4-add-server.xml`。本轮 integration
测试框架默认在结束后卸载测试包，随后已重装普通版本；测试前该模拟器无服务器
配置，不能把这次恢复称为保留数据升级。测试时临时提高了 pubspec build number
以避免安装降级，结束后已恢复且未提交。后续复测使用 `--no-uninstall`，并提前
检查安装版本与测试 APK versionCode；不要依赖工具卸载来解决降级失败。

### 无耳机图标 v2 初次实装记录

源码基线 `cc74a6f`。主模型执行
`flutter build apk --release --split-per-abi --build-number=3`，三个 ABI 全部成功。
ARM64 独立副本为 `artifacts/Pocket-Agent-0.3.0-android-arm64-owl-v2.apk`，
21,331,203 bytes，SHA-256：
`e92790932ae6374acddd8a2e63c1b732b90653b32ce3ca98d9af6eacf31e49c4`。
普通 `lib/main.dart` 入口，ARM64 versionCode 2003，min API 24、target API 36，
label Pocket Agent，APK v2 signature 有效；仍为 Android Debug certificate，
不是商店签名，未验证 ARM64 真机。

主模型通过 `adb install -r` 保留数据升级 x86_64 模拟器至 versionCode 4003；
实际检查默认 launcher 的圆形头像、点击图标进入正常首页、添加服务器页面与返回。
进程存活，定向日志未见 Flutter exception 或应用崩溃。
截图与 AX 证据位于 ignored artifacts：`pocket-owl-v2-launcher.jpg`、
`pocket-owl-v2-home.xml`、`pocket-owl-v2-main.xml`、`pocket-owl-v2-add-server.xml`。
未检查其他 OEM mask，未声称 iOS 构建/实机通过。

主模型复跑生成器 guard self-test、资源完整性检查、全项目 analyze 均通过；
完整本地套件 108 通过 / 6 live 跳过。源文件未重绘，旧包和源稿均未删除。
生成方式与完整 prompt 见 [无耳机头像 v2 记录](ICON_OWL_V2_PROMPT.md)。

### 历史耳机版候选测试包

源码基线 `3454cc2`。主模型执行
`flutter build apk --release --split-per-abi --build-number=2`，三个 ABI 全部成功。
新的 ARM64 副本为 `artifacts/Pocket-Agent-0.3.0-android-arm64-icon-candidate.apk`，
21,323,275 bytes，SHA-256：
`c28006ca2befdfee1d94a0c791c6f0a5775d16f29d5d4f67b08257e6df930b5b`。
旧测试包未覆盖或删除。

此包使用普通 `lib/main.dart`，ARM64 versionCode 2002，min API 24、target API 36，
label 为 Pocket Agent，APK v2 signature 有效但仍由 Android Debug certificate
签名，不是商店发布包。未在 ARM64 真机测试。

主模型用 `adb install -r` 将 x86_64 split 升级到 versionCode 4002，未卸载或清除
数据。实际桌面圆形图标已不再是 Flutter 占位，脸部可辨识；点击图标打开正常首页，
“添加服务器”导航正常，再返回未配置服务器的首页。进程存活；日志仅见系统
`ashmem` deprecated 提示，未见 Flutter exception 或崩溃。本轮不将桌面预测栏
的系统外圈当作源图设计，也未验证其他 OEM 的所有 mask。

截图与 AX 证据位于 ignored artifacts：`pocket-launcher-after.jpg`、
`pocket-launcher-after.xml`、`pocket-icon-main.jpg`、`pocket-icon-launch.xml`、
`pocket-icon-add-server.xml`、`pocket-icon-final.xml`。

资源工具验证了 5 档 Android legacy 尺寸、5 档 108dp adaptive foreground、
XML 资源引用，以及 25 个 iOS AppIcon 引用的尺寸与 RGB/无透明通道要求。
主模型复跑安全生成入口、自检和资源校验通过，Xcode project 没有内容改动；
生成器依赖只用于开发，不进入业务代码。完整本地套件仍为 108 通过 / 6 live 跳过，
最终 `flutter analyze` 无问题。iOS 仅完成静态资源检查，仍未构建、未真机验证。

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

### 历史登录阻塞（2026-09-05，本轮已解除）

此前真实 turn 返回 `authentication_refresh_revoked`。继续验证前需要完成新的
Codex 登录；重复复制原失效缓存不能视作解决。用户已授权主模型代办官方登录，
认证操作不委派给编码子代理。本轮改用远端 app-server 的设备登录 API，不读取
或上传本机失效缓存；目前受浏览器控制连接失败阻断，不能宣称登录完成。
仅在已获授权的临时测试中使用认证，测试结束再次退出并验证清理；不要在聊天
或仓库中提供认证文件。
参见 [OpenAI 官方身份验证文档](https://learn.chatgpt.com/docs/auth)。

本次继续执行时，Chrome 既有官方页面及新建的内置浏览器官方登录页均再次出现
控制调用超时，无法可靠读取和操作登录表单。因此本次没有再发起设备登录请求，
也未重复上传已失效的本机缓存。连接认证、signed-out SSH/Android 回归与凭据
清理已完成；真实模型回复、执行中断线恢复、interrupt 和远端审批仍未验收。

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
flutter test integration_test/app_vps_test.dart -d emulator-5554 --no-uninstall --dart-define-from-file=../artifacts/validation-defines.json
```

使用 `--without-codex-auth` 启动 fixture 时，只运行明确的无登录测试：

```sh
adb -s emulator-5554 reverse tcp:18089 tcp:18089
flutter test test/live_ssh_vps_test.dart --dart-define-from-file=../artifacts/validation-defines.json
flutter test integration_test/app_ssh_vps_test.dart -d emulator-5554 --no-uninstall --dart-define-from-file=../artifacts/validation-defines.json
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
仍对应 `df691d6`。后续设备登录尝试未成功，本轮没有上传或尝试复用失效认证缓存。

### 主模型代办设备登录

`mobile/tool/remote_login_test.dart` 通过私有 fixture 和 SSH tunnel 使用现有
app-server，支持 `login`、`status`、`logout` 三个显式动作。默认无 fixture 时
只运行本地安全测试；有 fixture 时默认仅查询认证状态，不启动远端 runtime。
正常 App 不引用该文件。发起登录必须显式指定交互式动作，CI 环境拒绝运行，
已认证的远端也拒绝重新登录以避免替换现有账户。

```sh
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=status
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=login --dart-define=POCKET_DEVICE_LOGIN_INTERACTIVE=true
flutter test tool/remote_login_test.dart --dart-define-from-file=../artifacts/validation-defines.json --dart-define=POCKET_LOGIN_ACTION=logout
```

此工具调用 `account/login/start` 的 `chatgptDeviceCode` 流程，只显示官方
verification URL 与短期 user code，不输出 login id 或账户详情。交互输出仍有
敏感性，不得使用 CI、日志归档或重定向持久保存，不得写入提交或长期验证报告。
登录等待超时会尝试取消对应请求，成功后还须读取已认证状态，不能
把请求创建当作成功。后续通过真实模型测试后先执行 `logout`，再结束 fixture。

本轮使用未上传本机凭据的隔离 fixture 发起登录，等待超时；真实注销用例
（含 2 项本地解析测试）3 项通过，返回 `authenticated=false`。随后 `/finish`
成功退出，另按用户授权核查并清理隔离、SSH 用户及 root 标准认证路径。
工具加固后再次启动无认证 fixture，主模型分别复跑默认状态查询与显式注销，
每次均为 5 项本地安全测试加 1 项真实 RPC 用例通过，均返回未登录；随后再次
完成 `/finish` 清理。加固后的完整设备登录仍未验证，不能由状态查询推断成功。
确认测试 runtime 已停止、临时 fixture 文件及监听端口已移除、无 adb reverse。
这些证据仅证明注销与清理，不替代尚未通过的登录、模型执行、恢复和审批验收。

测试结束必须调用 fixture 的 `/finish` 并检查退出结果；异常终止后按
[运维说明](MOBILE_OPERATIONS.md) 执行匹配模式的 `--cleanup-only`。
当前测试 APK 非商店签名包。源代码和静态配置存在不能证明 iOS 可发布。
