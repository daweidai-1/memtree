# 数据结构与状态机

> 数学推导（复平面模型、打分分解、时间旅行）见 [theory.md](theory.md)。本文件只讲表、状态机与命名。

## 4. 表

### blobs（内容寻址存储）

| 字段 | 说明 |
|---|---|
| `addr` | `sha256(正文)[:16]`，主键。相同内容天然去重 |
| `content` | 正文。`purge` 后置空 |
| `hot` | `1`=热（参与检索/上下文）`0`=冷（只可按地址取回）`2`=已清除 |

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
| `factor` | 墓碑/压缩标记，`曾:美式@09-15`；压缩摘要记 `压:09-01~09-20/3条` |
| `meta` | JSON。压缩摘要节点记 `{"rolled":N,"ids":[…],"event":"…","kept_detail":[…]}`，其它路径留空 |
| `rolled_into` | 被 `compress` 压进哪条 `summary` 节点的 id。NULL = 没被压过 |
| `refs` | 被强化次数（仅记录，不参与权重） |
| `supersedes` / `superseded_by` | 覆盖链双向指针 |
| `status` | `active / superseded / archived`（`competing` 为保留值，当前无写入路径） |
| `branch` / `parent_id` | 分支与 DAG 前驱 |
| `pinned` | INTEGER 0/1，保护位。1 = context 永不裁剪、compress 永不覆盖、purge 拒绝硬删 |
| `tombstoned_at` | REAL，进墓碑区的时刻。`now - tombstoned_at >= 7天` 才允许 `purge --apply` 真删 |
| `purge_reason` | 删除理由（隐私/错误/用户要求）。删完也保留，用于事后审计 |
| `accessed_at` | REAL，epoch 秒，最后一次被 `recall`/`signal` 碰过的时间。**只用于算热度，不累计次数** |
| `label` | `anchor / emotional / noise / NULL`。**`settle` 的结算产物**：写入后不可由热度改写 |
| `zone` | `hot / warm / cold / archive / tombstone`。**只随时间单向降级**：≤7d 热、7~90d 温、更旧则 `importance ≥ 0.7`（或保护位/锚点）进冷区、否则归档。升级只能 `zone --id <n> --set` —— 调用次数不许升区 |
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
| `quote` | 用户原话，情感场景要用它保住金句 |
| `settled` | 0 = 待结算，1 = 已结算并清空参与资格 |

### settle_log（结算审计）

没有这张表，"为什么这条被打成重要"就不可回答 —— 那和 LLM 黑箱没区别。

`node_id, signal_types, old_pinned, new_pinned, old_label, new_label, reason, at`

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
                                         │
                                    purge│
                                         ▼
                                   正文清除，地址悬空（hot=2）
```

- 只有 `active` 进 `context` 的 `■`。
- `superseded` 只以 `factor` 出现在新记忆的括号里。
- `purged` 的地址仍可用于**去重**和"曾经有过这条"的溯源，但取不回原文。
- `pinned=1` 的节点不参与任何降级：`compress` 跳过它，`purge` 直接拒绝（要清先 `pin <id> --off`）。
- `competing` 是保留状态位：用于「两条现状互相矛盾、等用户裁决」的场景，目前没有写入路径，`recall --status competing` 恒为空。
- `compress` 只动**细节**：被压的细节转 `archived` 并在 `rolled_into` 记住去处，结论节点原样留在 `active`——见 §5.5。

## 5.5 压缩：事件内细节梯度（SPEC §5 ①）

`compress` 的唯一职责是**在事件内部**降细节密度，不做跨事件的糊合。三段流水线：

```
候选筛选 → 按 event 分组 → 组内梯度（最新 keep_detail 条留原文 / 更老的压一行）
                              ↘ 结论命中 is_conclusion() 的节点整组跳过
```

### 候选

`status='active'` 且 `t < --before`（或 `now - --days`，默认 30 天），并且：

| 条件 | 说明 |
|---|---|
| `type='event'` 或 `event` 非空 | 压缩必须在事件内部做，跨事件糊成一条就丢了「哪个结论属于哪件事」 |
| `type != 'summary'` | 摘要的摘要不可逆丢信息 |
| `branch = --branch`（默认当前 HEAD） | 旧实现写死 `main`，侧枝的旧事件永远压不到 |
| 不是分支 `fork_node` / `head_id` | 分叉点与 HEAD 被引用，压掉就断开历史 |
| `zone != 'archive'` | 归档区已压过一轮 |
| `pinned=0` | 保护位永不进压缩（SPEC §5.4） |
| `--heat` 未给，或 `label='noise'`，或 `heat_of(r) <= --heat` | 热度门：只压「久没被碰过」的；`noise` 豁免是加速淘汰，不是放宽标准 |

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
| 热度 `heat` | `max(accessed_at, t)` 现算 | **只触发压缩**（`compress --heat`） | 排序、分区归属、压缩后去向 |
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
