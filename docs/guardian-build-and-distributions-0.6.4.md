# Gravity Steward 0.6.4 构建与双包验收

## Rust 编译对照

| 配置 | 宿主 EXE | ZIP 中的宿主 | 本机 Cargo 构建耗时 |
| --- | ---: | ---: | ---: |
| 0.6.3 基线，opt-level=2，LTO=false，16 单元 | 231.03 MiB | 78.76 MiB | — |
| 现有基线 EXE 使用 rust-objcopy 剥离符号 | 231.03 MiB | 78.76 MiB | — |
| opt-level=2，ThinLTO，16 单元，strip=symbols | 240.01 MiB | 81.99 MiB | 28 分 34 秒 |
| opt-level=2，ThinLTO，1 单元，strip=symbols | 167.05 MiB | 59.87 MiB | 38 分 40 秒 |
| opt-level=s，ThinLTO，16 单元，strip=symbols | 136.52 MiB | 47.40 MiB | 23 分 30 秒 |

发布默认采用已通过真实审核的单单元组并保留 panic=unwind。与 0.6.3 基线相比，宿主减少 63.98 MiB，下载中的宿主减少 18.89 MiB。单独处理已有 EXE 的符号没有减少体积。大小优化组保留为候选，采用前需要完成真实审核验收。当前实测适用于固定的 Codex 0.172.0 和 Windows x64 MSVC。

Cargo 的正式构建配置见 `native/SOURCE.json`。`scripts/Measure-GuardianBuild.ps1` 可复跑基线、仅 strip、两组 ThinLTO 和大小优化对照，并采样编译进程内存、宿主 ready 耗时和本机模拟审核 P50/P95。

单单元组和大小优化组各通过 8 项 Rust 测试与 20 次本机模拟审核。单单元组的审核 P50/P95 为 39.26/60.30 毫秒，大小优化组为 59.92/75.45 毫秒。模拟审核检查了 212,029 字节的完整动作、用户授权和撤销顺序，所有请求都携带零个工具。大小优化组采样的编译进程工作集峰值为 8.14 GiB，宿主 ready 样本为 3.23 秒。编译进程工作集受并行任务影响。

## 依赖与发行

保留 Codex 0.172.0 的上游依赖和既有 Guardian 入口补丁。Windows 宿主的实际依赖树未包含 V8 运行时、独立 Code Mode 宿主和 TUI。发布时按清单复制 Guardian 产物，并让 .NET 发布仅生成由各入口共同使用的框架依赖程序集。移除的本地 apphost 大小为 162,304 字节。

| 发行类型 | ZIP | 解压 | .NET |
| --- | ---: | ---: | --- |
| Standalone | 95.80 MiB | 245.47 MiB | 内置锁定的 x64 10.0.15 |
| Lite | 60.50 MiB | 168.49 MiB | 使用经过进程探测的系统 x64 10.0.x |

两包使用相同的 Guardian 二进制。`artifacts/release-build-info.json` 提供逐文件体积和哈希，`artifacts/checksums.sha256` 提供两个 ZIP 的校验值。

## 本地验收

- 两种发行类型全新安装，分别验证 Standalone 在系统 .NET 查找路径隔离时可启动，Lite 缺少 x64 .NET 10 时在安装前失败。
- 新版面板选择并核验两个资产。新版更新器验证同类型更新、双向切换及从运行中的 0.6.3 升至 0.6.4，并在更新后复验四类 Hook。
- 错误 ZIP 哈希与无法启动的 Guardian 在停服务前被拦下。服务健康检查失败时恢复旧服务、配置和 Hook，并校验项目长期授权及日志仍在。
- 最终优化包的 Windows 进程追踪覆盖安装、诊断、原生 Hook、修复、更新和卸载。99 次进程启动中有 8 次 Guardian 启动，Codex CLI 启动为 0 次。
- 单单元 Guardian 使用合成大写入通过一次真实在线审核。日志按同一请求确认 `native_guardian`、一次推理提交和 `auto_approve`，耗时 13.73 秒，拟议写入未执行。

本轮未实测双账号 A→B→A。基线与仅剥符号没有完整的冷构建内存及审核延迟记录。
