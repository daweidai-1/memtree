# 数据结构与状态机

> 数学推导（复平面模型、打分分解、时间旅行）见 [theory.md](theory.md)。本文件只讲表、状态机与命名。

## 4. 表

### blobs（内容寻址存储）

| 字段 | 说明 |
|---|---|
| `addr` | `sha256(正文)[:16]`，主键。相同内容天然去重 |
| `content` | 正文。`purge` 后置空 |
| `hot` | `1`=热（参与检索/上下文）`0`=冷（只可按地址取回）`2`=已清除 |
| `nbytes` | 正文字节数，只服务 `purge --gc` 的「能省多少」估算 |

正文**去重但不连坐**：`hot=0` 只能落在「全库没有活节点共用这个地址」时（`_cold_blob()`）——两条一字不差的记忆共用一个 `addr`，覆盖掉其中一条绝不能把另一条的正文一起转冷。

孤儿正文（全库没有任何节点引用，任何 zone/status 都不引用）由 `purge --gc` 显式回收：只删 `blobs` 行、不删任何 `nodes` 行，`--dry-run` 先报数。「墓碑区里的节点仍算引用者」——冷却期内必须能 `--restore` 撤回，所以它们不可能是孤儿。

### nodes（索引，不含正文）

| 字段 | 说明 |
|---|---|
| `id` / `addr` | 自增号 / 指向 blobs |
| `t` | **REAL**，epoch 秒。排序一律用这个，不要比字符串 |
| `outcome` | REAL，`[-1,1]`。进虚轴，只影响检索不影响覆盖 |
| `subject` | 同类事件的键，决定谁和谁比 |
| `v_text` | 128 维事件向量（稠密 ±1 随机投影，必须非稀疏） |
| `type` | `event/fact/pref/decision/anchor/hypothesis/summary/merge` |
| `scope` | `global`（跨分支共享）/ `branch` |
| `factor` | 墓碑/压缩标记，`曾:美式@09-15`；压缩摘要记 `压:9-01~09-20/3条` |
| `meta` | JSON。压缩摘要节点记 `{"rolled":N,"ids":[…],"event":"…","kept_detail":[…]}`，其它路径留空 |
| `rolled_into` | 被 `compress` 压进哪条 `summary` 节点的 id。NULL = 没被压过 |
| `refs` | 被强化次数（仅记录，不参与权重） |
| `supersedes` / `superseded_by` | 覆盖链双向指针 |
| `status` | `active / superseded / archived`（`competing` 为保留值，当前无写入路径） |
| `gone_at` | REAL，「**不再作为现状**」的时刻。写在被覆盖者身上：`commit` 记覆盖者的 `t`、`anchor` 覆盖记新锚点的 `t`、`merge`/`archive`/`compress` 记动作墙钟。`recall --at` 靠它判「T 那一刻谁是现状」；NULL = 时间未知（见 §5.7） |
| `branch` / `parent_id` | 分支与 DAG 前驱 |
| `pinned` | INTEGER 0/1，保护位。1 = context 永不裁剪、compress 永不覆盖、purge 拒绝硬删 |
| `tombstoned_at` | REAL，进墓碑区的时刻。`now - tombstoned_at >= 7天` 才允许 `purge --apply` 真删 |
| `purge_reason` | 删除理由（隐私/错误/用户要求）。删完也保留，用于事后审计 |
| `accessed_at` | REAL，epoch 秒，最后一次被 `recall`/`signal` 碰过的时间。**只用于算热度，不累计次数** |
| `label` | `anchor / emotional / noise / NULL`。**`settle` 的结算产物**：写入后不可由热度改写 |
| `zone` | `hot / warm / cold / archive / tombstone / purged`。前四档只随时间单向降级：≤7d 热、7~90d 温、更旧则 `importance ≥ 0.7`（或保护位/锚点）进冷区、否则归档。`tombstone` 只由 purge 进入；`purged` 是正文已永久删除的终态，不参与检索/上下文/迁移，也不能 restore |
| `importance` | REAL 0~1，默认 0.5。**只参与分区下限，不参与排序**（排序永远由时间说话） |
| `event` | 受控短标签（≤24 字）。**聚合键，不是句子**：同一件事的多次提及共用一个 `event`，`context` 据此输出 `▣ 名 起~止 n条`（`MIN(t)/MAX(t)` 即跨期区间），`recall --event` 用它在算相似度之前剪枝 |
| `source_type` | `stated / roleplay / inferred / system`。`roleplay` 永不打情感锚点（防虚构污染） |

### signals（采样队列）

访问过程中采集的原始证据。**结算前不参与任何决策** —— 它的唯一作用是被 `settle` 消费。

| 字段 | 说明 |
|---|---|
| `node_id` | 指向 nodes |
| `type` | `user_confirm`（用户明说重要）/ `correction`（纠正过）/ `emotional_peak` / `repeat_mention` |
| `intensity` | `emotional_peak` 的强度 0~1 |
| `emotion_tags` | 情感标签 JSON 数组，受控词表；老库由 `_migrate` 补列 |
| `valence` | 效价 [-1,1]，负=难受，正=愉快 |
| `quote` | 用户原话，情感场景要用它保住金句 |
| `settled` | 0 = 待结算，1 = 已结算并清空参与资格 |

### affect（结构化情感观察，SPEC §7）

`signals` 是原始证据队列，`nodes.label` 只保留「是不是情感锚点」；完整情绪语义落这里，一条记忆可以有多条观察。

```
affect(id INTEGER PK AUTOINCREMENT, node_id INTEGER, t REAL, tags TEXT,
       intensity REAL, valence REAL, key_quote TEXT, source TEXT, created_at REAL)
CREATE INDEX idx_affect_node ON affect(node_id, t DESC)
```

| 字段 | 说明 |
|---|---|
| `node_id` | 指向 nodes；`purge --apply/--now` 真删节点时级联删除 |
| `t` | 观察时刻（epoch 秒），不是记忆自身的事件时间 |
| `tags` | JSON 数组，规范顺序、去重；固定 `joy/trust/surprise/sadness/fear/anger/disgust/anticipation/unspecified` |
| `intensity` | 0~1；情绪相关性 = 查询标签命中率 × intensity × 来源权重 |
| `valence` | [-1,1]，情绪方向 |
| `key_quote` | 该次情绪的原话（隐私删除时一起消失） |
| `source` | `stated/inferred/system`；`roleplay` 永不入库。`inferred/system` 检索权重 ×0.5 |

### settle_log（结算审计）

没有这张表，"为什么这条被打成重要"就不可回答 —— 那和 LLM 黑箱没区别。

`node_id, signal_types, old_pinned, new_pinned, old_label, new_label, reason, at`

### persona_log（人格改动审计，SPEC §6）

**卡在文件系统，日志在库。** 三个槽的正文写在 `<db>.persona.md`（人能直接看、能 diff、能进版本控制），`persona_log` 只记「改过什么」——`persona show --at` 只能靠它正向重放，卡文件里永远只有"现在"。

```
persona_log(id INTEGER PK AUTOINCREMENT, t REAL, slot TEXT, op TEXT, old TEXT, new TEXT, reason TEXT)
```

| 字段 | 说明 |
|---|---|
| `id` | 自增主键，同时是「同一时刻多条改动」的排序键（`ORDER BY t, id`） |
| `t` | 改动时刻（epoch 秒）；`--at T` 按它重放 |
| `slot` | `hard` / `soft` / `var`（与卡文件三段标题一一对应） |
| `op` | `add` / `del` / `evict` —— 只此三值 |
| `old` / `new` | `add` 记 `new`；`del`/`evict` 记 `old` |
| `reason` | `--reason` 原文；挤出自动记「超预算挤出」 |

重放规则（`persona_replay()`）：从空卡起，按 `t, id` 顺序，`add` 加、`del`/`evict` 减 —— 所以 `--at` 给的是**那一刻的卡**，不是「那一刻之后的卡」。

### branches / kv

`branches(name, fork_node, head_id, status, merged_into)`；`kv` 只存 `head`。

## 5. 状态机

```
                 同 subject 且 t 更大
   active ──────────────────────────► superseded   （正文转冷，只留地址）
     │
     ├── merge 分支成员 ─────────────► archived
     │
     └── compress 压掉的旧细节 ──────► archived（rolled_into → 摘要节点，正文 hot=0）

  任意 zone/status 的候选 ──purge──► zone='tombstone'（正文仍在库，已从检索/上下文消失）
                                         │ 冷却 7 天（PURGE_COOLDOWN_DAYS），--restore 可撤回
                                         │ purge --apply（期满）或 --now（立即，覆盖所有墓碑）
                                         ▼
                                   zone='purged' 终态：正文清除，地址悬空（hot=2）
```

- 只有 `active` 进 `context` 的 `■`。
- `superseded` 只以 `factor` 出现在新记忆的括号里。
- `purged` 的地址仍可用于**去重**和"曾经有过这条"的溯源，但取不回原文。
- `pinned=1` 的节点不参与任何降级：`compress` 跳过它，`purge` 直接拒绝（要清先 `pin <id> --off`）。**墓碑区里的保护位照样有效** —— `pinned_refs()` 不看 zone，同一地址上任何一条钉住，整条地址就不抹正文（§5.6）。
- `tombstone` 是 **zone 不是 status**：进墓碑区的节点仍带着 `active/superseded/archived`，只是被排除出检索与上下文；`tombstoned_at` 起算 7 天后才允许 `--apply` 抹正文。真删成功后 `zone='purged'`、`tombstoned_at=NULL`，从此不在墓碑队列，也不能 restore。
- 反过来，**墓碑里不许打保护位**（`pin` 拒绝，提示先 `purge --restore`）：否则谁都能临时钉一下再删，保护位就成了假动作（§5.6 硬拦③）。
- `competing` 是保留状态位：用于「两条现状互相矛盾、等用户裁决」的场景，目前没有写入路径，`recall --status competing` 恒为空。
- `compress` 只动**细节**：被压的细节转 `archived` 并在 `rolled_into` 记住去处，结论节点原样留在 `active`——见 §5.5。

## 5.5 压缩：事件内细节梯度（SPEC §5 ①）

`compress` 的唯一职责是**在事件内部**降细节密度，不做跨事件的糊合。三段流水线：

```
候选筛选 → 按 event 分组 → 组内梯度（最新 keep_detail 条留原文 / 更老的压一行）
                              ↘ 结论命中 is_conclusion() 的节点整组跳过
```

### 候选

截止时刻默认按类型分档（SPEC §4.2），显式 `--days N` / `--before T` 则统一覆盖时间分档：

| 类型 | 默认截止 |
|---|---|
| 普通 | `now - 30 天` |
| 重要：`importance >= 0.7` 或 `pinned` | `now - 90 天` |
| 情感锚点：`label='emotional'` 或 `type='anchor'` | **永不自动压缩**（无截止） |

显式参数只覆盖“多久算旧”，**不覆盖** `is_conclusion()` 与保护位硬闸：情感锚点、锚点、决定、带结果值、`pinned` 仍不会被压掉。因为 `pinned` 同时命中 90 天档与“保护位永不自动压缩”，实际行为以更强者为准：不自动压。

`status='active'` 且早于上述截止时刻，并且：

| 条件 | 说明 |
|---|---|
| `type='event'` 或 `event` 非空 | 压缩必须在事件内部做，跨事件糊成一条就丢了「哪个结论属于哪件事」 |
| `type != 'summary'` | 摘要的摘要不可逆丢信息 |
| `branch = --branch`（默认当前 HEAD） | 旧实现写死 `main`，侧枝的旧事件永远压不到 |
| 不是分支 `fork_node` / `head_id` | 分叉点与 HEAD 被引用，压掉就断开历史 |
| `zone != 'archive'` | 归档区已压过一轮 |
| `pinned=0` | 保护位永不进压缩（SPEC §5.4） |
| `--heat` 未给，或 `label='noise'`，或 `t > now`，或 `heat_of(r) <= --heat` | 热度门：只压「久没被碰过」的；`noise` 豁免是加速淘汰，不是放宽标准；**未来条目走同一条快车道** —— 按 `min(t, now)` 算它是「刚写上去」，热度恒 1.0，若因此豁免就会出现「2030 年的事件永久免疫压缩」（§5.9） |

### 分组与梯度

- 分组键 = `event` → `subject` → `#id` 兜底；组内按 `(t, id)` 升序。
- `keep_n = min(--keep-detail, 组大小)`，**最新的 keep_n 条**留原文；其余吃梯度。
- 待压条数 `< --min-count`（默认 3）→ 整组进输出 `skipped`，附 `why`。

### 摘要节点

| 字段 | 值 |
|---|---|
| `t` | 被压的第一条（最老）的 `t`，插回原时间位置，不移动 HEAD |
| `type` / `scope` / `status` | `summary` / `global` / `active` |
| `event` | 继承原事件标签 → 事件轴 `▣ 名 起~止 n条` 不被打断 |
| `factor` | `压:<起>~<止>/N条` |
| `meta` | `{"rolled":N,"ids":[…],"event":"…","kept_detail":[…]}` |
| 正文 | `--text` 覆盖，否则 `[压缩N条] ` + 前 4 条片段（每条截 12 字）以 `；` 连接，超出加 `…` |

被压节点：`status='archived'`、`rolled_into=<摘要 id>`、`blobs.hot=0`。正文仍在 `blobs`，按地址可回溯。

### 结论必留：梯度的下限

`is_conclusion(r)` 为真即整条跳过，与年龄无关：

```python
type in (decision, anchor, merge) or pinned
or outcome != 0 or label in (anchor, emotional)
```

判据不看措辞、看类型与结果 —— 「这事到底怎么定」压掉等于记忆没了；细节可以越老越粗，结论不行。

### 输出（`--json`）

```json
{"groups":[{"event":"转岗","summary_node":41,"compressed":12,"span":"08-01~09-20",
            "text":"[压缩12条] …","kept_detail":[55]}],
 "compressed":12,"conclusions_preserved":[53],"skipped":[{"event":"搬家","candidates":2,"why":"…"}],
 "note":"事件内梯度：…"}
```

`conclusions_preserved` 是被识别为结论、因而**没被压**的节点 id —— 它是「这次压缩没吃掉结论」的证据行。

## 5.6 删除：两段式（SPEC §5.5）

删除是不可逆的决定，所以拆成两段：**先进墓碑区，期满才抹正文**。中间这几天是唯一的后悔窗口。

| 调用 | 作用 |
|---|---|
| `purge` | 整批进墓碑区：`status IN ('superseded','archived')` 且 `pinned=0` 且 `type != anchor` 且 `zone != 'tombstone'` |
| `purge --addr <前缀>` | 按地址进墓碑区（该地址上的节点一起进）；地址上有保护位或锚点 → 整次调用直接拒绝 |
| `purge --list` | 只看尚未结案的墓碑：排队、理由与剩余天数 `days_left` |
| `purge --apply` | 期满才抹正文，并把节点转 `zone='purged'` 终态 |
| `purge --restore <id>` | 冷却期内撤回（正文从未删除，分区按时间重算） |
| `purge --now` | 跳过冷却立即删：**覆盖所有墓碑节点**（含本轮之前就在墓碑区的），返回 `purged_now`（本轮新进）与 `purged_existing`（既有墓碑）；跳过冷却 ≠ 跳过引用计数与保护位 |
| `purge --gc [--dry-run]` | 回收孤儿正文：只删 `blobs` 行，**不删任何 `nodes` 行** |
| `--reason "<理由>"` | 记进 `purge_reason`，删完也保留（事后审计要能回答「谁为什么删的」） |

进墓碑区只是 `zone='tombstone'` + `tombstoned_at` + `purge_reason`：正文还在库里，但已从 `recall` 与 `context` 消失。冷却期常量 `PURGE_COOLDOWN_DAYS = 7.0`。

`--restore` 先验正文：`zone='purged'` 或 blob `hot=2/正文空` 一律 `exit != 0`，文案为「正文已永久删除，无法撤回」，且不改 zone/status；只有正文完好的墓碑节点才能回到按时间重算的分区。

### 三条硬拦（`--apply` 与 `--now` 都要过）

| # | 硬拦 | 判据 | 计数 |
|---|---|---|---|
| ① | 保护位 | `pinned_refs(addr) > 0` —— **同一地址上任何一条钉住都算，墓碑区里的 pinned 也算** | `skipped_pinned` |
| ② | 共享地址 | `live_refs(addr) > 0` —— 该地址上还有 `zone != 'tombstone'` 的节点（`active / superseded / archived` 全算活引用） | `skipped_shared` |
| ③ | 墓碑里不许 pin | `cmd_pin()` 直接拒绝进墓碑区的节点，提示先 `purge --restore <id>` | 报错退出 |

- ②的理由是内容寻址：两条一字不差的记忆共用一个 `addr`，抹掉一条就等于销毁另一条的正文 —— 地址是共享资产，不是私产。
- ③的理由是第①条：如果墓碑里能 pin，任何人都能「先钉一下再删」制造假保护位，或者反过来用「先删再钉」绕过①。两条一起才闭环。
- **计数归属**：同一地址既命中原保护位又有活引用时，**只计 `skipped_pinned`**，不重复计 `skipped_shared`（代码里 pinned 先判并 `continue`）。
- 被跳过的条目**仍留在墓碑区**（`due` 一直为真），下次 `--apply` 会重试；`--apply` 本身不累积状态、不删节点行。
- `still_waiting = 墓碑总数 - due 数`：冷却还没满的那批。

### 输出字段

| 路径 | 字段 |
|---|---|
| 进墓碑区 | `tombstoned` / `cooldown_days` / `due_at`；无候选时 `{"tombstoned":0,"note":"没有可删的候选"}` |
| `--list` | `tombstones` / `items[{id,subject,reason,days_left,due}]` |
| `--apply` | `purged` / `due` / `skipped_pinned` / `skipped_shared` / `still_waiting` |
| `--now` | `purged_now` / `skipped_pinned` / `skipped_shared` / `reason` / `cooldown_skipped: true` |
| `--restore` | `restored` |
| `--gc` | `gc_removed` / `bytes`；`--dry-run` 另有 `would_remove` |

### 真实输出（临时库实跑）

```console
$ memtree purge --reason "草稿清理"
{"tombstoned": 2, "cooldown_days": 7.0, "due_at": "2026-11-02", "note": "正文仍在库、已从检索与上下文消失；冷却期内 purge --restore <id> 撤回"}
$ memtree purge --apply          # 冷却未满
{"purged": 0, "due": 0, "skipped_pinned": 0, "skipped_shared": 0, "still_waiting": 2, "note": "冷却期满才真删：正文清除，只留悬空地址；保护位/仍被引用的地址不抹正文"}
$ memtree purge --apply          # 期满
{"purged": 2, "due": 2, "skipped_pinned": 0, "skipped_shared": 0, "still_waiting": 0, "note": "冷却期满才真删：正文清除，只留悬空地址；保护位/仍被引用的地址不抹正文"}
$ memtree purge --now --addr 5d1c… --reason "口误含密码"
{"purged_now": 1, "skipped_pinned": 0, "skipped_shared": 0, "reason": "口误含密码", "cooldown_skipped": true, "note": "立即删除：隐私/错误信息不需要冷却，删除不可恢复；保护位/仍被引用的地址不抹正文"}
$ memtree purge --restore 5
{"restored": 5, "note": "冷却期内撤回：正文从未删除，分区按时间重算"}
```

共享地址的真样例（`user.a` 的旧版与 `user.b` 的正文一字不差，共用 `addr=a6009f96ebf790c0`）：

```console
$ memtree purge                  # 只收 superseded/archived → 只把 user.a 旧版送进墓碑
{"tombstoned": 1, ...}
$ memtree purge --apply          # 期满，但同地址上 user.b 还活着
{"purged": 0, "due": 1, "skipped_pinned": 0, "skipped_shared": 1, "still_waiting": 0, "note": "冷却期满才真删：正文清除，只留悬空地址；保护位/仍被引用的地址不抹正文"}
```

正文仍在 `blobs`（`('a6009f96ebf790c0', 0, 9)`，`hot=0` 未变 `2`）—— 这就是②存在的意义。

> **诚实标注**：走正常 CLI 路径摸不到 `skipped_pinned` —— `pin` 拒绝墓碑区节点，`purge` 又拒绝带保护位的节点，所以「同一地址既命中保护位又有活引用」只可能出现在**老库或直连 SQL 改写过的数据**上。自检 [25] 就是直接构造这种数据来验计数归属。

## 5.7 `gone_at`：现状失效时刻

`status` 只回答「现在是不是现状」，回答不了「**2020 年 6 月那一刻**它是不是现状」。`gone_at` 补的就是这一格。

写在**被覆盖者**身上，值是「它不再作为现状的那一刻」：

| 动作 | `gone_at` 取什么 |
|---|---|
| `commit` 覆盖同 subject 的旧条目 | 覆盖者自己的 `t`（不是墙钟 —— 补录历史时墙钟会撒谎） |
| `anchor` 覆盖 | 新锚点的 `t` |
| `archive` / `merge` / `compress` | 动作发生的墙钟 |

- 老库迁移：`_migrate()` 补 `gone_at REAL` 列后回填一次 —— `superseded` 取 `superseded_by` 那条的 `t`，`archived` 取 `rolled_into` 那条的 `t`。
- **回填不到就留 NULL**，不猜。NULL 的条目在任何 `--at` 里都无法判定「当时是不是现状」：按当前 `status` 处理，并计进 `as_of_stats.unknown_timing` —— 宁可承认时间未知，也不假装确定。
- 现值条目（`active` 且没人覆盖）`gone_at` 为 NULL，这是正常状态，不计入 `unknown_timing`（它还没失效过）。

## 5.8 `recall --at`：时点快照

`recall --at T` 问的是「**T 那一刻的现状**」，不是「现在符合关键词、且时间靠近 T 的条目」。判据：

| 情况 | 判定 |
|---|---|
| `gone_at` 存在且 `<= T` | 那时已经失效 → `already_gone`，不当作当时的现状 |
| `gone_at` 存在且 `> T` | 那时还是现状 → `active`（当时口径） |
| `gone_at` 为 NULL 且 `status` 不是 `active`/`competing` | 时间未知 → `unknown_timing`，按当前 `status` 处理 |
| `t > T` | T 之后才写的 → `not_yet`，不算当时的现状 |
| `t > now` | **真实未来条目，任何 `--at` 都不返回** |

细节口径：

- 每条命中同时给两个状态位：`status` = **当时**的状态、`status_now` = 现在的状态。两者会分叉（样例里 `"status": "active", "status_now": "superseded"`）。
- `--at` 下命中**读全文**，不返回 `[地址 … 已转冷]` 占位 —— 回溯的时候给个占位符等于没回溯。
- 噪声门在 `--at` 下按**语义重合 `se`** 判，不按总分 Σ：深回溯时 Σ 会被时间权重压到 1e-16，按 Σ 会把确凿的历史静默丢掉。代价是可能多返回低分条目，所以命中带 `low_confidence` / `overlap` 标注让调用方自己判断。
- `--status auto` 在 `--at` 下剔除「当时不是现状」的条目；显式 `--status` 时按显式值来。

`as_of` / `as_of_stats` 字段：

| 字段 | 含义 |
|---|---|
| `as_of` | 回显传入的 `T`（ISO 日期） |
| `as_of_stats.active` | 命中里「当时确实是现状」的条数 |
| `as_of_stats.not_yet` | T 之后才写入、因而没参与的条数 |
| `as_of_stats.already_gone` | T 之前就已失效、因而没参与的条数 |
| `as_of_stats.unknown_timing` | `gone_at` 缺失、时间无法判定的条数 |
| `note` | 固定口径说明 |

真实输出（库：`住在南京` t=2020-06-01 已被 `搬到苏州` t=2030-06-01 覆盖）：

```console
$ memtree recall "南京" --at 2020-09-01 --json
{"query": "南京", "t": "2020-09-01", "outcome": 0.0, "hits": [{"id": 1, "score": 0.152, "sem": 0.64, "time": 0.24, "out": 0.0, "status": "active", "status_now": "superseded", "subject": "user.city", "event": null, "zone": "hot", "addr": "201320d1d96a57be", "overlap": 1.0, "low_confidence": false, "content": "住在南京", "ts": "2020-06-01"}], "as_of": "2020-09-01", "as_of_stats": {"active": 1, "not_yet": 1, "already_gone": 0, "unknown_timing": 0}, "note": "as_of 口径：按「覆盖/归档发生的时刻」(gone_at) 判定当时状态；T 之后才发生的现状类条目不算当时现状；gone_at 缺失的老数据按当前 status 处理并计入 unknown_timing"}
```

## 5.9 未来条目：还没发生的不算现状

写错的未来时间戳（把 2026 打成 2030）不许霸榜，也不许把真实现状顶掉。

| 位置 | 行为 |
|---|---|
| `context` 正文 | 另起一段：`⏳ 未来 N 条尚未发生（不参与现状判定） —— 显式查：recall --at <该日期之后> 或 log --all` |
| `context` 的 `■` 现状 | 未来条目**永不进**；它盖不住真实现状 |
| 被未来条目覆盖掉的现状 | 按 `gone_at > now` 补回 `■` 现状，行尾标 `(覆盖者在未来·此刻仍是现状)`，且正文强制读原文（不显示「已转冷」占位） |
| `context --json` | `total` 新增 `future` |
| 热度 `heat_of()` | `last = max(accessed_at, min(t, now))` —— 未来的 `t` 不让衰减起点跑进未来（否则 2030 那条永久热度 1.0） |
| `compress` | 未来条目按 `t > now` 直接放行热度门（快车道，与 `noise` 同理）：`min(t, now)` 让它看起来「刚写上去」，若因此豁免就会出现「2030 年的事件永久免疫压缩」 |
| `compress --keep-detail` | 「最新」= **已发生的最新**：未来条目不许抢占原文详情位 |

真实输出（`住在南京` 2020-06-01 + `搬到苏州` 2030-06-01）：

```console
$ memtree context
【记忆 2026-10-26 | main#2 | 2节点·废1】
■ user.city: 住在南京  (覆盖者在未来·此刻仍是现状)
※ ⚓锚点 ⚓人格 ■现状 ▣事件轴 ⟦事件名⟧ ❄冷 🪦墓碑 ★钉=保护位 ◇假设 ○分支(回顾点) ·事件
⏳ 未来 1 条尚未发生（不参与现状判定） —— 显式查：recall --at <该日期之后> 或 log --all
```

## 5.10 自检覆盖的契约（[25] / [26] / [31]–[34]）

| 组 | 条数 | 断言的契约 |
|---|---|---|
| `[25]` 删除路径加固 | 38 | 保护位挡住 `--apply`（含墓碑区内的 pinned）；共享地址不抹正文；`--addr` 遇保护位/锚点整次拒绝；墓碑区不许 `pin`；冷却未满不删；期满真删后正文为空、`hot=2`、节点行仍在；`--restore` 分区按时间重算；`--now` 跳过冷却但**不跳过**引用计数；**计数归属**：同一地址同时命中时只计 `skipped_pinned`、不重复计 `skipped_shared`；被跳过的正文仍活着 |
| `[26]` 时点快照 / 未来隔离 | 36 | `--at` 返回「T 那一刻是现状」的条目、不返回 T 之后才写的；T 之前已被覆盖的条目不当现状；`--at` 早于全部条目 → 空命中而不是拿后写的冒充；`status`(当时)/`status_now`(现在) 分叉；`--at` 下读全文非占位；`as_of` 回显、`as_of_stats` 四个键齐全；深回溯按 `se` 判而不被 Σ 饿死（带 `low_confidence`/`overlap`）；`context` 出 `⏳` 段且 `■` 不含未来条目；被未来覆盖者按 `gone_at > now` 补回并标 `(覆盖者在未来·此刻仍是现状)`；`total.future`；未来条目不免疫压缩 |
| `[31]` 分类型压缩阈值（§5.5） | 11 | 普通 31 天进候选；重要 31 天不进、91 天进；`label=emotional` 31/1000 天都不进；`type=anchor` 1000 天不进；默认只压两条；显式 `--days` 让重要 31 天进候选；显式参数不绕过情感/锚点硬闸；缺 `importance` 老库可直接 compress 且列被补回 |
| `[32]` 情感层（§4 affect / §7） | 22 | 中文别名规范化；settle 落结构化 affect；多条观察不覆盖；未知标签拒绝；roleplay 不落情感层；无 `--emotion` 老输出键不变；情绪查询重排；零命中退回 α=0 且分数逐位不变；部分命中保持 0.5；`affect clear` 不删记忆；`purge` 级联清标签与原话；缺情感列老库可打开 |
| `[33]` 分层检索 v2（§5.12） | 20 | legacy 无 pipeline 对象；v2 六段审计齐全；未来单列不进 topN；每级 in=pruned+out；时间窗/事件过滤报数；事件单元展开与正文加载计数；`--expand` 截断报 `units_skipped/members_dropped/warning`，未截断为 0/null；`--at` 锚定 T 且 as_of 统计不丢；`--expand 0` 拒绝 |
| `[34]` purge 语义（F2/F4/F5） | 18 | `--now` 覆盖既有墓碑并拆 `purged_existing/purged_now`；无墓碑文案准确；`--apply` 转 purged 终态、列表归零、再 apply 0/0、recall 不命中；老库 ghost 迁移；正文已抹 restore 拒绝且状态不变；冷却期 restore 成功可检索 |

## 5.11 人格卡：卡在文件系统，日志在库（SPEC §6）

`type=anchor` 的语义一个字没变（§6.5）—— 人格卡**不是** nodes 里的一类条目，而是独立文件：

| 项 | 值 |
|---|---|
| 默认路径 | `<db>.persona.md`（`persona_path()` :529-532：`memtree.db` → `memtree.db.persona.md`），`--persona-file` 覆盖 |
| 文件格式 | 三段固定标题、固定顺序：`## 硬槽` / `## 软槽` / `## 可变槽`；槽内一行一条、以 `- ` 开头；空槽保留标题 |
| 解析容错 | 未知段其下内容一律丢弃（宁可丢也不许乱归）、未知标题与空行忽略（`persona_load()` :535-556） |
| 写盘 | 同目录临时文件 + `os.replace` 原子写（`persona_save()` :576-590）——半张卡比旧卡更糟 |
| 日志表 | `persona_log`（§4 表定义），`op ∈ add|del|evict`（`persona_log()` :593-596） |

### 预算

用 `est_tokens()`（:202，中文 1 字≈1.5、ASCII≈0.3/字符）算，别用 `len/1.4`：

| 闸 | 上限 | 位置 |
|---|---|---|
| 硬槽 | 300 | `PERSONA_SLOT_BUDGET` :66 |
| 软槽 | 350 | 同上 |
| 可变槽 | 150 | 同上 |
| 整卡 | 800 | `PERSONA_TOTAL_BUDGET` :67 |

总闸是兜底：正常情况槽内先挤出，只有三槽都接近饱和时总闸才可能触发。空卡算 0 token（三段标题是格式，不是人格内容）。

### 写权限与超预算

| 情形 | 行为 |
|---|---|
| 硬槽 `set` / `drop` 不带 `--force` | 拒绝、`exit 2`，提示「硬槽改动需要 --force（防人格漂移）」（`set` :653-655；`drop` :697-699；不存在的条目先幂等返回） |
| 硬槽超 300 | **直接拒写**，不挤别人（硬槽是人格护栏，挤让 = 这次写入错了） |
| 软/可变槽超预算 | 按**最后一次写入最旧优先**逐条挤出（`persona_last_write()` :599-604，同刻按 `id` 升序），留 `op=evict` 日志 |
| 挤到只剩新条目仍超 | 整条回滚、`exit 2`，卡文件不动（:670-673） |
| 整卡超 800 | 回滚 + `exit 2`，并把三槽占用报出来（:676-679） |
| 重复写同一句 | 幂等：`changed:false`，不写文件、不写日志（:650-652） |

### 审计与回看

- `persona show` 回答「现在是什么」，`persona log` 回答「改过什么」。
- `persona show --at T` 用 `persona_replay()`（:607-619）从空卡正向重放 `t<=T` 的记录；T 早于首次写入 → 打印 `(卡为空)` 且退出码 0。
- 卡文件被人手改**不会**进日志 —— 日志只记 memtree 自己的写入，所以「卡」和「日志」可能不一致，以卡文件为现状。

### context 集成

卡非空时 `cmd_context()` 在首行之后、锚点之前插三行（只输出非空槽，:1184-1185）：

```text
【记忆 2026-10-26 | main#1 | 1节点·废0】
⚓人格·硬 我是小白，老大的人
⚓人格·软 先建直觉再上公式；……
■ user.style: 老大喜欢先看结论
```

- 三行进 `rebuild()`，因此**计入 `--budget` 但永不被裁剪**（:1187-1188）——人格不许因为这一次预算紧张而消失。
- 卡为空 → 一行都不出，context 输出与「没有人格卡」逐字相同。
- `context --json` 增 `"persona":{"hard":[…],"soft":[…],"var":[…],"est_tokens":N}`（:1232）。

真实输出（临时库实跑，`--db /tmp/pd.db`）：

```text
$ memtree persona set "我是小白，老大的人" --slot hard
[memtree] 硬槽改动需要 --force（防人格漂移）                            # exit=2，卡文件未被改动
$ memtree persona set "我是小白，老大的人" --slot hard --force --reason 初始
{"changed": true, "slot": "hard", "slot_tokens": 12, "total_tokens": 27, "evicted": []}
$ memtree persona set "先建直觉再上公式" --slot soft
{"changed": true, "slot": "soft", "slot_tokens": 12, "total_tokens": 40, "evicted": []}
$ memtree persona show
## 硬槽
- 我是小白，老大的人
## 软槽
- 先建直觉再上公式
## 可变槽
$ memtree persona log --limit 2
   2 2026-10-26T17:12:39+08:00 soft add   -→先建直觉再上公式
   1 2026-10-26T17:12:39+08:00 hard add   -→我是小白，老大的人  初始
$ memtree persona show --at 2020-01-01
(卡为空)                                                                # exit=0
```

### 已知取舍

- 卡是纯文本文件，**没有版本化**：不进 `blobs`、没有内容地址；历史只能靠 `persona_log` 重放。
- 硬槽只有「`set` / `drop` 不给 `--force` 就改不动」这一道闸，没有漂移检测/审批流。
- `--at` 的可信度等于日志的完整性：直连 SQL 改库或删 `persona_log` 会让历史卡不可重建。
- 自检 [30] 契约 J 钉的是：空卡不出现 `⚓人格·*` 内容行（图例固定含 `⚓人格` 符号，不算卡内容）/ 硬槽 `--force` 闸且被拒时不落卡不落日志 / 软槽最旧挤出 + `op=evict` 留痕 / 硬槽超限不挤别人 / 整卡超 800 回滚且卡文件 sha256 不变 / `--at` 早于首次写入给 `(卡为空)`、两次写入之间给中间态 / 重复写幂等、`drop` 留 `op=del` / `⚓人格` 行排在锚点之前且 `--budget` 极小时不被裁 / 卡非空时图例行含 `⚓人格`（J12）。

## 5.12 分层检索 v2（SPEC §8.3，灰度）

`recall --pipeline v2` 才启用；默认 `legacy` 单遍打分不变。

| 阶段 | 输入 → 输出 | 说明 |
|---|---|---|
| 有效性门 | 全库 → 有效候选 | status / branch / zone / tombstone / `gone_at` / 未来隔离；真实未来进 `future_hidden` |
| 时间窗 | 有效候选 → 窗内候选 | `--days` 以 `--at` 的 T（或 now）为锚；无 `--days` 时 window=all |
| 事件过滤 | 窗内 → 事件命中 | `--event` 在相似度之前剪枝 |
| 混合相似度 | 候选 → 单元 | 粗排用向量余弦；展开后 `0.85*cos + 0.15*lexical` |
| 加权排序 | 单元 → 排序 | 时间与（可选）情绪为主权重，结果项叠加；权重写进 JSON |
| 逐级展开 | 单元 → 成员 → topN | 事件为一个单元，无事件则单条为单元；只展开前 N 个单元并加载正文 |

`--json` 的 `pipeline` 字段：

```json
{"validity":{"in":5,"pruned":1,"out":4,"future_hidden":1},
 "time_window":{"days":10,"in":4,"pruned":1,"out":3,"anchor":"now"},
 "event_filter":{"event":"E1","in":3,"pruned":1,"out":2},
 "similarity":{"coarse":"vector_cos","hybrid":"0.85*cos+0.15*lexical","candidates":2,"kept":2},
 "ranking":{"time":1.0,"emotion":0.0,"outcome":1.0},
 "expand":{"units":1,"units_expanded":1,"units_skipped":0,"members_scored":2,
           "members_dropped":0,"bodies_loaded":2,"warning":null}}
```

`--expand N` 截断时 `units_skipped/members_dropped` 必须 >0，并在 `warning` 写明「--expand 增大可纳入」；未截断时两字段为 0、`warning` 为 null。非 JSON 模式同一 warning 打到 stderr。

每一级都满足 `in = pruned + out`，不允许静默截断。`--at` 下时间窗锚定 T，`not_yet/already_gone/unknown_timing` 仍按原有口径给全；`t > now` 的真实未来条目任何 `--at` 都不返回。

## 6. 权重

```
w = 2^(-|Δt|/45天)      Δt = t_q - t        t_q = 检索时刻（默认 now，可 --at 指定）
```

取绝对值是对称的：过去越久越小，**未来越临近越大**——写错的未来时间戳（把 2026 打成 2030）不会永久霸榜。同 `subject` 组内 `max(t, id)` 为现状，其余立即降级。

为什么不让可信度/结果值参与：一旦混入，就要定义"多少次确认能压过多新的改口"，规则会迅速变复杂且不可预测。**覆盖只回答"现在是什么"，其它维度只服务检索。**

## 6.5 热度、保护位、锚点的分工

| 概念 | 存在哪 | 决定什么 | 不决定什么 |
|---|---|---|---|
| 时间权重 `w` | 现算，不落盘 | 检索排序、context 里谁在前 | 谁进上下文（那由 status + pinned 决定） |
| 热度 `heat` | `max(accessed_at, min(t, now))` 现算（未来条目不跑进未来） | **只触发压缩**（`compress --heat`） | 排序、分区归属、压缩后去向 |
| 采样 `signals` | `signals` 表 | 攒出「值得升保护位」的证据 | 任何即时决策（要等 `settle`） |
| 保护位 `pinned` | `nodes.pinned` | 不被裁剪 / 不被压缩 / 不被硬删 | 排序（保护位不抬权重，只保命） |
| 锚点 `type=anchor` | 一条普通节点 | 独立成段、永不裁剪、撞上更新的 fact 时标 `⚑锚点未变` | 吞掉新现状（新 fact 照样 active，只标出张力） |

```
heat = 0.5 ^ (距上次访问天数 / 45)     # 分母是「多久没碰」，不是「碰了几次」
```

三条硬规则：

1. **热度是计时器，不是裁判。** 它不参与排序，排序看 `w × 语义 × 结果`。让它排序，一条被反复问到的旧偏好就会压过最近的改口，人格设定就漂了。
2. **不累计次数。** 高频对话里所有条目都热、低频对话里全都冷——次数是环境的函数，不是记忆的函数。只看「距上次访问」。
3. **写入即热区。** 刚 commit 的条目 `accessed_at` 为空、但 `t` 是现在，热度天然最高，不需要额外提升。
4. **热度只能通过一次结算影响重要性。** 见下。

### 6.6 采样 → 结算：热度唯一被允许影响保留的通道

只有计时器的热度有个死穴：**没法区分"曾经重要、后来没人提"和"从来没重要过"**。两者到期时都是"冷了"。

解法是让它同时当采样器，但**影响必须一次性兑现**：

```
访问 → 记一条 signal（零决策影响）
     → settle 一次性结算 → label
     → anchor/emotional：pinned=1（此后 heat 归零也不影响它）
     → noise：豁免热度门，提前淘汰
     → 清空 signals
```

| 采到的证据 | 判定条件 | label | 效果 |
|---|---|---|---|
| `user_confirm` | 用户明说"记住/重要" | `anchor` | `pinned=1`，永不压缩/裁剪/硬删 |
| `correction` | 用户纠正过这条 | `anchor` | 同上 |
| `emotional_peak` | 强度 ≥0.7 **且** `source_type=stated` | `emotional` | `pinned=1` |
| `repeat_mention` | 只有重复，无以上三种 | `noise` | 豁免热度门，加速淘汰 |

**为什么这不违反铁律三**：连续地延长寿命 = 裁判（隐式、不可审计）；一次性结算成状态 = 采样（显式、有 `settle_log`）。
结算之后参与保留的东西已经从"热度"换成了 `pinned`，而 `pinned` 不会再变。

三条防退化约束：

1. `signals` **不得跨结算周期累积** —— 攒起来就变回"问得多就一直留着"。
2. 判定走规则、不走 LLM；唯一用到模型的 `intensity` 也只输出离散档位。
3. 每次结算必须写 `settle_log`，否则不可审计。

保护位与锚点的区别：保护位是**行为标记**（别删我），锚点是**语义角色**（我是谁不许被最近一次对话改写）。关系里程碑这类「既重要又是身份锚点」的条目，两个都要打。

## 7. subject 命名

```
user.<属性>      user.coffee / user.city
proj.<维度>      proj.stack / proj.plan / proj.deadline
org.<对象>.<属性>
```

覆盖只发生在 `subject` 完全相等时。命名必须稳定——这是整套机制唯一的失败入口。

## 8. 换成真嵌入

`text_vec` 现在是稠密 ±1 随机投影的词袋（零依赖、可解释）。换成真嵌入时：

1. 把 `text_vec()` 换成调 embedding 服务，仍返回 128 维并 L2 归一化；
2. 已有数据需要重算 `v_text`（`UPDATE nodes SET v_text=...`）；
3. 其余逻辑（时间权重、结果项、覆盖、分支）不用改。

注意：**语义向量必须稠密**。稀疏哈希会让大量维度恒为 0，点积失去区分度——这是实测踩过的坑。

## 9. 与 Git 对照

| memtree | git | 差异 |
|---|---|---|
| `commit` | commit | 这里会触发同 subject 的时间覆盖 |
| `branch --from <id>` | branch | 可从任意历史节点分叉 |
| `merge` | merge | 不产生 diff，只落结论节点并归档分支 |
| `superseded` | — | git 没有"过时但保留"的概念，这是记忆独有 |
| `compress` | squash | 结果插回**原时间位置**，不移动 HEAD |
| `purge` | gc | **两段式**：默认 = 进墓碑区（`zone='tombstone'`，正文还在）；`--apply` = 冷却期满真删；`--now` = 立即真删；`--restore <id>` = 撤回 |
