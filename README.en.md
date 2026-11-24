# Gravity Steward

**Codex-powered tool approvals for Antigravity on Windows.**

Gravity Steward uses Codex Guardian to review Antigravity tool requests. Antigravity executes approved actions and continues to enforce your explicit permission rules. The tray panel shows review outcomes, token usage, and configurable cost estimates.

[Download for Windows](https://github.com/CarlosZ16420/gravity-steward/releases/latest) · [中文](README.md) · [Report an issue](https://github.com/CarlosZ16420/gravity-steward/issues)

## Quick start

1. Open Antigravity at least once on Windows x64 and sign in to a Codex account with access to the review model.
2. Download and fully extract the Windows ZIP. Verify it against the accompanying `checksums.sha256`.
3. Exit Antigravity. Run `GravitySteward.exe`, choose the install or repair option (「安装 / 修复插件」), then reopen Antigravity.

The Windows package bundles the .NET runtime. The panel UI is in Simplified Chinese. Detailed logging is off by default. When enabled, local logs may include paths, conversation content, and tool arguments. Model reviews send the context required for review to Codex.

## Build from source

Use Windows x64 with PowerShell 7, the .NET 10 SDK, Node.js 22+, stable Rust, and MSVC C++ build tools. Run `./scripts/Build.ps1` to build and test the project.

Gravity Steward is an independent open-source project. See [Apache-2.0](LICENSE) and [NOTICE](NOTICE).

## Community

- [LINUX DO](https://linux.do/)
