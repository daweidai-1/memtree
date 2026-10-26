# Changelog

## v1.0.0 — 首个公开发布（2026-10-26）

功能基线：`d096d92`（366 项自检通过）。发布准备提交：N1 `d71f27b`、N2 `4e0a5ac`、H1 `8c00adf`。

提交区间均为 Git 原生 `A^..B`（含首尾两个提交），可直接 `git log A^..B` 核对。

### 时间轴记忆层

- 一条记忆 = 复平面上的点 × 事件向量；时间轴是第一索引，覆盖由时间决定，不调 LLM。
- 内容寻址（`sha256(content)[:16]`）、单文件 SQLite、零第三方依赖。
- 提交：`fcddaa6`（根提交）

### 事件层（SPEC §2.2 最小版）

- `event` 列 + context 事件轴（`▣ 事件名 起~止 n条`）+ `recall --event` 先剪枝。
- 缺列老库可平滑升级。
- 提交：`812c828`

### 五档分区与删除

- `hot / warm / cold / archive` 按时间单向降级，升级只能显式。
- 墓碑区 + 两段式删除：冷却 7 天、`--restore` 撤回、`--now` 隐私直通车。
- 事件内细节梯度压缩：越新越细，结论必留。
- 时点回溯 `recall --at`（`gone_at`）、未来条目隔离。
- 去重不连坐 + `purge --gc` 孤儿正文回收。
- 提交：`bf58645^..c3c9414`、`446fd66`、`d330b28^..939bc37`、`87e5179^..45f9c42`、`146f5c5^..807e63a`

### 人格卡与三层锚点预算

- 独立 `<db>.persona.md`，硬 / 软 / 可变三槽预算，硬槽改动必须 `--force`。
- `persona_log` 审计 + `persona show --at` 回看。
- 提交：`12bbccb^..6ddb0d1`

### 分类型压缩阈值（SPEC §4.2）

- 普通 30 天 / 重要 90 天 / 情感锚点永不自动压缩；显式时间参数只覆盖时间分档。
- 提交：`9124f20`

### 结构化情感层（SPEC §7）

- 独立 `affect` 表：标签、强度、效价、原话、来源。
- `recall --emotion` 显式启用情绪权重；零命中自动退回 α=0。
- `roleplay` 不进入情感层；`purge` 级联删除情感观察。
- 提交：`26069d8`（文档 `211bcdf`）

### 分层检索 v2（灰度）

- `recall --pipeline v2`：有效性门 → 时间窗 → 事件过滤 → 混合相似度 → 加权排序 → 事件级展开。
- `--expand` 截断显式报 `units_skipped / members_dropped / warning`。
- 默认仍走 `legacy`。
- 提交：`153d1fc`、F1 `e2f0bde`、F3 `42e07b1`

### 工单修复 F1–F6 + 公开准备 G1–G3

- F2 `--now` 覆盖所有墓碑并拆 `purged_existing/purged_now`。
- F4 `--apply` 后转 `purged` 终态；F5 已永久删除的节点拒绝 `--restore`。
- F6 `label noise` 显式报告撤销保护位。
- G1 清本机绝对路径；G2 发布 `DESIGN.md`；G3 徽章/CI 数字与实际自检对齐。
- 提交：`ca940ac`、`88055ea`、`49e4f9b`、`a9b4c68`、`2a2a056^..d096d92`

### 发布准备

- N1 对外项目名统一为 `memtree`。
- N2 README Quick Start。
- H1 `.gitattributes` 锁 `bin/memtree` LF、`*.cmd` CRLF。
- 提交：`d71f27b^..8c00adf`

### 验证

- 本机 Python 3.12.8：`bash scripts/selftest.sh` → **通过 366 / 失败 0（34 组）**。
- Python 3.8：`ast.parse(..., feature_version=(3,8))` 通过；本机无 3.8 解释器，**未做 3.8 运行时验证**，由 CI 矩阵（3.8 / 3.11 / 3.13）补足。
