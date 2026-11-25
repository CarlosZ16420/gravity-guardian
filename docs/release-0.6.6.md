# Gravity Steward v0.6.6

本版本移除「项目长期授权」，并将"Guardian 判 `deny` 但判定用户明确授权（`user_authorization = high`）"的请求转为 Antigravity 原生人工确认（`force_ask`）。

## 改动摘要

- **移除项目长期授权**：
  - 经过 7 天 6795 次审核日志验证，长期授权目录启用次数为 0；且该机制最多只能将授权判为 `high`，无法覆盖 `risk_level = critical` 时的强制拒绝。
  - 删除聊天授权命令、Agent 规则文件 `project-authorizations.md`、`PreInvocation` 钩子及送审输入中的 `project_authorizations` 字段与附加策略文本，送审结构恢复与上游 Codex 对齐。
  - `ag-approval chat` 保留一个版本作为空返回（`{}`）兼容入口；`Uninstall.ps1 -PurgeData` 仍会清理历史残留的 `project-authorizations` 目录。
- **已授权拒绝转人工确认（`escalateAuthorizedDenials`，默认 `true`）**：
  - 当 Guardian 返回 `deny` 且 `user_authorization = high` 时，插件返回 `force_ask`（`status = escalated`、`reasonCode = policy_denied_user_authorized`），在 Antigravity 原生弹窗写明风险等级与 Guardian 理由，仅在用户亲自确认后执行（不复用 Always Allow，与 Codex `thread/approveGuardianDeniedAction` 一致）。
  - 同一绑定请求重复到达时保留相同的 `force_ask` 结果；若证据或用户指令在提交前变化则仍按 `action_invalidated` 拒绝。
  - 其余 `medium` / `low` / `unknown` 授权级别的拒绝仍直接返回 `deny`。
  - 如需恢复 0.6.5 的直接拒绝行为，可在 `approval.json` 中将 `escalateAuthorizedDenials` 设为 `false` 并重启审批服务。
