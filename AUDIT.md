# AUDIT —— 按 SPEC 逐节对照

> 审计对象：本项目（v2.1，代码基线 **446fd66**）在 2026-10 本轮改版后的状态。
> 验收标准：那份 12 节设计 SPEC（时间+事件二维图、五档分区、遗忘流水线、人格卡与三层锚点、情感层、上下文组装、落地选型、三条铁律、8 个待定参数）。
> 证据行号全部指向 `scripts/memtree.py`（改动后约 1.5k 行）。自检 `bash scripts/selftest.sh` → **通过 114 / 失败 0**（24 组）。

## 一句话结论

**memtree 实现的是 SPEC 的「状态层」骨架，不是全部。**
时间轴第一索引、时间覆盖、内容寻址、保护位、硬锚点、热度计时器这几件事做到了可用；
事件聚合、五档分区、情感层、人格卡版本化、分层检索（先剪枝再算相似度）都还没有。
把它当「记忆系统的写入层 + 现状层」用是对的，当 SPEC 的完整实现读会高估它。

## 逐节对照

| SPEC 节 | 状态 | 落在哪 | 缺什么 |
|---|---|---|---|
| §1 时间+事件二维图 | **部分** | 时间维是骨架（`nodes.t` 单一真相 + `w`）；事件维只有 `subject` 分组 | 没有独立的事件节点、没有跨期时间区间、没有「先命中事件再展开」 |
| §1 球体模型 | **部分** | `context --budget` 硬预算 + 溢出标记（:603） | 没有独立的「回看预算」，回看靠一次 `recall` 手动花 |
| §1 忒修斯之船 | **已实现** | 覆盖只把旧正文转冷（`blobs.hot=0`），只有 `purge` 抹正文 | — |
| §2.1 时间轴第一索引 | **已实现** | 写入、上下文边界、检索、压缩全部按 `t` | — |
| §2.2 事件聚合节点 | **部分**（本轮落地最小版） | `nodes.event` 受控短标签（≤24 字，超长直接拒写）；`context` 事件轴段 `▣ 名 起~止 n条` 即跨期时间区间；现状行尾 `⟦名⟧`；`recall --event` 在分支过滤之后、算相似度之前剪枝（先剪枝后相似度） | 事件边界仍由外部 Agent 给（未做会话分段）；没有独立事件节点/事件级权重；同类型事件的秩位衰减未做 |
| §2.3 三档时间权重 | **部分** | 过去衰减 `0.5^(abs(dt)/45d)`（:80 区域）、时间窗 `--days`、未来对称衰减 | 未来「越临近越高、过期转历史」是用 `abs()` 近似出来的，不是独立方向项；同类型事件的秩位衰减完全没有 |
| §3 五档分区 | **已实现** | `nodes.zone`（hot/warm/cold/archive/tombstone）+ `zone_target()` + `zone --migrate` 单向降级；`blobs.hot` 0/1/2 是存储态 | 归档区磁盘配额、分区按分支差异化阈值没做 |
| §4.1 热度=计时器 | **已实现** | `heat_of()`：只算「距上次访问」，绝不累计次数；`compress --heat` 是唯一消费者 | — |
| §4.1 动态因子采样（本轮新增） | **已实现** | `signal` 采样 → `settle` 一次性结算 → `label` → `pinned`；`_judge()` 走规则不调 LLM；`settle_log` 留审计 | 情感摘要的 `emotion_tags` 尚未结构化落库（目前只存 `signals.quote`） |
| §4.2 分类型压缩阈值 | **未实现** | 单一 `--days/--min-count/--heat` | 普通/重要/情感锚点三档阈值 |
| §5 遗忘五级流水线 | **部分**（①本轮完成） | ①**事件内细节梯度**：`compress --keep-detail` 按 `event` 分组、组内最新 N 条留原文，`is_conclusion()` 强制结论必留（:1205-1285）；②事件级合并 `compress`；③影响隔离（`superseded` 不进 context）；⑤硬删除 `purge`（带保护位拦截 :797）；保护位 `pinned` | ④归档区只是 `status='archived'`，默认不加载靠代码过滤而非独立存储；事件边界仍靠外部 Agent 给（会话分段未做）；没有事件级独立节点与事件级权重 |
| §5.4 保护位 | **已实现** | `--pin` / `pin <id> --off`（:411）；context 永不裁剪、compress 跳过、purge 拒绝 | — |
| §6 人格卡 | **未实现** | 最基础形态：`type=anchor` 独立成段、永不裁剪、被更新 fact 撞上标 `⚑锚点未变`（:388-407） | 没有 token 上限、没有版本化、没有卡内预算分配（硬/软/可变三层）、没有变更日志、没有漂移检测 |
| §6.4 冲突检测 | **部分** | 锚点与现状并存时打 ⚑ 标记，不静默覆盖 | 不落 `conflict` 状态，没有「候选取舍」流程 |
| §7 情感层 | **部分** | `label='emotional'` 自动拿保护位；`source_type=roleplay` 挡住虚构污染；`signals.quote` 保住用户原话 | 没有独立的 `emotion_tags / intensity` 结构化落库；检索权重里没有情绪相关性（SPEC 要求与时间并列为主权重） |
| §8.1 上下文组装 | **部分** | 组装顺序固定：锚点 → 现状 → 分支 → 事件 → 图例；硬预算；溢出显式标记（:603） | 不含情感状态层、不含 3~5 条热记忆预取、滑窗归 Agent 侧 |
| §8.3 分层检索 | **部分** | 时间窗 `--days` + 权重打分（时间×语义×结果） | 「时间窗剪枝 → 事件标签过滤 → 混合相似度 → 加权排序 → 逐级展开」是一条流水线，现在是单遍打分；没有事件标签这一层 |
| §9 落地选型 | **部分** | SQLite 元数据 ✅、单文件零依赖 ✅、CLI+JSON 工具接口 ✅ | 原文没有落到文件系统（在 `blobs` 里）、没用 FTS5/sqlite-vec、无后台调度（没有日终 consolidation）、无 MCP 封装、无 `update_persona / affect.update` |
| §9 MVP P1 | **已实现** | 建表 + 写入 + 覆盖 + 时间窗检索 + context 组装 | — |
| §9 MVP P2 | **部分** | 热度衰减 + 压缩 + 归档 | 无区域迁移、无日终 consolidation 调度 |
| §9 MVP P3 / P4 | **未实现** | — | 情感层、漂移检测、评估埋点、可视化 |
| §10 铁律一（时间定位置、调用只微调） | **已实现** | `refs` 只记录，从不进排序；`accessed_at` 只喂热度 | — |
| §10 铁律二（被问得多 ≠ 值得记住） | **已实现** | 热度不升区、不进 context、不参与排序；`repeat_mention` 单独结算成 `noise` 后加速淘汰 | — |
| §10 铁律三（热度是计时器） | **已实现** | 见 §4.1。热度影响保留的唯一通道是 `settle` 的一次性结算——离散、留审计，不是连续延长寿命 | — |
| §12 八个待定参数 | **部分** | 已定并落地：热度代理=距上次访问（乘性） | 未落地：分类型压缩阈值、秩位快照（没有秩位）、情感锚点豁免、分区天数与重要性下限、人格卡 token 上限、归档配额与清理、摘要用本地模型 |

## 本轮改了什么（对照旧版）

| # | 改动 | 位置 | 为什么 |
|---|---|---|---|
| 1 | 时间权重改对称衰减 `2^(-|Δt|/45)` | :80 一带 / time_weight | 旧版未来时间戳拿满分，一条 2030 笔误永久霸榜（SPEC §2.3） |
| 2 | `--outcome / --refs / --ts` 参数校验 | :163 `_range()`、parse_ts | 脏值入库后污染排序；非法时间戳原来抛裸 traceback |
| 3 | `pinned` 保护位：`--pin` / `pin --off` | :411 `cmd_pin` | SPEC §5.4「保护位永不进压缩归档、永不硬删」 |
| 4 | `type=anchor` 硬锚点 + ⚑ 冲突标记 | :388-407 | SPEC §6「最近定义现在，锚点定义始终」；旧版 anchor 会被同 subject 的 fact 直接吞掉 |
| 5 | 热度 `heat_of()` + `stats` 热度分布 | :80 / :937 | SPEC §4.1 与铁律三；旧版压缩只看 `--days`，没有「被访问过就该缓一缓」 |
| 6 | context 溢出显式标记 | :603 | 旧的静默截断会让 Agent 笃定回答「没记录过」——这是最贵的一类幻觉 |
| 7 | 非 ASCII 词面向量化（emoji/假名/韩文） | :102 `_terms()` | 旧版这类记忆是零向量，恒定 `sem+0.00`；陪伴场景 emoji 密度最高 |
| 8 | `bin/memtree` + `bin/memtree.cmd` 入口 | bin/ | SKILL.md 全程教裸 `memtree`，仓库里根本没有这个命令 |
| 9 | `recall` 低置信标记 | :710 / :723 | Σ=0 的噪声命中原来当证据展示；现在词面零重合会明说 |
| 10 | `compress` 默认分支改 HEAD、跳过保护位、`--heat` | :902 | 旧版写死 `main`，在别的分支上压缩静默 0 条 |
| 11 | 自检 20 → 52 项 | scripts/selftest.sh | 上面每一项都要有回归测试，尤其「未来笔误不霸榜」和「保护位扛住裁剪」 |
| 13 | **事件层最小版**（SPEC §2.2） | scripts/memtree.py :237 `event` 列 / `_migrate` / `cmd_commit` / `cmd_context` 事件轴 / `cmd_recall --event` | 索引必须等 `_migrate` 补列之后再建——写进 `executescript` 会让老库一打开就报错并整段回滚，升级即崩。自检 [19][20] 专测「事件随正文入上下文」与「缺列老库能平滑升级」 |
| 14 | **五档分区 `zone` + 单向迁移器**（SPEC §3/§4） | scripts/memtree.py `zone_target()` / `cmd_zone()` / `cmd_commit --importance` / `cmd_context` 分区门 / `cmd_recall --zone` / `cmd_stats.by_zone` / `cmd_compress` 跳过归档 | 分区只由「时间 + 重要度 + 保护位」决定：降级自动、升级必须 `--set`（铁律一/二）。老库补列后立刻按时间回填一次，否则新建列全 hot、单向降级从第一天就不成立。冷/归档被隐藏时必须显式说出条数，不许静默丢状态 |
| 15 | **墓碑区 + 两段式删除**（SPEC §3/§5.5） | scripts/memtree.py `cmd_purge()` 重写 / `PURGE_COOLDOWN_DAYS=7.0` / `nodes.tombstoned_at` `purge_reason` / `cmd_zone` 双向拒绝绕过分区接口 / `cmd_context` 墓碑计数与隐藏 / `cmd_recall` 默认排除 / `cmd_stats.tombstone` / `cmd_log` 🪦 标记 | 不可逆的决定必须留缓冲：`purge` 原来一按就烧，地址还在、正文没了。现在默认进墓碑区冷却 7 天，`--apply` 才真删、`--restore` 可撤回。墓碑区**不许**用 `zone --set` 进出——删除要走 purge 的理由与冷却，不能借分区接口绕过 |
| 16 | **事件内细节梯度压缩 + 结论必留**（SPEC §5 ①） | scripts/memtree.py `is_conclusion()`（:1205）/ `cmd_compress()` 重写（:1216-1285）/ `--keep-detail`（默认 1）/ `nodes.rolled_into` / `meta{rolled,ids,event,kept_detail}` | 旧实现「把一个分支里所有旧事件糊成一条摘要」——细节和结论一起没了，再想问「当时为什么这么定」只剩悬空地址。现在按 `event` 分组：组内最新 `--keep-detail` 条细节留原文，更老的够 `--min-count` 条才压成一条 `summary`（正文 `[压缩N条] 片段；片段；…`，`t` 回填最早那条、`event` 标签继承 → 事件轴不被打断），被压节点 `status='archived'` + `rolled_into` + `blobs.hot=0` 仍可按地址回溯；`decision/anchor/merge`、`outcome≠0`、`label∈{anchor,emotional}`、`pinned` 一律不压 —— **梯度只压细节，结论无论多老都不动**。自检新增 [24] 共 20 条断言：梯度归档 / `rolled_into` 指向 / `hot=0` 非删除 / 最新 N 条逐字保留 / 事件标签继承 / 两事件不合并 / 四类结论必留 / `conclusions_preserved` 精确性 / `--keep-detail 0` 退化 / 二次压缩幂等 |
| 12 | 文档校准（schema/README/SKILL） | references/schema.md、README.md、SKILL.md | README 的 554 token / 20 项自检已与实现不符；实测 context 358 token；本轮补 `event` 列与 `▣/⟦⟧` 图例 |

## 明确没做（别误以为有）

- **事件层只有最小版**：`nodes.event` 是受控短标签 + 时间区间聚合，能回答「这三个月围绕哪几件事」，但没有独立事件节点、没有事件级权重、事件边界仍靠外部 Agent 给（会话分段未做）。`subject` 仍然是「谁和谁比」的分组键，别当事件用。
- **分区只做了前四档**：`zone` 列 + `zone --migrate` 单向降级（hot≤7d → warm 7~90d → cold[重要度≥0.7 或保护位] → archive），升级必须 `zone --id <n> --set`。**墓碑区已做**：`purge` 改成两段式（进墓碑 → 冷却 7 天 → `--apply` 真删），冷却期内 `--restore` 可撤回、`--now` 给隐私开直通车。
- **没有情感层**：情绪、强度、金句、关系里程碑都无处可存（里程碑只能塞 `type=anchor`）。
- **没有自动抽取**：写什么、`subject` 叫什么、摘要写什么，全由外部 Agent 决定。`subject` 的自由生成是本系统唯一的失败入口。
- **没有 LLM 调用**：这就是零依赖的代价——「零 LLM 成本」对整条链路不成立，每轮仍要外部 Agent 抽一次。
- **`competing` 状态无写入路径**：`recall --status competing` 恒为空，相关分支是死代码（保留位，见 schema.md §5）。
- **分支语义弱**：`scope=global` 的 fact/pref 跨分支互相覆盖，分支 DAG 在状态层被抹平；合并后的分支仍可 checkout 写入（只改 `branches.status`，未拦截）。

## 下一期建议（按投入产出排序）

1. **受控 subject 枚举**：在 SKILL.md 里给出枚举表并让抽取器只能选，不自由生成。这一条的收益大于剩下所有 bug 的总和。
2. ~~事件层最小版~~（已完成：`event` 列 + 事件轴 + `recall --event` 剪枝）。剩下的：会话分段自动划事件边界、事件级权重、同类型事件秩位衰减。
3. ~~`zone` 列 + 单向迁移器~~ ~~墓碑区 + 硬删除冷却期~~ ~~「压缩只压细节」（事件内细节梯度 + 结论必留）~~（均已完成）。剩下：归档区磁盘配额。
4. **情感层独立表**：`affect(ts, emotion_tags, intensity, key_quote, event_id)`，会话内内存、结束时落一条；情感锚点用 `pinned + emotional_anchor` 双标记。
5. **人格卡**：单独文件 + token 上限 + 变更日志；先把「卡从哪来、谁批准改」定下来，再谈版本化。

## 怎么复核本文件

```bash
bash scripts/selftest.sh          # 期望：通过 114 / 失败 0
python scripts/memtree.py context --budget 200   # 期望：末行有「⚠ 还有 N 条未展开」
python scripts/memtree.py stats                   # 期望：有 protected 与 heat 两段
```

行号会随改动漂移，函数名不会：`heat_of` / `_terms` / `_range` / `cmd_pin` / `_heat_hist` / `cmd_context`。