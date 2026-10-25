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
| `type` | `event/fact/pref/decision/hypothesis/summary/merge` |
| `scope` | `global`（跨分支共享）/ `branch` |
| `factor` | 墓碑/压缩标记，`曾:美式@09-15` |
| `refs` | 被强化次数（仅记录，不参与权重） |
| `supersedes` / `superseded_by` | 覆盖链双向指针 |
| `status` | `active / superseded / archived` |
| `branch` / `parent_id` | 分支与 DAG 前驱 |

### branches / kv

`branches(name, fork_node, head_id, status, merged_into)`；`kv` 只存 `head`。

## 5. 状态机

```
                 同 subject 且 t 更大
   active ──────────────────────────► superseded   （正文转冷，只留地址）
     │
     ├── merge 分支成员 ─────────────► archived
     │
     └── compress 覆盖的旧事件 ──────► archived
                                         │
                                    purge│
                                         ▼
                                   正文清除，地址悬空（hot=2）
```

- 只有 `active` 进 `context` 的 `■`。
- `superseded` 只以 `factor` 出现在新记忆的括号里。
- `purged` 的地址仍可用于**去重**和"曾经有过这条"的溯源，但取不回原文。

## 6. 权重

```
w = 2^(-Δt/45天)        Δt = now - t
```

只用时间，越新越大，严格单调。同 `subject` 组内 `max(t, id)` 为现状，其余立即降级。

为什么不让可信度/结果值参与：一旦混入，就要定义"多少次确认能压过多新的改口"，规则会迅速变复杂且不可预测。**覆盖只回答"现在是什么"，其它维度只服务检索。**

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
| `purge` | gc | 正文真删，只留地址 |
