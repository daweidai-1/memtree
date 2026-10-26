# AUDIT —— 按 SPEC 逐节对照

> 审计对象：本项目（v2.1，代码基线 **a9b4c68**）在 2026-10 本轮改版后的状态。
> 验收标准：那份 12 节设计 SPEC（时间+事件二维图、五档分区、遗忘流水线、人格卡与三层锚点、情感层、上下文组装、落地选型、三条铁律、8 个待定参数）。
> 证据行号全部指向 `scripts/memtree.py`（a9b4c68 上 2,550 行，行号以该提交为准；历史改动记录里的行号保留其当时提交口径）。自检 `bash scripts/selftest.sh` → **通过 366 / 失败 0**（34 组）。

## 一句话结论

**memtree 实现的是 SPEC 的「状态层」骨架，不是全部。**
时间轴第一索引、时间覆盖、内容寻址、保护位、硬锚点、热度计时器、五档分区、两段式删除、事件层最小版、事件内细节梯度压缩这几件事做到了可用；
人格卡（三槽预算 + `persona_log` 审计 + `--at` 回看）本轮也已落地；情感层已做**结构化 `affect` + 显式情绪检索**，但还没常驻 context / 自动打标；人格卡**版本化**（内容地址/快照/审批流）、分层检索成为默认路径、归档区磁盘配额还没有。
「过去」与「未来」两个方向本轮补齐了：`recall --at` 按 `gone_at` 判「那一刻谁是现状」，未来条目另起 `⏳` 段、不进现状、不免疫压缩；中间层已有结构化情绪，但还没有常驻情感上下文。人格卡只做到「有护栏、有审计、能回看」，没有版本化。
把它当「记忆系统的写入层 + 现状层 + 时点回溯层」用是对的，当 SPEC 的完整实现读会高估它。

## 逐节对照

| SPEC 节 | 状态 | 落在哪 | 缺什么 |
|---|---|---|---|
| §1 时间+事件二维图 | **部分** | 时间维是骨架（`nodes.t` 单一真相 + `w`）；事件维只有 `subject` 分组 | 没有独立的事件节点、没有跨期时间区间、没有「先命中事件再展开」 |
| §1 球体模型 | **部分** | `context --budget` 硬预算 + 溢出标记（`cmd_context()`，`⚠ 还有 N 条未展开` :1000） | 没有独立的「回看预算」，回看靠一次 `recall` 手动花 |
| §1 忒修斯之船 | **已实现** | 覆盖只把旧正文转冷（`blobs.hot=0`），只有 `purge` 抹正文 | — |
| §2.1 时间轴第一索引 | **已实现** | 写入、上下文边界、检索、压缩全部按 `t` | — |
| §2.2 事件聚合节点 | **部分**（本轮落地最小版） | `nodes.event` 受控短标签（≤24 字，超长直接拒写）；`context` 事件轴段 `▣ 名 起~止 n条` 即跨期时间区间；现状行尾 `⟦名⟧`；`recall --event` 在分支过滤之后、算相似度之前剪枝（先剪枝后相似度） | 事件边界仍由外部 Agent 给（未做会话分段）；没有独立事件节点/事件级权重；同类型事件的秩位衰减未做 |
| §2.3 三档时间权重 | **部分** | 过去衰减 `0.5^(abs(dt)/45d)`（`time_weight()` :76）、时间窗 `--days`、未来对称衰减 | 未来「越临近越高、过期转历史」是用 `abs()` 近似出来的，不是独立方向项；同类型事件的秩位衰减完全没有 |
| §3 五档分区 | **已实现**（+purged 终态） | `nodes.zone`（hot/warm/cold/archive/tombstone/purged）+ `zone_target()` + `zone --migrate` 单向降级；`purged` 只由 purge 真删进入，不参与检索/迁移/复生 | 归档区磁盘配额、分区按分支差异化阈值没做 |
| §4.1 热度=计时器 | **已实现** | `heat_of()`：只算「距上次访问」，绝不累计次数；`compress --heat` 是唯一消费者 | — |
| §4.1 动态因子采样（本轮新增） | **已实现** | `signal` 采样 → `settle` 一次性结算 → `label` → `pinned`；`_judge()` 走规则不调 LLM；`settle_log` 留审计 | 情感摘要的 `emotion_tags` 尚未结构化落库（目前只存 `signals.quote`） |
| §4.2 分类型压缩阈值 | **已实现**（T3，`9124f20`） | `cmd_compress()` :1754；默认普通 30 天 / 重要（`importance≥0.7` 或 `pinned`）90 天 / 情感锚点（`label='emotional'` 或 `type='anchor'`）永不自动压缩（`automatic_cut()` :1766-1772）；显式 `--days` / `--before` 统一覆盖时间分档（:1763-1764），但不绕过 `is_conclusion()` 与保护位；自检 [31] 11 条 | `pinned` 仍受更强的「保护位永不自动压缩」既有硬闸约束，不因重要档 90 天而解禁 |
| §5 遗忘五级流水线 | **部分**（①②③⑤已做，④仍缺） | ①**事件内细节梯度**：`compress --keep-detail` 按 `event` 分组、组内最新 N 条留原文，`is_conclusion()` 强制结论必留（`is_conclusion()` :1743 / `cmd_compress()` :1754-1841）；②事件级合并 `compress`；③影响隔离（`superseded` 不进 context、`gone_at` 让 `--at` 能判当时）；⑤**两段式硬删除** `purge`：进墓碑区 → 冷却 7 天 → `--apply` 才抹正文，三条硬拦（保护位含墓碑内的 / 共享地址还有活引用 / 墓碑里不许 pin）在 `cmd_purge()` :1266-1384；保护位 `pinned` | ④归档区只是 `status='archived'`，默认不加载靠代码过滤而非独立存储；事件边界仍靠外部 Agent 给（会话分段未做）；没有事件级独立节点与事件级权重 |
| §5.4 保护位 | **已实现** | `--pin` / `pin <id> --off`（`cmd_pin()` :610）；context 永不裁剪、compress 跳过、purge 拒绝，**墓碑区里的保护位同样挡硬删**（`pinned_refs()` :454 不看 zone） | — |
| §6 人格卡 | **已实现**（本轮，契约 J/J11） | 独立文件 `<db>.persona.md`（`persona_path()` :529-532，`--persona-file` 覆盖）；三段固定标题 `## 硬槽`/`## 软槽`/`## 可变槽`（`PERSONA_TITLES` :63）、一行一条 `- `；预算硬 300/软 350/可变 150/整卡 800（`PERSONA_SLOT_BUDGET` :66、`PERSONA_TOTAL_BUDGET` :67，用 `est_tokens()` :202）；`cmd_persona()` :622-722 中硬槽 `set` 必须 `--force`（:653-655），硬槽 `drop` 同样必须 `--force`（:689-703，契约 J11），超预算硬槽直接拒、软/可变最旧优先挤出并留 `op=evict`（:662-669）、挤不动整条回滚 `exit 2`（:670-673）；`persona_log` 表（:302-310）记 add/del/evict，`persona show --at T` 正向重放（`persona_replay()` :607-619）；`cmd_context()` 在首行后、锚点前插 `⚓人格·硬/软/可变` 三行、计入 `--budget` 但永不裁剪（:1185-1193），`--json` 增 `persona`（:1233-1239）；原子写（`persona_save()` :576-590） | 没有版本化（不进 `blobs`、无快照、无审批流）、没有漂移检测；卡文件被手改不进日志 |
| §6.4 冲突检测 | **部分** | 锚点与现状并存时打 ⚑ 标记，不静默覆盖 | 不落 `conflict` 状态，没有「候选取舍」流程 |
| §7 情感层 | **部分**（本轮结构化） | `affect` 独立表（`cmd_affect()` :633、建表 :306/:407）：`tags/intensity/valence/key_quote/source` 全落库；`signal --tags/--valence` → `settle` 聚合；固定 8 类 + `unspecified`；`recall --emotion` 激活情绪权重（α 默认 0.5，零命中自动退回 0 并报 `emotion.matched/alpha_applied`）；`roleplay` 双入口拒绝；`purge` 级联删 `affect`。自检 [32] 22 条 | 情绪还没有常驻进 `context` 的情感状态段；标签仍由外部 Agent 给，没有自动打标/LLM 抽取 |
| §8.1 上下文组装 | **部分** | 组装顺序固定：锚点 → 现状 → 分支 → 事件 → 图例 → `⏳` 未来段；硬预算；溢出显式标记（:1000） | 不含情感状态层、不含 3~5 条热记忆预取、滑窗归 Agent 侧 |
| §8.3 分层检索 | **部分**（v2 灰度） | `recall --pipeline v2`（`cmd_recall()` :1450）：有效性门 → 时间窗 → 事件过滤 → `0.85*cos+0.15*lexical` 混合 → 时间/情绪加权 → 事件单元展开；`pipeline` 每级报 `in/pruned/out`，未来单列 `future_hidden`；`--at` 锚定 T。自检 [33] 20 条；`--expand` 截断报 `units_skipped/members_dropped/warning` | 默认仍是 `legacy`，v2 尚未成为默认；事件级独立权重/秩位衰减仍未做 |
| §9 落地选型 | **部分** | SQLite 元数据 ✅、单文件零依赖 ✅、CLI+JSON 工具接口 ✅ | 原文没有落到文件系统（在 `blobs` 里）、没用 FTS5/sqlite-vec、无后台调度（没有日终 consolidation）；MCP 只有设计稿（`references/mcp.md`），**未实现**；无 `update_persona / affect.update` |
| §9 MVP P1 | **已实现** | 建表 + 写入 + 覆盖 + 时间窗检索 + context 组装 | — |
| §9 MVP P2 | **部分** | 热度衰减 + 压缩 + 归档 | 无区域迁移、无日终 consolidation 调度 |
| §9 MVP P3 / P4 | **未实现** | — | 情感层、漂移检测、评估埋点、可视化 |
| §10 铁律一（时间定位置、调用只微调） | **已实现** | `refs` 只记录，从不进排序；`accessed_at` 只喂热度 | — |
| §10 铁律二（被问得多 ≠ 值得记住） | **已实现** | 热度不升区、不进 context、不参与排序；`repeat_mention` 单独结算成 `noise` 后加速淘汰 | — |
| §10 铁律三（热度是计时器） | **已实现** | 见 §4.1。热度影响保留的唯一通道是 `settle` 的一次性结算——离散、留审计，不是连续延长寿命 | — |
| §12 八个待定参数 | **部分** | 已定并落地：热度代理=距上次访问（乘性）、分类型压缩阈值（普通 30 / 重要 90 / 情感锚点豁免）、人格卡 token 上限（300/350/150/整卡 800）、情感权重 α=0.5（显式查询才激活）、v2 混合相似度 0.85/0.15 | 未落地：秩位快照（没有秩位）、分区天数与重要性下限、归档配额与清理、摘要用本地模型 |

## 本轮改了什么（对照旧版）

| # | 改动 | 位置 | 为什么 |
|---|---|---|---|
| 1 | 时间权重改对称衰减 `2^(-|Δt|/45)` | `time_weight()` :76 | 旧版未来时间戳拿满分，一条 2030 笔误永久霸榜（SPEC §2.3） |
| 2 | `--outcome / --refs / --ts` 参数校验 | `_range()` :172、parse_ts | 脏值入库后污染排序；非法时间戳原来抛裸 traceback |
| 3 | `pinned` 保护位：`--pin` / `pin --off` | `cmd_pin()` :610 | SPEC §5.4「保护位永不进压缩归档、永不硬删」 |
| 4 | `type=anchor` 硬锚点 + ⚑ 冲突标记 | `cmd_context()` :804 一带 | SPEC §6「最近定义现在，锚点定义始终」；旧版 anchor 会被同 subject 的 fact 直接吞掉 |
| 5 | 热度 `heat_of()` + `stats` 热度分布 | `heat_of()` :87 / `_heat_hist()` :1624 | SPEC §4.1 与铁律三；旧版压缩只看 `--days`，没有「被访问过就该缓一缓」 |
| 6 | context 溢出显式标记 | :1000 | 旧的静默截断会让 Agent 笃定回答「没记录过」——这是最贵的一类幻觉 |
| 7 | 非 ASCII 词面向量化（emoji/假名/韩文） | `_terms()` :111 | 旧版这类记忆是零向量，恒定 `sem+0.00`；陪伴场景 emoji 密度最高 |
| 8 | `bin/memtree` + `bin/memtree.cmd` 入口 | bin/ | SKILL.md 全程教裸 `memtree`，仓库里根本没有这个命令 |
| 9 | `recall` 低置信标记 | `cmd_recall()` :1015 一带 | Σ=0 的噪声命中原来当证据展示；现在词面零重合会明说 |
| 10 | `compress` 默认分支改 HEAD、跳过保护位、`--heat` | `cmd_compress()` :1487 | 旧版写死 `main`，在别的分支上压缩静默 0 条 |
| 11 | 自检 20 → 52 项 | scripts/selftest.sh | 上面每一项都要有回归测试，尤其「未来笔误不霸榜」和「保护位扛住裁剪」 |
| 13 | **事件层最小版**（SPEC §2.2） | scripts/memtree.py `nodes.event` 列 / `_migrate()` / `cmd_commit()` / `cmd_context()` 事件轴 / `cmd_recall --event` | 索引必须等 `_migrate` 补列之后再建——写进 `executescript` 会让老库一打开就报错并整段回滚，升级即崩。自检 [19][20] 专测「事件随正文入上下文」与「缺列老库能平滑升级」 |
| 14 | **五档分区 `zone` + 单向迁移器**（SPEC §3/§4） | scripts/memtree.py `zone_target()` / `cmd_zone()` / `cmd_commit --importance` / `cmd_context` 分区门 / `cmd_recall --zone` / `cmd_stats.by_zone` / `cmd_compress` 跳过归档 | 分区只由「时间 + 重要度 + 保护位」决定：降级自动、升级必须 `--set`（铁律一/二）。老库补列后立刻按时间回填一次，否则新建列全 hot、单向降级从第一天就不成立。冷/归档被隐藏时必须显式说出条数，不许静默丢状态 |
| 15 | **墓碑区 + 两段式删除**（SPEC §3/§5.5） | scripts/memtree.py `cmd_purge()` 重写 / `PURGE_COOLDOWN_DAYS=7.0` / `nodes.tombstoned_at` `purge_reason` / `cmd_zone` 双向拒绝绕过分区接口 / `cmd_context` 墓碑计数与隐藏 / `cmd_recall` 默认排除 / `cmd_stats.tombstone` / `cmd_log` 🪦 标记 | 不可逆的决定必须留缓冲：`purge` 原来一按就烧，地址还在、正文没了。现在默认进墓碑区冷却 7 天，`--apply` 才真删、`--restore` 可撤回。墓碑区**不许**用 `zone --set` 进出——删除要走 purge 的理由与冷却，不能借分区接口绕过 |
| 16 | **事件内细节梯度压缩 + 结论必留**（SPEC §5 ①） | scripts/memtree.py `is_conclusion()`（:1476）/ `cmd_compress()` 重写（:1487-1568）/ `--keep-detail`（默认 1）/ `nodes.rolled_into` / `meta{rolled,ids,event,kept_detail}` | 旧实现「把一个分支里所有旧事件糊成一条摘要」——细节和结论一起没了，再想问「当时为什么这么定」只剩悬空地址。现在按 `event` 分组：组内最新 `--keep-detail` 条细节留原文，更老的够 `--min-count` 条才压成一条 `summary`（正文 `[压缩N条] 片段；片段；…`，`t` 回填最早那条、`event` 标签继承 → 事件轴不被打断），被压节点 `status='archived'` + `rolled_into` + `blobs.hot=0` 仍可按地址回溯；`decision/anchor/merge`、`outcome≠0`、`label∈{anchor,emotional}`、`pinned` 一律不压 —— **梯度只压细节，结论无论多老都不动**。自检新增 [24] 共 20 条断言：梯度归档 / `rolled_into` 指向 / `hot=0` 非删除 / 最新 N 条逐字保留 / 事件标签继承 / 两事件不合并 / 四类结论必留 / `conclusions_preserved` 精确性 / `--keep-detail 0` 退化 / 二次压缩幂等 |
| 12 | 文档校准（schema/README/SKILL） | references/schema.md、README.md、SKILL.md | README 的 554 token / 20 项自检已与实现不符；实测 context 358 token；本轮补 `event` 列与 `▣/⟦⟧` 图例 |
| 17 | **删除路径加固：三条硬拦**（SPEC §5.5） | `cmd_purge()` :1266-1384 / `pinned_refs()` :454 / `live_refs()` :442 / `cmd_pin()` :610 拒绝墓碑区 | 旧 `purge` 只看节点自己的 `pinned`：共享地址和墓碑里的保护位都能绕过。现在 `--apply` 与 `--now` 都过三关 —— ①`pinned_refs(addr)>0`（同一地址任一节点钉住，**含墓碑区内**）②`live_refs(addr)>0`（该地址还有 `zone<>'tombstone'` 的节点，active/superseded/archived 全算）③`pin` 直接拒绝墓碑区节点（否则「先钉再删」能造假保护位）。`--addr` 一遇保护位/锚点整次拒绝。（`d330b28`） |
| 18 | **契约 F：计数归属** | `cmd_purge()` :1321-1330 | 同一地址既命中原保护位又有活引用时**只计 `skipped_pinned`**、不重复计 `skipped_shared`（pinned 先判并 `continue`）。被跳过的条目仍留在墓碑区，下次 `--apply` 继续重试，`still_waiting` 不吞状态。（`5855fea`） |
| 19 | 自检 [25] 删除路径加固 **38 条** | scripts/selftest.sh | 保护位挡 `--apply`（含墓碑内的 pinned）、共享地址不抹正文、`--addr` 整次拒绝、墓碑不许 `pin`、冷却未满不删、期满真删后 `hot=2` + 正文空 + 节点行仍在、`--restore` 分区按时间重算、`--now` 跳过冷却但**不跳过**引用计数。（`fd8bc2f` + `939bc37`） |
| 20 | **`gone_at` + `recall --at` 时点快照 + 未来条目隔离** | `nodes.gone_at`（`_migrate()` :341 补列、:347-359 回填）/ `cmd_recall()` :1015-1122 / `cmd_context()` :804、:829-841、:973、:983 / `heat_of()` :87 | ①`gone_at` 记「不再作为现状的时刻」（覆盖记覆盖者的 `t`，不记墙钟 —— 补录历史时墙钟会撒谎），`--at T` 按它判当时现状，每条命中同时给 `status`（当时）/`status_now`（现在），`--at` 下读全文而非「已转冷」占位，`as_of_stats` 给 active/not_yet/already_gone/unknown_timing 四键；②未来条目不进 `■` 现状，被未来覆盖者按 `gone_at > now` 补回并标 `(覆盖者在未来·此刻仍是现状)`，`context --json` 的 `total` 新增 `future`；③未来条目**不免疫压缩**（热度 `last = max(accessed_at, min(t, now))`，未来条目走快车道），`--keep-detail` 的「最新」= 已发生的最新。（`87e5179`） |
| 21 | 自检 [26] 时点快照 / 未来隔离 **36 条** | scripts/selftest.sh | `--at` 三态判定、T 之后写的条目不当现状、T 之前已失效的不返回、`status`/`status_now` 分叉、`as_of` 回显、`as_of_stats` 四键、深回溯按语义重合 `se` 判而非 Σ（带 `low_confidence`/`overlap`）、`⏳` 段与补回行、`total.future`、未来条目不免疫压缩。（`45f9c42`） |
| 22 | **去重不连坐 + 孤儿正文回收** | `_cold_blob()` :475 / `orphan_addrs()` :464 / `purge --gc [--dry-run]` / `cmd_stats.blobs.orphans` | 两个旧账一起收：①覆盖时对败者地址盲目标 `hot=0`，若胜者与它共用同一 `addr`（正文一字不差），胜者正文会被一起转冷 → 现在只在「全库没有活节点共用该地址」时才转冷；②`blobs` 里没人引用的正文此前永不释放 → `purge --gc` 显式回收（只删 `blobs` 行、不删 `nodes` 行；墓碑节点仍算引用者，冷却期内不可能被当孤儿）。（`146f5c5`） |
| 23 | **人格卡 + 三层锚点预算**（SPEC §6，契约 J） | `persona_path()` :529-532 / `persona_load()` :535-556 / `persona_save()` :576-590（原子写）/ `persona_slot_tokens()` :572 / `cmd_persona()` :622-722 / `persona_log` 表 :302-310 / `PERSONA_SLOT_BUDGET` :66 / `PERSONA_TOTAL_BUDGET` :67 / `cmd_context()` :1184-1188、:1232 / CLI :2071-2105 | 人格卡落成**独立文件**（默认 `<db>.persona.md`，`--persona-file` 覆盖），三段固定标题 `## 硬槽`/`## 软槽`/`## 可变槽`、一行一条 `- `、空槽保留标题；预算用 `est_tokens()`（中文 1 字≈1.5）分三层 + 整卡兜底 800。写侧：**硬槽 `set` / `drop` 不给 `--force` 就改不动**（人格漂移不会自己回滚，`set` :653-655、`drop` :697-699）；硬槽超预算直接拒（不许挤别人），软/可变超预算按「最后一次写入最旧优先」挤出并留 `op=evict`，挤到只剩新条目仍超 → 整条回滚 `exit 2`；重复写幂等。审计侧：`persona_log(t,slot,op,old,new,reason)`，`op ∈ add|del|evict`，`persona show --at T` 从空卡正向重放（卡文件里只有「现在是什么」）。context 侧：卡非空时在首行之后、锚点之前插 `⚓人格·硬/软/可变` 三行（只出非空槽），计入 `--budget` 但**永不被裁**，卡为空时输出与没有人格卡逐字相同。`nodes` 不存人格条目，`--type anchor` 语义不变。（`12bbccb`） |
| 24 | 自检 [30] 人格卡（契约 J）**47 条** | scripts/selftest.sh [30] | 空卡不出现 `⚓人格·*` 内容行（图例符号除外）/ 硬槽 `--force` 闸且被拒时不落卡不落日志 / 软槽最旧挤出 + `op=evict` 留痕 / 硬槽超限不挤别人 / 整卡超 800 回滚且卡文件 sha256 不变 / `--at` 早于首次写入给 `(卡为空)`、两次写入之间给中间态 / 重复写幂等、`drop` 留 `op=del`、`drop` 不存在不报错 / `⚓人格` 行排在锚点之前且 `--budget` 极小时不被裁 / `context --json` 带三槽 + `est_tokens` / 卡非空时图例行含 `⚓人格`（J12）。（本轮） |
| 25 | **context 图例补 `⚓人格`**（契约 J12） | `legend` 常量 :1179 / scripts/selftest.sh [30] | 人格卡已经进 context 三行，但图例没教模型 `⚓人格` 是什么意思 —— 文档此前靠一句「常量还没改」替代码认错。现在图例与 SKILL 样例逐字一致，并用 J12 钉住「卡非空时图例行含 `⚓人格`」。改动文件：`scripts/memtree.py` + `scripts/selftest.sh`（T2 破例同轮）。（`09869c9`） |
| 26 | **分类型压缩阈值**（SPEC §4.2） | `cmd_compress()` :1754 / `automatic_cut()` :1766-1772 / CLI `--days` 默认 None :2068 / scripts/selftest.sh [31] | 默认不再一刀切 30 天：普通 30 天；重要（`importance≥0.7` 或 `pinned`）90 天；`label='emotional'` 或 `type='anchor'` 永不自动压缩。显式 `--days` / `--before` 仍统一覆盖时间分档（老行为），但不绕过 `is_conclusion()` 与保护位。自检 [31] 11 条：三档边界、1000 天情绪/锚点仍 active、显式覆盖、缺 `importance` 老库可直接 compress。（`9124f20`） |
| 27 | **结构化情感层 + 显式情绪检索**（SPEC §7） | `affect` 表 :306/:407 / `normalize_affect_tags()` / `affect_add()` / `affect_relevance()` / `cmd_affect()` :633 / `cmd_signal()` / `cmd_settle()` / `cmd_recall()` :1450 / `cmd_purge()` 级联 / CLI :2320 | 情绪不再只靠 `signals.quote` 裸存：`affect` 保存标签、强度、效价、原话、来源；固定 8 类 + `unspecified`，中文别名可输入，未知标签拒绝。`recall --emotion` 才启用情绪维，`S=sim*((1-α)*time+α*emotion+outcome)`，默认 α=0.5；不带参数时输出与旧版逐键相同。`roleplay` 的 settle 与手写 `affect set` 双入口拒绝；`purge --apply/--now` 级联删情感行。自检 [32] 18 条。（`26069d8`） |
| 28 | **分层检索 v2**（SPEC §8.3，灰度） | `cmd_recall()` :1450 / `--pipeline` :2378 / `--expand` / scripts/selftest.sh [33] | 新增 `--pipeline v2`：有效性门 → 时间窗 → 事件过滤 → `0.85*cos+0.15*lexical` 混合相似度 → 时间/情绪加权 → 事件单元逐级展开。每级 `in=pruned+out`，未来条目单列 `future_hidden` 不占 topN，`--at` 的时间窗锚定 T。默认仍 `legacy`，老输出不变。自检 [33] 15 条。（`153d1fc`） |
| 29 | **工单修复 F1–F6 + 公开准备 G1/G2** | `cmd_recall()` / `cmd_purge()` / `cmd_label()` / `PROJECT_STATE.md` / `.gitignore` | F1 v2 展开截断报数；F2 `--now` 覆盖既有墓碑并拆 `purged_existing/purged_now`；F3 情绪零命中退回 α=0；F4 apply 后转 `purged` 终态；F5 正文已抹拒绝 restore；F6 noise 摘保护位显式报 `pin_revoked`。G1 清本机绝对路径，G2 发布 `DESIGN.md`。自检从 337/33 → 366/34。 |

## 明确没做（别误以为有）

- **事件层只有最小版**：`nodes.event` 是受控短标签 + 时间区间聚合，能回答「这三个月围绕哪几件事」，但没有独立事件节点、没有事件级权重、事件边界仍靠外部 Agent 给（会话分段未做）。`subject` 仍然是「谁和谁比」的分组键，别当事件用。
- **分区只做了前四档**：`zone` 列 + `zone --migrate` 单向降级（hot≤7d → warm 7~90d → cold[重要度≥0.7 或保护位] → archive），升级必须 `zone --id <n> --set`。**墓碑区已做**：`purge` 改成两段式（进墓碑 → 冷却 7 天 → `--apply` 真删），冷却期内 `--restore` 可撤回、`--now` 给隐私开直通车。
- **情感层只做到「结构化 + 显式查询」**：`affect` 已能存标签/强度/效价/原话并参与 `--emotion` 排序，但情绪状态还没常驻进 `context`，也没有自动打标；关系里程碑仍建议 `type=anchor`。
- **没有自动抽取**：写什么、`subject` 叫什么、摘要写什么，全由外部 Agent 决定。`subject` 的自由生成是本系统唯一的失败入口。
- **没有 LLM 调用**：这就是零依赖的代价——「零 LLM 成本」对整条链路不成立，每轮仍要外部 Agent 抽一次。
- **`competing` 状态无写入路径**：`recall --status competing` 恒为空，相关分支是死代码（保留位，见 schema.md §5）。
- **分支语义弱**：`scope=global` 的 fact/pref 跨分支互相覆盖，分支 DAG 在状态层被抹平；合并后的分支仍可 checkout 写入（只改 `branches.status`，未拦截）。

## 下一期建议（按投入产出排序）

1. **受控 subject 枚举**：在 SKILL.md 里给出枚举表并让抽取器只能选，不自由生成。这一条的收益大于剩下所有 bug 的总和。
2. ~~事件层最小版~~（已完成：`event` 列 + 事件轴 + `recall --event` 剪枝）。剩下的：会话分段自动划事件边界、事件级权重、同类型事件秩位衰减。
3. ~~`zone` 列 + 单向迁移器~~ ~~墓碑区 + 硬删除冷却期~~ ~~「压缩只压细节」（事件内细节梯度 + 结论必留）~~ ~~删除路径三条硬拦 + 契约 F 计数归属~~ ~~`recall --at` 时点快照（`gone_at`）~~ ~~未来条目隔离~~ ~~去重不连坐 + 孤儿正文回收~~ ~~分类型压缩阈值~~（均已完成）。剩下：**归档区磁盘配额**。
4. ~~情感层独立表~~（已完成：`affect(node_id,t,tags,intensity,valence,key_quote,source)` + `--emotion` 查询权重 + `purge` 级联，见 #27）。剩下：情绪状态进 `context`、自动打标。
5. ~~人格卡：单独文件 + token 上限 + 变更日志~~（已完成：`<db>.persona.md` + 300/350/150/800 + `persona_log`，见改动记录 #23）。剩下：**版本化**——卡的内容地址/快照、「谁批准改」的审批流、手改文件的检测。

## 怎么复核本文件

```bash
bash scripts/selftest.sh          # 期望：通过 366 / 失败 0（34 组）
python scripts/memtree.py context --budget 200   # 期望：末行有「⚠ 还有 N 条未展开」
python scripts/memtree.py stats                   # 期望：有 protected 与 heat 两段
```

行号会随改动漂移，函数名不会：`heat_of` / `_terms` / `_range` / `cmd_pin` / `_heat_hist` / `cmd_context`。