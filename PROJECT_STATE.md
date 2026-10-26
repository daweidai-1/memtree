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
| `AUDIT.md` | 按 SPEC 逐节对照（哪节已实现/部分/未实现）+ 改动记录 16 条 + 明确没做 + 下一期建议 |
| `PROJECT_STATE.md` | **本文件**：跨会话进度台账（能力状态、缺口、安装态、接手指南） |
| `DESIGN.md` | 早期设计稿（问题定义、四个设计决定、代价），保留作思路存档；**与实现冲突时以 AUDIT.md 为准** |
| `references/schema.md` | 表结构、状态机、权重公式、**§5.5 压缩梯度**、subject 命名、换真嵌入的方法 |
| `references/theory.md` | 数学推导（复平面模型、打分分解、时间旅行），按需读，不进 SKILL |
| `references/prompts.md` | 注入模板与抽取提示词 |
| `scripts/memtree.py` | **全部实现**，单文件约 1.5k 行，argparse 子命令 + SQLite，零第三方依赖 |
| `scripts/selftest.sh` | 114 项自检（24 组），末尾打印 `通过 N / 失败 M`，`FAIL>0` 则 exit 1 |
| `bin/memtree` / `bin/memtree.cmd` | POSIX / Windows 启动器，按 `MEMTREE_PY → python3 → python → py` 找解释器 |
| `.github/workflows/selftest.yml` | CI：Python 3.8/3.11/3.13 三档跑同一份自检 + CLI 冒烟 |
| `.gitattributes` / `.gitignore` / `LICENSE` | 行尾规范化 / 忽略规则 / MIT |

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

---

## 3. 能力状态表

| 能力 | 状态 | 接口在哪 | 一句话证据 |
|---|---|---|---|
| 事件层（SPEC §2.2） | **已实现（最小版）** | `commit --event`（受控短标签 ≤24 字，超长直接拒写）；`nodes.event`；`context` 事件轴 `▣ 名 起~止 n条`；`recall --event` 在算相似度**之前**剪枝 | 自检专测「事件随正文进 context」与「缺列老库平滑升级」；事件边界仍由外部 Agent 给（无会话分段） |
| 三维检索 | **已实现** | `recall --at --outcome --days --event --mode --status --top`；时间项 `time_weight()`:76、总权重 `weight()`:388 | 输出行自带三元分解 `t·0.99 r·+0.90 sem+0.42 Σ=+0.57`；自检 [3] 同 query 换 `--outcome ±0.9` 命中不同节点 |
| 内容寻址 | **已实现** | `blobs.addr = sha256(正文)[:16]`（`addr_of()`:201）；`verify <addr>`、`show <id>` | 相同内容天然去重；`verify` 重算 sha256 比对，篡改必被发现 |
| 分支 | **已实现（语义弱）** | `branch --from <id>` / `checkout` / `merge --summary`；`branches(name,fork_node,head_id,status,merged_into)` | 自检 [5] 3 条；`compress` 默认跟随当前 HEAD（旧实现写死 `main`，侧枝压不到） |
| 保护位 / 硬锚点 | **已实现** | `commit --pin`、`pin <id> [--off]`（`cmd_pin()`:498）；`type=anchor` 独立成段、撞上更新的 fact 标 `⚑锚点未变`（:388-407） | 自检 [12] 5 条（不裁剪/不压缩/不硬删）、[13] 3 条（不被现状吞掉） |
| 热度与压缩计时器 | **已实现** | `heat_of()`:87 = `0.5^(距上次访问天数/45)`，**只看「距上次访问」，不累计次数**；唯一消费者 `compress --heat`；`stats` 热度直方图 `_heat_hist()`:1337 | 自检 [15] 3 条；热度不进 `weight()` —— 不参与排序、不进上下文、不升区 |
| 采样 → 结算 → 打标签 | **已实现** | `signal --type user_confirm\|correction\|emotional_peak\|repeat_mention`；`settle`（`_judge()`:530 走规则、不调 LLM）；`label <id> anchor\|emotional\|noise\|clear`；`signals` + `settle_log` 两表 | 自检有「anchor 不被压缩」「noise 豁免热度门」；每次结算写 `settle_log`，可审计 |
| 五档分区 hot/warm/cold/archive/tombstone | **已实现** | `nodes.zone` + `ZONES`:53 + `zone_target()`:303；`zone --migrate` **单向降级**、`zone --id N --set X` **唯一升级入口**（`tombstone` 除外，:1298 拒绝）；`context` 分区门；`recall --zone`；`stats.by_zone` | 自检：冷区/墓碑条数必须明说、不许静默隐藏；老库补列后按时间回填一次（否则单向降级从第一天就不成立） |
| 墓碑两段式删除 | **已实现** | `purge`（`cmd_purge()`:1039）：默认进墓碑（`zone='tombstone'` + `tombstoned_at` + `purge_reason`），冷却 `PURGE_COOLDOWN_DAYS=7.0`:55；`--apply` 期满真删、`--restore` 撤回、`--now` 隐私直通车、`--list` 报 `days_left` | 自检：冷却未满不真删 / 期满真删正文清空只留悬空地址 / 保护位拒绝 purge / `zone --set tombstone` 被拒 |
| **事件内细节梯度压缩**（SPEC §5 ①） | **已实现**（`446fd66`） | `compress --keep-detail N`（默认 1）+ `--min-count`（默认 3）+ `is_conclusion()`:1205 + `cmd_compress()`:1216；`nodes.rolled_into`、`meta{rolled,ids,event,kept_detail}` | 自检 `[24]` 20 条断言全绿：`rolled_into` 指向 / `hot=0` 非删除 / 最新 N 条逐字保留 / 事件标签继承 / 两事件不合并 / 四类结论必留 / `conclusions_preserved` 精确性 / `--keep-detail 0` 退化 / 二次压缩幂等。文档落点：`references/schema.md` §5.5、README「压缩是梯度，不是剪切」、SKILL 的 compress 段、AUDIT #16 |

---

## 4. 未实现清单（带 SPEC 章节）

**别误以为有。** 以下是审计过确认没有的：

| 缺口 | SPEC | 现状 | 为什么还没做 |
|---|---|---|---|
| 归档区磁盘配额 | §3 / §9 | `zone='archive'` 只是标记，同库同表，无配额、无清理、无独立存储 | 需要真做独立归档文件或外部冷存储 |
| 情感层 `affect` 表 | §7 | 只有 `label='emotional'` + `signals.quote` 保住用户原话；**没有 `emotion_tags / intensity` 结构化落库**；检索权重里没有情绪相关性（SPEC 要求与时间并列为主权重） | 需要先定情绪分类体系与打标来源 |
| 人格卡 + 三层锚点 | §6 | 只有最基础形态：`type=anchor` 独立成段、永不裁剪、被更新 fact 撞上标 `⚑锚点未变` | 没有 token 上限、版本化、卡内预算（硬/软/可变三层）、变更日志、漂移检测；得先定「卡从哪来、谁批准改」 |
| 分类型压缩阈值 | §4.2 | 只有单一 `--days / --min-count / --heat` | 普通/重要/情感锚点三档阈值未定 |
| 分层检索流水线 | §8.3 | 现在是一次打分（时间窗 + 权重排序）；有 `--event` 剪枝，但没串成「剪枝 → 事件过滤 → 混合相似度 → 加权排序 → 逐级展开」 | 依赖事件级权重 |
| 事件边界自动化 | §2.2 | `event` 全靠外部 Agent 给；没有会话分段、独立事件节点、事件级权重、同类型事件秩位衰减 | 需要对话分段模型（与「零依赖、零 LLM」冲突） |
| `competing` 状态 | schema §5 | 保留值，**无写入路径**：`recall --status competing` 恒为空，相关分支是死代码 | 缺「两条现状互相矛盾、等用户裁决」的交互流程 |
| 分支语义 | §2 / schema §9 | `scope=global` 的 fact/pref 跨分支互相覆盖（分支 DAG 在状态层被抹平）；`merge` 后分支仍可 `checkout` 写入 | 需要给「全局 vs 分支」定优先级规则 |
| 后台调度 / 日终 consolidation | §9 | 全靠手工或外部触发 | 零依赖 CLI 的边界；要做得另起进程或交给宿主 |
| MCP 封装 / 库级 API | §9 | 只有 CLI + `--json` | 优先级低于正确性 |
| 摘要用本地模型 | §12 待定参数 | 摘要正文是规则拼接（前 4 条片段、每条截 12 字） | 与零依赖冲突 |

### 4.1 文档类缺口（不影响功能，但会误导人）

- **README 的实测数字已过期**：`context` 358 token / 轮、22 条库那组数据是「事件层 + 分区层」之前的测量；本轮实测 `SKILL.md` 已是 **3,221 token**（README 原写 ~2,130），已按实测更正，但其余命令的 token 数**尚未在完整功能库上重测**。
- **CI step 名过期**：`.github/workflows/selftest.yml` 里 step 仍叫 `Run 20 self-tests`，实际 114 项。改它要动 CI 文件，注意边界。
- **README 自检徽章/项数**已在本轮校正：徽章 `20/20 → 114/114`、正文 `37 项 → 114 项`。

---

## 5. 当前状态

### 5.1 提交与自检

| 项 | 值 |
|---|---|
| 代码基线 | **`446fd66`** `feat: in-event detail gradient compression (SPEC 5-1)` |
| 更早的骨架提交 | `1349794` 文档排序 · `c3c9414` 墓碑区 + 两段式删除 · `bf58645` 五档分区 · `812c828` 事件层最小版 · `13c4f40` 采样→结算→标签 |
| 自检项数 | **114 项 / 24 组** |
| 自检结果 | **通过 114 / 失败 0**（`446fd66` 上实测；同一条命令在本台账写作时也跑过一次） |

> 提交号会变，别只信这张表：`git log --oneline -3` 永远是对的。

### 5.2 安装态是第二份副本（必须同步）

技能实际加载的位置是 **`C:/Users/荣贤达/.workbuddy/skills/memory-timeline`**（整棵树副本，自带 `.git`）。
仓库改了不同步 = Agent 读旧文档、跑旧代码。**这是最容易忘的一步。**

**六件文档**（一个循环覆盖）：

```bash
cd "C:/Users/荣贤达/OneDrive/Desktop/memory-timeline"
D="C:/Users/荣贤达/.workbuddy/skills/memory-timeline"
for f in SKILL.md README.md AUDIT.md references/schema.md references/theory.md references/prompts.md; do
  cp "$f" "$D/$f"
done
```

**但代码也要覆盖**，否则 skill 跑的是旧实现：

```bash
cd "C:/Users/荣贤达/OneDrive/Desktop/memory-timeline"
D="C:/Users/荣贤达/.workbuddy/skills/memory-timeline"
cp scripts/memtree.py scripts/selftest.sh "$D/scripts/"
cp bin/memtree bin/memtree.cmd "$D/bin/"
diff -rq . "$D" 2>/dev/null | grep -v '\.git'   # 期望：无输出
```

- `PROJECT_STATE.md` **不在这六件里**：它是仓库台账，Agent 运行时只读 `SKILL.md`。要给人看就顺手 `cp PROJECT_STATE.md "$D/"`。
- 本次核对时的实测差异：`diff -rq` 只报 `scripts/memtree.py` 不同（文档当时一致）——即**代码已漂移，文档没漂**。

### 5.3 自检怎么跑（本机必须先给解释器）

本机 MSYS2 bash 的 PATH 里，用户名段是乱码（`/c/Users/���ʹ�/...`），所以 `command -v python` 全部 MISSING，直接跑会报：

```
找不到 python，请设 MEMTREE_PY
```

正确姿势：

```bash
cd "C:/Users/荣贤达/OneDrive/Desktop/memory-timeline"
MEMTREE_PY="/c/Users/荣贤达/AppData/Local/Programs/Python/Python312/python.exe" bash scripts/selftest.sh
```

（实测 Python 3.12.8。最后一行应打印 `通过 114 / 失败 0`。）

---

## 6. 下次接手先读这里

**第一步：** 读本文件 → 读 `AUDIT.md` 的「明确没做」和「下一期建议」→ 再看 `references/schema.md` §5.5（压缩）。
**别做的：** 别先读 `scripts/memtree.py` 全文（1.5k 行）；用 `grep -n "^def "` 拿函数索引，再定点读。

**怎么跑自检**：见 §5.3。`FAIL>0` 时先看是不是工作区有你或别人的未提交改动（`git status`）。

**怎么提交**（不改全局 git config、不 push）：

```bash
cd "C:/Users/荣贤达/OneDrive/Desktop/memory-timeline"
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
cd "C:/Users/荣贤达/OneDrive/Desktop/memory-timeline"
PY="/c/Users/荣贤达/AppData/Local/Programs/Python/Python312/python.exe"
"$PY" - <<'EOF'
import pathlib
src = pathlib.Path("scripts/memtree.py").read_text(encoding="utf-8")
i = src.index("legend = ("); d = 0
for k in range(i + len("legend = "), len(src)):
    if src[k] == "(": d += 1
    elif src[k] == ")":
        d -= 1
        if d == 0: break
leg = eval(src[i + len("legend = "):k + 1])
doc = [l for l in pathlib.Path("SKILL.md").read_text(encoding="utf-8").split("\n") if l.startswith("\u203b ")]
print("PARITY_OK" if [leg] == doc else "PARITY_DIFF")
EOF
```

3. **安装态是第二份副本**：见 §5.2。改了仓库不同步，Agent 用的还是旧版。
4. **新增列必须走 `_migrate`**：`ALTER TABLE` + 索引要在补列**之后**建。把 `CREATE INDEX` 写进建表的 `executescript` 会让老库一打开就报错并整段回滚（升级即崩，AUDIT #13 记过）。
5. **分区不许借道上浮**：`zone --set` 是唯一升级入口；`tombstone` 只能由 `purge` 进入（删除要带理由与冷却）。`zone --set tombstone` 会被直接拒绝。
6. **自检只用自己的临时库**：脚本开头 `export MEMTREE_DB=$(mktemp -d)/...`。别把外部 `MEMTREE_DB` 继承进去——历史上因此出现过 19 项假失败。
7. **压缩不是剪切**：`compress` 只压细节，`decision/anchor/merge`、`outcome≠0`、`label∈{anchor,emotional}`、`pinned` **无论多老都不压**。改这段前先读 `is_conclusion()`:1205 —— 它就是「梯度的下限」。

---

## 7. 本文件怎么维护

- 每轮有**能力落地或被推翻**时更新 §3；有**新缺口**时更新 §4；每次提交后更新 §5.1 的提交号。
- 只记录**已验证的事实**（附证据：文件:行号、自检断言名、命令输出）。拿不准就写「待验证」，别写成结论。
- 别把这里当 changelog —— 逐条改动归 `AUDIT.md` 的「本轮改了什么」（现已 16 条）。本文件只回答三件事：**现在有什么、缺什么、下一个会话怎么起步**。
