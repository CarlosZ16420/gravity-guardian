# Gravity Steward

**Tool approvals for Antigravity on Windows via Codex CLI.**

Gravity Steward integrates with your local Codex CLI. When CLI review is enabled, Gravity Steward uses Codex CLI to call the `codex-auto-review` model for Antigravity tool requests. Antigravity executes approved actions and continues to enforce your explicit permission rules. The tray panel shows review outcomes, token usage, and configurable cost estimates.

[Download for Windows](https://github.com/CarlosZ16420/gravity-steward/releases/latest) · [中文](README.md) · [Report an issue](https://github.com/CarlosZ16420/gravity-steward/issues)

## Quick start

1. Open Antigravity at least once on Windows x64. Install Codex CLI and sign in to Codex CLI (`codex login`) with an account that can use the `codex-auto-review` model.
2. Download and fully extract the Windows ZIP. Verify it against the accompanying `checksums.sha256`.
3. Fully exit Antigravity. In PowerShell, run `.\scripts\Install.ps1 -ReviewerBackend Cli` from the extracted folder to enable Codex CLI review, then reopen Antigravity.

Run `GravitySteward.exe` to open the panel and view review results. The panel's install or repair option (「安装 / 修复插件」) defaults to Native Guardian for reviews and uses the Codex CLI sign-in.

The Windows package bundles the .NET runtime. The panel UI is in Simplified Chinese. Detailed logging is off by default. When enabled, local logs may include paths, conversation content, and tool arguments. Model reviews send the context required for review to Codex.

To uninstall, fully exit Antigravity and choose 「完整卸载」 in the panel. This removes the installed plugin and its startup entry and permanently deletes local logs, statistics, settings, caches, and backups. You can also run `scripts/Uninstall.ps1 -PurgeData` from the package. You can delete the downloaded ZIP and extracted folder separately.

## Build from source

Use Windows x64 with PowerShell 7, the .NET 10 SDK, Node.js 22+, stable Rust, and MSVC C++ build tools. Run `./scripts/Build.ps1` to build and test the project.

Gravity Steward is an independent open-source project. See [Apache-2.0](LICENSE) and [NOTICE](NOTICE).

## Community

- [LINUX DO](https://linux.do/)
