# Gravity Guardian Windows 打包与验收手册

从仓库根目录执行。每次发布用同一提交生成 Standalone、Lite 和 Portable，核对三个 ZIP 后再准备发布草稿。常规版本沿用已验收的 Rust 参数和锁定的 .NET 运行时。

> 日常本地开发与验证无需打包 ZIP，请使用 `.\scripts\Update-Local.ps1`（自动复用 Guardian 并按改动组件构建后直接更新本机；涉及 Rust 调试可使用 `-Components Guardian -GuardianProfile Dev` 与 `node .\scripts\Test-NativePrompt.mjs .local\prompt-dev --dev`）。`Package.ps1` 会校验 `artifacts/gravity-guardian/native/SOURCE.json` 必须为 `Release` 构建，防止误将 Dev 产物打包发布。

## 1. 准备版本与构建环境

1. 在 Windows x64 上准备 PowerShell 7、Git、Node.js 22+、.NET 10 SDK、Rust stable 和带 x64 C++ 工具的 Visual Studio 2022 Build Tools。首次构建需要访问已锁定的上游源码、依赖与运行时下载站。
2. 将 `plugin/plugin.json`、`src/AgApproval/AgApproval.csproj`、`src/AgApproval.Panel/version.h`、`src/AgApproval.Panel/panel.manifest` 和 `native/guardian-host/Cargo.toml` 更新为同一个三段（manifest 为四段 `.0`）版本号。在 `docs/release-<版本>.md` 写入发布说明。构建脚本会核对这五处版本和面板 EXE 的产品版本。
3. 记录准备发布的提交 SHA。保留上一可用版本的 ZIP 和校验值，供测试升级与回退。构建目录与验收目录使用较短的路径并留足磁盘空间。
4. 升级 Codex 时，按 `native/SOURCE.json` 更新锁定的上游来源并核对现有 Guardian 入口补丁。更换内置 .NET 时，在 `scripts/dotnet-runtime.lock.json` 同步更新微软 Windows x64 运行时的版本、下载 URL 和 SHA-256。

## 2. 构建并生成三种分发包

用 PowerShell 7 按顺序执行。任一步抛错时，修复后从该步继续。修改构建输入后，从构建重新开始。

推荐统一入口，它会在重型 Rust 编译前完成版本、发布说明、脚本语法、源码卫生、产物扫描器回归、C#、Schema 与日志测试，再构建一次并完成所有分发验收：

```powershell
.\scripts\Run-Release.ps1 -EvidenceDirectory .local/release-checks/current
# 同一份源码被中断后续跑；已通过阶段和未改变的附件不会重做
.\scripts\Run-Release.ps1 -EvidenceDirectory .local/release-checks/current -Resume
# 日常快速检查，不编 Rust、不打 ZIP
.\scripts\Run-Release.ps1 -PreflightOnly
```

先定稿版本和发布说明并提交，再开始正式构建。源码、构建参数或已检查附件发生变化时，使用新的证据目录；不能复用旧验收记录。每步通过后会立即记录阶段耗时与附件哈希，完整通过后生成 `artifacts/release-acceptance.json`，供发布脚本校验。以下单步命令保留用于定位问题；使用统一入口后不必重复执行。

```powershell
$ErrorActionPreference = 'Stop'
.\scripts\Build.ps1
.\scripts\Test-Installation.ps1
.\scripts\Package.ps1
.\scripts\Test-Update.ps1
.\scripts\Test-Distributions.ps1
$manifest = Get-Content artifacts/release-manifest.json -Raw | ConvertFrom-Json
.\scripts\Test-Portable.ps1 -PackageZip (Join-Path artifacts $manifest.distributions.portable.assetName)
```

有上一版同插件身份的可用包时，把 `Test-Distributions.ps1` 替换为以下命令。测试会先安装上一版，再用**本次新版更新器**升级并验证服务与 Hook；随后仍执行 Portable 验收。

```powershell
$previous = 'C:\release-inputs\gravity-guardian-0.6.5-windows-x64.zip'
.\scripts\Test-Distributions.ps1 -PreviousPackage $previous
```

若从 CI 取包，选择与发布提交 SHA 相同且结果成功的 Windows 构建，下载 `gravity-guardian-windows-x64` 构建产物。[Windows 构建工作流](../.github/workflows/release.yml)

## 3. 核对产物与运行结果

| 产物 | 核验内容 |
| --- | --- |
| `gravity-guardian-<版本>-windows-x64.zip` | Standalone。带 `runtime/dotnet.exe` 和锁定的单一 x64 .NET 10.0.x。 |
| `gravity-guardian-<版本>-lite-windows-x64.zip` | Lite。包内没有 `runtime/`。安装器会运行系统 x64 `dotnet.exe`，确认有可用的 .NET 10。 |
| `gravity-guardian-<版本>-portable-windows-x64.zip` | Portable。自带同一 .NET 和 Guardian，根面板与脚本各一份；使用中在根目录生成 `config/` 和 `data/`，宿主仅登记入口。 |
| `release-manifest.json` | 顶层资产指向 Standalone。`distributions` 分别记录三包的文件名、URL、字节数和 SHA-256。 |
| `checksums.sha256` | 三条 ZIP 校验值与发布清单一致。 |
| `release-build-info.json` | 审计留档。记录三包的文件清单、总大小、运行时版本和 Guardian 哈希。 |
| `release-acceptance.json` | 统一入口的完整验收记录，绑定提交、构建输入、阶段结果与六个附件哈希；不放进用户 ZIP。 |

`Package.ps1` 会重新读取三个 ZIP 并逐文件校验，检查无 PDB、ZIP 不超过 120 MiB、解压不超过 310 MiB，以及三包的 Guardian 哈希一致。Portable 的 ZIP 与解压程序均不得超过同批 Standalone；另保存改造前后的同条件体积对照。下载后可用 `Get-FileHash -Algorithm SHA256` 再核对。保留包清单、校验值和对应的验收日志。

在隔离测试目录确认 Standalone 可以启动，Lite 有系统 .NET 时可以安装，缺少时在变更安装前给出提示。使用新版更新器验证两种资产、同类型更新、双向切换和三类 Hook。坏 SHA-256 和失效的 Guardian 必须在停止旧服务前被拒绝。新服务健康检查失败时，应恢复旧服务、配置和 Hook，并保留审批日志。

Guardian 上游、Rust 编译参数或审核链路变化时，追加离线零工具及大动作测试，并用测试账号运行真实审核。用同一个请求 ID 核对 `native_guardian`、推理次数和最终 Hook 决策。涉及认证的变更还需验证退出登录与换号。账号或环境缺失时，在该版本的验收记录里列明未覆盖项。以下命令的输出路径在每次运行时应使用新目录。

```powershell
node .\scripts\Test-NativePrompt.mjs .local\prompt-release
.\scripts\Test-NoCli.ps1 -OutputDirectory .local\no-cli-release
```

## 4. 发布与回退

### 本地构建与云端构建

两种方式使用相同的 `Run-Release.ps1`、`Build.ps1`、`Package.ps1` 和验收脚本。普通 `main` 推送和 PR 只做快速预检及服务回归，方便先同步源码供审阅。完整云端构建需手动运行 `Windows build`，或执行 `gh workflow run release.yml --ref main`；成功后下载 `gravity-guardian-windows-x64` 产物。本地执行统一入口后使用 `artifacts/` 中的同一套附件。

云端会缓存 Cargo 公开依赖、锁定上游/V8 源码、Rust 编译目录、经过指纹和哈希校验的 Guardian 与测试程序以及锁定运行时下载。缓存按编译器、Windows 镜像、编译参数、上游来源和本项目原生源码区分；源码改变可复用兼容依赖，程序不匹配会重建。只有可信 `main` 手动任务写缓存，凭据、安装设置和测试数据不缓存。首次填充、缓存被清理或工具链升级时仍可能需要冷编译。

原生验收仍执行全部测试，并复用正式优化依赖；仅测试程序自身使用较低优化级别，保留依赖所需的 LTO 链接。测试程序按源码、锁文件、编译器与参数校验后复用，测试结果本身不会作为跨构建跳过的依据。正式 EXE 的 ThinSize、ThinLTO、完整内核与 V8 保持不变。

正式构建会统一映射 Rust、C/C++ 与 C# 的编译路径；发布包的 `native/SOURCE.json` 只保留中性的构建目录。`Package.ps1` 会扫描实际分发文件中的本机工作区、用户目录和 Cargo 目录（含二进制、UTF-16 和 JSON 转义形式），通过后才生成 ZIP 与校验清单。源码卫生检查和产物检查是两道独立门禁。旧 Guardian 缓存若未启用路径映射，需重新执行正式构建，不能直接打包。

本地完整构建位置仅保留在 `.local/` 的构建缓存与日志中。禁止通过修改已编译二进制或跳过产物扫描来发布。两种方式均使用下面的 Release 草稿、附件校验与公开流程。

在 GitHub Releases 为已验收提交准备对应的 `v<版本>` 草稿，附上三个 ZIP、`checksums.sha256` 和 `release-manifest.json`，使用该版本的发布说明。核对远端附件名称、大小和 SHA-256 与本地验收产物一致后再公开。GitHub Actions 会归档产物，发布草稿单独处理。

可用同一个发布脚本处理本地产物或下载的云端产物。默认只准备并核验草稿，`-Publish` 才公开；脚本按 REST ID 查询草稿，支持续传，拒绝修改已发布的版本：

```powershell
.\scripts\Publish-Release.ps1 -Directory artifacts -ValidateOnly
.\scripts\Publish-Release.ps1 -Directory artifacts             # 草稿与附件校验
.\scripts\Publish-Release.ps1 -Directory artifacts -Publish    # 校验后公开
# 云端完整构建、验收并发布；请先提交新版本及发布说明
gh workflow run release.yml --ref main -f publish_release=true
```

另一个仓库可通过 `-Repository owner/repository` 上传同一套附件，无需重新编译或打包。验收记录必须来自已提交的干净源码，附件被修改会在上传前被拒绝。此流程不会替换已有 Release 的附件。

遇到升级故障，先备份升级后新增的日志。使用上一次更新备份恢复插件、配置及安装元数据，确认旧服务运行并复验 PreToolUse。

## 5. 常见问题

| 现象 | 处理方式 |
| --- | --- |
| 编译或解压时磁盘空间不足 | 检查工作盘和临时盘。Rust 可把 `CARGO_TARGET_DIR` 指向空间充足的短路径。验收脚本的 `-OutputDirectory` 可将解包和测试安装放到其他磁盘。保留通过验收的 ZIP 和证据，清理已经结束的临时构建和测试目录。 |
| 从解包目录启动 Guardian 失败 | 检查完整路径长度。新版事务会从较短的暂存目录启动 Guardian 做预检。必要时将验收根目录移到更短的位置，再跑相同的检查。 |
| Lite 报告缺少 .NET | 安装 Windows x64 .NET 10 Runtime，可运行 `winget install Microsoft.DotNet.Runtime.10 --architecture x64`，然后让安装器重新探测。 |
| Rust 优化后包变大 | 保持同一锁定提交和目标，使用 `Measure-GuardianBuild.ps1 -Tuning <配置>` 对照。比较 EXE 与 ZIP、冷构建耗时、内存和审核延迟后，再修改 `native/SOURCE.json`。 |
| 更新后版本或 SHA-256 不一致 | 按 Git 提交从同一次构建重新取包、清单和校验值，再验收。 |

0.6.4 的实测参数与体积见[构建与双包验收记录](guardian-build-and-distributions-0.6.4.md)。
