---
name: memory-timeline
description: 跨会话长期记忆库（SQLite + CLI，零依赖）。时间轴做主索引：同 subject 下新记忆按时间覆盖旧状态，避免"既喜欢 A 又喜欢 B"；旧正文转冷只留内容地址，可回溯"当初为什么改"。用于记住用户事实/偏好/决定、给长对话省 token、回答"我以前说过什么"。触发词：记住、长期记忆、时间轴记忆、记忆覆盖、agent memory。
agent_created: true
---

# memtree — 时间轴记忆

数学只有一句：`w = 2^(-Δt/45天)`，越新越大。同一 `subject` 内时间最大者为现状，其余立刻转 `superseded`。**覆盖只看时间**，不看结果值/可信度/重复次数——那些只服务检索定位。

## 写：什么时候 commit

| 场景 | 命令 |
|---|---|
| 稳定偏好 / 属性 | `commit "内容" --type fact --subject user.xxx` |
| 用户拍板做了选择 | `commit "..." --type decision --subject proj.xxx` |
| 发生了有结果的事 | `commit "..." --type event --outcome 0.8` |
| 只是"如果 / 试试" | `commit "..." --type hypothesis` |

- `--outcome`：成功 `+0.5~1`，失败 `-0.5~-1`，中性省略。**漏填等于丢掉一维**，以后没法按"当时成功还是失败"定位。
- `subject` 必须稳定（写 `user.coffee`，不写"咖啡"）。**命名不稳 = 覆盖失效**，这是整套机制唯一的失败入口。

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
■ proj.plan: 方案B 已上线，延迟 90ms  (曾:方案A 内存泄漏@10-01)
◇ proj.idea: 设想用 sqlite-vec 做召回
· 09-01 [压缩3条] 起步；选型；确定 5 分钟 K 线
※ ■现状 ◇假设 ○分支 ·事件  (曾:…@日期)=已废弃，禁止当作现状
```

`■` 是现状，可直接当事实；`(曾:…)` 是墓碑，只能解释"以前怎样"；`◇` 是没验证的假设，不能当结论。**最后一行图例必须原样带给模型**，它是防幻觉的关键。

## 铁律

1. **只有 ■ 是现状。** `(曾:…)` 禁止当结论，`◇` 禁止当事实。
2. **不得跨时间合并状态**——不能把"曾喜欢美式"和"现在喜欢拿铁"合成"美式拿铁"。
3. **查不到就说没有**，不要用常识补。
4. **涉及"以前"必须给日期。**
5. **每轮只注入 `context`，不要塞 `log`。** log 一次 1000+ token，是 context 的 1.6 倍；两者一起塞比不记忆还费。

## 反模式

- ❌ 每条都 `--type fact` → 事件被当状态，覆盖逻辑误伤
- ❌ `subject` 随手写 → 覆盖失效，两条状态并存
- ❌ `--outcome` 一律省略 → 白丢一维
- ❌ 分支写完忘 `checkout main` → 后续记忆全掉进侧枝

## 其它

`branch try-1 --from 5` 分叉 · `checkout try-1` 切换 · `merge try-1 --summary "…"` 合并并归档 · `compress --days 30` 旧事件压成一行摘要 · `graph` 出 Mermaid 图 · `stats` 统计

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

自检 20 项：`bash scripts/selftest.sh`。
数学推导见 `references/theory.md`；表结构与状态机见 `references/schema.md`。
