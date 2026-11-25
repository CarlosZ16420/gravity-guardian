# Gravity Steward Windows 打包与验收手册

从 `gravity-steward` 仓库根目录执行。每次发布用同一提交生成 Standalone 和 Lite，核对两个 ZIP 后再准备发布草稿。常规版本沿用已验收的 Rust 参数和锁定的 .NET 运行时。

> 日常本地开发与验证无需打包 ZIP，请使用 `.\scripts\Update-Local.ps1`（自动复用 Guardian 并按改动组件构建后直接更新本机；涉及 Rust 调试可使用 `-Components Guardian -GuardianProfile Dev` 与 `node .\scripts\Test-NativePrompt.mjs .local\prompt-dev --dev`）。`Package.ps1` 会校验 `artifacts/codex-approval/native/SOURCE.json` 必须为 `Release` 构建，防止误将 Dev 产物打包发布。

## 1. 准备版本与构建环境

1. 在 Windows x64 上准备 PowerShell 7、Git、Node.js 22+、.NET 10 SDK、Rust stable 和带 x64 C++ 工具的 Visual Studio 2022 Build Tools。首次构建需要访问已锁定的上游源码、依赖与运行时下载站。
2. 将 `plugin/plugin.json`、`src/AgApproval/AgApproval.csproj` 和 `src/AgApproval.Panel/version.h` 更新为同一个三段版本号。在 `docs/release-<版本>.md` 写入发布说明。构建脚本会核对三处版本和面板 EXE 的产品版本。
3. 记录准备发布的提交 SHA。保留上一可用版本的 ZIP 和校验值，供测试升级与回退。构建目录与验收目录使用较短的路径并留足磁盘空间。
4. 升级 Codex 时，按 `native/SOURCE.json` 更新锁定的上游来源并核对现有 Guardian 入口补丁。更换内置 .NET 时，在 `scripts/dotnet-runtime.lock.json` 同步更新微软 Windows x64 运行时的版本、下载 URL 和 SHA-256。

## 2. 构建并生成双包

用 PowerShell 7 按顺序执行。任一步抛错时，修复后从该步继续。修改构建输入后，从构建重新开始。

```powershell
$ErrorActionPreference = 'Stop'
.\scripts\Build.ps1
.\scripts\Test-Installation.ps1
.\scripts\Package.ps1
.\scripts\Test-Update.ps1
.\scripts\Test-Distributions.ps1
```

有上一版可用包时，把最后一条替换为以下命令。测试会先安装上一版，再用**本次新版更新器**升级并验证服务与 Hook。

```powershell
$previous = 'C:\release-inputs\gravity-steward-0.6.3-windows-x64.zip'
.\scripts\Test-Distributions.ps1 -PreviousPackage $previous
```

若从 CI 取包，选择与发布提交 SHA 相同且结果成功的 Windows 构建，下载 `gravity-steward-windows-x64` 构建产物。[Windows 构建工作流](../.github/workflows/release.yml)

## 3. 核对产物与运行结果

| 产物 | 核验内容 |
| --- | --- |
| `gravity-steward-<版本>-windows-x64.zip` | Standalone。带 `runtime/dotnet.exe` 和锁定的单一 x64 .NET 10.0.x。 |
| `gravity-steward-<版本>-lite-windows-x64.zip` | Lite。包内没有 `runtime/`。安装器会运行系统 x64 `dotnet.exe`，确认有可用的 .NET 10。 |
| `release-manifest.json` | 顶层资产指向 Standalone。`distributions` 分别记录两包的文件名、URL、字节数和 SHA-256。 |
| `checksums.sha256` | 两条 ZIP 校验值与发布清单一致。 |
| `release-build-info.json` | 审计留档。记录两包的文件清单、总大小、运行时版本和 Guardian 哈希。 |

`Package.ps1` 会重新读取两个 ZIP 并逐文件校验，检查无 PDB、ZIP 不超过 120 MiB、解压不超过 310 MiB，以及两包的 Guardian 哈希一致。下载后可用 `Get-FileHash -Algorithm SHA256` 再核对。保留包清单、校验值和对应的验收日志。

在隔离测试目录确认 Standalone 可以启动，Lite 有系统 .NET 时可以安装，缺少时在变更安装前给出提示。使用新版更新器验证两种资产、同类型更新、双向切换和四类 Hook。坏 SHA-256 和失效的 Guardian 必须在停止旧服务前被拒绝。新服务健康检查失败时，应恢复旧服务、配置和 Hook，并保留审批日志和项目授权。

Guardian 上游、Rust 编译参数或审核链路变化时，追加离线零工具及大动作测试，并用测试账号运行真实审核。用同一个请求 ID 核对 `native_guardian`、推理次数和最终 Hook 决策。涉及认证的变更还需验证退出登录与换号。账号或环境缺失时，在该版本的验收记录里列明未覆盖项。以下命令的输出路径在每次运行时应使用新目录。

```powershell
node .\scripts\Test-NativePrompt.mjs .local\prompt-release
.\scripts\Test-NoCli.ps1 -OutputDirectory .local\no-cli-release
```

## 4. 发布与回退

在 GitHub Releases 为已验收提交准备对应的 `v<版本>` 草稿，附上两个 ZIP、`checksums.sha256` 和 `release-manifest.json`，使用该版本的发布说明。核对远端附件名称、大小和 SHA-256 与本地验收产物一致后再公开。GitHub Actions 会归档产物，发布草稿单独处理。

遇到升级故障，先备份升级后新增的日志和项目授权。使用上一次更新备份恢复插件、配置及安装元数据，确认旧服务运行并复验 PreToolUse。

## 5. 常见问题

| 现象 | 处理方式 |
| --- | --- |
| 编译或解压时磁盘空间不足 | 检查工作盘和临时盘。Rust 可把 `CARGO_TARGET_DIR` 指向空间充足的短路径。验收脚本的 `-OutputDirectory` 可将解包和测试安装放到其他磁盘。保留通过验收的 ZIP 和证据，清理已经结束的临时构建和测试目录。 |
| 从解包目录启动 Guardian 失败 | 检查完整路径长度。新版事务会从较短的暂存目录启动 Guardian 做预检。必要时将验收根目录移到更短的位置，再跑相同的检查。 |
| Lite 报告缺少 .NET | 安装 Windows x64 .NET 10 Runtime，可运行 `winget install Microsoft.DotNet.Runtime.10 --architecture x64`，然后让安装器重新探测。 |
| Rust 优化后包变大 | 保持同一锁定提交和目标，使用 `Measure-GuardianBuild.ps1 -Tuning <配置>` 对照。比较 EXE 与 ZIP、冷构建耗时、内存和审核延迟后，再修改 `native/SOURCE.json`。 |
| 更新后版本或 SHA-256 不一致 | 按 Git 提交从同一次构建重新取包、清单和校验值，再验收。 |

0.6.4 的实测参数与体积见[构建与双包验收记录](guardian-build-and-distributions-0.6.4.md)。
