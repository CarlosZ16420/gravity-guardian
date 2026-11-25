# Gravity Guardian

**Tool approvals for Antigravity on Windows via the bundled Native Guardian.**

Gravity Guardian ships a bundled Codex Native Guardian host, which calls the `codex-auto-review` model for Antigravity tool requests. Antigravity executes approved actions and enforces your explicit permission rules. When Guardian denies an action despite `user_authorization = high`, the hook escalates to Antigravity's native confirmation prompt (`force_ask`, configurable via `escalateAuthorizedDenials`). The tray panel shows review outcomes, token usage, and configurable cost estimates. A separate Codex CLI installation is unnecessary.

[Download for Windows](https://github.com/CarlosZ16420/gravity-guardian/releases/latest) · [中文](README.md) · [Report an issue](https://github.com/CarlosZ16420/gravity-guardian/issues)

## Quick start

1. Open Antigravity at least once on Windows x64. Sign in to Codex as the same Windows user with an account that can use the `codex-auto-review` model.
2. Download and fully extract the Windows ZIP. Verify it against the accompanying `checksums.sha256`.
3. Fully exit Antigravity. In PowerShell, run `.\scripts\Install.ps1` from the extracted folder, then reopen Antigravity.

Run `GravityGuardian.exe` to install or repair the plugin (「安装 / 修复插件」), view review results, or check local credentials under 「Guardian 登录」. Upgrades migrate old CLI reviewer settings to Guardian and preserve custom credential directories and historical review statistics. The [validation record](docs/guardian-0.172.0-validation.md) covers tested credential setups.

Standalone keeps the original ZIP name and bundles the x64 .NET 10 runtime. Lite has `-lite-` in its ZIP name and uses the installed x64 .NET 10 runtime. You can install it with `winget install Microsoft.DotNet.Runtime.10 --architecture x64`. To switch editions, extract the desired ZIP and run Install / Repair from that folder. The panel UI is in Simplified Chinese. Detailed logging is off by default. When enabled, local logs may include paths, conversation content, and tool arguments. Model reviews send the context required for review to Codex.

Use the tray panel's takeover switch to pause Gravity Guardian for new requests and let Antigravity apply its native permission rules. Repairs and updates preserve the switch setting.

To uninstall, fully exit Antigravity and choose 「完整卸载」 in the panel. This removes the installed plugin and its startup entry and permanently deletes local logs, statistics, settings, caches, and backups. You can also run `scripts/Uninstall.ps1 -PurgeData` from the package. You can delete the downloaded ZIP and extracted folder separately.

## Build from source

Upgrading from Gravity Steward requires removing the old plugin first with the **old** package's `scripts/Uninstall.ps1` **without** `-PurgeData`, then installing the new ZIP. Exit Antigravity and the old panel first. To retain historical logs, pass the original data directory to the new installer with `-DataDirectory`. Old installation settings are not automatically migrated; review them in the new panel. See the [0.6.6 release notes](docs/release-0.6.6.md).

Use Windows x64 with PowerShell 7, the .NET 10 SDK, Node.js 22+, stable Rust, and MSVC C++ build tools. Run `./scripts/Build.ps1`, then `./scripts/Package.ps1` to build both editions and `./scripts/Test-Distributions.ps1` to verify installation and updates.

Gravity Guardian is an independent open-source project. See [Apache-2.0](LICENSE) and [NOTICE](NOTICE).

## Community

- [LINUX DO](https://linux.do/)
