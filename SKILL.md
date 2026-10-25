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

## context 输出怎么读

```text
【记忆 2026-10-18 | main#13 | 14节点·冷11】
⚓ user.identity: 她叫小满，2024-03 起每月 8 号聊一次
■ proj.plan: 方案B 已上线，延迟 90ms  (曾:方案A 内存泄漏@10-01)
■ user.coffee: 只喝冰美式不加糖  ★钉
◇ proj.idea: 设想用 sqlite-vec 做召回
· 09-01 [压缩3条] 起步；选型；确定 5 分钟 K 线
▣ 转岗 08-01~10-05 3条
※ ⚓锚点 ■现状 ▣事件轴 ⟦事件名⟧ ★钉=保护位 ◇假设 ○分支(回顾点) ·事件  (曾:…@日期)=已废弃，禁止当作现状
⚠ 还有 26 条未展开（现状 26 / 事件 0） —— 不要据此回答「没有记录」
```

`⚓` 是硬锚点（身份/里程碑，永远在、永不裁）；`■` 是现状，可直接当事实；`▣` 是事件轴（事件名 + 起止区间 + 条数，跨多天聊的同一件事只有一行）；`⟦名⟧` 是这条现状属于哪个事件；`★钉` 是打了保护位的现状；
`(曾:…)` 是墓碑，只能解释"以前怎样"；`◇` 是没验证的假设，不能当结论。**图例行必须原样带给模型**，它是防幻觉的关键。

末行的 `⚠ 还有 N 条未展开` 表示**输出被预算截断**了：超预算时 context 会砍掉较早的现状。
看到这一行就不要说"没有记录"，改用 `recall` / `log --brief` 查全，或调大 `--budget`。

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

`compress --days 30 [--heat 0.1]`：`--heat` 是热度门，只压"久没被碰过"的旧事件。

`branch try-1 --from 5` 分叉 · `checkout try-1` 切换 · `merge try-1 --summary "…"` 合并并归档

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

自检 60 项：`bash scripts/selftest.sh`。
数学推导见 `references/theory.md`；表结构与状态机见 `references/schema.md`。
