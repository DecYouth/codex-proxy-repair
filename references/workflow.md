# 执行说明

## 启动与检测

脚本兼容 Windows PowerShell 5.1 及 PowerShell 7。通过当前 PowerShell 调用文件；若执行策略阻止脚本，解释限制，优先用已允许的执行环境，不永久更改执行策略。

```powershell
# 将变量设为实际 skill 文件夹，切勿照抄其他机器的用户名。
$skillDir = '<本机 skill 文件夹的绝对路径>'
$inspection = & (Join-Path $skillDir 'scripts\Inspect-CodexProxy.ps1') -Probe -TimeoutMs 15000 | ConvertFrom-Json
```

检查检测结果，而非无条件取第一个候选。当前系统代理可以是失效的旧设置；只有活动监听归属和协议测试才能证明当前提供了代理服务。HTTP CONNECT 通过只证明代理隧道可建立；TLS 校验通过证明隧道可到达目标，尚未验证登录或模型服务。

运行客户端前端可能不直接监听端口，实际由子进程核心监听。此时从返回的父进程 PID、进程树和已观察到的路径建立关系。不要全盘搜索安装包或把名字相似的进程当成真实代理。若读不到路径，保留“未知”，可用已核验的监听归属继续分析，但有身份歧义时需用户辨认。

## 找到正确的 Codex 与配置目录

使用正在运行的后端可执行文件路径、桌面启动日志和相关配置核对。多个 Codex 后端（包括不同版本、不同配置目录、远程后端）不可合并为一个。本技能不把本机代理写入远程 SSH/WSL 主机。

确认 `.env` 所在目录：使用后端实际的 `CODEX_HOME`；没有自定义配置时，候选为当前用户目录下的 `.codex`。不要给系统环境设置 `CODEX_HOME`。`config.toml` 中的 `shell_environment_policy.set` 只控制命令子进程，不能当作后端本身的环境证据。

只筛选现有 `.env` 中代理键的名称和经脱敏的值；不要输出整份文件。日志按时间和相关目标筛选 `request timed out`、`responses_websocket`、`falling back to HTTP` 等简短片段，避免混入用户消息、工具请求或认证信息。

## 连接对照

先对实际发现的可执行文件运行 `--version` 与 `doctor --help`。若不支持 `doctor --json`，使用该版本官方文档及本机日志进行替代验证；不要自动安装或升级，也不要声称已经通过标准化认证握手测试。

提供的 `Test-CodexProxyConnection.ps1` 只启动诊断子进程，不发送模型生成请求，不改任何配置文件：

```powershell
$codexExe = '<实际发现并核对过的 codex.exe>'
$configDir = '<确认过的 Codex 配置目录>'
$proxyUrl = '<检测并验证过的本地 HTTP 代理 URL>'
$testScript = Join-Path $skillDir 'scripts\Test-CodexProxyConnection.ps1'

# 新进程，清除继承的五类代理变量，但保留该目录已有 .env 的自动加载行为。
$before = & $testScript -CodexExe $codexExe -CodexHome $configDir | ConvertFrom-Json
# 仅在子进程内显式指定候选代理，不影响 Windows 或当前桌面。
$candidate = & $testScript -CodexExe $codexExe -CodexHome $configDir -ProxyUrl $proxyUrl | ConvertFrom-Json
```

这不是旧桌面进程完整环境的复制，只是受控对照。已有 `.env` 仍参与首次测试，不能称之为“强制直连测试”。不要为了制造对照删除或临时改名用户的 `.env`。若现有测试已通过，但日志显示旧桌面未加载配置，优先提示重启，通常不需要再写文件。

诊断以 `network.websocket_reachability` 的明确成功和 HTTP 101 为准；版本字段或输出结构变化、缺少证据时判为未知。整体 doctor 可能因无关 CDN、终端或插件问题给 warning；不能把总体退出码/总体 warning 当作模型 WebSocket 失败或成功。

候选连接成功、原连接失败以及与之吻合的日志，支持代理加载修复。两组都失败时检查节点、认证、TLS、服务端状态等；两组都成功时不推断故障已永久消失。不要关闭证书验证。

## 写入、复测、撤销

完成 SKILL.md 决策后，先预览再写入，不能把以下示例当作无条件执行清单：

```powershell
$editor = Join-Path $skillDir 'scripts\Set-CodexProxyEnv.ps1'
$preview = & $editor -CodexHome $configDir -ProxyUrl $proxyUrl | ConvertFrom-Json
# 只有通过 SKILL.md 决策门槛、展示检测结果并重新核对身份后执行：
$change = & $editor -CodexHome $configDir -ProxyUrl $proxyUrl -Apply -ExpectedHash $preview.ExpectedHash | ConvertFrom-Json

# 必须不传 -ProxyUrl，才是验证持久配置的测试：
$after = & $testScript -CodexExe $codexExe -CodexHome $configDir | ConvertFrom-Json

# 仅在需要撤销本次实际修改时，先预览撤销：
& $editor -RestoreReceipt $change.ReceiptPath
# 核对目标与影响后撤销；若脚本提示后续修改冲突，停止自动撤销。
& $editor -RestoreReceipt $change.ReceiptPath -Apply
```

`.env` 只写入五个代理键：HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、WS_PROXY、WSS_PROXY。本机 HTTP 代理 URL 在这五项中一致；HTTPS/WSS 是目标流量类型，并不要求把代理 URL 改成 https/wss。未知 SOCKS5 兼容性需单独核验，不能把 socks 端口伪装成 HTTP。

保留已有 `NO_PROXY`（含大小写变体及 export 形式）和其他设置。若它覆盖了 chatgpt.com 或使用 `*`，可能令候选连接绕过代理，需说明原因并让用户决定是否调整该独立规则；不要静默清除它。

执行写入后，再运行**不传 `-ProxyUrl`**的新进程诊断，验证持久配置确实生效。若失败需要撤销，按编辑脚本输出的 receipt 调用 `-RestoreReceipt`；不要整份覆盖已经发生后续修改的文件。

预览输出的 `HasChanges=false` 表示无需写入；不要继续调用撤销，因为没有本次修改 receipt。已有文件包含无法可靠保留的语法或非 UTF-8 编码时，编辑器拒绝写入；先检查相关结构，不要用整文件覆盖来绕过拒绝。

没有固定系统代理但发现了明确的运行中候选时，可以加载检测脚本中的只读函数，在独立核对监听归属后测试用户选定端口：

```powershell
. (Join-Path $skillDir 'scripts\Inspect-CodexProxy.ps1') -LibraryOnly
Test-HttpProxyTls -ProxyHost '<已确认的回环地址>' -ProxyPort <已确认的端口整数> -BudgetMs 15000
```

这个函数不核验端口所属进程，不能跳过身份核验与认证 WebSocket 对照。对于 `localhost` 解析到多个进程的情况，需先确认具体 IPv4/IPv6 路由，不能通过试中一个端口就替用户选择。

## 特殊分支

- **PAC / 自动发现**：固定 ProxyServer 不一定生效，不把残留端口当当前代理。明确确认目标站点的实际代理路由再继续。
- **仅 TUN**：系统可以通过虚拟网卡转发而没有 HTTP 监听端口。先诊断该链路；需要本地 HTTP 端口时请用户通过其客户端支持的设置开启后再检测。
- **多候选**：至少列出名称、协议、地址、PID 和测试结果供确认。用户选择后仍需重新核对监听与协议。
- **IPv4 / IPv6**：localhost 可能解析到两种地址；相同端口不代表相同监听进程。不把 :: 的监听自动等同于 IPv4 可达。
- **权限不足**：不得自动提权，说明无法取得哪一项证据。能消除歧义时继续，不能消除则请用户提供所需信息。
- **端口变化**：重新检测、验证、预览并更新；不安装守护进程来自动改配置。
- **已修复**：配置已匹配且新进程诊断通过时返回无需修改。不要重复追加变量、生成不必要备份。

## 来源与已验证边界

- [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)：子进程环境配置的含义。
- [OpenAI 高级配置](https://learn.chatgpt.com/docs/config-file/config-advanced)：保留内置 provider，不伪造覆盖内置 ID。
- 本技能源于 Windows + Nano 的实测：桌面后端 Codex 0.160.0 无显式进程代理时认证 WebSocket 超时，Codex 用户目录 `.env` 配置本地 HTTP 代理后，清空继承代理的新进程诊断返回 101，用户随后确认恢复。此案例不代表所有版本、协议或节点已验证。

遇到新版行为变化时查看该版本本机帮助和官方文档。不要把旧 feature 开关 `responses_websockets` / `responses_websockets_v2` 当通用修复，也不要将“回退 HTTP”描述为已证明第五次才开始使用代理。
