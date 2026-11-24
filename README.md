<div align="center">

# Gravity Steward

**通过 Codex CLI 审核 Antigravity 的工具请求。**

Tool approvals for Antigravity on Windows via Codex CLI.

![Windows x64](https://img.shields.io/badge/Windows-x64-2558a8?style=flat-square)
![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-26735d?style=flat-square)

**[下载 Windows 版](https://github.com/CarlosZ16420/gravity-steward/releases/latest)** · [English](README.en.md) · [反馈问题](https://github.com/CarlosZ16420/gravity-steward/issues)

[快速开始](#快速开始) · [功能介绍](#功能介绍) · [开发与开源](#开发与开源) · [友链](#友链)

</div>

Gravity Steward 接入本机的 Codex CLI。启用 CLI 审批后，插件通过 Codex CLI 调用 `codex-auto-review` 模型，审核 Antigravity 的工具请求。Antigravity 负责执行，并保留你设置的显式允许、询问和拒绝规则。

## 快速开始

1. 在 Windows x64 上至少打开一次 Antigravity。安装 Codex CLI，并用有权使用 `codex-auto-review` 审核模型的账号登录 Codex CLI（`codex login`）。
2. 从 [Releases](https://github.com/CarlosZ16420/gravity-steward/releases/latest) 下载 `gravity-steward-*-windows-x64.zip`，完整解压到可写目录。
3. 完全退出 Antigravity，在解压目录的 PowerShell 中运行 `.\scripts\Install.ps1 -ReviewerBackend Cli` 启用 Codex CLI 审批，然后重新打开 Antigravity。

运行 `GravitySteward.exe` 可以打开面板查看审批结果。面板的「安装 / 修复插件」默认使用 Native Guardian 审批，并复用 Codex CLI 的登录状态。

Windows 包自带 .NET 运行时。下载后可对照同页的 `checksums.sha256` 核对 ZIP。升级或卸载前先完全退出 Antigravity。

在面板点击「完整卸载」，确认后会关闭面板，移除已安装的插件和开机启动项，并永久删除本地审批日志、统计、设置、项目长期授权、缓存和备份。也可运行包内的 `scripts/Uninstall.ps1 -PurgeData`。手动下载的 ZIP 和解压目录可自行删除。

## 功能介绍

- **工具审批**。把模型审核的拒绝原因反馈给 Antigravity。经过校验的部分只读请求交由 Antigravity 原生规则处理。
- **项目长期授权**。在 Antigravity 聊天中保存、查看和撤销授权。同一项目的新聊天和重启后可继续使用已确认的范围。[聊天命令](plugin/README.md)
- **托盘与统计**。从面板查看今日及近 7 日的审批、用量和可配置的成本估算。
- **日志与更新**。详细日志默认关闭。启用后，日志保存在本机，可能包含路径、对话或工具参数。模型审核会向 Codex 服务发送审核所需的上下文。面板可检查 GitHub Releases 并校验更新包。

## 开发与开源

构建需要 Windows x64、PowerShell 7、.NET 10 SDK、Node.js 22+、Rust stable 和 MSVC C++ 构建工具。

```powershell
.\scripts\Build.ps1
.\scripts\Test-Installation.ps1
.\scripts\Test-Update.ps1
```

项目采用 [Apache-2.0](LICENSE)，上游与分发声明见 [NOTICE](NOTICE)。Gravity Steward 是独立的开源项目。

反馈问题时请附插件版本和复现步骤，并隐去私人路径、凭据及原始对话。[提交问题](https://github.com/CarlosZ16420/gravity-steward/issues)

## 友链

- [LINUX DO — 新的理想型社区](https://linux.do/)
