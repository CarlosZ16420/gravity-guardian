# Gravity Guardian

Antigravity 提出并执行工具请求，固定版本的 Codex Native Guardian（codex-auto-review / low）负责审核。插件将真实的用户指令、适用项目规则、权限快照和待审动作交给 Guardian，并在放行前再次核对动作和授权。

模型允许返回 `auto_approve`；模型拒绝时保留原始反馈，其中 `user_authorization = high` 的拒绝默认转为 Antigravity 原生人工确认（`force_ask`，可通过 `escalateAuthorizedDenials` 关闭）。额度耗尽、限流、超时和接口故障单独记录。原生审核按固定上游策略在同一截止时间内最多尝试三次；一次尝试可能包含多次推理提交。未知或无效的用量不会改变审批结果。

精确匹配的普通问答和已验证的无执行副作用操作可直接交给原生权限规则，不等待模型队列。受宿主硬编码询问保护的非密钥目录（如工作区 `.cache` 读写与 `.git`、`.vscode` 只读）在审批服务与接管开启期间默认交由 Guardian 逐次审核，暂停接管、停止服务、关闭开关或卸载时自动回收原生授权。新动作不会继承其他请求的拒绝。技术失败的原生 `ask` 交接默认关闭，等待实际 Antigravity 验收。

通过 Windows 面板安装，或在项目根目录运行 `scripts/Install.ps1`。更新前退出 Antigravity，可用 `-PlanOnly -ReviewMode Preserve` 核对安装范围并保留当前权限模式。安装后可用 `scripts/Doctor.ps1` 核对实际运行版本。
