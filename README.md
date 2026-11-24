<div align="center">

# Gravity Steward

**让 Codex 审核 Antigravity 的工具请求。**

Codex-powered tool approvals for Antigravity on Windows.

![Windows x64](https://img.shields.io/badge/Windows-x64-2558a8?style=flat-square)
![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-26735d?style=flat-square)

**[下载 Windows 版](https://github.com/CarlosZ16420/gravity-steward/releases/latest)** · [English](README.en.md) · [反馈问题](https://github.com/CarlosZ16420/gravity-steward/issues)

[快速开始](#快速开始) · [功能介绍](#功能介绍) · [开发与开源](#开发与开源) · [友链](#友链)

</div>

当 Antigravity 请求运行命令或修改文件时，Gravity Steward 可以把请求交给 Codex Guardian 审核。Antigravity 仍负责执行，并保留你设置的显式允许、询问和拒绝规则。

## 快速开始

1. 在 Windows x64 上打开过一次 Antigravity，并登录可使用审核模型的 Codex 账号。
2. 从 [Releases](https://github.com/CarlosZ16420/gravity-steward/releases/latest) 下载 `gravity-steward-*-windows-x64.zip`，完整解压到可写目录。
3. 完全退出 Antigravity，运行 `GravitySteward.exe`。确认面板识别到了 Antigravity 和 Codex，点击「安装 / 修复插件」，然后重新启动 Antigravity。

Windows 包自带 .NET 运行时。下载后可对照同页的 `checksums.sha256` 核对 ZIP。升级前先退出 Antigravity，卸载可运行包内的 `scripts/Uninstall.ps1`。

## 功能介绍

- **工具审批**。用 Codex Guardian 审核需要判断的请求，把拒绝原因反馈给 Antigravity。经过校验的部分只读请求交由 Antigravity 原生规则处理。
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
