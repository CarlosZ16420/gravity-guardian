# Gravity Guardian v0.6.6

本版本正式将项目统一命名为 **Gravity Guardian**，移除「项目长期授权」，将"Guardian 判 `deny` 但判定用户明确授权（`user_authorization = high`）"的请求转为 Antigravity 原生人工确认（`force_ask`），并新增生命周期绑定的「受保护目录全局审核委派」。

## 改动摘要

- **品牌与底层标识统一命名为 Gravity Guardian**：
  - 对外品牌、插件 ID 与安装目录（`~/.gemini/config/plugins/gravity-guardian`）、数据目录（`~/.gemini/gravity-guardian-data`）、面板程序（`GravityGuardian.exe`）、核心服务（`gravity-guardian.dll`）、命名管道前缀（`gravity-guardian-*`）及开机启动项（`GravityGuardian`）全面统一为 Gravity Guardian。
  - 修复审核缓存前缀：当前授权放在开发者指令之后、持久历史之前，当前动作事实独立置于末尾；按每次推理输入的增量而非固定基础提示长度触发会话检查点，避免大基础提示导致每轮重建审核会话。

- **移除项目长期授权**：
  - 经过 7 天 6795 次审核日志验证，长期授权目录启用次数为 0；且该机制最多只能将授权判为 `high`，无法覆盖 `risk_level = critical` 时的强制拒绝。
  - 删除聊天授权命令、Agent 规则文件 `project-authorizations.md`、`PreInvocation` 钩子及送审输入中的 `project_authorizations` 字段与附加策略文本，送审结构恢复与上游 Codex 对齐。
  - `gravity-guardian chat` 保留一个版本作为空返回（`{}`）兼容入口；`Uninstall.ps1 -PurgeData` 仍会清理历史残留的 `project-authorizations` 目录。
- **已授权拒绝转人工确认（`escalateAuthorizedDenials`，默认 `true`）**：
  - 当 Guardian 返回 `deny` 且 `user_authorization = high` 时，插件返回 `force_ask`（`status = escalated`、`reasonCode = policy_denied_user_authorized`），在 Antigravity 原生弹窗写明风险等级与 Guardian 理由，仅在用户亲自确认后执行（不复用 Always Allow，与 Codex `thread/approveGuardianDeniedAction` 一致）。
  - 同一绑定请求重复到达时保留相同的 `force_ask` 结果；若证据或用户指令在提交前变化则仍按 `action_invalidated` 拒绝。
  - 其余 `medium` / `low` / `unknown` 授权级别的拒绝仍直接返回 `deny`。
  - 如需恢复 0.6.5 的直接拒绝行为，可在 `approval.json` 中将 `escalateAuthorizedDenials` 设为 `false` 并重启审批服务。
- **受保护目录全局审核委派（`delegateProtectedPaths`，默认 `true`）**：
  - 在审批服务运行中且接管开启期间，自动挂载受管裸段规则（`read_file(.git)`、`read_file(.cache)`、`write_file(.cache)`、`read_file(.vscode)`），消除 Antigravity 对工作区 `.cache` 读写及 `.git`/`.vscode` 只读的无来源硬编码弹窗，交由 Native Guardian 逐次审核；永久排除 `.git`/`.vscode` 写入及 `.env*`、`.npmrc`、`.ssh`，且绝不改动用户自建授权规则。
  - 暂停接管、停止/崩溃、关闭面板「偏好设置 → 受保护目录交由插件审核」开关或卸载时立即回收托管授权；关闭委派时仅对未点名的 `.git` 只读访问提示改用 `git -C` 只读命令（`host_protected_redirect`），不对 `.cache` 半途改道。
  - 移除旧提示词绕行规则 `plugin/rules/antigravity-scratch.md`。
