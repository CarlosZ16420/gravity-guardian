<div align="center">
<img src="src/AgApproval.Panel/assets/icon.svg" alt="Gravity Guardian icon" width="88">

# Gravity Guardian

### Informed approvals. Fewer interruptions.

A tool approval assistant for Antigravity on Windows.<br>
Built-in Codex Native Guardian reviews requests, explains decisions, and tracks usage.

![Source version](https://img.shields.io/badge/source-0.6.8-0071e3?style=flat-square)
![Windows x64](https://img.shields.io/badge/Windows-x64-172a47?style=flat-square)
![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-26735d?style=flat-square)

**[Download for Windows](https://github.com/CarlosZ16420/gravity-guardian/releases/latest)** · [Simplified Chinese](README.zh-CN.md) · [Report an issue](https://github.com/CarlosZ16420/gravity-guardian/issues)

[Quick start](#quick-start) · [Features](#features) · [Common questions](#common-questions) · [Development and license](#development-and-license)

</div>

Guardian reviews Antigravity tool requests using your instructions and project rules. Antigravity then executes approved actions while enforcing its native permission controls. **No separate Codex CLI installation is needed to run the plugin.**

> This guide describes the **0.6.8 source**. Available downloads are listed in [Releases](https://github.com/CarlosZ16420/gravity-guardian/releases/latest); follow the matching release instructions for older versions.

The panel UI is currently in Simplified Chinese. Button and menu names below are English translations of the labels shown in the app. [View the approval overview screenshot](assets/readme/panel-showcase.zh-CN.png) (Simplified Chinese UI; sample statistics and status).

## Quick start

1. Open Antigravity at least once on Windows x64. Sign in to Codex under the same Windows user account, using a Codex account with access to `codex-auto-review`.
2. Download a release ZIP and **fully extract it to a writable folder**. Exit Antigravity, then open `GravityGuardian.exe`.
3. In Portable, choose **Connect / Repair Connection**. In Standalone or Lite, choose **Install / Repair Plugin**. Reopen Antigravity when setup is complete.

Version 0.6.8 supports three editions with the same review engine:

| Edition | How to choose |
| --- | --- |
| **Portable** · ZIP name contains `-portable-` | Bundles the runtime; keeps the program, settings, and approval data in the extracted folder for easy backup. |
| **Standalone** · ZIP name has no edition suffix | Bundles the runtime; installs the plugin and stores its data in the current user's profile. |
| **Lite** · ZIP name contains `-lite-` | Uses an existing x64 .NET 10 runtime; otherwise works like Standalone. |

Verify the ZIP against `checksums.sha256` on the same release page. If Lite needs the runtime, install it with `winget install Microsoft.DotNet.Runtime.10 --architecture x64`. Fully exit Antigravity before connecting, switching editions, or upgrading. See the [portable guide](docs/portable.md) (Simplified Chinese).

[View the Portable panel screenshot](assets/readme/portable-showcase.zh-CN.png) (Simplified Chinese UI; sample statistics and status).

## Features

| What you need | How Guardian helps |
| --- | --- |
| **Reviews that use context** | `codex-auto-review` evaluates tool requests and returns decisions and denial reasons to Antigravity. |
| **A way to confirm explicitly authorized actions** | By default, when Guardian denies a request it classifies as having high user authorization, it asks you to decide through Antigravity's native confirmation prompt. |
| **A way to pause plugin review** | Use the tray panel switch to return new requests to Antigravity's native permission rules. |
| **Clear approval usage** | View approval statistics, input and output tokens, cache hit rate, and estimated costs for today, the past seven days, or a custom date range. |
| **Central controls** | Install or repair the plugin, check credentials, manage logs, delegate reviews for protected directories, and verify update packages. |

Reviews send the required context to Codex services. Detailed logs are off by default; when enabled, they are saved locally and may contain paths, conversation content, and tool arguments. Costs are configurable estimates.

## Common questions

<details>
<summary>Is signing in to Codex enough?</summary>

Your account must also have access to `codex-auto-review`. In the panel, use **Approval Account > Check** to check local credentials; finding credentials does not guarantee access to the model. See the [validation record](docs/guardian-0.172.0-validation.md) (Simplified Chinese) for supported sign-in configurations.

</details>

<details>
<summary>How do I update or uninstall it?</summary>

The panel can check for updates, download update packages, and verify them. Upgrades preserve settings and approval history. To switch editions manually, fully extract the target ZIP, then install or connect from the new folder.

In Portable, **Disconnect** removes the Antigravity registration and keeps the data in the Portable folder. Exit the related programs before deleting that folder. In Standalone or Lite, **Full Uninstall** removes the plugin and startup entry, and permanently deletes local approval logs, statistics, settings, caches, and backups. Fully exit Antigravity before either operation.

To switch from Portable to an installed edition: exit Antigravity, choose **Disconnect** in Portable, confirm that the panel has exited, then open the installed edition. Closing the window or exiting the tray does not disconnect Portable. You can keep the Portable folder as a backup; its history is not automatically merged into the installed edition.

</details>

## Development and license

Building requires Windows x64, PowerShell 7, the .NET 10 SDK, Node.js 22+, stable Rust, and the MSVC C++ build tools.

```powershell
.\scripts\Update-Local.ps1 -BuildOnly   # Incremental build without local installation
```

[Build and release validation](docs/packaging-runbook.md) (Simplified Chinese) · [Changelog](CHANGELOG.md) (Simplified Chinese) · [Apache-2.0](LICENSE) · [Third-party notices](NOTICE)

Gravity Guardian is an independent open-source project. When reporting an issue, include the version, steps to reproduce it, and error messages. Remove private paths, credentials, and raw conversation content.

## Community

- [LINUX DO](https://linux.do/)
- [Hamster Archiver](https://github.com/CarlosZ16420/hamster-archiver)
- [Data Traffic Ledger](https://github.com/CarlosZ16420/DataTrafficLedger)
