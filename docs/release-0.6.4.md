# Gravity Steward v0.6.4

Windows x64 提供两个安装包。原有文件名的 ZIP 是 Standalone，自带锁定的 .NET 10。文件名含 lite 的 ZIP 使用系统的 x64 .NET 10 运行时，可通过 Microsoft Store 外的 Windows 包管理器安装。

```powershell
winget install Microsoft.DotNet.Runtime.10 --architecture x64
```

完整解压后打开 GravitySteward.exe 并选择「安装 / 修复插件」。要切换发行类型，退出 Antigravity，解压目标发行类型，再从那个目录执行安装或修复。更新清单的旧格式字段仍指向 Standalone。新版面板按已安装类型选择更新包。

安装包的 SHA-256 见同目录的 checksums.sha256。
