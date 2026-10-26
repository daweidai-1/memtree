# MCP 封装方案（SPEC §9）

> 状态：**设计稿，未实现**。本文件只定义边界、工具契约与安全机制，不改核心 CLI。
> 目标：让 Agent 通过 MCP 调用 `commit / recall / context / purge`，同时保住 memtree 的三条铁律与删除不可逆保护。

## 1. 定位与边界

MCP 层是**可选适配器**，不是第二套记忆逻辑：

```text
Agent / MCP Host
      │ JSON-RPC over stdio
      ▼
memtree-mcp（可选依赖 mcp SDK）
      │ 只做参数校验、权限闸、结果整形
      ▼
scripts/memtree.py（同一套 SQLite + 业务规则）
```

- 核心仓库继续保持**零第三方依赖**；MCP 适配器单独目录/单独启动，不 import 核心内部函数。
- 不复制覆盖、压缩、检索逻辑；所有行为以 CLI 为唯一真源。
- 不暴露任意 SQL、任意文件路径、任意 shell。
- 默认库路径由启动参数或 `MEMTREE_DB` 决定；工具参数**不能**改库路径。

## 2. 工具清单

| 工具 | 作用 | 读/写 | 破坏性 |
|---|---|---|---|
| `memtree_commit` | 写入一条记忆 | 写 | 否（可能覆盖同 subject 状态，属正常语义） |
| `memtree_recall` | 检索定位 | 读 + 更新 `accessed_at` 热度 | 否 |
| `memtree_context` | 生成上下文块 | 只读 | 否 |
| `memtree_purge` | 删除/撤回/墓碑列表/GC | 写 | **是** |

MCP 注解建议：

| 工具 | `readOnlyHint` | `destructiveHint` | `idempotentHint` |
|---|---|---|---|
| `memtree_commit` | false | false | false |
| `memtree_recall` | false | false | true |
| `memtree_context` | true | false | true |
| `memtree_purge` | false | **true** | false |

`recall` 虽然不改正文，但会更新 `accessed_at`，所以**不能**标成只读工具。

## 3. `memtree_commit`

### 输入

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `content` | string | 是 | 1~2000 字；空串拒绝 |
| `type` | enum | 否 | `event/fact/pref/decision/hypothesis/anchor`；默认 `event` |
| `subject` | string | 否 | `fact/pref/decision` 建议必填；必须是稳定命名 |
| `event` | string | 否 | ≤24 字；超长 CLI 本身会拒 |
| `importance` | number | 否 | 0~1 |
| `outcome` | number | 否 | -1~1 |
| `ts` | string | 否 | ISO 时间；非法值拒绝 |
| `source` | enum | 否 | `stated/inferred/system/roleplay` |
| `pin` | boolean | 否 | 打保护位 |
| `scope` | enum | 否 | `global/branch` |
| `branch` | string | 否 | 分支名 |
| `idempotency_key` | string | 否 | 客户端重试去重键，1~128 字 |

### 输出

```json
{"ok": true, "node_id": 42, "superseded": [41], "note": "同 subject 的旧状态已转 superseded"}
```

- `superseded` 由写入前后查询得出；没有覆盖则空数组。
- 写入失败返回 `{"ok": false, "error": {"code": "...", "message": "..."}}`。
- `idempotency_key` 只在适配器侧去重；相同 key 重试返回首次结果，不重复写节点。

## 4. `memtree_recall`

### 输入

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `query` | string | 是 | 1~500 字 |
| `at` | string | 否 | 时点快照 |
| `outcome` | number | 否 | -1~1 |
| `days` | number | 否 | ≥0；v2 时间窗 |
| `event` | string | 否 | 事件标签 |
| `zone` | string | 否 | 逗号分隔分区 |
| `mode` | enum | 否 | `and/mix` |
| `branch` | string | 否 | 分支名 |
| `top` | integer | 否 | 1~50，默认 5 |
| `status` | enum | 否 | `auto/active/any/superseded/archived/competing` |
| `emotion` | string | 否 | 情感标签，逗号分隔 |
| `emotion_weight` | number | 否 | 0~1，默认 0.5 |
| `pipeline` | enum | 否 | `legacy/v2`，默认 `legacy` |
| `expand` | integer | 否 | ≥1，仅 v2 |

### 输出

直接返回 CLI `--json` 结果，适配器只补：

```json
{"ok": true, "result": { "query": "...", "hits": [], "pipeline": {} }}
```

- 不把 `low_confidence=false` 当成事实担保；原样保留 `overlap/low_confidence`。
- 不允许适配器自行改写正文、补全答案或删掉 `⚠` 类提示。
- 错误参数由 CLI 拒绝，适配器映射为 MCP `isError: true`，不返回半截结果。

## 5. `memtree_context`

### 输入

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `budget` | integer | 否 | 100~4000，默认 650 |
| `recent` | integer | 否 | 0~20，默认 3 |
| `branch` | string | 否 | 分支名 |
| `json` | boolean | 否 | 默认 true |

### 输出

```json
{"ok": true, "text": "【记忆 …】\n…", "chars": 620,
 "est_tokens": 358, "dropped": 0, "total": {"facts": 12, "events": 4, "future": 0}}
```

- `text` 必须原样包含图例行、人格三槽、`⚠ 还有 N 条未展开`、墓碑/冷区/未来提示。
- 不允许适配器做二次摘要；预算由 CLI 的 `--budget` 控制。
- 默认返回 `--json` 结构，避免文本层再解析。

## 6. `memtree_purge`

删除是唯一不可逆动作，MCP 层必须比 CLI 更严。

### 6.1 动作

| `action` | 行为 | 安全级 |
|---|---|---|
| `list` | 墓碑列表、剩余冷却天数 | 安全 |
| `stage` | 进墓碑区（默认）；可带 `ids`/`addr`/`reason` | 可逆 |
| `restore` | 冷却期内撤回 | 安全 |
| `gc` | 回收孤儿正文，可 `dry_run` | 可逆/低危 |
| `apply` | 冷却期满真删 | **不可逆，需 token** |
| `now` | 跳过冷却立即真删 | **不可逆，需 token + reason** |

### 6.2 输入

| 字段 | 类型 | 必填 | 约束 |
|---|---|---|---|
| `action` | enum | 是 | 上表 |
| `ids` | integer[] | 否 | `stage/restore` 使用；最多 50 个 |
| `addr` | string | 否 | address 前缀；与 `ids` 二选一 |
| `reason` | string | 否 | `stage/now` 必填，≤200 字 |
| `dry_run` | boolean | 否 | 仅 `gc` |
| `preview_token` | string | 否 | `apply/now` 必填 |
| `confirm` | string | 否 | 必须逐字为 `PURGE` |

### 6.3 两阶段确认

```text
1) action=stage/apply(dry-run) → 返回候选 id、将删条数、地址摘要
                                  → 同时发 preview_token（5 分钟有效、一次消费）
2) action=apply/now + preview_token + confirm="PURGE"
                                  → 重新校验候选集未变化 → 执行
```

- `preview_token` 绑定：库路径 + 动作 + 候选 id 集合 + 过期时间；服务端只存 SHA-256。
- 候选集在两次调用之间发生变化（新增到期、保护位变化）→ 拒绝执行，要求重新预演。
- `apply` **只处理预演过的那批 id**。这要求 CLI 增加 `purge --ids 1,2` 的精确删除入口；在它落地前，MCP 不暴露 `apply/now`，只开放 `list/stage/restore/gc`。
- `now` 额外要求 `reason`，且返回 `cooldown_skipped=true`。
- 禁止 MCP 侧“删除全部”：没有 `all=true` 这种参数；批量必须显式 id 列表。

### 6.4 输出

```json
{"ok": true, "action": "stage", "affected": 2,
 "ids": [41, 42], "preview_token": "…", "expires_in": 300,
 "skipped_pinned": 0, "skipped_shared": 0,
 "note": "正文仍在库；冷却 7 天，可 restore"}
```

`apply/now` 必须原样带回 CLI 的 `purged / skipped_pinned / skipped_shared / still_waiting`，不得只报“成功”。

## 7. 错误与超时

| 情况 | MCP 行为 |
|---|---|
| CLI 退出码 2（参数/校验） | `isError: true`，`code=VALIDATION`，不回显完整参数 |
| CLI 退出码 1（业务拒绝） | `isError: true`，`code=BUSINESS`，带回 stderr 的安全摘要 |
| 数据库锁 | 重试 1 次（250ms 退避），仍失败返回 `code=BUSY` |
| 超时 | 默认 10s，`commit/context` 可 5s；超时杀子进程 |
| 输出非 JSON | `code=PROTOCOL`，不猜结果 |

- 所有调用用 `subprocess` 参数数组，禁止 `shell=True`。
- 不在日志打印记忆正文/情感原话；只打印 id、命令名、耗时、退出码。

## 8. 并发与部署

- 单 MCP 服务单库；SQLite 开 `PRAGMA journal_mode=WAL`、`busy_timeout=3000`。
- 写工具串行化（适配器内 asyncio.Lock）；读工具可并发。
- 服务只通过 stdio 通信；stdout 只允许 JSON-RPC，日志一律 stderr。
- 启动参数：`memtree-mcp --db <path>`；不提供工具级 db 覆盖。
- MCP SDK 作为可选依赖；未安装时给出明确安装提示，不影响 CLI。

## 9. 测试方案（实现时必须补）

1. 工具清单/JSON Schema 与本文一致；启动后 `tools/list` 可读。
2. `commit` 正常写入、同 subject 覆盖、非法 type/outcome 拒绝。
3. `recall` legacy 与 v2 参数映射正确；`--emotion` 透传；不丢 `low_confidence`。
4. `context` 的 `text` 与 CLI 输出逐字一致；预算/`dropped` 一致。
5. `purge`：
   - 无 token 调 `apply/now` 必须拒绝；
   - token 过期、复用、候选集变化都拒绝；
   - `stage` 可 restore，`apply` 后正文与 `affect` 一并清除；
   - 保护位/共享地址仍按 CLI 规则跳过，计数不丢。
6. 并发：两个 commit 同时到达不产生重复节点/数据库锁死。
7. 安全：工具不能改 db 路径；错误日志不含正文与原话。

## 10. 实施前置与未决问题

**前置改动（不属 T6 文档范围，实现前需单独提交）：**

- `purge --ids` 精确删除入口，供两阶段 token 绑定候选集。
- `commit --json`（或稳定机读输出），避免适配器解析裸 id。
- `recall --no-touch`（可选）：给需要纯读的宿主用，避免更新 `accessed_at`。

**未决：**

- MCP 服务是否需要同时暴露 `persona set/drop`？涉及人格硬槽，建议默认不暴露，必须人工 CLI + `--force`。
- 是否提供 `resources` 读取 `context` 快照？当前先用工具返回，避免缓存不一致。
- 多库切换是否支持？建议 v1 单服务单库，避免路径注入面。
