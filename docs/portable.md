# Gravity Guardian 免安装版

将 Portable ZIP 完整解压到本机可写文件夹，打开 `GravityGuardian.exe`。完全退出 Antigravity 后，点击“连接 / 修复连接”，再重新打开 Antigravity。

程序保存在 `app/`，插件设置保存在 `config/`，审批日志和统计保存在 `data/`。免安装版自带 .NET 运行时，沿用本机已有的 Codex 登录，不需要安装 Codex CLI 来运行审批。

连接时只在 Antigravity 的插件目录登记调用入口。已有安装版的设置和审批日志会复制到当前目录，旧数据保留；切换前请等待当前任务完成并完全退出 Antigravity。

更新保留 `config/` 和 `data/`。在面板点击“断开连接”会停止服务并移除登记，设置和日志继续保留。完全退出程序后可自行删除解压文件夹。

从免安装版切换到安装版：完全退出 Antigravity → 在免安装版面板点击“断开连接” → 确认面板退出 → 打开安装版完成安装。关闭窗口只是隐藏，退出托盘也不会移除连接登记。原免安装目录可保留为备份；安装版不会自动合并其中的历史数据。

也可以在解压目录运行以下命令，`-PlanOnly` 仅预览连接变更：

```powershell
.\app\scripts\Install.ps1 -PlanOnly
.\app\scripts\Install.ps1
.\app\scripts\Doctor.ps1
.\app\scripts\Uninstall.ps1
```

不要在 Antigravity 运行期间手动覆盖程序文件。自定义计价写入 `config/pricing.json`；未定制时使用随版本更新的默认计价。
