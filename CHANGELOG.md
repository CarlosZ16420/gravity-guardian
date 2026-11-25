# 变更记录

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
