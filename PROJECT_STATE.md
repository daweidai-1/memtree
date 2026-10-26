# PROJECT_STATE —— 跨会话进度台账

> 这份文件是给**下一个接手的会话**看的，不是宣传页。
> 唯一规矩：**只写事实，不写愿景。** 没做的明写「未实现」，别让下一个会话以为有。
> 建立于 2026-10-26；建立原因：多会话并行时团队反复遗忘进度、重复踩同一个坑。

---

## 1. 一句话定位

**memtree = 时间轴优先的 Agent 长期记忆层**：SQLite 单文件 + 单文件 CLI + 零依赖。
同 `subject` 内新记忆按时间覆盖旧状态（闭式公式，零 LLM），旧正文转冷只留内容地址，可回溯「当初为什么改」。

它的赌注不是「检索更准」，而是 **写入时贵一次、读取时恒定且确定**。
短对话用它纯亏（累计成本交叉点约 25 轮），几十轮以上才划算。

---

## 2. 目录文件地图

| 路径 | 一句话职责 |
|---|---|
| `SKILL.md` | Agent 入口，每次会话加载（实测 **3,221 token**）。只留操作信息 + **图例行** |
| `README.md` | 对外说明：解决什么问题、D1–D4 设计决定、实测账、与 mem0/Zep/Letta 对比、安装、自检输出 |
| `AUDIT.md` | 按 SPEC 逐节对照（哪节已实现/部分/未实现）+ 改动记录 29 条 + 明确没做 + 下一期建议 |
| `CHANGELOG.md` | v1.0.0 发布说明、能力阶段与真实提交区间 |
| `PROJECT_STATE.md` | **本文件**：跨会话进度台账（能力状态、缺口、安装态、接手指南） |
| `DESIGN.md` | 早期设计稿（问题定义、四个设计决定、代价），保留作思路存档；**与实现冲突时以 AUDIT.md 为准** |
| `references/schema.md` | 表结构、状态机、权重公式、**§5.5 压缩梯度**、subject 命名、换真嵌入的方法 |
| `references/theory.md` | 数学推导（复平面模型、打分分解、时间旅行），按需读，不进 SKILL |
| `references/prompts.md` | 注入模板与抽取提示词 |
| `references/mcp.md` | MCP 封装**设计稿**（四工具契约、两阶段删除确认、未实现） |
| `scripts/memtree.py` | **全部实现**，单文件 a9b4c68 上 2,550 行，argparse 子命令 + SQLite，零第三方依赖 |
| `scripts/selftest.sh` | 366 项自检（34 组），末尾打印 `通过 N / 失败 M`，`FAIL>0` 则 exit 1 |
| `bin/memtree` / `bin/memtree.cmd` | POSIX / Windows 启动器，按 `MEMTREE_PY → python3 → python → py` 找解释器 |
| `.github/workflows/selftest.yml` | CI：Python 3.8/3.11/3.13 三档跑同一份自检 + CLI 冒烟 |
| `.gitattributes` / `.gitignore` / `LICENSE` | 行尾规范化 / 忽略规则 / MIT |

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

---

## 3. 能力状态表

| 能力 | 状态 | 接口在哪 | 一句话证据 |
|---|---|---|---|
| 事件层（SPEC §2.2） | **已实现（最小版）** | `commit --event`（受控短标签 ≤24 字，超长直接拒写）；`nodes.event`；`context` 事件轴 `▣ 名 起~止 n条`；`recall --event` 在算相似度**之前**剪枝 | 自检专测「事件随正文进 context」与「缺列老库平滑升级」；事件边界仍由外部 Agent 给（无会话分段） |
| 三维检索 | **已实现** | `recall --at --outcome --days --event --mode --status --top`；时间项 `time_weight()`:76、总权重 `weight()`:455 | 输出行自带三元分解 `t·0.99 r·+0.90 sem+0.42 Σ=+0.57`；自检 [3] 同 query 换 `--outcome ±0.9` 命中不同节点 |
| 内容寻址 | **已实现** | `blobs.addr = sha256(正文)[:16]`（`addr_of()`:203）；`verify <addr>`、`show <id>` | 相同内容天然去重；`verify` 重算 sha256 比对，篡改必被发现 |
| 分支 | **已实现（语义弱）** | `branch --from <id>` / `checkout` / `merge --summary`；`branches(name,fork_node,head_id,status,merged_into)` | 自检 [5] 3 条；`compress` 默认跟随当前 HEAD（旧实现写死 `main`，侧枝压不到） |
| 保护位 / 硬锚点 | **已实现** | `commit --pin`、`pin <id> [--off]`（`cmd_pin()`:610）；`type=anchor` 独立成段、撞上更新的 fact 标 `⚑锚点未变`（`cmd_context()` :804 一带）；墓碑区节点拒绝 `pin`（:573） | 自检 [12] 5 条（不裁剪/不压缩/不硬删）、[13] 3 条（不被现状吞掉） |
| 热度与压缩计时器 | **已实现** | `heat_of()`:87 = `0.5^(距上次访问天数/45)`，**只看「距上次访问」，不累计次数**；衰减起点是 `max(accessed_at, min(t, now))` —— 未来条目不许把起点跑进未来；唯一消费者 `compress --heat`；`stats` 热度直方图 `_heat_hist()`:1624 | 自检 [15] 3 条；热度不进 `weight()` —— 不参与排序、不进上下文、不升区 |
| 采样 → 结算 → 打标签 | **已实现** | `signal --type user_confirm\|correction\|emotional_peak\|repeat_mention`；`settle`（`_judge()`:645 走规则、不调 LLM）；`label <id> anchor\|emotional\|noise\|clear`；`signals` + `settle_log` 两表 | 自检有「anchor 不被压缩」「noise 豁免热度门」；每次结算写 `settle_log`，可审计 |
| 五档分区 hot/warm/cold/archive/tombstone | **已实现** | `nodes.zone` + `ZONES`:53 + `zone_target()`:306；`zone --migrate` **单向降级**、`zone --id N --set X` **唯一升级入口**（`tombstone` 除外，:1586 拒绝）；`context` 分区门；`recall --zone`；`stats.by_zone` | 自检：冷区/墓碑条数必须明说、不许静默隐藏；老库补列后按时间回填一次（否则单向降级从第一天就不成立） |
| 墓碑两段式删除 | **已实现**（`d330b28` 加固 + F2/F4/F5） | `cmd_purge()`：默认进墓碑（`zone='tombstone'` + `tombstoned_at` + `purge_reason`），冷却 `PURGE_COOLDOWN_DAYS=7.0`；`--apply` 期满真删并转 `purged` 终态；`--now` 覆盖所有既有/新进墓碑，拆 `purged_existing/purged_now`；`--restore` 正文已抹则拒绝；`--list` 只列未结案墓碑 | 自检 [23] 19 条 + [25] 38 条 + [34] 18 条 |
| 删除路径三条硬拦 | **已实现**（`d330b28` / `5855fea`） | `pinned_refs()`:454（**含墓碑区内的 pinned**）→ `skipped_pinned`；`live_refs()`:442（`zone<>'tombstone'`，active/superseded/archived 全算）→ `skipped_shared`；`cmd_pin()` :573 拒绝墓碑区节点。计数归属：同时命中只计 `skipped_pinned` | 自检 [25]：共享地址不抹正文、`--now` 不跳过引用计数、`pin` 墓碑被拒、`zone --set tombstone` 被拒（:1586） |
| **事件内细节梯度压缩**（SPEC §5 ①） | **已实现**（`446fd66`） | `compress --keep-detail N`（默认 1）+ `--min-count`（默认 3）+ `is_conclusion()`:1743 + `cmd_compress()`:1754；`nodes.rolled_into`、`meta{rolled,ids,event,kept_detail}` | 自检 `[24]` 20 条断言全绿：`rolled_into` 指向 / `hot=0` 非删除 / 最新 N 条逐字保留 / 事件标签继承 / 两事件不合并 / 四类结论必留 / `conclusions_preserved` 精确性 / `--keep-detail 0` 退化 / 二次压缩幂等。文档落点：`references/schema.md` §5.5、README「压缩是梯度，不是剪切」、SKILL 的 compress 段、AUDIT #16 |
| **分类型压缩阈值**（SPEC §4.2） | **已实现**（`9124f20`） | `cmd_compress()`:1754 + `automatic_cut()`:1766：默认普通 30 天 / 重要（`importance≥0.7` 或 `pinned`）90 天 / 情感锚点（`label=emotional` 或 `type=anchor`）永不自动压缩；显式 `--days`/`--before` 统一覆盖时间分档，但不绕过结论与保护位 | 自检 `[31]` 11 条全绿：普通 31 天进、重要 31 天不进 / 91 天进、情绪 31/1000 天不进、锚点 1000 天不进、显式覆盖、缺 `importance` 老库可跑 |
| **结构化情感层**（SPEC §7） | **已实现**（`26069d8`） | `affect` 表 :306/:407；`cmd_affect()`:633；`signal --tags/--valence` → `settle` 聚合；`recall --emotion` 权重 α=0.5；`roleplay` 双入口拒绝；`purge` 级联删 | 自检 `[32]` 18 条：别名规范化、结构化落库、多观察、未知标签拒绝、无 --emotion 老输出不变、情绪重排、隐私级联、老库补列 |
| **分层检索 v2**（SPEC §8.3） | **已实现（灰度）** | `recall --pipeline v2`（`cmd_recall()`:1450）；有效性门→时间窗→事件过滤→混合相似度→加权排序→事件单元展开；`pipeline` 每级报数 | 自检 `[33]` 15 条：legacy 无 pipeline、六段审计、future_hidden、in=pruned+out、事件展开、--at 锚定 T |
| **时点回溯 `recall --at`**（`87e5179`） | **已实现** | `nodes.gone_at`（`_migrate()`:341 补列、:347-359 回填：superseded 取 `superseded_by` 的 `t`、archived 取 `rolled_into` 的 `t`，回填不到留 NULL）+ `cmd_recall()` :1015-1122：`as_of` / `as_of_stats{active,not_yet,already_gone,unknown_timing}` / `status`(当时) / `status_now`(现在) | 自检 [26] 36 条：T 之后才写的不当现状、T 之前已失效的不返回、`--at` 读全文非「已转冷」占位、深回溯按语义重合 `se` 判而非 Σ。文档落点：`references/schema.md` §5.7/§5.8、README「回溯问的是当时，不是现在」、AUDIT #20/#21 |
| **未来条目隔离**（`87e5179`） | **已实现** | `cmd_context()`：未来条目另起 `⏳ 未来 N 条尚未发生（不参与现状判定）` 段（:973）、不进 `■`、被未来覆盖者按 `gone_at > now` 补回并标 `(覆盖者在未来·此刻仍是现状)`（:829-841）、`context --json` 的 `total.future`（:983）；`heat_of()` 用 `min(t, now)` 使未来条目不免疫压缩 | 自检 [26]：`■` 不含未来正文、补回行标记、`total.future`、未来条目被 `compress` 压成 archived（有 `rolled_into`）。文档落点：`references/schema.md` §5.9、README「回溯问的是当时，不是现在」末条 |
| **去重不连坐 + 孤儿正文回收**（`146f5c5`） | **已实现** | `_cold_blob()`:475（只有「全库没有活节点共用该地址」才转冷）；`orphan_addrs()`:464 + `purge --gc [--dry-run]`（只删 `blobs` 行、不删 `nodes` 行）+ `stats.blobs.orphans` / `orphan_bytes` | 覆盖时不再把共用地址的活节点正文一起转冷；孤儿正文可显式释放，墓碑节点仍算引用者所以冷却期内不会被当孤儿 |

---

## 4. 未实现清单（带 SPEC 章节）

**别误以为有。** 以下是审计过确认没有的：

| 缺口 | SPEC | 现状 | 为什么还没做 |
|---|---|---|---|
| 归档区磁盘配额 | §3 / §9 | `zone='archive'` 只是标记，同库同表，无配额、无清理、无独立存储 | 需要真做独立归档文件或外部冷存储 |
| 人格卡**版本化** | §6 | 卡本体**已实现**（`12bbccb`，契约 J）：独立文件 `<db>.persona.md`、三段固定标题、三层预算 300/350/150 + 整卡 800、硬槽必须 `--force`、挤出记 `op=evict`、`persona_log` 审计、`persona show --at T` 正向重放、`context` 插 `⚓人格·硬/软/可变` 且永不裁剪 | 卡是**原地覆写**：不进 `blobs`、没有内容地址/快照/审批流，卡文件被手改也不进日志；漂移检测没有 |
| 事件边界自动化 | §2.2 | `event` 全靠外部 Agent 给；没有会话分段、独立事件节点、事件级权重、同类型事件秩位衰减 | 需要对话分段模型（与「零依赖、零 LLM」冲突） |
| `competing` 状态 | schema §5 | 保留值，**无写入路径**：`recall --status competing` 恒为空，相关分支是死代码 | 缺「两条现状互相矛盾、等用户裁决」的交互流程 |
| 分支语义 | §2 / schema §9 | `scope=global` 的 fact/pref 跨分支互相覆盖（分支 DAG 在状态层被抹平）；`merge` 后分支仍可 `checkout` 写入 | 需要给「全局 vs 分支」定优先级规则 |
| 后台调度 / 日终 consolidation | §9 | 全靠手工或外部触发 | 零依赖 CLI 的边界；要做得另起进程或交给宿主 |
| MCP 封装 / 库级 API | §9 | 只有 CLI + `--json`；方案见 `references/mcp.md`，**未实现** | 需先补 `purge --ids`、`commit --json`；优先级低于正确性 |
| 摘要用本地模型 | §12 待定参数 | 摘要正文是规则拼接（前 4 条片段、每条截 12 字） | 与零依赖冲突 |

### 4.1 文档类缺口（不影响功能，但会误导人）

- **token 数没有可信来源**：`context` 358 token / 轮、22 条库那组数据都是「事件层 + 分区层」之前的测量；`SKILL.md` 的 token 数（曾写 3,221）会随文档改动漂移，**引用前请重测**，别把旧数字当真。
- **CI step 名**：`.github/workflows/selftest.yml` 已改成 `Run 366 self-tests`。新增自检组时记得同时改它，否则 CI 日志的名字会撒谎。
- **README 自检徽章/项数**已按本轮实测校正为 `366/366`、`366 项（34 组）`，组表格补到 `[34]`。

---

## 5. 当前状态

### 5.1 提交与自检

| 项 | 值 |
|---|---|
| 代码基线 | **`a9b4c68`** `fix(label): report pin revocation on noise (F6)` |
| 本轮关键提交 | `e2f0bde` F1 v2 展开报数 · `42e07b1` F3 情绪零命中降级 · `ca940ac` F2 `--now` 覆盖既有墓碑 · `88055ea` F4 apply 终态 · `49e4f9b` F5 restore 拒绝永久删除 · `a9b4c68` F6 撤保护位提示 · `2a2a056` G1 清绝对路径 · `f7945ba` G2 发布 DESIGN · 更早：`153d1fc` v2 · `26069d8` affect · `9124f20` 分档压缩 |
| 更早的骨架提交 | `1349794` 文档排序 · `c3c9414` 墓碑区 + 两段式删除 · `bf58645` 五档分区 · `812c828` 事件层最小版 · `13c4f40` 采样→结算→标签 |
| 自检项数 | **366 项 / 34 组** |
| 自检结果 | **通过 366 / 失败 0**（`a9b4c68` 代码 + G 文档实测，34 组） |

### 5.1.1 批次记录：T1 文档收尾

- **提交哈希**：`a421d65`（`docs: align persona contract and selftest counts`）。
- **自检增量**：`+0`；本轮实测仍为 **292 项 / 30 组，通过 292 / 失败 0**，只校正文档与 CI step 名。
- **契约编号**：J（人格卡三槽/预算/回看/context）与 J11（硬槽 `drop` 同要 `--force`）。
- **已知取舍**：未改运行时代码；证据行号固定在 `6ddb0d1`；安装态副本按交接约定由审核方统一同步；`⚓人格` 图例缺口留给 T2 改代码常量。

### 5.1.2 批次记录：T2 图例修复

- **提交哈希**：`09869c9`（`fix: add persona marker to context legend`）。
- **自检增量**：`+1`；从 292/30 到 **293/30，通过 293 / 失败 0**。
- **契约编号**：J12（卡非空时 context 图例行含 `⚓人格`）。
- **已知取舍**：同时改了 `scripts/memtree.py` 与 `scripts/selftest.sh`（交接单允许的破例）；旧 J1「空卡全文不得出现 ⚓人格」被收窄为“不得出现 `⚓人格·*` 内容行”，原因是图例符号现在固定存在，旧断言与 J12 直接冲突，不是为了让代码变绿而改期望。

### 5.1.3 批次记录：T3 分类型压缩阈值

- **提交哈希**：`9124f20`（`feat: add typed compression thresholds`）。
- **自检增量**：`+11`；从 293/30 到 **304/31，通过 304 / 失败 0**。
- **契约编号**：SPEC §4.2；自检 [31]。
- **已知取舍**：显式 `--days` / `--before` 只覆盖时间分档，不绕过 `is_conclusion()` 与保护位；`pinned` 虽被归入“重要 90 天”，但仍受“保护位永不自动压缩”更强硬闸约束，实际不自动压；本批未改 schema，老库直接打开由 [31] 的缺 `importance` 用例覆盖。

### 5.1.4 批次记录：T4 结构化情感层

- **提交哈希**：`26069d8`（`feat: add structured affect layer`）。
- **自检增量**：`+18`；从 304/31 到 **322/32，通过 322 / 失败 0**。
- **契约编号**：SPEC §7；自检 [32]。
- **已知取舍**：`affect` 是独立表，`nodes.label` 仍只表示“是否情感锚点”；情绪只在显式 `--emotion` 时进入排序，不带参数时旧输出逐键不变；`roleplay` 在 settle 与手写入口都拒绝；`purge --apply/--now` 级联删 `affect`。缺列老库由 `_migrate` 补 `signals.emotion_tags/valence`。

### 5.1.5 批次记录：T5 分层检索 v2

- **提交哈希**：`153d1fc`（`feat: add staged retrieval pipeline v2`）。
- **自检增量**：`+15`；从 322/32 到 **337/33，通过 337 / 失败 0**。
- **契约编号**：SPEC §8.3；自检 [33]。
- **已知取舍**：默认仍是 `legacy`，v2 只是可选项；v2 的真实未来条目不占当前 topN、单独计入 `future_hidden`；混合相似度固定 0.85×cos + 0.15×lexical，事件单元展开数由 `--expand` 控制；v2 尚未成为默认，事件级权重/秩位衰减未做。

### 5.1.6 批次记录：T6 MCP 封装方案

- **提交哈希**：`08db4fc`（`docs: add MCP wrapper design`）。
- **自检增量**：`+0`；仍为 **337 / 0（33 组）**，本批只写设计文档，不写实现。
- **契约编号**：SPEC §9；T6 四工具 `commit/recall/context/purge`。
- **已知取舍**：MCP 层设计为可选 stdio 适配器，核心保持零依赖；`purge` 用两阶段 preview token，候选集变化即拒绝，且禁止 `all=true`。实现前置：CLI 需先补 `purge --ids` 精确入口与 `commit --json`；在 `purge --ids` 落地前，MCP 只开放 `list/stage/restore/gc`，不暴露 `apply/now`。

### 5.1.7 批次记录：工单 F1–F6 + G1/G2

- **提交链**：`e2f0bde` F1 · `42e07b1` F3 · `ca940ac` F2 · `88055ea` F4 · `49e4f9b` F5 · `a9b4c68` F6 · `2a2a056` G1 · `f7945ba` G2。
- **自检增量**：`+29`；从 337/33 到 **366/34，通过 366 / 失败 0**。
- **关键语义**：`--now` 覆盖所有墓碑并拆 `purged_existing/purged_now`；`--apply` 后转 `purged` 终态；正文已抹的 `--restore` 拒绝；v2 展开截断报数；情绪零命中退回 α=0；`label noise` 显式报 `pin_revoked`。
- **公开准备**：PROJECT_STATE 本机绝对路径清零；DESIGN.md 从 `.gitignore` 移除并纳入版本库（老大选 a）。

> 提交号会变，别只信这张表：`git log --oneline -3` 永远是对的。

### 5.2 安装态是第二份副本（必须同步）

技能实际加载的位置是 **`$HOME/.workbuddy/skills/memory-timeline`**（整棵树副本，自带 `.git`）。
仓库改了不同步 = Agent 读旧文档、跑旧代码。**这是最容易忘的一步。**

**六件文档**（一个循环覆盖）：

```bash
cd "$(git rev-parse --show-toplevel)"
D="$HOME/.workbuddy/skills/memory-timeline"
for f in SKILL.md README.md AUDIT.md references/schema.md references/theory.md references/prompts.md; do
  cp "$f" "$D/$f"
done
```

**但代码也要覆盖**，否则 skill 跑的是旧实现：

```bash
cd "$(git rev-parse --show-toplevel)"
D="$HOME/.workbuddy/skills/memory-timeline"
cp scripts/memtree.py scripts/selftest.sh "$D/scripts/"
cp bin/memtree bin/memtree.cmd "$D/bin/"
diff -rq . "$D" 2>/dev/null | grep -v '\.git'   # 期望：无输出
```

- `PROJECT_STATE.md` **不在这六件里**：它是仓库台账，Agent 运行时只读 `SKILL.md`。要给人看就顺手 `cp PROJECT_STATE.md "$D/"`。
- 本次核对（`task-8`）时仓库已改到 `146f5c5`，而安装态是旧的 —— **代码和文档都漂了**，两份都得覆盖。`diff -rq` 是唯一可信的判据，别凭印象。

### 5.3 自检怎么跑（本机必须先给解释器）

某些 MSYS2 bash 环境的 PATH 里用户名段可能乱码，导致 `command -v python` 全部 MISSING，直接跑会报：

```
找不到 python，请设 MEMTREE_PY
```

正确姿势：

```bash
cd "$(git rev-parse --show-toplevel)"
PYTHONIOENCODING=utf-8 bash scripts/selftest.sh
```

最后一行应打印 `通过 366 / 失败 0`，共 34 组。若 `python/python3` 不在 PATH，设 `MEMTREE_PY` 指向解释器（Windows 下填 `python.exe` 的路径即可）。

---

## 6. 下次接手先读这里

**第一步：** 读本文件 → 读 `AUDIT.md` 的「明确没做」和「下一期建议」→ 再看 `references/schema.md` §5.5（压缩）。
**别做的：** 别先读 `scripts/memtree.py` 全文（1.5k 行）；用 `grep -n "^def "` 拿函数索引，再定点读。

**怎么跑自检**：见 §5.3。`FAIL>0` 时先看是不是工作区有你或别人的未提交改动（`git status`）。

**怎么提交**（不改全局 git config、不 push）：

```bash
cd "$(git rev-parse --show-toplevel)"
git -c user.name=xiaobai -c user.email=xiaobai@localhost commit -m "..."
```

多人共用同一仓库并行：只改自己边界内的文件；**不要 amend / rebase**（会重写别人的提交）。

### 6.1 常见坑（都踩过）

1. **`sqlite3.Row` 断言写法**：`scripts/selftest.sh` 的 `chk "<描述>" "<python 表达式>"` 里，`c` 是 **`row_factory=sqlite3.Row`** 的连接。
   - 必须 `.fetchone()` 取值：`c.execute("select status from nodes where id=1").fetchone()[0]=='superseded'`。
   - **漏掉 `.fetchone()`** 拿到的是 Cursor 对象，恒真 → **假通过**（最阴的一类测试 bug）。
   - 按列序用 `[0]`，按列名用 `["col"]`，别对 Row 用 `row[1:]`。
   - 断言正文用脚本给的 `text('关键字')` 辅助函数，别自己 join `blobs`。
2. **图例 parity**：`SKILL.md` 的图例行必须与 `memtree.py` 的 `legend` 常量**逐字**一致（历史上专为它做过校验）。注意：**自检只验图例「存在」**（`grep "禁止当作现状"`），**不验 parity** —— 改完自己跑：

```bash
cd "$(git rev-parse --show-toplevel)"
PY="${MEMTREE_PY:-python}"
"$PY" - <<'EOF'
import ast, pathlib
src = pathlib.Path("scripts/memtree.py").read_text(encoding="utf-8")
leg = None
for node in ast.walk(ast.parse(src)):
    if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "legend" for t in node.targets):
        leg = ast.literal_eval(node.value); break
doc = [l for l in pathlib.Path("SKILL.md").read_text(encoding="utf-8").split("\n") if l.startswith("\u203b ")]
print("PARITY_OK" if leg is not None and [leg] == doc else "PARITY_DIFF")
EOF
```

> 旧版按括号配对截取 `legend = (...)`，遇到图例里的 `(回顾点)` 会提前截断并报 `SyntaxError`；用 AST 取赋值表达式才可靠（2026-10-26 T2 实测踩到）。

3. **安装态是第二份副本**：见 §5.2。改了仓库不同步，Agent 用的还是旧版。
4. **新增列必须走 `_migrate`**：`ALTER TABLE` + 索引要在补列**之后**建。把 `CREATE INDEX` 写进建表的 `executescript` 会让老库一打开就报错并整段回滚（升级即崩，AUDIT #13 记过）。
5. **分区不许借道上浮**：`zone --set` 是唯一升级入口；`tombstone` 只能由 `purge` 进入（删除要带理由与冷却）。`zone --set tombstone` 会被直接拒绝。
6. **自检只用自己的临时库**：脚本开头 `export MEMTREE_DB=$(mktemp -d)/...`。别把外部 `MEMTREE_DB` 继承进去——历史上因此出现过 19 项假失败。
7. **压缩不是剪切**：`compress` 只压细节，`decision/anchor/merge`、`outcome≠0`、`label∈{anchor,emotional}`、`pinned` **无论多老都不压**。改这段前先读 `is_conclusion()`:1476 —— 它就是「梯度的下限」。

---

## 7. 本文件怎么维护

- 每轮有**能力落地或被推翻**时更新 §3；有**新缺口**时更新 §4；每次提交后更新 §5.1 的提交号。
- 只记录**已验证的事实**（附证据：文件:行号、自检断言名、命令输出）。拿不准就写「待验证」，别写成结论。
- 别把这里当 changelog —— 逐条改动归 `AUDIT.md` 的「本轮改了什么」（现已 16 条）。本文件只回答三件事：**现在有什么、缺什么、下一个会话怎么起步**。
