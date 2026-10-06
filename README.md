# Codex 代理连接修复

一个用于 **Windows 上 Codex 首次请求超时、反复重连**的 skill。

适用于这样的现象：Codex 可以登录，代理软件已经运行，但新对话或重启后的首次消息出现 `request timed out`、重连 `5/5`，日志中可能显示 WebSocket 失败后 `falling back to HTTP`。

skill 会识别**当前运行、实际提供代理的程序**，核对代理地址、监听进程和 Codex 连接；证据充分时修复 Codex 启动代理配置，存在歧义时先请用户确认。

## 安装与使用

将本仓库地址交给 Codex：

> 请安装这个 skill：https://github.com/DecYouth/codex-proxy-repair

也可以下载本仓库 ZIP，解压后把整个 `codex-proxy-repair` 文件夹放入自己的 Codex 用户技能目录。默认目录可使用 `%USERPROFILE%\.codex\skills`；如果设置了自定义 `CODEX_HOME`，使用该目录下的 `skills`。

安装后重新打开 Codex 或新建对话，输入：

> 使用 $codex-proxy-repair 修复 Codex 首次请求反复重连的问题。我的代理软件已在运行，请自动检测，存在歧义时再向我确认。

## 自动检测与修复

1. 读取当前 Windows 系统代理及 PAC/自动检测状态。
2. 将代理地址和端口与真实监听地址、所属 PID、运行程序交叉核对。安装文件夹、进程名字或后台服务本身都不足以证明它是当前可用代理。
3. 核对 Codex 实际后端程序、配置目录、连接状态和相关日志，验证候选代理的 HTTP CONNECT、TLS 和认证 WebSocket。
4. 展示程序、协议、端口和测试结果。唯一候选且证据充分时继续；多个候选、IPv4/IPv6 归属不一致或证据冲突时等待用户确认。
5. 先预览，再更新 Codex 用户目录 `.env` 中的五项代理变量：`HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`WS_PROXY`、`WSS_PROXY`。
6. 备份已有文件，保留其他内容与自定义 `NO_PROXY`。通过新的诊断进程验证持久配置，再提示用户完全退出并重开 Codex，测试首次消息。

修复不依赖某个安装目录、用户名或固定端口。Nano、Clash/Mihomo 及其他客户端只要提供可验证的本地 HTTP/混合代理端口，就可以进入该流程。

## 适用边界

- 自动写入支持本地 HTTP 代理及能够处理 HTTP CONNECT 的混合端口。
- SOCKS5、仅 TUN、PAC、远程代理、代理认证和自定义模型供应商需要进一步判断，不会被强行改成 HTTP。
- 代理运行不代表端口可用；HTTP CONNECT 成功也不代表 WebSocket 或真实聊天成功。
- 无法确认代理身份时询问用户；测试失败时报告失败，不无条件套用修复。
- 端口以后变化时需要重新检测并更新，`.env` 本身不会自动跟踪端口。
- 已修复且新进程诊断正常时，无需重复写入。
- 较旧 Codex 不支持 `doctor --json` 或输出格式发生变化时，需要该版本对应的诊断，不会自动升级。

## 脚本

| 文件 | 用途 |
|---|---|
| [SKILL.md](SKILL.md) | 技能入口与决策条件 |
| [references/workflow.md](references/workflow.md) | 执行、验证、撤销及特殊分支 |
| `scripts/Inspect-CodexProxy.ps1` | 只读检测运行代理、监听端口和 Codex 连接；`-Probe` 可测试 CONNECT/TLS |
| `scripts/Test-CodexProxyConnection.ps1` | 在隔离的诊断子进程中检查 Codex；只输出经过筛选的证据 |
| `scripts/Set-CodexProxyEnv.ps1` | 默认预览，显式 `-Apply` 才写入；支持备份和带哈希保护的撤销 |

脚本兼容 Windows PowerShell 5.1 和 PowerShell 7，无需额外依赖。优先让 Codex 按技能判据调用脚本；不要绕过验证直接填写一个猜测的端口。

## 验证与撤销

开发时在 Windows PowerShell 5.1.22621.6931 与 PowerShell 7.6.5 下，地址/绑定测试各 18 项、配置编辑/撤销测试各 66 项、连接诊断夹具各 39 项，共 **246 项断言通过**。这些测试验证脚本的行为与保护措施，不代表所有电脑、节点或代理协议均已实测。

运行隔离测试：

```powershell
powershell.exe -NoProfile -File .\tests\Test-InspectCodexProxy.ps1
powershell.exe -NoProfile -File .\tests\Test-SetCodexProxyEnv.ps1
powershell.exe -NoProfile -File .\tests\Test-ConnectionHarness.ps1
```

测试会在 `tests` 下建立专用夹具目录，不修改用户的真实 `.env`；连接诊断夹具使用本机编译的模拟程序，不访问真实模型。

实际应用修改后，会返回备份与 receipt 路径。撤销时先预览：

```powershell
.\scripts\Set-CodexProxyEnv.ps1 -RestoreReceipt '<实际 receipt 路径>'
```

核对后添加 `-Apply` 执行撤销。如果 `.env` 已有后续修改，脚本会拒绝覆盖，以保留后续改动。备份可能含有秘密，应留在本机，不随分享包发送。

## 隐私

仓库只包含通用技能、脚本和测试，不包含个人 `.env`、认证文件、订阅、节点密钥、原始聊天日志或诊断记录。运行时不打印完整 `.env` 或认证内容。

## 参考

- [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)
- [OpenAI 高级配置](https://learn.chatgpt.com/docs/config-file/config-advanced)

实测经验表明，`config.toml` 中的 `shell_environment_policy.set` 控制命令子进程，不能据此认定桌面聊天后端已经取得同样的代理环境。
