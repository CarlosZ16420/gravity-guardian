# Gravity Steward Native Guardian 候选版发布说明

本候选版基于 0.6.3。Windows x64 安装包自带基于上游 0.172.0 的 Native Guardian。它负责审核 Antigravity 的工具请求，并可处理超出旧预算的大写入和编辑。

安装、修复和更新统一使用 Native Guardian。旧 CLI 审核配置会迁移，历史审批和用量统计仍可查看。更新前请完全退出 Antigravity。

托盘面板新增「插件接管」热开关。关闭后，新请求立即回到 Antigravity 原生权限规则。修复和更新会保留该设置。

### 已验证的登录组合

- 在当前 Windows 用户下，Guardian 使用文件凭据完成了探测和真实模型审核。
- 隔离安装使用测试文件凭据验证了面板、诊断脚本和已安装的 Guardian。

全新 Windows 用户仅通过桌面端登录，以及真实 A→B→A 和审核中途切号，均未做实机验收。具体测试结果见[验收记录](guardian-0.172.0-validation.md)。
