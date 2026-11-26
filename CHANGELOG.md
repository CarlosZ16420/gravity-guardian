# 变更记录

## 0.6.7 · 未发布

- 统一插件、审批服务、面板和原生宿主版本号为 0.6.7，便于核对本机是否运行缓存修复后的构建。
- 审核会话的输入增长估计仅采纳单次尝试且单次推理的有效用量；重试、多次推理或缺失计数保留既有基线，避免提前重建会话。保留 64 次成功审核及 96,000 Token 增长检查点。

### 审计修复与发版流程优化

- 安装失败可恢复本次操作前的插件、登记、权限和清单；预先校验配置，区分升级回滚与卸载恢复记录，异常退出后明确中止重试。修复时保留已有自定义数据目录、历史和暂停状态。
- 日志压缩改为同目录逐文件替换，保留原文件名，不再多段合并或按年龄删除旧 stage；仅按顶层事件类型清理，避免正文中的嵌套标记误删审批记录。
- 本地 IPC 使用独立编码与一致的 UTF-8 帧预算，编码超限提示拆小重试；历史工具结果保留状态、错误与截断信息，不改变原生协议或审批策略。
- 明确便携版先断开再切换安装版；停止助手支持 Lite 的系统运行时，自启动参数统一为 `--minimized`。便携版连接失败使用本次恢复记录，保留卸载/断开的历史恢复用途。
- 面板在首次安装状态刷新后只触发一次启动自动更新检查；增加安装故障、日志压缩中断、传输边界、事件识别和便携版回滚的针对性回归。

- 新增本地与云端统一入口 `Run-Release.ps1`：快速预检先于重型编译，完整验收按阶段保存耗时和哈希，支持同一构建输入下安全续跑，避免中断后重走已通过步骤。
- 普通源码推送及 PR 只跑快速预检和服务回归；正式编译、三包与完整验收通过手动工作流触发。云端缓存兼容的 Rust 编译图、锁定依赖与已校验程序，首次填充及工具链升级仍可能冷编译。
- 原生测试复用正式依赖，测试目标降低自身优化级别并缓存经过指纹校验的测试程序，每次仍执行完整测试；发行 EXE 的 ThinSize / ThinLTO 及完整上游内核不变。
- 新增 `Publish-Release.ps1`，统一处理本地或云端的已验收附件，先核对草稿及远端哈希，支持续传并拒绝覆盖已发布版本。
- 修复 Windows PowerShell 5.1 在便携版迁移时把已停止服务的查询错误提前终止的问题；查询失败仍须确认对应进程已退出，未知状态继续中止切换，并在快速预检中回归这一行为。

## 0.6.6 · 2026-11-26

- **统一本地与云端的正式构建路径处理**：Rust 与原生 C/C++ 依赖采用编译路径映射，C# Release 不再嵌入本机 PDB 位置；发布用 Native Guardian 元数据使用中性构建目录。打包前新增实际产物扫描，覆盖二进制、UTF-16、JSON 转义和跨读取边界的路径，旧缓存不能绕过正式重编。
- **新增本机免安装包 Portable**：
  - 解压后打开面板，完全退出 Antigravity 并点击「连接 / 修复连接」即可使用。程序、插件配置、审批日志及统计分别保存在同一解压目录的 `app/`、`config/`、`data/` 中；宿主只保留必要的调用登记。
  - 复用本机已有的 Codex 登录、现有 Guardian 和锁定的 .NET 运行时，不增加登录依赖、额外运行时或常驻进程。使用说明见[免安装版说明](docs/portable.md)。
  - 连接时支持复制并校验现有安装的配置、审批日志、接管状态和自定义计价，保留原始宿主设置的恢复记录及旧数据；「断开连接」停止服务、撤销插件委托并保留当前文件夹内的设置和日志。
  - 更新仅替换程序与发行元数据，保留配置和日志；增加必要的更新恢复记录。发行清单新增 `distributions.portable`，保留原 Standalone / Lite 入口。
  - 修复后台服务继承输出句柄导致 PowerShell 安装脚本等待不退出的问题，以及 Windows PowerShell 5.1 的中文卸载脚本编码问题；断开后重新连接时刷新恢复基线，保留用户在断开期间调整的宿主设置。
  - 去除重复面板和脚本。同运行时、同 Guardian 的改造前 Standalone 基线为 87,614,636 字节，Portable ZIP 为 87,261,202 字节（约 83.22 MiB），减少 353,434 字节（约 345 KiB）；干净解压后的程序减少 643,512 字节（约 628 KiB）。打包时同时校验 Portable 不超过同批 Standalone 的 ZIP 与解压体积。
  - 已通过既有 94 项审批回归、面板构建与自检、原安装及 Standalone / Lite 回归，以及免安装迁移、Hook 调用、运行时缺失阻断、更新保留数据、早期更新恢复、断开和重连验证。
- **品牌与底层标识统一更名为 Gravity Guardian**：
  - 将对外品牌、GitHub 仓库引用、插件 ID 与安装目录（`plugins/gravity-guardian`）、数据目录（`gravity-guardian-data`）、Win32 面板（`GravityGuardian.exe`）、核心服务程序集（`gravity-guardian.dll`）、命名管道前缀（`gravity-guardian-*`）及开机自启注册表项（`GravityGuardian`）统一为 **Gravity Guardian**。
- **审核缓存与会话续接修复**：当前授权紧随开发者指令、先于持久历史，当前动作事实独立置于末尾；检查点按每次推理输入相对基线的增量触发，避免大基础提示和重试累计输入造成每轮重建。
- **移除项目长期授权**：
  - 7 天 6795 次真实审批日志显示长期授权目录启用次数为 0，且该机制只能把授权抬升到 `high`，无法覆盖 `risk_level = critical` 的强制拒绝。
  - 删除 `ProjectAuthorizations.cs`、`ProjectAuthorizationTests.cs`、`plugin/rules/project-authorizations.md`、`hooks.json` 中的 `PreInvocation` 钩子、Schema 与原生宿主 `Authorization.project_authorizations` 字段，以及策略与适配提示中的附加说明，使送审结构恢复与上游 Codex 对齐。
  - `gravity-guardian chat` 保留一个版本作为空返回（`{}`）兼容入口；`Uninstall.ps1 -PurgeData` 保留对遗留 `project-authorizations` 目录的清理。
- **已授权拒绝转原生人工确认（`escalateAuthorizedDenials`，默认 `true`）**：
  - Guardian 判定 `outcome = deny` 且 `user_authorization = high` 时，改为返回 `force_ask`（`status = escalated`、`reasonCode = policy_denied_user_authorized`），弹出 Antigravity 原生确认并附带风险等级与拒绝理由（不附带禁止绕过的 Agent 提示，不复用 Always Allow，对应 Codex `thread/approveGuardianDeniedAction`）。
  - `DenialGuard` 记录 `escalated` 状态并兼容重复请求与开关回滚；审核提交前若用户撤销或证据变更仍按 `action_invalidated` 拒绝；`UsageStats` 与 `Analyze-Logs.ps1` 将其计入 `Denied` 与 `authorizedDenialEscalations` 而非技术失败。
- **受保护目录全局审核委派（`delegateProtectedPaths`，默认 `true`）**：
  - 新增清单 `plugin/host-protected-paths.json` 与 `ProtectedPathDelegation.cs`（配合 `delegated-grants.json` 归属账本与跨进程锁 `delegated-grants.lock`），在审批服务运行中、接管开启且宿主版本满足要求（`>= 2.29.0`）时，向全局 `globalPermissionGrants.allow` 挂载受管裸段规则（`read_file(.git)`、`read_file(.cache)`、`write_file(.cache)`、`read_file(.vscode)`），消除 Antigravity 对 `.cache` 读写与 `.git`/`.vscode` 只读的无来源硬编码弹窗，由 Native Guardian 逐次真审。
  - 永久排除 `.git` 写入、`.vscode` 写入、`.env*`、`.npmrc` 与 `.ssh`；保留用户既有授权规则，`PermissionSnapshot.Read` 送审前自动过滤插件托管的绕行条目以免 Guardian 误判为用户授权；将 `.vscode` 移出 `ScopedRead.SafeDotSegments`，确保 `.vscode` 读取同样经过 Guardian 审核。
  - 严格绑定插件生命周期：暂停接管（`takeover --enabled false`）、服务停止/失联故障（`review` fail-closed 兜底）、关闭开关（`set-protected-delegation`）或卸载（`Review-Mode.ps1` `Clear-DelegatedProtectedGrants` / `Uninstall.ps1`）均立即回收托管授权。委派关闭时，仅对用户未点名的 `.git` 元数据读取退回为 `host_protected_redirect`（提示改跑只读 `git -C` 命令，绝不对 `.cache` 半途改道），由 `UsageStats.Redirected` 与 `Analyze-Logs.ps1` `hostProtectedRedirects` 单独统计。
  - Win32 面板「偏好设置」新增全局复选框「受保护目录交由插件审核」（`ID_CHK_PROTECTED_DELEGATION`），`Doctor.ps1` 增加委派与活跃授权计数巡检，并移除旧提示词规则 `plugin/rules/antigravity-scratch.md`。

## 0.6.5 · 2026-11-25

本次发布在 Codex `0.172.0` 原生 Guardian 架构（保留完整上游内核与 `rusty_v8`，不裁剪内核 crate）的基础上，完成 `0.6.5` 长会话授权修复、端到端隐性缺陷治理、全仓版本统一与发布包构建。GitHub 公开发布需待下列人工实机复验确认后执行。

### 故障根因与综合修复

- **长会话授权与预算归因**：
  - 修复 Codex `0.172.0` 弹性预算前上游保留层（每类 8 条 / 单条 16 KiB / 总 64 KiB）挤掉早期真实用户授权导致的 `review_authorization_budget_exceeded`。改为独立传递完整用户原文与撤销记录，并将 `AGENTS.md` 项目规则与项目长期授权分源纳入审核。
  - 修复桥接层（`GuardianFacts.cs`）与 Codex 补丁（`input_budget.rs`）在大动作场景下误归因为 `review_authorization_budget_exceeded` 的问题，确保动作本身超限稳定归类为 `native_action_budget_exceeded` 并零推理停止。
  - 默认 `MaxInputBytes`（及 `Install.ps1` / `Review-Mode.ps1` 新旧配置默认值）提升至 `1,048,576` 字节（1 MiB）；`IsOversizedSingleRequest` 扩展支持 `write_to_file`、`replace_file_content`、`multi_replace_file_content`。
- **工具路由与故障恢复**：
  - `Routing.cs`、`ReviewAdapter.cs` 与 `schemas/review-input.schema.json` 新增 `update_focus`、`update_steps`、`enter_plan_mode`（无参）及 `manage_task`（仅 `Action="list"`）的严格模式本地判定委派。
  - 修复 `Codex.cs` 在超时/取消路径中复用了已取消 `ct` 导致 `DenialGuard` 清理与 `review_completed` 审计失败的问题，改为独立 500ms CTS。
  - `NativeGuardian.cs` 在未提交到原生宿主前的预检失败分支避免误杀健康宿主进程；`main.rs` 补充可选 `conversation_id` 以随跨会话轮换回收旧作用域槽位，并在 `account_changed` / `store_unavailable`（`to_ascii_lowercase().contains("account changed")` 大小写无关判定）时递增所有权代数并排空所有活跃父会话。
- **凭据探测、零 CLI 与日志压缩**：
  - `EnvironmentDiscovery.cs` 在 `approval.json` 尚未安装时回退至同级 `..\native\ag-guardian-host.exe`；`ProbeNativeAuth` 与 `NativeGuardian` 一并剥离 `CODEX_ACCESS_TOKEN`、`OPENAI_API_KEY`、`CODEX_API_KEY`、`CODEX_AUTH_TOKEN` 及测试重放变量；Windows 探测超时放宽至 12s（C#）/ 18s（Panel）。
  - `native/guardian-host/src/main.rs` 在 `arg0_dispatch_or_else` 之前同步处理 `--version` 与轻量 `--check-auth`，消除沙箱受限环境下的 `os error 5` stderr 噪音。
  - `UsageStats.cs` 重写 `LogCompactor.Compact`：增加跨进程 `.compact.lock` 排他锁、清理中断残留临时文件、跳过当天 UTC 活跃日志段、对锁定分组整组跳过并支持回滚，消除 `.compacted.jsonl` 重复累加。
- **面板自修复、安装更新与冷启动回滚稳定性**：
  - `AgApproval.Panel` 在内部运行「安装 / 修复插件」时先将 bundle 暂存至 `updates\repair-*` 并以系统目录脱离启动 `Install.ps1` 后退出，避免目录替换自锁；修复外置启动时工作目录占用；`Install.ps1` 空 `AntigravityPath` 回退检查默认配置路径下运行中的 Antigravity 并同步停止 `GravitySteward`；`Apply-Update.ps1` 在重启面板时透传 `--gemini-root`。
  - 修复高负载冷启动下回滚校验超前失败：`Program.cs` `EnsureAsync` 等待上限提升至 40 次轮询，`Install.ps1` / `Apply-Update.ps1` 启动与回滚 `WaitForExit` 放宽至 30s、补全超时终止清理与 `$null -ne ExitCode` 保护及日志换行。
  - `Review-Mode.ps1` 修复存量配置升级缺失字段回填；`Package.ps1` 补齐顶层 `Resolve-Runtime.ps1` 并将临时 stage 清理移至外层 `finally`。
- **全仓版本统一与体积优化**：
  - 统一 `plugin/plugin.json`、`src/AgApproval/AgApproval.csproj`、`src/AgApproval.Panel/version.h`、`src/AgApproval.Panel/panel.manifest`（`0.6.5.0`）与 `native/guardian-host/Cargo.toml`（`0.6.5`），并在 `Build.ps1` 与 `Update-Local.ps1` 强制五方校验。
  - `native/SOURCE.json` Release 默认调优切换为 `ThinSize`（`OPT_LEVEL="s"`、`CODEGEN_UNITS="16"`、`LTO="thin"`、`STRIP="symbols"`、`DEBUG="0"`、`PANIC="unwind"`）。

### 自动化验证与构建产物（ThinSize Release）

- **桥接与核心测试（`Build.ps1`）**：**92/92 项** C# 单元测试全部通过（含超时清理、UI/规划委派、预算归因、`conversationId`、日志锁、凭据变量剥离与旁路探测）。
- **Schema 与统计（`Build.ps1`）**：`Validate-Schema.mjs`（实际契约与伪造角色拒绝）及 `Test-LogStatistics.ps1` 全部通过；`Check-PublicHygiene.ps1` 扫描 120 份源文件 **0 违规**。
- **Win32 面板（`Build-Panel.ps1`）**：`/W4 /WX` 零警告通过，仅依赖系统 DLL，`539,648` 字节（`527 KB`），4 项面板自测全部通过。
- **Rust 原生宿主离线测试（`Test-NativePrompt.mjs --release`）**：**9/9 项** Release 单元测试通过（用时 `0.80s`），覆盖两轮 `TrunkNew` → `TrunkReused`、12 条用户记录 + 长正文 + `toolDefinitions: 0`（四轮延迟 `75.8–142.5 ms`）、以及超大动作 + 小授权仅归因 `native_action_budget_exceeded` 且零推理提交。
- **安装、分发与无 CLI 追踪**：`Test-Distributions.ps1` 全部通过（Standalone/Lite 洁净安装、缺失运行时拦截、双向切换、Lite 修复、损坏 Guardian 预检拦截、健康检查失败自动回滚并保留日志与长期授权）；`Test-NoCli.ps1` 捕获 **99 次**子进程启动（含 Guardian 8 次、Panel 2 次），**0 次** `codex.exe` 启动。
- **产物校验**：
  - `ag-guardian-host.exe`：`143,182,336` 字节（约 `136.55 MiB`），SHA-256 `51ab9d27ce6c6bc4cf4255cf61dda3a84600e139af333011f534f5414261bb86`（`ThinSize`）。
  - 分发包为 `gravity-steward-0.6.5-windows-x64.zip`（Standalone）与 `gravity-steward-0.6.5-lite-windows-x64.zip`（Lite），精确哈希见发布目录 `checksums.sha256` 与 `release-manifest.json`。

### 与本地保留的 0.6.0 基线比较

| 项目 | 0.6.0 基线 | 0.6.5 当前状态 |
| --- | --- | --- |
| 基础产品功能 | 已有原生审核、面板、托盘、统计、日志开关与事务升级 | 在此基础上修复长会话、压缩锁、回滚与界面自修复 |
| Codex 内核 | 0.166.0 | 0.172.0（完整保留上游 crate 与 `rusty_v8`，启用弹性预算） |
| 项目长期授权 | 该基线未包含后续的长期授权管理功能 | 支持跨聊天保存、查看和撤销已确认范围 |
| 安装与登录流程 | 探测和配置中包含 Codex CLI | 统一使用 Native Guardian，运行插件无需安装 CLI |
| 面板操作 | 已有安装、统计和更新 | 增加完整卸载、插件接管热开关与内部自修复暂存重启 |
| 发行类型 | 单一 Windows ZIP | 提供 Standalone 和 Lite 双资产发行与互换 |
| 原生宿主 EXE | 220,675,072 字节（约 210.45 MiB） | 143,182,336 字节（约 136.55 MiB），减少约 35.1% |
| 发布优化 | `opt-level=2`、`LTO=false`、`16` 单元 | `ThinSize`（`opt-level=s`、`ThinLTO`、`16` 单元、剥离符号） |

### 待发布前人工实机复验清单

本轮 `ThinSize` 修复构建尚未在联网真机或 GUI 界面中手动执行以下 4 项验证，建议发布至 GitHub 前逐一确认：
1. 运行 1 次真实在线 `ThinSize` 模型审核，确认联网推理与响应解析端到端正常；
2. 在未安装 Codex CLI 的干净 Windows 用户账户下通过 Codex Desktop 登录并复测 Keyring 凭据探测；
3. 实机验证多账号切换（`A → B → A`）及审核中途换号时原生宿主会话隔离与清理；
4. 在已安装的 `GravitySteward.exe` 面板界面内实际点击「安装 / 修复插件」，确认暂存重启动作顺畅完成。

## 0.6.4

- 支持 Standalone 与 Lite 两种 Windows 发行类型及对应更新资产。
- 发布 Guardian 采用已验收的 ThinLTO、单代码生成单元参数，缩小宿主体积。
- 补充双向切换、旧版升级、错误校验值拒绝和故障回滚的验证。
- 同一候选版本阶段升级到 Codex 0.172.0，启用同步弹性预算，完成 CLI 解耦并增加插件接管热开关。0.6.5 继续修复该升级的授权适配问题。

## 0.6.3

- 锁定随包的单一微软 .NET 10.0.15 运行时。
- 增加发布文件清单、体积和 SHA-256 校验，修正运行时目录过量复制问题。

## 0.6.2

- 面板发行版接入项目长期授权管理。
- 增加完整卸载和配置恢复流程。

## 0.6.1

- Gravity Steward 首个公开版本，提供原生 Guardian 审核、托盘面板、用量记录和更新流程。
- 记录上下文精简及零推理和缺失用量的区分。

## 0.6.0 · 本地旧基线

- 原生 Win32 面板与系统托盘。
- Antigravity 和 Codex CLI 环境探测。
- 本地自然日统计与成本折算。
- 详细日志热开关及清理。
- 基于 SHA-256 校验的更新与事务回滚。
