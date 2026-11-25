# Gravity Steward v0.6.5

详细修复、验证与构建比较见[变更记录](../CHANGELOG.md)。

修复升级到 Codex `0.172.0` 后长会话与多端联动场景下的多项审核、会话、状态与更新问题：按来源顺序分离并完整传递当前请求的用户授权与撤销记录，区分待审动作超限与授权证据超限，支持 UI 状态/规划工具精确判定委派，收紧异常清理与跨进程日志压缩锁，并统一全仓 5 处版本号为 `0.6.5` / `0.6.5.0`。

Release Guardian 宿主采用 `ThinSize` 配置（`opt-level=s`、ThinLTO、`codegen-units=16`、剥离符号），已通过 92 项 C# 桥接测试、9 项 Release Rust 离线测试（含两轮会话复用 `TrunkReused` 与超大动作归因）、Schema 与日志统计校验、Win32 面板 4 项自测、Standalone/Lite 安装升级与健康检查失败回滚验证，以及无 CLI 进程追踪测试（99 次子进程启动零 `codex.exe`）。真实在线模型审核、无 CLI Desktop 凭据环验证与面板界面实机操作仍需在发布前手动复验。

Windows x64 继续提供 Standalone 和 Lite 两种安装包。退出 Antigravity 后，从完整解压的目录运行 `GravitySteward.exe`，选择「安装 / 修复插件」。安装包的校验值见同目录的 `checksums.sha256`。
