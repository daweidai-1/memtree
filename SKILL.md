---
name: memory-timeline
description: 跨会话长期记忆库（SQLite + CLI，零依赖）。时间轴做主索引：同 subject 下新记忆按时间覆盖旧状态，避免"既喜欢 A 又喜欢 B"；旧正文转冷只留内容地址，可回溯"当初为什么改"。用于记住用户事实/偏好/决定、给长对话省 token、回答"我以前说过什么"。触发词：记住、长期记忆、时间轴记忆、记忆覆盖、agent memory。
agent_created: true
---

# memtree — 时间轴记忆

数学只有一句：`w = 2^(-|Δt|/45天)`，离当下越远越小（**未来也一样衰减**）。同一 `subject` 内时间最大者为现状，其余立刻转 `superseded`。**覆盖只看时间**，不看结果值/可信度/重复次数——那些只服务检索定位。

## 命令入口

本 skill 零依赖、不装包，所以有两种等效写法（下文一律简写为 `memtree`）：

```bash
memtree context                 # 把 <skill>/bin 加进 PATH 后可用
sh <skill>/bin/memtree context  # 不改进 PATH 时用这个
python <skill>/scripts/memtree.py context   # 最裸的一种，等价
```

- 解释器按 `$MEMTREE_PY` → `python3` → `python` → `py` 顺序自动找；全找不到会明确报错而不是静默失败。
- Windows 用 `bin\memtree.cmd`（或直接 `py -3 scripts\memtree.py`）。


## 写：什么时候 commit

| 场景 | 命令 |
|---|---|
| 稳定偏好 / 属性 | `commit "内容" --type fact --subject user.xxx` |
| 用户拍板做了选择 | `commit "..." --type decision --subject proj.xxx` |
| 发生了有结果的事 | `commit "..." --type event --outcome 0.8` |
| 只是"如果 / 试试" | `commit "..." --type hypothesis` |

- `--outcome`：成功 `+0.5~1`，失败 `-0.5~-1`，中性省略。**漏填等于丢掉一维**，以后没法按"当时成功还是失败"定位。
- `subject` 必须稳定（写 `user.coffee`，不写"咖啡"）。**命名不稳 = 覆盖失效**，这是整套机制唯一的失败入口。
- `event` 是**受控短标签**（≤24 字，如 `转岗`/`搬家`），不是句子。同一件事聊三次就用同一个 event，`context` 会聚成一行跨期区间；写太长会直接被拒（事件名字里塞句子，聚合层就退化成第二个 subject）。
- `--pin`：打**保护位**。永不从 context 裁剪、不自动压缩、不被 purge 硬删。给"重要但低频"的冷信息用（生日、约定、禁忌）。
- 删除走**两段式**：`purge --addr <addr> --reason 隐私` 先进墓碑区（正文还在、冷却 7 天、`purge --restore <id>` 可撤回），到期 `purge --apply` 才真删；隐私/错误信息用 `purge --addr <addr> --now` 立即删。一按就烧的删除是不可逆的决定，必须留缓冲。
- `--type anchor`：**硬锚点**。身份/关系里程碑/安全约束用这类，它独立成段显示、不与现状互相覆盖。
  - 现状（fact/pref/decision）遇到同 subject 的活跃锚点时不会被静默吞掉，只在 context 里标 `⚑锚点未变`。
- `--source roleplay`：**角色扮演/虚构内容**。它情绪再高也不会进情感锚点，防止把台词写进事实库。

## 读：三个命令够用

```bash
memtree context                                          # 每轮注入，默认 650 字符
memtree recall "咖啡" --at 2026-09-10 --outcome 0.9       # 按「时刻 + 成败」定位
memtree log --brief --width 28                            # 时间轴速览（1357 → 696 token）
```

补充：`recall "方案" --status any`（连已废弃的一起看，会标注）、`show <id>`（来龙去脉 + 覆盖链）、`verify <addr>`（地址校验正文）。

`--at T` 问的是**T 那一刻的现状**（按 `gone_at` 判，命中读全文、同时回 `status`当时 / `status_now`现在 与 `as_of_stats`），不是「现在相关、时间靠近 T」；`t` 在未来的条目任何 `--at` 都不返回，`context` 里它们单独排在 `⏳` 段、不参与现状判定。

## context 输出怎么读

```text
【记忆 2026-10-18 | main#13 | 14节点·废11】
⚓人格·硬 我是小白，老大的人；先建直觉再上公式
⚓ user.identity: 她叫小满，2024-03 起每月 8 号聊一次
■ proj.plan: 方案B 已上线，延迟 90ms  (曾:方案A 内存泄漏@10-01)
■ user.coffee: 只喝冰美式不加糖  ★钉
◇ proj.idea: 设想用 sqlite-vec 做召回
· 09-01 [压缩3条] 起步；选型；确定 5 分钟 K 线
▣ 转岗 08-01~10-05 3条
※ ⚓锚点 ⚓人格 ■现状 ▣事件轴 ⟦事件名⟧ ❄冷 🪦墓碑 ★钉=保护位 ◇假设 ○分支(回顾点) ·事件  (曾:…@日期)=已废弃，禁止当作现状
⚠ 还有 26 条未展开（现状 26 / 事件 0） —— 不要据此回答「没有记录」
```

`⚓` 是硬锚点（身份/里程碑，永远在、永不裁）；`■` 是现状，可直接当事实；`❄冷` 是冷区（重要但低频，仍在库里、默认不占热区）；`🪦墓碑` 是已受理删除、冷却还没满（正文还在、能 `purge --restore` 撤回，但检索和上下文都看不到）；`▣` 是事件轴（事件名 + 起止区间 + 条数，跨多天聊的同一件事只有一行）；`⟦名⟧` 是这条现状属于哪个事件；`★钉` 是打了保护位的现状；
`(曾:…)` 是墓碑，只能解释"以前怎样"；`◇` 是没验证的假设，不能当结论。**图例行必须原样带给模型**，它是防幻觉的关键。

`⚓人格·硬 / ⚓人格·软 / ⚓人格·可变` 是人格卡三槽（见下节）：排在锚点之前、计入 `--budget` 但永不被裁，卡为空时这三行内容行一个都不出现（图例里的 `⚓人格` 符号仍固定存在）。

末行的 `⚠ 还有 N 条未展开` 表示**输出被预算截断**了：超预算时 context 会砍掉较早的现状。
看到这一行就不要说"没有记录"，改用 `recall` / `log --brief` 查全，或调大 `--budget`。

## 人格卡（SPEC §6）：改硬槽要 --force

人格卡是**独立文件**（默认 `<库路径>.persona.md`，`--persona-file` 覆盖），三段固定标题、固定顺序 `## 硬槽` / `## 软槽` / `## 可变槽`，槽内一行一条、以 `- ` 开头，空槽保留标题。`nodes` 表里**没有**人格条目，`--type anchor` 的语义一个字没变。

```bash
memtree persona show [--json] [--at 2026-09-01]   # 现在的卡 / 那一刻的卡
memtree persona set "我是小白，老大的人" --slot hard [--force] [--reason 初始]
memtree persona set "先建直觉再上公式" --slot soft
memtree persona drop "过期的那条" --slot var       # 硬槽 drop 同样要 --force
memtree persona log [--limit 20] [--json]         # 改过什么：add / del / evict
```

- **硬槽 `set` / `drop` 都必须带 `--force`**：它是"我是谁"的护栏。人格漂移和记忆覆盖不一样，它不会自己回滚；删除也不能绕过这道闸 —— 所以默认改不动（被拒时卡文件和日志都不动；不存在的条目仍按幂等返回）。
- 预算（`est_tokens`：中文 1 字≈1.5 token）：硬 ≤300 / 软 ≤350 / 可变 ≤150，整卡 ≤800 是兜底闸。硬槽超预算**直接拒写**（不挤别人）；软/可变超预算按**最旧优先**挤出，并留 `op=evict` 日志；挤到只剩新条目仍超 → 整条回滚、`exit 2`。
- 卡非空时 `context` 多三行 `⚓人格·硬 / ⚓人格·软 / ⚓人格·可变`（只出非空槽、排在锚点之前、计入 `--budget` 但**永不被裁**）；卡为空时不出现这三行内容，图例符号不变。
- **卡是"现在是什么"，日志是"改过什么"**：`persona show --at T` 靠 `persona_log` 正向重放到那一刻（T 早于首次写入 → `(卡为空)`）。卡文件没有历史，别指望从文件里翻旧人格。

## 情感层（SPEC §7）：只在显式查询时排序

```bash
memtree signal <id> --type emotional_peak --tags 喜悦,信任 --intensity 0.9 --valence 0.8 --quote "原话"
memtree settle                                    # emotional_peak → 结构化 affect 行
memtree affect show <id> [--json]                 # 一条记忆的全部情感观察
memtree recall "…" --emotion 喜悦 [--emotion-weight 0.5]
```

- 固定 8 类 + `unspecified`，中文别名可用；未知标签直接拒绝。`roleplay` 永不进入情感层。
- **不带 `--emotion` 时情绪维完全休眠**，输出与旧版一致；带情绪时时间占 `1-α`、情绪占 `α`（默认 0.5）。
- 情绪只影响本次排序，不改 status / 分区 / 保护位 / 压缩 / 保留时长。`purge` 真删时级联删 `affect`。

## 分层检索 v2（灰度）

`recall "…" --pipeline v2 [--expand 20]`：有效性门 → 时间窗 → 事件过滤 → 混合相似度 → 加权排序 → 事件级展开。`--json` 的 `pipeline` 报每级 `in/pruned/out` 与 `future_hidden`；`--at` 的时间窗锚定 T。**默认仍是 `legacy`**，别在未验证场景直接换默认。

## 铁律

1. **只有 ■ 是现状。** `(曾:…)` 禁止当结论，`◇` 禁止当事实。
2. **不得跨时间合并状态**——不能把"曾喜欢美式"和"现在喜欢拿铁"合成"美式拿铁"。
3. **查不到就说没有**，不要用常识补。带 `⚠ 还有 N 条未展开` 时，先补查再说"没有"。
4. **涉及"以前"必须给日期。**
5. **每轮只注入 `context`，不要塞 `log`。** log 一次 1000+ token，是 context 的 1.6 倍；两者一起塞比不记忆还费。
6. **访问不直接延长寿命。** `signal` 只入队、不做决策；`settle` 才一次性结算成标签，结算后保护位与热度脱钩。
   所以"被问得多"不会自动变重要 —— 除非它带 `user_confirm` / `correction` / 够强的情绪峰值。

## 反模式

- ❌ 每条都 `--type fact` → 事件被当状态，覆盖逻辑误伤
- ❌ `subject` 随手写 → 覆盖失效，两条状态并存
- ❌ `--outcome` 一律省略 → 白丢一维
- ❌ 分支写完忘 `checkout main` → 后续记忆全掉进侧枝

## 其它

`pin <id>` / `pin <id> --off` 打/取消保护位 · `graph` 出 Mermaid 图 · `stats` 统计（含热度与标签分布）

**采样 → 结算**（动态因子的第二职责：除了降噪，还要把"冷但重要"从冷里救出来）

```bash
memtree signal <id> --type user_confirm|correction|emotional_peak|repeat_mention [--intensity 0.8] [--quote "原话"]
memtree settle                 # 证据 → 标签：一次性、留审计，之后保护位与热度彻底脱钩
memtree label <id> anchor|emotional|noise|clear    # 手动打标
```

`user_confirm`/`correction` → `anchor` 自动拿保护位；情绪峰值 ≥0.7 且 `stated` → `emotional`；只有重复提及 → `noise`（豁免热度门，加速淘汰）。判定全是规则、不调 LLM，详见 `references/schema.md`。

`compress [--days N] [--min-count 3] [--heat 0.1] [--keep-detail 1]`：**事件内细节梯度**，越新越细（SPEC §5 ①）。

- **默认按类型分档**（SPEC §4.2）：普通 30 天、重要（`importance≥0.7` 或 `pinned`）90 天、情感锚点（`label=emotional` 或 `type=anchor`）**永不自动压缩**。显式 `--days` / `--before` 统一覆盖时间分档，但不绕过结论与保护位。
- 候选只限「事件本身 / 带 `event` 标签的条目」，按 `event` 分组，**不跨事件合并**；同事件内最新 `--keep-detail` 条细节留原文，更老的够 `--min-count` 条才压成一条 `summary` —— 正文 `[压缩3条] 片段；片段；…`，`t` 回填最早那条、`event` 继承，事件轴不断。
- **结论必留**：`decision/anchor/merge`、`outcome≠0`、`label∈{anchor,emotional}`、`pinned` 的节点无论多老都不压。
- 被压原文不丢：`status=archived` + `blobs.hot=0` + `rolled_into`，内容地址仍可 `show` / `verify` 回溯。
- `--heat` 是热度门，只压"久没被碰过"的旧事件；`label=noise` 豁免（加速淘汰）。`--text` 覆盖摘要正文，`--before` 指定截止时刻。

`branch try-1 --from 5` 分叉 · `checkout try-1` 切换 · `merge try-1 --summary "…"` 合并并归档

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

自检 337 项（33 组）：`bash scripts/selftest.sh`。
数学推导见 `references/theory.md`；表结构与状态机见 `references/schema.md`。
