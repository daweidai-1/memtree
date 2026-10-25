# memtree

**时间轴优先的 Agent 长期记忆层。零依赖、单文件、确定性覆盖。**

[![Python](https://img.shields.io/badge/python-3.8%2B-blue)](https://www.python.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Deps](https://img.shields.io/badge/dependencies-0-brightgreen)]()
[![Self-test](https://img.shields.io/badge/self--test-20%2F20-success)]()

> A timeline-first memory layer for AI agents. Old state is superseded by time, not by an LLM vote. 530 bytes per memory, ~550 tokens per turn, zero dependencies.

---

## 它解决的问题

几乎所有记忆系统都在优化同一件事：**怎么把检索做得更准、把文本压得更短**。

memtree 换了个问题：**怎么让大部分文本根本不需要进上下文。**

具体到两个真实故障：

| 故障 | 表现 | 常见方案的解法 |
|---|---|---|
| **状态矛盾** | 用户先说喜欢美式、后改喝拿铁，模型答"你既喜欢美式又喜欢拿铁" | LLM 判定 ADD/UPDATE/DELETE —— 同一输入跑两次可能结果不同 |
| **上下文膨胀** | 200 轮对话后每轮都在重发十几万 token 的历史 | 摘要压缩 —— 压到一定程度就丢结论 |

memtree 的解法是两条硬规则：

1. **覆盖由时间决定，不由模型决定。** 同一 `subject` 内时间最大者为现状，其余立刻转 `superseded`。闭式公式，可复现、可审计、零 LLM 调用。
2. **旧记忆不压缩，只是挪出去。** 正文从热路径移除，只保留 `sha256` 内容地址；需要时按地址取回，`verify` 能校验是否被篡改。

---

## 三条设计决定

### D1　一条记忆 = 复平面上的点 × 事件向量

```
M = z ⊗ e        z = t + i·r     (实轴 t = 时间, 虚轴 r = 结果)
⟨Q, M⟩ = (t_q·t_m + r_q·r_m) · cos(e_q, e_m)
```

查询永远站在"此刻"这唯一时刻，归一化后 `t_q ≡ 1`，于是 `t_q·t_m` 退化成一条衰减权重：

```
w = 2^(-Δt / 45天)
```

**时间不是匹配维度，是权重。** 所以问"我喜欢吃什么"时，内积 = 语义相似度 × 新鲜度，最大值自然落在最新那条——不需要额外排序规则。

虚轴平时休眠（`r_q = 0` 时整项消失），只有传 `--outcome` 才激活，用于定位"当初哪个方案成功了"。

### D2　覆盖只看时间

```
同一 subject 内：t 最大者 = 现状，其余 → superseded
```

不看结果值、不看可信度、不看重复次数。**为什么**：一旦让这些参与覆盖，就要定义"多少次确认能压过多新的改口"，规则会迅速复杂化且不可预测。

结果是确定性的：同样的输入永远同样的输出。这一点在对比里很重要 —— 主流方案（mem0、Zep、Letta）的冲突消解都依赖 LLM 判定。

### D3　正文地址化

```
addr = sha256(content)[:16]
```

| 状态 | 正文位置 | 能否取回 |
|---|---|---|
| `active` | `blobs.hot=1` | 能，进上下文 |
| `superseded` / `archived` | `blobs.hot=0` | 能（`verify`/`show`），不进检索 |
| `purged` | `hot=2`，正文清空 | 不能，地址成为悬空指针，仅作溯源 |

相同内容天然去重。`verify <addr>` 重算 sha256 比对 —— 地址即内容，篡改必被发现。

---

## 实测

22 条记忆的库，实测输出（可复现，见下方「自检」）：

| 项 | 数值 |
|---|---|
| 单条记忆存储 | ~530 字节（t 8B + r 8B + 向量 512B） |
| `context` 每轮注入 | **554 token**（596 字符） |
| `recall --top 5` 一次 | 381 token |
| `log --brief` 一次 | 1,044 token |
| `log --brief --width 28` 一次 | **696 token** |
| `log` 默认（含地址/权重） | 1,357 token |
| `show` 单条 | 131 token |
| **SKILL.md（每次会话加载）** | **~1,400 token** |

### 和"什么都不做"比

| | 无记忆 | memtree |
|---|---|---|
| 每轮上下文 | `2000 + 600n`，随轮数线性涨 | **恒定 ~554** |
| 撞 150K 上限 | 第 **247** 轮 | 不会 |
| 累计成本交叉点 | — | **第 25 轮**（短于 25 轮用它纯亏） |
| 第 200 轮累计 token | 12.46M | 1.94M（**省 84%**） |

> 25 轮这个拐点值得记住：**短对话不该用记忆层**，它是有明确最小适用长度的。

### 一个容易忽略的账

`SKILL.md` 每次会话都要加载。Agent 不像人，它每个新会话都从零开始 —— 所以"文档写得详细"在人眼里是优点，在 Agent 眼里是**每次会话都要重付的税**。

本项目为此做过一次专项瘦身：`SKILL.md` 从 3,323 → **1,406 token（−58%）**，数学推导移到 `references/theory.md` 按需读取，可用信息一条没少。

---

## 与同类方案的差异

不是"谁更好"，是"解哪个问题"。

| | memtree | mem0 | Zep / Graphiti | Letta (MemGPT) |
|---|---|---|---|---|
| 记忆模型 | 时间轴 + 复平面点 | 向量事实层 | 时序知识图谱 | OS 式分页运行时 |
| **状态覆盖** | **闭式公式，确定性** | LLM 判 ADD/UPDATE/DELETE | LLM 输出 `contradicted_facts` | agent 自己改 memory block |
| 时间语义 | 单时间轴 + 可回溯 | created/updated + TTL | 双时间（valid_at/invalid_at） | 无内建 |
| 分支 | 有（DAG） | 无 | 无 | 无 |
| 写入 LLM 调用 | **0** | ≥1 次/写入 | 多次/写入 | 有 |
| 多跳推理 | 无 | 无 | **有（图遍历）** | 无 |
| 依赖 | **仅标准库** | 向量库 | 图数据库 | 运行时 |

**memtree 明确不做的事**：实体图、多跳推理、自动抽取。要这些请用 Zep/Graphiti 或 Cognee。

基准数据提醒：LongMemEval 上各家自报差距极大（mem0 94.4% / Zep 63.8% / MemPalace 96.6%），LoCoMo 被独立审计出 6.4% 答案键错误、LLM judge 接受 63% 的故意错误答案。**这些数字互不可比，别用来选型。**

---

## 安装

只有一个文件，只用标准库（Python 3.8+）：

```bash
git clone https://github.com/<your-name>/memory-timeline.git
cd memory-timeline

python scripts/memtree.py init          # 建库
python scripts/memtree.py commit "喜欢美式" --type fact --subject user.coffee --outcome 0.5
python scripts/memtree.py context       # 看注入块长什么样
```

### 作为 Agent Skill 使用

把整个目录放进 skills 目录，Agent 会自动读 `SKILL.md`：

```bash
# WorkBuddy / Claude Code 类环境
cp -r memory-timeline ~/.workbuddy/skills/
```

### 作为独立 CLI / 库使用

```python
import subprocess, json
out = subprocess.check_output(
    ["python", "scripts/memtree.py", "context", "--json"]
)
print(json.loads(out)["text"])
```

> 提示：`context` 的输出是**给模型读的**，别原样展示给用户——里面是 `■ (曾:…)` 这类压缩标记。

---

## 快速上手

```bash
M="python scripts/memtree.py"

# 写：发生改变时覆盖旧的
$M commit "喜欢美式" --type fact --subject user.coffee
$M commit "改喝拿铁" --type fact --subject user.coffee
$M context
# ■ user.coffee: 拿铁  (曾:美式@09-15)
#   ↑ 旧值不会消失，只是降级成墓碑，禁止当现状回答

# 读：按「时刻 + 成败」定位
$M recall "方案" --at 2026-09-10 --outcome 0.9    # 9月做的、成功的方案
$M recall "方案" --status any                     # 连废弃的一起看（会标注）

# 维护
$M log --brief                    # 时间轴速览
$M show 12                        # 来龙去脉 + 覆盖链
$M compress --days 30             # 旧事件压成一行摘要
$M graph --style git              # 输出 Mermaid 图
```

### 命令速查

| 命令 | 作用 |
|---|---|
| `commit` | 写入；`--subject --outcome --type --ts --refs` |
| `context` | 生成压缩记忆块；`--budget 650 --recent 3 --json --verbose` |
| `recall` | 定位；`--at --outcome --days --mode --status --top` |
| `log` | 时间轴；`--brief` 精简、`--all` 含归档 |
| `show` / `verify` | 详情 + 覆盖链 / 地址校验 |
| `branch` / `checkout` / `merge` | 分叉 / 切换 / 合并归档 |
| `compress` / `purge` | 旧事件压缩 / 正文物理删除 |
| `graph` / `stats` / `export` | 出图 / 统计 / 导出 |

DB 默认 `./.workbuddy/memory/memtree.db`，用 `MEMTREE_DB` 覆盖（按项目分库）。

---

## 设计边界（必须先读）

**它不做什么：**

1. **没有自动抽取。** 需要模型或人把对话压成结构化 `commit`。这是最大的短板，mem0 在这点上完胜。
2. **没有实体图。** 多跳推理为零。这是权衡：Zep 用图数据库换来的能力。
3. **语义是词面近似。** 128 维随机投影词袋，做不到语义泛化。要精准得换 embedding（见 `references/schema.md` 第 8 节）。
4. **`subject` 是命门。** 写错或写不一致，覆盖直接失效，退化成"一堆并列记忆"。这是唯一的失败入口。
5. **短对话不划算。** 累计成本交叉点在 25 轮左右，低于此用它纯亏。

**一个已知的理论限制**：压缩保留的是结论，不是推理链。"选了方案 B" 脱离"当时 A 有内存泄漏"就无法支撑后续推理。这是所有摘要式记忆的通病，memtree 不免疫——缓解办法是把关键前提写成独立 `commit`，而不是塞进摘要。

---

## 自检

```bash
bash scripts/selftest.sh
```

20 项，覆盖：时间覆盖 / 乱序补录 / 三维检索 / 内容寻址 / 分支 / context 预算 / 压缩 / 物理清除 / 出图。

```
[1] 时间权重覆盖（越新越大）        ok ×4
[2] 乱序补录：旧时间不该覆盖新时间   ok ×2
[3] 三维检索：时间×结果×语义        ok ×2
[4] 内容寻址                        ok ×1
[5] 分支                            ok ×3
[6] context 预算与图例              ok ×3
[7] 压缩                            ok ×2
[8] 物理清除                        ok ×1
[9] 出图                            ok ×2
通过 20 / 失败 0
```

---

## 文件结构

```
memory-timeline/
├── SKILL.md              # Agent 入口（~1200 token，精简到只留操作信息）
├── README.md             # 本文件
├── LICENSE               # MIT
├── references/
│   ├── theory.md         # 数学推导（复平面模型、打分分解、时间旅行）
│   ├── schema.md         # 表结构、状态机、subject 命名、换真嵌入的方法
│   └── prompts.md        # 注入模板与抽取提示词
└── scripts/
    ├── memtree.py        # 全部实现，单文件，零依赖
    └── selftest.sh       # 20 项自检
```

---

## 一句话总结

> 它用**写入时的结构化成本**换了**读取时的确定性和恒定开销**。
>
> 值不值，取决于写入侧愿不愿意付这个成本 —— 需要有人（或模型）把对话压成 `subject + content + outcome`，而不是丢一整段原始对话进去。

## License

MIT
