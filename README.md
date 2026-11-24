<div align="center">

# Gravity Steward

**通过随包提供的 Native Guardian 审核 Antigravity 的工具请求。**

Tool approvals for Antigravity on Windows via Native Guardian.

![Windows x64](https://img.shields.io/badge/Windows-x64-2558a8?style=flat-square)
![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-26735d?style=flat-square)

**[下载 Windows 版](https://github.com/CarlosZ16420/gravity-steward/releases/latest)** · [English](README.en.md) · [反馈问题](https://github.com/CarlosZ16420/gravity-steward/issues)

[快速开始](#快速开始) · [功能介绍](#功能介绍) · [开发与开源](#开发与开源) · [友链](#友链)

</div>

Gravity Steward 自带 Native Guardian，由它调用 `codex-auto-review` 模型审核 Antigravity 的工具请求。Antigravity 负责执行，并保留你设置的显式允许、询问和拒绝规则。运行插件无需安装 Codex CLI。

## 快速开始

1. 在 Windows x64 上至少打开一次 Antigravity。准备有权使用 `codex-auto-review` 的 Codex 账号，并在同一 Windows 用户下登录 Codex。
2. 从 [Releases](https://github.com/CarlosZ16420/gravity-steward/releases/latest) 下载 `gravity-steward-*-windows-x64.zip`，完整解压到可写目录。
3. 完全退出 Antigravity，在解压目录的 PowerShell 中运行 `.\scripts\Install.ps1`，然后重新打开 Antigravity。

运行 `GravitySteward.exe` 可以打开面板「安装 / 修复插件」、查看审批结果，并在「Guardian 登录」检测本机凭据。升级时，旧 CLI 审核设置会自动迁移到 Guardian，自定义凭据目录和历史审批统计会保留。支持的验证范围见[验收记录](docs/guardian-0.172.0-validation.md)。

**Standalone** 沿用原安装包文件名，自带 x64 .NET 10。**Lite** 的文件名带 `-lite-`，需要系统已安装 x64 .NET 10，可运行 `winget install Microsoft.DotNet.Runtime.10 --architecture x64` 安装。切换类型时，完整解压目标 ZIP，再从该目录运行「安装 / 修复插件」。下载后可对照同页的 `checksums.sha256` 核对 ZIP。升级或卸载前先完全退出 Antigravity。

在面板点击「完整卸载」，确认后会关闭面板，移除已安装的插件和开机启动项，并永久删除本地审批日志、统计、设置、项目长期授权、缓存和备份。也可运行包内的 `scripts/Uninstall.ps1 -PurgeData`。手动下载的 ZIP 和解压目录可自行删除。

## 功能介绍

- **工具审批**。把模型审核的拒绝原因反馈给 Antigravity。经过校验的部分只读请求交由 Antigravity 原生规则处理。
- **插件接管开关**。可在托盘面板即时切换。关闭后，新请求由 Antigravity 原生权限规则处理。修复和更新会保留开关设置。
- **项目长期授权**。在 Antigravity 聊天中保存、查看和撤销授权。同一项目的新聊天和重启后可继续使用已确认的范围。[聊天命令](plugin/README.md)
- **托盘与统计**。从面板查看今日及近 7 日的审批、用量和可配置的成本估算。
- **日志与更新**。详细日志默认关闭。启用后，日志保存在本机，可能包含路径、对话或工具参数。模型审核会向 Codex 服务发送审核所需的上下文。面板可检查 GitHub Releases 并校验更新包。

## 开发与开源

构建需要 Windows x64、PowerShell 7、.NET 10 SDK、Node.js 22+、Rust stable 和 MSVC C++ 构建工具。

版本准备、双包验收和发布步骤见 [Windows 打包与验收手册](docs/packaging-runbook.md)。

```powershell
.\scripts\Build.ps1
.\scripts\Package.ps1
.\scripts\Test-Distributions.ps1
node .\scripts\Test-NativePrompt.mjs .local\prompt-test
.\scripts\Test-NoCli.ps1 -OutputDirectory .local\no-cli-test
```

用 `Measure-GuardianBuild.ps1 -Tuning` 测量 Rust 发布配置。可选 `Baseline`、`Symbols`、`Thin`、`ThinSingleUnit` 和 `ThinSize`。依次运行，记录冷构建耗时、编译进程内存、包体占用和本机模拟审核延迟。

项目采用 [Apache-2.0](LICENSE)，上游与分发声明见 [NOTICE](NOTICE)。Gravity Steward 是独立的开源项目。

反馈问题时请附插件版本和复现步骤，并隐去私人路径、凭据及原始对话。[提交问题](https://github.com/CarlosZ16420/gravity-steward/issues)

## 友链

- [LINUX DO — 新的理想型社区](https://linux.do/)
