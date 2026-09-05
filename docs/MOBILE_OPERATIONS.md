# Pocket Agent 移动端运维

## 连接结构

每台服务器有独立的 SSH 连接、终端集合和 Codex 任务视图。Android / iOS
客户端直接连接服务器，不需要集中式网关或公网 app-server 端口。

SSH 通道有两种用途：交互式 PTY，以及转发远端回环地址上的 Codex WebSocket。
普通终端关闭后 shell 会结束；持久终端由远端 tmux 保持，可以重新附加。
Codex app-server 运行在独立 tmux 会话中，关闭 App 不等于关闭该进程。

## 服务器准备

首版支持 Linux，验证基线为 Ubuntu 24.04、Codex CLI 0.153.4。安装 tmux
并使用 [OpenAI 官方发行包](https://github.com/openai/codex/releases/tag/rust-v0.153.4)
安装该版本的完整 Codex runtime；完整包包含所需的伴随程序。下载后核对官方
校验值，不要只复制完整包里的单个二进制。

```sh
sudo apt-get install tmux
codex --version
codex login --device-auth
```

将 `codex` 放入登录用户的 PATH 或 `~/.local/bin`。登录与任务均属于该 SSH
系统用户。需要更新时先记录当前版本、完成或中断运行中的任务，再升级和验证。

在 App 中添加服务器，填写 SSH 地址、端口、系统用户名和密码或 PEM 私钥。
第一次连接必须核对主机密钥指纹。可通过服务器控制台核对，例如：

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

密钥不匹配时不要直接忽略警告；先核实服务器是否重装、密钥是否更换，以及
网络是否可信。编辑目标主机或 SSH 端口会要求重新确认该目标的主机密钥。

## 生命周期与恢复

- 每个用户、每个配置端口使用 `pocket-agent-runtime-codex-<port>`。
- App 创建的持久终端使用独立的 `pocket-agent-term-<id>` 命名空间。
- SSH 终端列表和删除操作不会访问 Codex runtime 的 tmux 会话。
- 暂时无法完成健康检查时不会自动杀掉已有 runtime；恢复网络后手动重连。
- 服务器重启、用户注销策略杀掉进程、tmux 被终止，与手机断网不同。首版不
  承诺跨服务器重启继续执行同一进程；可恢复的任务历史仍保存在远端 Codex 中。
- 不接管另一个独立 Codex CLI 进程的正在执行状态。原生 Codex TUI 可在 SSH
  终端使用，App 的结构化任务由其连接的 app-server 管理。

## 安全与发行边界

凭据仅进入系统安全存储。Android 禁止自动备份及设备迁移；iOS Keychain 使用
仅本设备且解锁时可访问的配置。不在源代码、构建参数或普通偏好中保存 SSH 密码。
App 不保存远端 Codex token；使用远端 SSH 用户的 Codex 登录。

app-server 只监听 `127.0.0.1`，经 SSH 隧道使用。不要开放 4500 等配置端口到
公网。服务器上能访问同一用户/回环服务的本地程序仍属于信任边界；该方案不是
多租户隔离系统。

官方仍将 WebSocket transport 标注为实验性，不应将个人验证结果解读为上游
生产 SLA。协议版本固定、升级回归和真实断线测试是必要门槛。参见
[OpenAI Docs](https://learn.chatgpt.com/docs/app-server)。

当前安装包用于个人验证，不是已签名上架的商店版本。iOS 源码与平台配置已提供，
但本次没有 Mac/Xcode，不宣称 iOS 构建或真机通过。

## 凭据清理与复测

`scripts/mobile_validation_bridge.py` 是显式授权后使用的本地测试辅助程序。
它通过 SSH 将本机 Codex 登录放进远端独立测试目录；仅在本机回环地址向测试
提供内存中的 SSH fixture。不要在共享机器或公网接口运行该辅助服务。

只验证 Android SSH、tunnel 与未登录 Codex 状态时，应显式使用无认证模式：

```powershell
python scripts/mobile_validation_bridge.py --config <private-config> --without-codex-auth
```

该模式不读取或上传本机 Codex auth，将远端隔离 `CODEX_HOME` 强制设为 file-based
credential storage、确认其中不存在 `auth.json`，并从 runtime 环境移除
`OPENAI_API_KEY` 与 `CODEX_ACCESS_TOKEN`。它也不会退出或删除远端用户及 root 的
标准 Codex 登录。默认模式仍只用于用户显式授权复制本机 Codex 登录的验证。

需要新的认证而不复制本机缓存时，可在上述隔离 fixture 上显式运行
`mobile/tool/remote_login_test.dart` 的设备登录动作，见
[验证记录](MOBILE_VALIDATION.md#主模型代办设备登录)。这会在远端隔离目录生成新登录，
此后不能继续把该 runtime 当作未登录环境。完成测试后先使用工具的显式 `logout`
并确认未登录，再结束 fixture；不要只删除文件而遗留已登录的运行进程。

测试完成后使用其 `/finish` 控制入口，或者在异常终止后显式运行
`--cleanup-only`。辅助程序停止属于本次验证的 runtime、删除临时终端，并退出及
删除测试目录、当前 SSH 用户标准目录和 root 标准目录中的 Codex 登录。
该退出行为仅适用于本次用户明确授权的验证，不能作为 App 默认退出行为。
无认证模式的异常清理必须同时传入 `--without-codex-auth`，其清理范围仅限隔离
runtime 与隔离 auth 路径。

认证文件删除后无法从 VPS 恢复登录；需要再次运行 `codex login`。本地认证文件
仅被读取，不会被辅助程序删除。远端工作文件和正常 SSH 配置不会被清理。
