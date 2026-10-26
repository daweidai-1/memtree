#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""memtree — 时间轴记忆库：时间 × 结果 × 语义 + 内容寻址

一条记忆 = 复平面上的点 × 事件向量：

    M = z ⊗ e        z = t + i·r     (实轴 t = 时间，虚轴 r = 结果)
    Q = z_q ⊗ e_q
    ⟨Q, M⟩ = Re(z̄_q · z_m) · ⟨e_q, e_m⟩ = (t_q·t_m + r_q·r_m) · cos(e_q, e_m)

三条设计决定：

1. 时间不做匹配，只做权重。查询永远站在"此刻"这唯一时刻，归一化后 t_q ≡ 1，
   于是 t_q·t_m 退化成 2^(-Δt/45)，一条严格单调的衰减权重。问"我喜欢吃什么"时，
   内积 = 语义相似度 × 新鲜度，最大值自然落在最新那条——不需要额外的排序规则。

2. 虚轴平时休眠。不问结果时 r_q = 0，虚轴整项为 0，退化成"语义 × 新鲜度"；
   传 --outcome 时才激活，才能定位"当初哪个方案成功了"。

3. 覆盖只看时间。同一 subject 内时间最大者为现状，其余立刻转 superseded，
   正文移出热路径只留地址。结果值不参与覆盖判定——它只服务检索定位。

正文用 sha256 前 16 位做内容寻址（CAS），相同内容天然去重；verify 可校验篡改。

只依赖标准库。
"""

import argparse
import hashlib
import json
import math
import os
import random
import re
import sqlite3
import struct
import sys
import tempfile
import unicodedata
from datetime import datetime, timedelta

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

# ------------------------------------------------------------------ 常量
VEC_D = 128            # 事件（语义）向量维度：128 × float32 = 512B/条
TAU_DAYS = 45.0        # 时间权重半衰期（天）：w = 2^(-|Δt|/45)，越新越大、未来封顶 1.0
STATEFUL = ("fact", "pref", "decision")
ANCHOR = "anchor"      # 硬锚点：身份/关系里程碑/安全约束。不参与覆盖、不压缩、不裁剪
GLYPH = {"active": "●", "superseded": "◐", "archived": "○", "competing": "◆"}
# 分区（SPEC §3）：时间单向降级 hot→warm→cold→archive。升级只能显式（zone --set），
# 因为「被问得多」不等于「值得记住」—— 调用次数不许把球往回推（铁律一）。
ZONES = ("hot", "warm", "cold", "archive", "tombstone", "purged")
ZONE_RANK = {"hot": 0, "warm": 1, "cold": 2, "archive": 3, "tombstone": 4, "purged": 5}
# 墓碑与已抹正文终态都不参与正常检索/上下文/活引用计数。purged 是终点：
# zone='tombstone' 只表示「已受理删除、冷却中」，真删成功后必须离开墓碑区。
HIDDEN_ZONES = ("tombstone", "purged")
PURGE_COOLDOWN_DAYS = 7.0           # 墓碑区冷却期：删除不可逆，缓冲几天给手滑与「真要删」区分开
HOT_DAYS, WARM_DAYS = 7.0, 90.0     # 热 ≤7 天；温 7~90 天；更旧则看重要度：冷（保护区）或归档
COLD_MIN_IMPORTANCE = 0.7           # 进冷区（保护区）的重要度下限：冷区不是垃圾桶
DEFAULT_DB = os.path.join(".workbuddy", "memory", "memtree.db")
# 人格卡（SPEC §6）：三层锚点预算。卡文件只说"现在是什么"，persona_log 说"改过什么"。
# 硬槽是"我是谁"的护栏 —— 改它必须 --force：人格漂移和记忆覆盖不同，它不会自己回滚。
PERSONA_SLOTS = ("hard", "soft", "var")
PERSONA_TITLES = {"hard": "## 硬槽", "soft": "## 软槽", "var": "## 可变槽"}
PERSONA_TITLE_TO_SLOT = {v: k for k, v in PERSONA_TITLES.items()}
PERSONA_LABELS = {"hard": "硬", "soft": "软", "var": "可变"}
PERSONA_SLOT_BUDGET = {"hard": 300, "soft": 350, "var": 150}
PERSONA_TOTAL_BUDGET = 800
# 情感层（SPEC §7）：固定 8 类 + 未标注。标签是内容属性，不是访问次数；
# 只在显式 --emotion 查询时进入排序，绝不参与覆盖、分区、压缩或保留时长。
AFFECT_TAGS = ("joy", "trust", "surprise", "sadness",
               "fear", "anger", "disgust", "anticipation", "unspecified")
AFFECT_TAG_ALIASES = {
    "喜悦": "joy", "开心": "joy", "高兴": "joy", "快乐": "joy",
    "信任": "trust", "信赖": "trust",
    "惊讶": "surprise", "意外": "surprise",
    "悲伤": "sadness", "难过": "sadness", "伤心": "sadness",
    "恐惧": "fear", "害怕": "fear", "焦虑": "fear",
    "愤怒": "anger", "生气": "anger", "恼火": "anger",
    "厌恶": "disgust", "反感": "disgust",
    "期待": "anticipation", "盼望": "anticipation",
    "未标注": "unspecified",
}


# ------------------------------------------------------------------ 记忆的数学形式
#
#   一条记忆 = 复平面上的一个点 × 一个事件向量
#
#       M = z ⊗ e        z = t + i·r     (实轴 t = 时间, 虚轴 r = 结果)
#
#   查询同构：Q = z_q ⊗ e_q
#   打分    ：⟨Q, M⟩ = Re(z̄_q · z_m) · ⟨e_q, e_m⟩
#                    = (t_q·t_m + r_q·r_m) · cos(e_q, e_m)
#
#   查询的时间是"此刻"这唯一值，所以 t_q ≡ 1，t_m 退化成一条时间权重；
#   默认不问结果时 r_q = 0，虚轴整项自动为 0 —— 虚数平时休眠，问结果时才激活。
#   这就是"纯定位是二维、虚数用来定位结果"的字面实现。


def time_weight(t_m, t_q=None):
    """时间量：查询时间唯一，所以它不做匹配，只做权重。

    w = 2^(-|Δt|/45)：过去越久越低；未来越临近越高，但在"此刻"封顶为 1.0。
    未来取绝对值而不是 clamp 成 0 —— clamp 会让一条年份写错的记忆（如 2030）
    永久拿满权重霸占检索首位，实测过。
    """
    t_q = t_q or datetime.now().timestamp()
    return 0.5 ** (abs(t_q - t_m) / 86400.0 / TAU_DAYS)


def heat_of(row, t_now=None):
    """热度 = 计时器，不是裁判（SPEC §4.1 / 铁律三）。

    只回答一个问题："这条有多久没被碰过了？" 只看距上次访问的时长，
    绝不累计访问次数 —— 累计次数会让高频闲聊全部变热，正是铁律二禁止的裁判行为。
    写入即热区（§3.4）：从没被访问过的条目，从它的写入时间开始衰减。
    返回值只用于触发压缩（compress --heat），永远不进入排序。
    """
    t_now = t_now or datetime.now().timestamp()
    # 未来时间戳按「尚未发生」算：衰减起点是现在，不是那个未来时刻。
    # 用 max(accessed_at, t) 会让一条 2030 年的记录永久热度 1.0、永久免疫压缩。
    last = max(float(row["accessed_at"] or 0.0), min(float(row["t"] or 0.0), t_now))
    return 0.5 ** (max(0.0, t_now - last) / 86400.0 / TAU_DAYS)


def l2(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _terms(text):
    """切词：ASCII 单词 + 非 ASCII 文字段的单字符与相邻二元组。

    随机投影词袋没有"意思相近"的能力，任何两段文字都会有非零余弦（噪声）。
    所以召回侧还要用它算一次**词面重合**，把纯噪声的命中标出来。
    """
    s = (text or "").lower()
    toks = re.findall(r"[a-z0-9_]+", s)
    # 非 ASCII 文字段（汉字/假名/谚文/emoji…）统一按"单字符 + 相邻二元组"入袋。
    # 只认 CJK 的话，假名·韩文·emoji 会退化成零向量 —— 情感对话里 emoji 密度很高，
    # 而这些记忆会静默变成"召回恒 0 分"的死数据。
    for seg in re.findall(r"[^\x00-\x7f]+", s):
        chars = [ch for ch in seg if unicodedata.category(ch)[0] not in "PZC"]
        toks += chars
        toks += [chars[i] + chars[i + 1] for i in range(len(chars) - 1)]
    return toks


def text_vec(text, vec_d=None):
    """事件向量：每个 token 生成一条稠密 ±1 随机向量再叠加（随机投影式词袋）。
    必须稠密——稀疏哈希会让"没命中的维度"权重为 0，把另一维整段打空。"""
    d = vec_d or VEC_D
    v = [0.0] * d
    toks = _terms(text)
    if not toks:
        return [0.0] * d
    for t in toks:
        x = int(hashlib.md5(t.encode("utf-8")).hexdigest()[:16], 16) | 1
        for i in range(d):
            x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF
            x ^= x >> 7
            x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
            v[i] += 1.0 if (x >> 63) & 1 else -1.0
    return l2(v)


def pack_real(v):
    return struct.pack("<%df" % len(v), *v)


def unpack_real(b):
    return list(struct.unpack("<%df" % (len(b) // 4), b))


# ------------------------------------------------------------------ 通用工具
def now_iso(dt=None):
    return (dt or datetime.now().astimezone()).isoformat(timespec="seconds")


def parse_ts(s):
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        pass
    try:
        return datetime.strptime(str(s)[:19], "%Y-%m-%d %H:%M:%S").astimezone()
    except ValueError:
        sys.exit(f"[memtree] 时间格式无法解析：{s!r}"
                 "（示例：2026-10-25 或 2026-10-25T09:30:00）")


def _range(v, lo, hi, name):
    """范围校验。越界值不报错就会污染排序：实测 --outcome 5 会让一条记忆长期霸榜。"""
    if v is None:
        return 0.0
    v = float(v)
    if not (lo <= v <= hi):
        sys.exit(f"[memtree] {name} 超出范围 [{lo},{hi}]：{v}")
    return v


def short_date(ts, ref=None):
    d = parse_ts(ts) if isinstance(ts, str) else datetime.fromtimestamp(ts).astimezone()
    ref = ref or datetime.now().astimezone()
    return d.strftime("%m-%d") if d.year == ref.year else d.strftime("%y-%m-%d")


def clip(s, n):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def est_tokens(s):
    """估算 token 数。中文 1 字≈1.5 token，ASCII≈0.3 token/字符。

    不要用 len/1.4 —— 那只对纯英文成立，对中文会低估 40% 以上，
    按它做预算规划会系统性超支。
    """
    cjk = sum(1 for ch in s if "\u4e00" <= ch <= "\u9fff")
    return int(cjk * 1.5 + (len(s) - cjk) * 0.3)


def addr_of(text):
    """内容地址：sha256 前 16 位十六进制。相同内容 → 相同地址（天然去重）。"""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()[:16]


def db_path(args):
    p = getattr(args, "db", None) or os.environ.get("MEMTREE_DB") or DEFAULT_DB
    return os.path.abspath(p)


def connect(args):
    path = db_path(args)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    _schema(conn)
    return conn


def _schema(conn):
    conn.executescript(
        """
        -- 内容寻址存储：正文只在这里出现一次，节点只持地址
        CREATE TABLE IF NOT EXISTS blobs(
            addr       TEXT PRIMARY KEY,
            content    TEXT NOT NULL,
            nbytes     INTEGER,
            hot        INTEGER NOT NULL DEFAULT 1,   -- 1=参与检索/上下文 0=冷存 2=已清除
            created_at TEXT
        );
        CREATE TABLE IF NOT EXISTS nodes(
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            t             REAL NOT NULL,             -- 时间（epoch 秒）—— 第 1 维
            outcome       REAL NOT NULL DEFAULT 0,   -- 结果值 [-1,1] —— 第 2 维
            subject       TEXT,
            addr          TEXT NOT NULL,             -- 内容地址
            v_text        BLOB,                      -- 事件向量（语义）
            type          TEXT NOT NULL DEFAULT 'event',
            scope         TEXT NOT NULL DEFAULT 'global',
            factor        TEXT,                      -- 因子标记（墓碑/压缩）
            refs          INTEGER NOT NULL DEFAULT 0,-- 被强化次数 → 可信度（不参与排序）
            pinned        INTEGER NOT NULL DEFAULT 0,-- 保护位：不压缩、不硬删、不裁剪
            accessed_at   REAL,                      -- 最近一次检索命中（热度代理，不参与排序）
            label         TEXT,                      -- anchor|emotional|noise —— settle 结算产物
            zone          TEXT NOT NULL DEFAULT 'hot',   -- hot|warm|cold|archive：时间单向降级（SPEC §3）
            importance    REAL NOT NULL DEFAULT 0.5, -- 重要度：只参与分区下限，不参与排序
            event         TEXT,                      -- 所属事件（SPEC §2.2：记忆挂在事件下，事件是时间轴上的骨节）
            source_type   TEXT NOT NULL DEFAULT 'stated', -- stated|roleplay|inferred|system
            supersedes    INTEGER,
            superseded_by INTEGER,
            rolled_into   INTEGER,
            gone_at       REAL,                      -- 不再作为现状的时刻（覆盖/归档发生的那一刻）
            status        TEXT NOT NULL DEFAULT 'active',
            branch        TEXT NOT NULL DEFAULT 'main',
            parent_id     INTEGER,
            meta          TEXT,
            ts_iso        TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sub ON nodes(subject, status);
        CREATE INDEX IF NOT EXISTS idx_br  ON nodes(branch, t);
        CREATE INDEX IF NOT EXISTS idx_addr ON nodes(addr);

        -- 采样：访问过程中采集的原始证据。结算前不参与任何决策。
        CREATE TABLE IF NOT EXISTS signals(
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id   INTEGER NOT NULL,
            type      TEXT    NOT NULL,   -- user_confirm|correction|emotional_peak|repeat_mention
            intensity REAL    NOT NULL DEFAULT 0,
            quote     TEXT,
            emotion_tags TEXT,             -- 受控词表 JSON 数组（SPEC §7）
            valence   REAL    NOT NULL DEFAULT 0,
            at        TEXT    NOT NULL,
            settled   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_sig ON signals(node_id, settled);

        -- 情感观察（SPEC §7）：一条记忆可以有多次情绪记录，nodes.label 只保留
        -- 「是不是情感锚点」这一个结算结论，不再承担完整的情绪语义。
        CREATE TABLE IF NOT EXISTS affect(
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id    INTEGER NOT NULL,
            t          REAL NOT NULL,
            tags       TEXT NOT NULL,          -- JSON 数组，规范顺序、去重
            intensity  REAL NOT NULL DEFAULT 0,
            valence    REAL NOT NULL DEFAULT 0,
            key_quote  TEXT,
            source     TEXT NOT NULL DEFAULT 'stated',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_affect_node ON affect(node_id, t DESC);

        -- 结算审计：没有这张表，"为什么这条被打成重要"就不可回答
        CREATE TABLE IF NOT EXISTS settle_log(
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id     INTEGER NOT NULL,
            signal_types TEXT,
            old_pinned  INTEGER,
            new_pinned  INTEGER,
            old_label   TEXT,
            new_label   TEXT,
            reason      TEXT,
            at          TEXT NOT NULL
        );

        -- 人格卡审计（SPEC §6）：卡文件只说"现在是什么"，这张表是"改过什么"的唯一真源。
        -- --at 回溯、超预算挤出、防人格漂移都只能靠它回答。
        CREATE TABLE IF NOT EXISTS persona_log(
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            t      REAL NOT NULL,
            slot   TEXT NOT NULL,
            op     TEXT NOT NULL,          -- add|del|evict
            old    TEXT,
            new    TEXT,
            reason TEXT
        );

        CREATE TABLE IF NOT EXISTS branches(
            name TEXT PRIMARY KEY, fork_node INTEGER, head_id INTEGER,
            status TEXT NOT NULL DEFAULT 'open', merged_into TEXT, merged_at TEXT, created_at TEXT
        );
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        """
    )
    _migrate(conn)
    # 索引必须等补列之后再建：老库上 nodes(event) 还不存在，在 executescript 里建会当场报错，
    # 连带整段 schema 脚本回滚 —— 升级即崩，比缺功能更糟。
    conn.execute("CREATE INDEX IF NOT EXISTS idx_ev ON nodes(event)")
    conn.execute("INSERT OR IGNORE INTO branches(name,status,created_at) VALUES('main','open',?)", (now_iso(),))
    conn.commit()


def zone_target(age_days, importance, pinned=0, label=None):
    """分区只由「时间 + 重要度 + 保护位」决定，不由调用次数决定（SPEC §3.4）。

    这条规则的形状就是防漂移：降级自动发生，升级必须有人按按钮。
    保护位把下限卡在冷区 —— 重要但低频的记忆是保护区，不是垃圾桶。
    noise 是结算产物（重复提及但没过情绪/确认阈值）：封顶不进热区（§3.3 垃圾热点）。
    """
    if age_days <= HOT_DAYS:
        z = "hot"
    elif age_days <= WARM_DAYS:
        z = "warm"
    elif (importance or 0.0) >= COLD_MIN_IMPORTANCE:
        z = "cold"
    else:
        z = "archive"
    if (pinned or label == "anchor") and ZONE_RANK[z] > ZONE_RANK["cold"]:
        z = "cold"
    if label == "noise" and ZONE_RANK[z] < ZONE_RANK["warm"]:
        z = "warm"
    return z


def _migrate(conn):
    """老库补列。CREATE TABLE IF NOT EXISTS 不会给已存在的表加新列，
    缺了这一步，升级后旧库上 pinned/accessed_at 全是 UndefinedColumn。"""
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(nodes)")}
    added = set()
    for name, ddl in (("pinned", "INTEGER NOT NULL DEFAULT 0"),
                      ("accessed_at", "REAL"),
                      ("label", "TEXT"),
                      ("event", "TEXT"),
                      ("zone", "TEXT NOT NULL DEFAULT 'hot'"),
                      ("importance", "REAL NOT NULL DEFAULT 0.5"),
                      ("tombstoned_at", "REAL"),
                      ("purge_reason", "TEXT"),
                      ("gone_at", "REAL"),
                      ("source_type", "TEXT NOT NULL DEFAULT 'stated'")):
        if name not in cols:
            conn.execute(f"ALTER TABLE nodes ADD COLUMN {name} {ddl}")
            added.add(name)
    conn.commit()
    # 情感层补列/建表：老库的 signals 没有 tags/valence，affect 表也不存在。
    # 列必须先补，再建依赖它的索引/表（与 event 索引同一条铁律）。
    scols = {r["name"] for r in conn.execute("PRAGMA table_info(signals)")}
    for name, ddl in (("emotion_tags", "TEXT"),
                      ("valence", "REAL NOT NULL DEFAULT 0")):
        if name not in scols:
            conn.execute(f"ALTER TABLE signals ADD COLUMN {name} {ddl}")
    conn.execute("""CREATE TABLE IF NOT EXISTS affect(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    node_id INTEGER NOT NULL, t REAL NOT NULL,
                    tags TEXT NOT NULL, intensity REAL NOT NULL DEFAULT 0,
                    valence REAL NOT NULL DEFAULT 0, key_quote TEXT,
                    source TEXT NOT NULL DEFAULT 'stated', created_at REAL NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_affect_node ON affect(node_id, t DESC)")
    conn.commit()
    if "gone_at" in added:
        # 老库只记了「现在是什么 status」，没记「什么时候不再是现状」。回溯必须靠后者，
        # 所以补列时按最小可信代理回填：覆盖者自身的 t（我们没记写入墙钟，只有时间轴）。
        # 回填不到（superseded_by / rolled_into 为空）就留 NULL —— 那种情况在 recall --at
        # 里按当前 status 处理并计入 unknown_timing，绝不假装知道。
        conn.execute("""UPDATE nodes SET gone_at=
                          (SELECT w.t FROM nodes w WHERE w.id=nodes.superseded_by)
                        WHERE status='superseded' AND gone_at IS NULL
                          AND superseded_by IS NOT NULL""")
        conn.execute("""UPDATE nodes SET gone_at=
                          (SELECT s.t FROM nodes s WHERE s.id=nodes.rolled_into)
                        WHERE status='archived' AND gone_at IS NULL
                          AND rolled_into IS NOT NULL""")
        conn.commit()
    if "zone" in added:
        # 老库补列后全是 hot，等于「单向降级」从第一天就不成立（所有记忆都在热区），
        # 所以补列后立刻按时间回填一次 —— 这是唯一一次允许的批量重算，之后只由 zone --migrate 走。
        now_e = datetime.now().timestamp()
        for r in conn.execute("SELECT id,t,importance,pinned,label FROM nodes").fetchall():
            age = max(0.0, now_e - r["t"]) / 86400.0
            conn.execute("UPDATE nodes SET zone=? WHERE id=?",
                         (zone_target(age, r["importance"], r["pinned"], r["label"]), r["id"]))
        conn.commit()
    # 老版本 --apply 只清正文、不结案，留下 zone='tombstone' + hot=2 的幽灵。
    # 升级时一次性转 purged 终态：正文已经不可恢复，继续留在墓碑队列只会
    # 让 --list 永远 due、--restore 谎报可撤回。
    conn.execute("""UPDATE nodes SET zone='purged', tombstoned_at=NULL
                      WHERE zone='tombstone' AND EXISTS(
                        SELECT 1 FROM blobs b WHERE b.addr=nodes.addr AND b.hot=2)""")
    conn.commit()


def get_branch(conn, name):
    r = conn.execute("SELECT * FROM branches WHERE name=?", (name,)).fetchone()
    if not r:
        sys.exit(f"[memtree] 分支不存在: {name}（先 `branch {name}`）")
    return r


def head_branch(conn):
    v = conn.execute("SELECT v FROM kv WHERE k='head'").fetchone()
    return v["v"] if v else "main"


def node(conn, nid):
    r = conn.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone()
    if not r:
        sys.exit(f"[memtree] 节点不存在: #{nid}")
    return r


def content_of(conn, addr, hot_only=False):
    r = conn.execute("SELECT * FROM blobs WHERE addr=?", (addr,)).fetchone()
    if not r:
        return f"[地址 {addr} 正文已清除]"
    if hot_only and r["hot"] != 1:
        return f"[地址 {addr} 已转冷]"
    return r["content"]


def readable(conn, r):
    """检索命中时要给出的正文：库里还有这句话，就不许只回一个占位符。

    content_of(hot_only=True) 是「预取视图」（context/log 的省 token 口径），
    冷区就回占位；但检索是「我记过什么」的回答，占位等于半空手 —— 命中给了
    分数和地址却读不到话，是比没命中更坏的结果（会诱导模型自己编）。

    返回 (正文, 说明)。说明只描述「这是什么」，由输出层如实标注：
    - kind: '原文' / '摘要' / '占位'
    - cold: 正文在冷库(hot=0)，仍在库里，只是没被预取
    - summary_of: 这行本身是摘要，它概括的原文节点号（不许假装是原文）
    - summarized_into: 这行是被压掉的细节，它的摘要节点号
    - cleared: 正文真的被 purge 抹掉了（不可恢复）
    """
    info = {"kind": "原文", "cold": False}
    b = conn.execute("SELECT * FROM blobs WHERE addr=?", (r["addr"],)).fetchone()
    text = b["content"] if b else None
    if r["type"] == "summary":
        # 摘要正文是「压 N 条」的一句话：必须自报家门，否则会被当成原话引用
        info["kind"] = "摘要"
        try:
            info["summary_of"] = json.loads(r["meta"] or "{}").get("ids") or []
        except Exception:
            info["summary_of"] = []
    if text:
        info["cold"] = bool(b["hot"] != 1)
        if r["rolled_into"]:
            info["summarized_into"] = r["rolled_into"]
        return text, info
    # 正文确实被抹了：退到摘要，并明说这是摘要不是原文
    if r["rolled_into"]:
        s = conn.execute("SELECT * FROM nodes WHERE id=?", (r["rolled_into"],)).fetchone()
        sb = (conn.execute("SELECT * FROM blobs WHERE addr=?", (s["addr"],)).fetchone()
              if s else None)
        if sb and sb["content"]:
            info.update({"kind": "摘要", "cold": bool(sb["hot"] != 1),
                         "summarized_into": s["id"], "cleared": True})
            return sb["content"], info
    info.update({"kind": "占位", "cleared": True})
    return f"[地址 {r['addr']} 正文已清除]", info


def live_refs(conn, addr):
    """地址的「活引用」数：除墓碑区以外任何 zone 的节点都算。

    含 status='archived'/'superseded' —— 转冷、被压掉的正文也还要能回溯，
    所以它们照样保护 blob。内容寻址会去重：两条不同来源、正文一字不差的
    节点共用同一 addr，抹掉就是删别人的数据，不可恢复。
    """
    return conn.execute("SELECT COUNT(*) c FROM nodes WHERE addr=?"
                        " AND (zone IS NULL OR zone NOT IN ('tombstone','purged'))",
                        (addr,)).fetchone()["c"]


def pinned_refs(conn, addr):
    """该地址上打了保护位的节点数 —— 墓碑区里的也算。

    墓碑 A(pinned) 与墓碑 B(unpinned) 共用同一 addr 时，B 到期不能抹掉
    A 的保护位想保住的那串正文：保护位在墓碑里同样必须有效。
    """
    return conn.execute("SELECT COUNT(*) c FROM nodes WHERE addr=? AND pinned=1",
                        (addr,)).fetchone()["c"]


def orphan_addrs(conn):
    """孤儿地址：全库没有任何节点（任何 zone、任何 status）引用的 blob。

    这种正文是纯占用 —— 地址还在、谁也不要了。但墓碑区节点仍算引用者
    （冷却期内要能 --restore 撤回），所以它不在孤儿之列。
    """
    return conn.execute(
        "SELECT b.addr, b.nbytes FROM blobs b"
        " WHERE NOT EXISTS (SELECT 1 FROM nodes n WHERE n.addr=b.addr)").fetchall()


def _cold_blob(conn, addr):
    """给地址转冷，但绝不误伤还活着的那条 —— 内容寻址会把正文一字不差的两条并成一个地址。

    审计实证的 bug：覆盖时对败者的 addr 盲目标 hot=0，若胜者与它共用同一地址，
    活着的胜者读自己的正文就成了「[地址 … 已转冷]」。静默把正文变成占位符是
    本项目最贵的一类 bug，所以转冷前必须问一句：这地址上还有现状类节点吗？
    有 → 不转冷（宁可多占一点热区，也不许让活条目读不到自己的正文）。
    """
    alive = conn.execute(
        "SELECT COUNT(*) c FROM nodes WHERE addr=? AND status IN ('active','competing')"
        " AND (zone IS NULL OR zone NOT IN ('tombstone','purged'))", (addr,)).fetchone()["c"]
    if alive:
        return 0
    return conn.execute("UPDATE blobs SET hot=0 WHERE addr=? AND hot=1", (addr,)).rowcount


def emit(conn, obj, quiet=False):
    if not quiet:
        print(json.dumps(obj, ensure_ascii=False))


# ------------------------------------------------------------------ 情感层（SPEC §7）
def normalize_affect_tags(raw):
    """把 CLI 输入规范成受控词表；未知标签直接拒绝，不做静默丢弃。"""
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        parts = [str(x) for x in raw]
    else:
        parts = [x for x in re.split(r"[,，;；\s]+", str(raw).strip()) if x]
    out = set()
    for p in parts:
        key = p.strip().lower()
        key = AFFECT_TAG_ALIASES.get(p.strip(), AFFECT_TAG_ALIASES.get(key, key))
        if key not in AFFECT_TAGS:
            sys.exit(f"[memtree] 未知情感标签: {p}（可选 {', '.join(AFFECT_TAGS)}，也接受常见中文别名）")
        out.add(key)
    order = {t: i for i, t in enumerate(AFFECT_TAGS)}
    return sorted(out, key=lambda x: order[x])


def affect_parse_tags(raw):
    try:
        tags = json.loads(raw or "[]")
    except (TypeError, ValueError):
        tags = []
    return [t for t in tags if t in AFFECT_TAGS]


def affect_add(conn, node_id, tags, intensity=0.0, valence=0.0,
               key_quote=None, source="stated", t=None):
    """落一条不可变的情感观察。调用方负责 source=roleplay 的过滤。"""
    tags = normalize_affect_tags(tags)
    if not tags:
        tags = ["unspecified"]
    now_e = datetime.now().timestamp()
    conn.execute(
        """INSERT INTO affect(node_id,t,tags,intensity,valence,key_quote,source,created_at)
           VALUES(?,?,?,?,?,?,?,?)""",
        (int(node_id), float(t if t is not None else now_e),
         json.dumps(tags, ensure_ascii=False), float(intensity), float(valence),
         key_quote, source or "stated", now_e))


def affect_relevance(rows, qtags):
    """情绪相关性：命中查询标签的比例 × 强度 × 来源可信度；返回 (分数, 最佳行)。"""
    if not qtags or not rows:
        return 0.0, None
    q = set(qtags)
    src_weight = {"stated": 1.0, "inferred": 0.5, "system": 0.5, "roleplay": 0.0}
    best, best_row = 0.0, None
    for r in rows:
        tags = affect_parse_tags(r["tags"])
        if not tags:
            continue
        overlap = len(q & set(tags)) / float(len(q))
        score = overlap * max(0.0, min(1.0, float(r["intensity"] or 0.0)))
        score *= src_weight.get(r["source"] or "stated", 1.0)
        if score > best:
            best, best_row = score, r
    return best, best_row


def affect_map(conn):
    out = {}
    for r in conn.execute("SELECT * FROM affect ORDER BY node_id, t DESC, id DESC"):
        out.setdefault(r["node_id"], []).append(r)
    return out


def cmd_affect(conn, a):
    act = a.action
    if act == "set":
        nrow = node(conn, a.node)
        if (nrow["zone"] or "hot") in HIDDEN_ZONES:
            sys.exit("[memtree] 已删除/冷却中的节点不能再挂情感观察")
        if a.source == "roleplay" or (nrow["source_type"] or "stated") == "roleplay":
            sys.exit("[memtree] roleplay 内容不进入情感层（防虚构污染）")
        tags = normalize_affect_tags(a.tags)
        if not tags:
            sys.exit("[memtree] affect set 需要 --tags")
        inten = _range(a.intensity, 0.0, 1.0, "--intensity") if a.intensity is not None else 0.0
        val = _range(a.valence, -1.0, 1.0, "--valence") if a.valence is not None else 0.0
        affect_add(conn, a.node, tags, inten, val, a.quote, a.source,
                   parse_ts(a.ts).timestamp() if a.ts else None)
        conn.commit()
        emit(conn, {"node": a.node, "tags": tags, "intensity": inten,
                    "valence": val, "source": a.source})
        return
    if act == "show":
        node(conn, a.node)
        rows = conn.execute("SELECT * FROM affect WHERE node_id=? ORDER BY t DESC, id DESC",
                            (a.node,)).fetchall()
        items = [{"id": r["id"], "t": now_iso(datetime.fromtimestamp(r["t"]).astimezone()),
                  "tags": affect_parse_tags(r["tags"]), "intensity": r["intensity"],
                  "valence": r["valence"], "quote": r["key_quote"], "source": r["source"]}
                 for r in rows]
        if a.json:
            emit(conn, {"node": a.node, "affect": items})
        else:
            print(f"#{a.node} 情感 {len(items)} 条")
            for x in items:
                print(f"  {x['t'][:16]}  {','.join(x['tags']) or '-'}  "
                      f"intensity={x['intensity']:.2f} valence={x['valence']:+.2f}"
                      f"  {x['quote'] or ''}")
        return
    if act == "list":
        qtags = set(normalize_affect_tags(a.tags)) if a.tags else set()
        rows = conn.execute("SELECT * FROM affect ORDER BY t DESC, id DESC LIMIT ?",
                            (a.limit,)).fetchall()
        items = []
        for r in rows:
            tags = affect_parse_tags(r["tags"])
            if qtags and not qtags.intersection(tags):
                continue
            items.append({"node": r["node_id"], "tags": tags,
                          "intensity": r["intensity"], "valence": r["valence"],
                          "quote": r["key_quote"], "source": r["source"]})
        emit(conn, {"affect": items, "count": len(items)})
        return
    if act == "clear":
        node(conn, a.node)
        n = conn.execute("DELETE FROM affect WHERE node_id=?", (a.node,)).rowcount
        conn.commit()
        emit(conn, {"node": a.node, "cleared": n})
        return


# ------------------------------------------------------------------ 权重
def weight(node_row, now_epoch=None):
    """权重只由时间决定：w = 2^(-|Δt|/τ)，越新越大，未来对称收敛到 1.0。

    调用次数（refs）、访问热度（accessed_at）一律不进入这里 ——
    铁律："球的位置由时间决定，不由调用次数决定"。热度只用于触发压缩。
    """
    now_epoch = now_epoch or datetime.now().timestamp()
    return 0.5 ** (abs(now_epoch - node_row["t"]) / 86400.0 / TAU_DAYS)


# ------------------------------------------------------------------ 人格卡（SPEC §6）
def persona_path(args):
    """卡文件默认躺在库旁边（memtree.db.persona.md）：记忆和人格同生共死，别指望它们分头备份。"""
    p = getattr(args, "persona_file", None) or (db_path(args) + ".persona.md")
    return os.path.abspath(p)


def persona_load(args):
    """读卡。空槽保留标题、未知标题与空行一律忽略：手改坏一行不许把整张卡读崩。"""
    slots = {k: [] for k in PERSONA_SLOTS}
    try:
        with open(persona_path(args), "r", encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return slots
    cur = None
    for line in raw.splitlines():
        s = line.strip()
        if s in PERSONA_TITLE_TO_SLOT:
            cur = PERSONA_TITLE_TO_SLOT[s]
            continue
        if s.startswith("##"):
            cur = None                  # 未知段：其下内容不属于任何槽，宁可丢掉也不许乱归
            continue
        if cur and s.startswith("- "):
            v = s[2:].strip()
            if v and v not in slots[cur]:
                slots[cur].append(v)
    return slots


def persona_text(slots):
    out = []
    for k in PERSONA_SLOTS:
        out.append(PERSONA_TITLES[k])
        out += [f"- {x}" for x in slots[k]]
    return "\n".join(out) + "\n"


def persona_tokens(slots):
    # 空卡算 0：三段标题是格式，不是人格内容 —— 空卡不该在预算里占 14 token。
    return est_tokens(persona_text(slots)) if any(slots[k] for k in PERSONA_SLOTS) else 0


def persona_slot_tokens(entries):
    return est_tokens("\n".join(f"- {x}" for x in entries)) if entries else 0


def persona_save(args, slots):
    """原子写：同目录临时文件 + os.replace。半张卡比旧卡更糟 —— 人格没有回滚。"""
    path = persona_path(args)
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d or ".", prefix=".persona-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(persona_text(slots))
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def persona_log(conn, slot, op, old=None, new=None, reason=None, t=None):
    conn.execute(
        "INSERT INTO persona_log(t,slot,op,old,new,reason) VALUES(?,?,?,?,?,?)",
        (t if t is not None else datetime.now().timestamp(), slot, op, old, new, reason))


def persona_last_write(conn):
    """(slot, 条目) → (最后写入时刻, log id)。挤出次序只按这个，不按卡文件行序。"""
    last = {}
    for r in conn.execute("SELECT id,t,slot,new FROM persona_log WHERE op='add' AND new IS NOT NULL"):
        last[(r["slot"], r["new"])] = (float(r["t"]), r["id"])
    return last


def persona_replay(conn, t_ref):
    """--at：从空卡正向重放 t<=T 的记录。历史卡只能这样重建 —— 卡文件里只有"现在"。"""
    slots = {k: [] for k in PERSONA_SLOTS}
    for r in conn.execute("SELECT * FROM persona_log WHERE t<=? ORDER BY t, id", (t_ref,)):
        s = r["slot"]
        if s not in slots:
            continue
        if r["op"] == "add":
            if r["new"] and r["new"] not in slots[s]:
                slots[s].append(r["new"])
        elif r["old"] in slots[s]:       # del / evict：从那一刻起不在卡上
            slots[s].remove(r["old"])
    return slots


def cmd_persona(conn, a):
    act = a.action
    slots = persona_load(a)

    if act == "show":
        if a.at:
            slots = persona_replay(conn, parse_ts(a.at).timestamp())
        empty = not any(slots[k] for k in PERSONA_SLOTS)
        if a.json:
            tok = persona_slot_tokens(slots["hard"]), persona_slot_tokens(slots["soft"]), persona_slot_tokens(slots["var"])
            obj = {"slots": {k: list(slots[k]) for k in PERSONA_SLOTS},
                   "est_tokens": persona_tokens(slots),
                   "total_budget": PERSONA_TOTAL_BUDGET,
                   "slot_budgets": dict(PERSONA_SLOT_BUDGET),
                   "path": persona_path(a)}
            if a.at:
                obj["as_of"] = now_iso(parse_ts(a.at).astimezone())
            emit(conn, obj)
        else:
            print("(卡为空)" if empty else persona_text(slots).rstrip("\n"))
        return

    if act == "set":
        text = " ".join((a.text or "").split())      # 卡格式是一行一条：正文里的换行压成空格
        if not text:
            print("[memtree] 人格条目不能为空", file=sys.stderr)
            sys.exit(2)
        slot = a.slot
        if text in slots[slot]:                      # 幂等：不写文件、不写日志
            emit(conn, {"changed": False, "note": "已存在，未改动"})
            return
        if slot == "hard" and not a.force:
            print("[memtree] 硬槽改动需要 --force（防人格漂移）", file=sys.stderr)
            sys.exit(2)
        t_now = datetime.now().timestamp()
        last = persona_last_write(conn)
        cand = {k: list(slots[k]) for k in PERSONA_SLOTS}
        cand[slot].append(text)
        evicted = []
        # 硬槽不许挤：它是人格护栏，超了就是这次写入错了，不是别人的位置该让开。
        while slot != "hard" and persona_slot_tokens(cand[slot]) > PERSONA_SLOT_BUDGET[slot]:
            others = [x for x in cand[slot] if x != text]
            if not others:
                break
            others.sort(key=lambda x: last.get((slot, x), (0.0, 0)))
            victim = others[0]                       # 最旧优先（同刻按 log id 升序）
            cand[slot].remove(victim)
            evicted.append(victim)
        if persona_slot_tokens(cand[slot]) > PERSONA_SLOT_BUDGET[slot]:
            print(f"[memtree] 槽预算超限：需要 {persona_slot_tokens(cand[slot])} token，"
                  f"上限 {PERSONA_SLOT_BUDGET[slot]}", file=sys.stderr)
            sys.exit(2)
        tok = {k: persona_slot_tokens(cand[k]) for k in PERSONA_SLOTS}
        total = persona_tokens(cand)
        if total > PERSONA_TOTAL_BUDGET:             # 三槽各有预算，整卡还有一条总闸
            print(f"[memtree] 总预算超限：需要 {total} token，上限 {PERSONA_TOTAL_BUDGET}"
                  f"（硬 {tok['hard']} / 软 {tok['soft']} / 可变 {tok['var']}）", file=sys.stderr)
            sys.exit(2)
        persona_save(a, cand)                        # 先落卡文件，再记日志：卡是"现在"，日志是"改过什么"
        for v in evicted:
            persona_log(conn, slot, "evict", v, None, a.reason or "超预算挤出", t_now)
        persona_log(conn, slot, "add", None, text, a.reason, t_now)
        conn.commit()
        emit(conn, {"changed": True, "slot": slot, "slot_tokens": tok[slot],
                    "total_tokens": total, "evicted": evicted})
        return

    if act == "drop":
        text = " ".join((a.text or "").split())
        slot = a.slot
        if text not in slots[slot]:             # 幂等优先：no-op 不该因为缺 --force 变成报错
            emit(conn, {"changed": False, "note": "不存在，未改动"})
            return
        # 契约 J11：防漂移不能只锁 set —— 一把 drop 就能把硬锚点删干净，等于把锁装在门上、
        # 窗户敞着。判据与文案和 set 完全一致。
        if slot == "hard" and not a.force:
            print("[memtree] 硬槽改动需要 --force（防人格漂移）", file=sys.stderr)
            sys.exit(2)
        cand = {k: list(slots[k]) for k in PERSONA_SLOTS}
        cand[slot] = [x for x in slots[slot] if x != text]
        persona_save(a, cand)
        persona_log(conn, slot, "del", text, None, a.reason)
        conn.commit()
        emit(conn, {"changed": True, "slot": slot, "dropped": text,
                    "slot_tokens": persona_slot_tokens(cand[slot]),
                    "total_tokens": persona_tokens(cand), "evicted": []})
        return

    if act == "log":
        rows = conn.execute("SELECT * FROM persona_log ORDER BY t DESC, id DESC LIMIT ?",
                            (a.limit,)).fetchall()
        if a.json:
            emit(conn, [{"id": r["id"], "t": now_iso(datetime.fromtimestamp(r["t"]).astimezone()),
                         "slot": r["slot"], "op": r["op"], "old": r["old"],
                         "new": r["new"], "reason": r["reason"]} for r in rows])
        else:
            for r in rows:
                arrow = f"{r['old'] or '-'}→{r['new'] or '-'}"
                print(f"{r['id']:>4} {now_iso(datetime.fromtimestamp(r['t']).astimezone())} "
                      f"{r['slot']:<4} {r['op']:<5} {arrow}  {r['reason'] or ''}")
            if not rows:
                print("(无人格改动记录)")
        return

    print(f"[memtree] 未知 persona 动作：{act}", file=sys.stderr)
    sys.exit(2)


# ------------------------------------------------------------------ 写入
def _put_blob(conn, text):
    a = addr_of(text)
    conn.execute(
        "INSERT OR IGNORE INTO blobs(addr,content,nbytes,hot,created_at) VALUES(?,?,?,1,?)",
        (a, text, len(text.encode("utf-8")), now_iso()),
    )
    return a


def cmd_commit(conn, a):
    bname = a.branch or head_branch(conn)
    br = get_branch(conn, bname)
    parent = a.parent if a.parent is not None else br["head_id"]
    ts = a.ts or now_iso()
    t_epoch = parse_ts(ts).timestamp()
    ntype = a.type
    scope = a.scope or ("global" if ntype in ("fact", "pref", ANCHOR) else "branch")
    subject = a.subject
    outcome = _range(a.outcome, -1.0, 1.0, "--outcome")
    refs = int(a.refs or 0)
    if refs < 0:
        sys.exit(f"[memtree] --refs 不能为负：{refs}")
    pinned = 1 if a.pinned else 0
    # 事件不是自由命名，是聚合键（SPEC §2.2）：长句当事件名会让聚合层退化成第二个 subject。
    ev = re.sub(r"\s+", "_", (a.event or "").strip())
    if ev and len(ev) > 24:
        sys.exit(f"[memtree] --event 太长（{len(ev)}>24）：事件是聚合节点，请用短标签（如 换工作/搬家）")
    # 重要度只决定「老了之后进冷区还是归档区」，不参与排序 —— 排序永远由时间说话。
    imp = 0.5 if a.importance is None else _range(a.importance, 0.0, 1.0, "--importance")

    addr = _put_blob(conn, a.content)
    sem = text_vec(a.content)

    cur = conn.execute(
        """INSERT INTO nodes(t,outcome,subject,addr,v_text,type,scope,factor,refs,pinned,
                             zone,importance,event,status,branch,parent_id,meta,ts_iso,source_type)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?, 'active', ?,?,?,?,?)""",
        (t_epoch, outcome, subject, addr, pack_real(sem),
         ntype, scope, a.factor, refs, pinned, "hot", imp, ev or None, bname, parent, a.meta, ts,
         getattr(a, "source", None) or "stated"),
    )
    nid = cur.lastrowid

    decision, rival = "new", None
    if ntype in STATEFUL and subject and not a.no_supersede:
        group = [r for r in conn.execute(
            """SELECT * FROM nodes WHERE subject=? AND type IN ('fact','pref','decision')
               AND scope=? AND (scope='global' OR branch=?) AND status!='archived'""",
            (subject, scope, bname))]
        if len(group) > 1:
            # 同类事件里，时间权重最大的那条为现状（越新越大；t 相同则 id 大者胜）
            win = max(group, key=lambda r: (r["t"], r["id"]))
            losers = [r for r in group if r["id"] != win["id"]]
            loser = max(losers, key=lambda r: r["t"])
            loser_text = content_of(conn, loser["addr"])          # 先读，后转冷
            for r in losers:
                # gone_at = 覆盖者自身的 t：回溯要回答「T 那一刻这条还是不是现状」，
                # 只有记下覆盖发生的时刻才算得出来（当前 status 只知道结果，不知道时刻）。
                conn.execute("""UPDATE nodes SET status='superseded', superseded_by=?, gone_at=?
                                WHERE id=?""", (win["id"], win["t"], r["id"]))
                _cold_blob(conn, r["addr"])
            decision = "supersede" if win["id"] == nid else "kept"
            rival = {"id": loser["id"], "w_lost": round(weight(loser), 3),
                     "w_win": round(weight(win), 3)}
            if win["id"] == nid:
                fac = a.factor or f"曾:{clip(loser_text, 14)}@{short_date(loser['ts_iso'])}"
                conn.execute("UPDATE nodes SET factor=?, supersedes=? WHERE id=?",
                             (fac, loser["id"], nid))

    anchored = None
    if ntype == ANCHOR and subject and not a.no_supersede:
        # 锚点之间按时间覆盖（人格更新本来就要留痕），但与 fact/pref/decision 分组隔离：
        # 身份不该被一句随手记下的偏好顶掉。
        for r in conn.execute(
            """SELECT * FROM nodes WHERE subject=? AND type=? AND status='active' AND id!=?
               ORDER BY t DESC, id DESC""", (subject, ANCHOR, nid)):
            conn.execute("""UPDATE nodes SET status='superseded', superseded_by=?, gone_at=?
                            WHERE id=?""", (nid, t_epoch, r["id"]))
            _cold_blob(conn, r["addr"])
        decision = "anchor-replace"
    elif ntype in STATEFUL and subject:
        anc = conn.execute(
            """SELECT id FROM nodes WHERE subject=? AND type=? AND status='active'
               ORDER BY t DESC, id DESC LIMIT 1""", (subject, ANCHOR)).fetchone()
        if anc:
            anchored = anc["id"]        # 现状可以变，锚点不动；由 context 显示张力

    conn.execute("UPDATE branches SET head_id=? WHERE name=?", (nid, bname))
    conn.commit()
    if a.quiet:
        print(nid)
    else:
        out = {"id": nid, "branch": bname, "addr": addr, "type": ntype,
               "w": round(weight(node(conn, nid), datetime.now().timestamp()), 3),
               "decision": decision, "rival": rival}
        if pinned:
            out["pinned"] = True
        if anchored:
            out["anchored_by"] = anchored
        emit(conn, out)


def cmd_pin(conn, a):
    """保护位：不压缩、不硬删、不裁剪（§5.4 保护位机制）。"""
    r = node(conn, a.id)
    if (r["zone"] or "hot") == "purged":
        sys.exit(f"[memtree] #{a.id} 正文已永久删除，保护位无意义")
    if (r["zone"] or "hot") == "tombstone":
        sys.exit(f"[memtree] #{a.id} 在墓碑区：墓碑区节点没有保护位可用，"
                 f"请先 purge --restore {a.id}")
    conn.execute("UPDATE nodes SET pinned=? WHERE id=?", (0 if a.off else 1, a.id))
    conn.commit()
    emit(conn, {"id": a.id, "pinned": 0 if a.off else 1})


# ------------------------------------------------------------------ 采样 → 结算（动态因子的第二职责）
SIGNAL_TYPES = ("user_confirm", "correction", "emotional_peak", "repeat_mention")
EMOTIONAL_GATE = 0.7        # 情绪强度过此线才算情感锚点


def cmd_signal(conn, a):
    """记一条采样信号。只入队、不做决策 —— 决策全部留给 settle。

    这是动态因子的另一半：访问本身不改变任何保留时长，
    它只是往采样队列里放一条证据（SPEC §4.1「按后续索引去安排重要性」）。
    """
    node(conn, a.node)
    if a.type not in SIGNAL_TYPES:
        sys.exit(f"[memtree] 未知信号类型: {a.type}（可选 {', '.join(SIGNAL_TYPES)}）")
    tags = normalize_affect_tags(a.tags) if getattr(a, "tags", None) else []
    if tags and a.type != "emotional_peak":
        sys.exit("[memtree] 只有 emotional_peak 信号可以带 --tags")
    inten = _range(a.intensity, 0.0, 1.0, "--intensity") if a.intensity is not None else 0.0
    val = _range(a.valence, -1.0, 1.0, "--valence") if getattr(a, "valence", None) is not None else 0.0
    conn.execute("""INSERT INTO signals(node_id,type,intensity,quote,emotion_tags,valence,at,settled)
                    VALUES(?,?,?,?,?,?,?,0)""",
                 (a.node, a.type, inten, a.quote,
                  json.dumps(tags, ensure_ascii=False) if tags else None, val, now_iso()))
    conn.execute("UPDATE nodes SET accessed_at=? WHERE id=?",
                 (datetime.now().timestamp(), a.node))
    conn.commit()
    pend = conn.execute("SELECT COUNT(*) c FROM signals WHERE node_id=? AND settled=0",
                        (a.node,)).fetchone()["c"]
    emit(conn, {"node": a.node, "signal": a.type, "pending": pend,
                "tags": tags, "intensity": inten, "valence": val})


def _judge(conn, nid):
    """规则判定：signals → label。不调 LLM —— 四个信号都可判定。"""
    rows = conn.execute("SELECT type, intensity FROM signals WHERE node_id=? AND settled=0",
                        (nid,)).fetchall()
    if not rows:
        return None, "无信号"
    types = {r["type"] for r in rows}
    peak = max([float(r["intensity"] or 0) for r in rows if r["type"] == "emotional_peak"] or [0.0])
    r = conn.execute("SELECT source_type FROM nodes WHERE id=?", (nid,)).fetchone()
    src = (r["source_type"] if r and r["source_type"] else "stated")
    if "user_confirm" in types:
        return "anchor", "用户显式确认"
    if "correction" in types:
        return "anchor", "用户纠正过这条（说明重要）"
    if peak >= EMOTIONAL_GATE and src == "stated":
        return "emotional", f"情绪峰值 intensity={peak:.2f}"
    if "emotional_peak" in types and src == "roleplay":
        return None, "角色扮演内容，不进情感锚点（防虚构污染）"
    if "repeat_mention" in types or peak > 0:
        return "noise", "仅重复提及，未达情绪/确认阈值"
    return None, "未达阈值"


def cmd_settle(conn, a):
    """日终结算：把未结算信号一次性转成 label，然后清空。

    这是"访问可以影响保留"的唯一入口 —— 一次性、离散、留审计。
    结算之后保护位就与热度彻底脱钩：heat_of 再怎么变，pinned 不动。
    """
    ids = [r["node_id"] for r in conn.execute(
        "SELECT DISTINCT node_id FROM signals WHERE settled=0")]
    changed, affect_written = [], []
    for nid in ids:
        row = conn.execute("SELECT id,label,pinned,source_type FROM nodes WHERE id=?",
                           (nid,)).fetchone()
        if not row:
            conn.execute("UPDATE signals SET settled=1 WHERE node_id=?", (nid,))
            continue
        src = row["source_type"] or "stated"
        # 情感观察先落结构化表，再结算 label：label 只回答「是不是情感锚点」，
        # affect 才保存标签、强度、效价和原话，二者不是同一层信息。
        srows = conn.execute(
            """SELECT type,intensity,quote,emotion_tags,valence FROM signals
               WHERE node_id=? AND settled=0 AND type='emotional_peak'
               ORDER BY id""", (nid,)).fetchall()
        if srows and src != "roleplay":
            tags = set()
            for s in srows:
                for t in affect_parse_tags(s["emotion_tags"]):
                    tags.add(t)
            peak = max(float(s["intensity"] or 0.0) for s in srows)
            best = max(srows, key=lambda s: float(s["intensity"] or 0.0))
            vals = [float(s["valence"] or 0.0) for s in srows]
            affect_add(conn, nid, sorted(tags) if tags else ["unspecified"], peak,
                       sum(vals) / len(vals), best["quote"], src)
            affect_written.append(nid)
        label, reason = _judge(conn, nid)
        old_pin, old_label = int(row["pinned"] or 0), row["label"]
        new_pin = old_pin
        if label in ("anchor", "emotional"):
            new_pin = 1          # 复用保护位：不压缩、不硬删、不裁剪
        if label:
            conn.execute("UPDATE nodes SET label=?, pinned=? WHERE id=?", (label, new_pin, nid))
            sig = ",".join(sorted({x["type"] for x in conn.execute(
                "SELECT type FROM signals WHERE node_id=? AND settled=0", (nid,))}))
            conn.execute(
                """INSERT INTO settle_log(node_id,signal_types,old_pinned,new_pinned,
                                          old_label,new_label,reason,at)
                   VALUES(?,?,?,?,?,?,?,?)""",
                (nid, sig, old_pin, new_pin, old_label, label, reason, now_iso()))
            changed.append({"node": nid, "label": label, "pinned": new_pin, "reason": reason})
        conn.execute("UPDATE signals SET settled=1 WHERE node_id=? AND settled=0", (nid,))
    conn.commit()
    if a.json:
        emit(conn, {"scanned": len(ids), "changed": changed,
                    "affect_written": affect_written})
    else:
        if not changed:
            print(f"[settle] 扫描 {len(ids)} 条，无一条达阈值")
        for c in changed:
            print(f"#{c['node']:<4} → {c['label']:<9} pinned={c['pinned']}  {c['reason']}")
    return changed


def cmd_label(conn, a):
    """手动打标签。与 settle 同一条写入路径，同样留审计。"""
    row = conn.execute("SELECT id,label,pinned FROM nodes WHERE id=?", (a.node,)).fetchone()
    if not row:
        sys.exit(f"[memtree] 节点不存在: #{a.node}")
    lab = None if a.value in ("clear", "none", "null") else a.value
    if lab not in (None, "anchor", "emotional", "noise"):
        sys.exit("[memtree] label 只能是 anchor | emotional | noise | clear")
    old_pin, old_label = int(row["pinned"] or 0), row["label"]
    new_pin = 1 if lab in ("anchor", "emotional") else (0 if lab == "noise" else old_pin)
    conn.execute("UPDATE nodes SET label=?, pinned=? WHERE id=?", (lab, new_pin, a.node))
    conn.execute(
        """INSERT INTO settle_log(node_id,signal_types,old_pinned,new_pinned,
                                  old_label,new_label,reason,at)
           VALUES(?,?,?,?,?,?,?,?)""",
        (a.node, "manual", old_pin, new_pin, old_label, lab, a.reason or "手动标注", now_iso()))
    conn.commit()
    emit(conn, {"node": a.node, "label": lab, "pinned": new_pin})


def cmd_reinforce(conn, a):
    r = node(conn, a.id)
    conn.execute("UPDATE nodes SET refs=refs+? WHERE id=?", (a.times, a.id))
    r2 = node(conn, a.id)
    if r["status"] == "competing" and a.resolve:
        conn.execute("UPDATE nodes SET status='active' WHERE id=?", (a.id,))
        for x in conn.execute("SELECT id FROM nodes WHERE subject=? AND status='competing' AND id!=?",
                              (r["subject"], a.id)):
            conn.execute("UPDATE nodes SET status='superseded', superseded_by=? WHERE id=?", (a.id, x["id"]))
    conn.commit()
    emit(conn, {"id": a.id, "refs": r2["refs"], "w": round(weight(r2, datetime.now().timestamp()), 3),
                "status": node(conn, a.id)["status"]})


def cmd_branch(conn, a):
    if conn.execute("SELECT 1 FROM branches WHERE name=?", (a.name,)).fetchone() and not a.force:
        sys.exit(f"[memtree] 分支已存在: {a.name}（--force 覆盖 head）")
    src_name = a.src or head_branch(conn)
    src = get_branch(conn, src_name)
    fork = a.var_from if a.var_from is not None else src["head_id"]
    conn.execute(
        """INSERT INTO branches(name,fork_node,head_id,status,created_at) VALUES(?,?,?,'open',?)
           ON CONFLICT(name) DO UPDATE SET fork_node=excluded.fork_node, head_id=excluded.head_id, status='open'""",
        (a.name, fork, fork, now_iso()))
    conn.commit()
    emit(conn, {"branch": a.name, "fork_from": fork, "parent_branch": src_name})


def cmd_checkout(conn, a):
    get_branch(conn, a.name)
    if a.at is not None:
        conn.execute("UPDATE branches SET head_id=? WHERE name=?", (a.at, a.name))
    conn.execute("INSERT OR REPLACE INTO kv(k,v) VALUES('head',?)", (a.name,))
    conn.commit()
    emit(conn, {"head": a.name,
                "at": conn.execute("SELECT head_id FROM branches WHERE name=?", (a.name,)).fetchone()["head_id"]})


def cmd_merge(conn, a):
    br = get_branch(conn, a.name)
    target = get_branch(conn, a.into)
    if br["name"] == target["name"]:
        sys.exit("[memtree] 不能合并到自己")
    text = a.summary or f"合并分支 {a.name}"
    addr = _put_blob(conn, text)
    t_e = datetime.now().timestamp()
    cur = conn.execute(
        """INSERT INTO nodes(t,outcome,subject,addr,v_text,type,scope,factor,
                             status,branch,parent_id,meta,ts_iso)
           VALUES(?,0,?,?,?,'merge','global',?, 'active',?,?,?,?)""",
        (t_e, f"merge:{a.name}", addr, pack_real(text_vec(text)),
         a.factor or f"→{a.name}已并入", target["name"], target["head_id"],
         json.dumps({"merged_branch": a.name}, ensure_ascii=False), now_iso()))
    nid = cur.lastrowid
    conn.execute("UPDATE branches SET head_id=? WHERE name=?", (nid, target["name"]))
    conn.execute("UPDATE branches SET status='merged', merged_into=?, merged_at=? WHERE name=?",
                 (target["name"], now_iso(), a.name))
    # 归档＝离开现状：gone_at 记归档发生的时刻（回滚/回溯时要知道"当时它还活着"）
    conn.execute("""UPDATE nodes SET status='archived', gone_at=?
                    WHERE branch=? AND status IN ('active','competing')""", (t_e, a.name))
    for r in conn.execute("SELECT addr FROM nodes WHERE branch=? AND status='archived'", (a.name,)):
        _cold_blob(conn, r["addr"])
    conn.commit()
    emit(conn, {"merge_node": nid, "branch": a.name, "into": a.into, "archived": True})


# ------------------------------------------------------------------ 读取
def _rows(conn, sql="SELECT * FROM nodes", params=()):
    return sorted(conn.execute(sql, params), key=lambda r: (r["t"], r["id"]))


def _w(conn, rows, now_e):
    return {r["id"]: weight(r, now_e) for r in rows}


def cmd_context(conn, a):
    branch = a.branch or head_branch(conn)
    now_e = datetime.now().timestamp()
    ref = datetime.now().astimezone()
    anchors, facts, branches, events = [], [], [], []
    n_future = 0        # 还没发生的条目数（t > now）：不参与现状判定，但要明说

    # 硬锚点（SPEC §6.3）：身份/关系里程碑/安全约束。独立成段、永不裁剪，
    # 也不与现状混排 —— 「最近的状态」定义我现在是谁，「锚点」定义我始终是谁。
    for r in _rows(conn, """SELECT * FROM nodes WHERE status='active' AND type=?
                            AND (scope='global' OR branch=?)
                            AND COALESCE(zone,'hot') NOT IN ('tombstone','purged')""",
                   (ANCHOR, branch)):
        if float(r["t"] or 0.0) > now_e:      # 未来的锚点也还没发生，不进 ⚓
            n_future += 1
            continue
        anchors.append(f"⚓ {r['subject'] or '锚点'}: "
                       f"{clip(content_of(conn, r['addr'], True), a.width)}")

    stateful = [r for r in _rows(conn, """SELECT * FROM nodes WHERE status IN ('active','competing')
                                          AND type IN ('fact','pref','decision')
                                          AND (scope='global' OR branch=?)
                                          AND COALESCE(zone,'hot') NOT IN ('tombstone','purged')""",
                                 (branch,))]
    # 未来条目（t > now）不是现状：它们还没发生，既不许占 ■现状 的位，
    # 也不许把真实现状挤成「已废弃，禁止当作现状」（审计实证：一条 2027 的计划
    # 直接顶掉了当下的真实状态）。单独给一段 ⏳，同样遵守"隐藏必须说出来"。
    _fut = [r for r in stateful if float(r["t"] or 0.0) > now_e]
    if _fut:
        n_future += len(_fut)
        _fut_ids = {r["id"] for r in _fut}
        stateful = [r for r in stateful if r["id"] not in _fut_ids]
    # 默认只加载热区与温区（SPEC §8：默认少量预取，冷/归档按需）。
    # 保护位与锚点是例外 —— 重要但低频的记忆永远在。隐藏了必须说出来，否则就是静默丢状态。
    _hid_ids = {r["id"] for r in stateful
                if (r["zone"] or "hot") not in ("hot", "warm") and not r["pinned"]
                and r["label"] != "anchor"}
    # 墓碑区单算：它和冷/归档不是一回事 —— 前者是「已受理删除」，后者是「还在库里只是低频」
    # 墓碑要按全类型数，不能只数 fact/pref/decision：一条被删掉的 event 同样不许静默消失
    _tomb_hidden = conn.execute(
        "SELECT COUNT(*) c FROM nodes WHERE zone='tombstone' AND (scope='global' OR branch=?)",
        (branch,)).fetchone()["c"]
    # 冷/归档计数只减掉「同属现状类型且被判墓碑」的那些：墓碑全类型计数更大，
    # 直接相减会算出 -1（一条被删的 event 不在 stateful 里，却进了 _tomb_hidden）
    _zone_hidden = len(_hid_ids) - len({r["id"] for r in stateful
                                        if (r["zone"] or "hot") == "tombstone"} & _hid_ids)
    stateful = [r for r in stateful if r["id"] not in _hid_ids]
    # 未来赢家不许压掉当下的现状（审计实证：一条 2030 的计划把 2025 的真实状态顶成
    # 「已废弃，禁止当作现状」）。计划还没发生，那它覆盖掉的那条 —— 只要「离开现状的
    # 时刻」(gone_at) 还在未来 —— 此刻依然是现状，按 gone_at 补回来。
    _back_ids = set()
    _best_back = {}
    for r in conn.execute(
            """SELECT * FROM nodes WHERE status IN ('superseded','archived')
                 AND gone_at IS NOT NULL AND gone_at > ?
                 AND type IN ('fact','pref','decision')
                 AND (scope='global' OR branch=?)""", (now_e, branch)).fetchall():
        if r["id"] in _hid_ids:
            continue
        k = r["subject"] or f"#{r['id']}"
        if k not in _best_back or (r["t"], r["id"]) > (_best_back[k]["t"], _best_back[k]["id"]):
            _best_back[k] = r
    if _best_back:
        _have = {r["subject"] or f"#{r['id']}" for r in stateful}
        for k, r in _best_back.items():
            if k in _have:          # 这个 subject 已经有真实现状，不必回溯
                continue
            stateful.append(r)
            _back_ids.add(r["id"])
    wmap = _w(conn, stateful, now_e)
    anchored_sub = {x["subject"] for x in conn.execute(
        "SELECT subject,zone FROM nodes WHERE type=? AND status='active'", (ANCHOR,))
        if x["subject"] and (x["zone"] or "hot") not in HIDDEN_ZONES}

    def mark(line, r):
        # ★钉=保护位，永不被裁剪；⚑=该 subject 有锚点，现状与锚点并存要看得见
        if r["pinned"]:
            line += "  ★钉"
        if (r["subject"] or "") in anchored_sub:
            line += "  ⚑锚点未变"
        if r["event"]:                      # 事件标签：这条现状属于时间轴上的哪一节
            line += f"  ⟦{r['event']}⟧"
        if (r["zone"] or "hot") == "cold":   # 冷区（保护区）：还在，但不再占热区
            line += "  ❄冷"
        if r["id"] in _back_ids:             # 覆盖它的那条还在未来：它此刻仍是现状
            line += "  (覆盖者在未来·此刻仍是现状)"
        return line

    def _content(r):
        # 被未来计划顶下去的现状，正文已经被标冷（hot=0）—— 但它正是"此刻是什么"要
        # 回答的那句话，不许退化成「[地址 … 已转冷]」占位。
        return content_of(conn, r["addr"], r["id"] not in _back_ids)

    # 冲突聚合：同 subject 下 >1 条待定
    by_sub = {}
    for r in stateful:
        by_sub.setdefault(r["subject"] or f"#{r['id']}", []).append(r)
    # 按权重降序排 subject：预算不足时砍掉的应该是权重最低的，
    # 而不是 SQL 返回顺序里最后碰到的那条（原实现按 dict 插入顺序，等于随机砍）。
    ordered = sorted(by_sub.items(), key=lambda kv: -max(wmap[r["id"]] for r in kv[1]))

    for sub, rs in ordered:
        rs.sort(key=lambda r: -wmap[r["id"]])
        if len(rs) == 1 or rs[0]["status"] != "competing":
            r = rs[0]
            if len(rs) == 1:
                line = f"■ {sub}: {clip(_content(r), a.width)}"
                if r["factor"]:
                    line += f"  ({r['factor']})"
                facts.append(mark(line, r))
                continue
        if any(x["status"] == "competing" for x in rs):
            parts = " ⟷ ".join(f"{clip(content_of(conn, x['addr'], True), 16)}({wmap[x['id']]:.2f})" for x in rs[:3])
            facts.append(f"◆ {sub}: {parts} 冲突待定")
        else:
            r = rs[0]
            line = f"■ {sub}: {clip(_content(r), a.width)}"
            if r["factor"]:
                line += f"  ({r['factor']})"
            facts.append(line)

    for r in reversed(_rows(conn, """SELECT * FROM nodes WHERE status='active' AND type='hypothesis'
                                     AND branch=?
                                     AND COALESCE(zone,'hot') NOT IN ('tombstone','purged')""",
                            (branch,))):
        facts.append(f"◇ {r['subject'] or '假设'}: {clip(content_of(conn, r['addr'], True), a.width)}")

    # 事件轴（SPEC §2.2）：记忆挂在事件下，先看事件、再展开细节。
    # 跨期事件用时间区间表达 —— 同一件事聊了三次，是一个事件、三个时间点，不是三条无关记忆。
    evl = []
    _evrows = list(conn.execute(
        """SELECT event ev, MIN(t) t0, MAX(t) t1, COUNT(*) c FROM nodes
           WHERE event IS NOT NULL AND status IN ('active','competing')
             AND (scope='global' OR branch=?)
             AND COALESCE(zone,'hot') NOT IN ('tombstone','purged')
           GROUP BY event ORDER BY t1 DESC""", (branch,)))
    for e in _evrows[:8]:
        evl.append(f"▣ {e['ev']} {short_date(e['t0'], ref)}~{short_date(e['t1'], ref)} {e['c']}条")
    if len(_evrows) > 8:                    # 显式说出还有多少，绝不静默截断
        evl.append(f"▣ …还有 {len(_evrows) - 8} 个事件（recall --event <名> 查）")

    for b in conn.execute("SELECT * FROM branches WHERE status='open' AND name!=? ORDER BY created_at", (branch,)):
        h = conn.execute("SELECT * FROM nodes WHERE id=?", (b["head_id"],)).fetchone() if b["head_id"] else None
        tip = clip(content_of(conn, h["addr"], True), 30) if h else "(空)"
        branches.append(f"○ {b['name']}#{b['head_id'] or '-'} {tip}")

    # 墓碑区是「已受理删除」：连事件轴都不许出现，否则删除只删了 status、没删掉记忆
    ev = [r for r in _rows(conn, """SELECT * FROM nodes WHERE status='active'
                                    AND type IN ('event','merge','summary')""")
          if r["branch"] == branch and (r["zone"] or "hot") not in HIDDEN_ZONES]
    picked = ev[-a.recent:] if a.recent else []
    picked += [r for r in ev if r["type"] == "summary" and r["id"] not in {p["id"] for p in picked}][-2:]
    for r in sorted(picked, key=lambda r: (r["t"], r["id"]), reverse=True):
        events.append(f"· {short_date(r['t'], ref)} {clip(content_of(conn, r['addr'], True), a.width)}")

    n_all = conn.execute("SELECT COUNT(*) c FROM nodes").fetchone()["c"]
    n_cold = conn.execute("SELECT COUNT(*) c FROM nodes WHERE status!='active'").fetchone()["c"]
    head = conn.execute("SELECT head_id FROM branches WHERE name=?", (branch,)).fetchone()["head_id"]
    legend = ("※ ⚓锚点 ⚓人格 ■现状 ▣事件轴 ⟦事件名⟧ ❄冷 🪦墓碑 ★钉=保护位 ◇假设 ○分支(回顾点) ·事件"
              "  (曾:…@日期)=已废弃，禁止当作现状")
    head_line = (f"【记忆 {ref.strftime('%Y-%m-%d')} | {branch}#{head or '-'} "
                 f"| {n_all}节点·废{n_cold}】")
    n_fact_all, n_ev_all = len(facts), len(events)

    # 人格卡（SPEC §6）：整卡为空时一行都不出（输出与没有人格卡时逐字相同）。
    # 它排在锚点之前、加进 rebuild，因此自然计入 --budget，但永不被裁剪：
    # 人格不许因为这一次预算紧张而消失 —— "我是谁"不是可裁的上下文。
    _pslots = persona_load(a)
    persona_lines = [f"⚓人格·{PERSONA_LABELS[k]} " + "；".join(_pslots[k])
                     for k in PERSONA_SLOTS if _pslots[k]]

    def rebuild():
        return [head_line] + persona_lines + anchors + facts + evl + branches + events + legend.split("\n")

    def size():
        return sum(len(x) + 1 for x in rebuild())

    # 裁剪优先级：锚点 > 保护位 > 最近事件 > 普通现状 > 保底事件。
    # 事件是时间轴的骨节、fact 是状态：先保住最近的 keep_ev 条事件，再砍普通 fact，
    # 最后才动保底事件。原实现先砍 events 会把它砍光，上下文退化成静态事实、时间轴消失。
    keep_ev = min(max(a.recent, 0), len(events))
    while size() > a.budget and len(events) > keep_ev:
        events.pop()
    while size() > a.budget:
        cut = None
        for i in range(len(facts) - 1, 0, -1):
            if "★钉" not in facts[i]:      # 保护位永不裁剪
                cut = i
                break
        if cut is None:
            break
        facts.pop(cut)
    while size() > a.budget and len(events) > 0:
        events.pop()

    out = "\n".join(rebuild())
    # 静默丢状态是本项目最贵的 bug：模型看到 18 条就会笃定答「没记录过」。
    # 溢出必须说出来 —— 宁可超预算一行，也不能让 Agent 以为自己看到了全部。
    if _tomb_hidden:
        out += (f"\n🪦 墓碑区 {_tomb_hidden} 条已受理删除（冷却期内可撤回）"
                " —— 显式查：recall --zone tombstone / purge --list")
    if _zone_hidden:
        out += (f"\n❄ 冷区/归档 {_zone_hidden} 条未加载（保护位与锚点除外）"
                " —— 显式查：recall --zone cold 或 recall --zone archive")
    if n_future:
        out += (f"\n⏳ 未来 {n_future} 条尚未发生（不参与现状判定）"
                " —— 显式查：recall --at <该日期之后> 或 log --all")
    dropped = (n_fact_all - len(facts)) + (n_ev_all - len(events))
    if dropped:
        out += (f"\n⚠ 还有 {dropped} 条未展开"
                f"（现状 {n_fact_all - len(facts)} / 事件 {n_ev_all - len(events)}）"
                " —— 不要据此回答「没有记录」，用 recall 或 log --brief 查全")
    if a.json:
        emit(conn, {"text": out, "chars": len(out), "est_tokens": est_tokens(out),
                    "shown": {"anchors": len(anchors), "facts": len(facts), "events": len(events)},
                    "total": {"facts": n_fact_all, "events": n_ev_all, "future": n_future},
                    "persona": {"hard": list(_pslots["hard"]), "soft": list(_pslots["soft"]),
                                "var": list(_pslots["var"]),
                                "est_tokens": persona_tokens(_pslots)},
                    "dropped": dropped})
    else:
        print(out)
        if a.verbose:
            print(f"\n[chars={len(out)} est_tokens≈{est_tokens(out)} budget={a.budget} "
                  f"dropped={dropped}]", file=sys.stderr)


def cmd_recall(conn, a):
    """定位：Q = z_q ⊗ e_q，M = z_m ⊗ e_m，⟨Q,M⟩ = (t_q·t_m + r_q·r_m)·cos(e_q,e_m)。

    查询的时间是唯一值（此刻），t_q ≡ 1 —— 时间不做匹配，只做权重；
    不问结果时 r_q = 0，虚轴那项自动为 0，退化成"语义 × 新鲜度"。
    所以问"我喜欢吃什么"时，内积直接落到最新那条上。
    """
    q_text = a.query
    if a.at:
        _dt = parse_ts(a.at)
        if len(str(a.at).strip()) <= 10:      # 只给日期 → 视为"那天结束"，否则当天白天的事会被判为未来
            _dt = _dt.replace(hour=23, minute=59, second=59)
        t_ref = _dt.timestamp()
    else:
        t_ref = datetime.now().timestamp()
    r_ref = a.outcome if a.outcome is not None else 0.0
    e_q = text_vec(q_text)
    qtags = normalize_affect_tags(a.emotion) if getattr(a, "emotion", None) else []
    if getattr(a, "emotion", None) and not qtags:
        sys.exit("[memtree] --emotion 需要至少一个情感标签")
    emo_alpha = _range(getattr(a, "emotion_weight", 0.5), 0.0, 1.0, "--emotion-weight")
    amap = affect_map(conn) if qtags else {}
    pipeline = getattr(a, "pipeline", "legacy")
    expand_n = getattr(a, "expand", None)
    if expand_n is None:
        expand_n = max(a.top * 3, 20)
    if expand_n < 1:
        sys.exit("[memtree] --expand 必须 >= 1")
    p_in = conn.execute("SELECT COUNT(*) c FROM nodes").fetchone()["c"]
    p_valid = p_time = p_event = p_future = 0
    p_rej_valid = p_time_pruned = p_event_pruned = 0

    want = {"active", "competing"} if a.status == "auto" else \
           {"active", "competing", "superseded", "archived"} if a.status == "any" else {a.status}

    # 回溯到某个时刻：问的是「在 T 那一刻，库里的现状是什么」（SPEC §1：时间轴是主索引）。
    # 判据必须是「覆盖/归档发生的时刻」(gone_at)，不是节点自身 t，更不是当前 status ——
    # 只看当前 status 会让一条 8 月才被覆盖的记忆在 6 月的视角里凭空消失（审计实证的空手）。
    at_mode = a.at is not None
    cur_ids = set()
    n_at = n_not_yet = n_gone = n_unknown = 0
    # 契约 H：无 subject 的条目（事件）在 --at 下按 gone_at 判当时是否仍有效
    n_ev_active = n_ev_gone = 0
    if at_mode:
        best = {}
        for r in conn.execute("SELECT * FROM nodes"):
            if float(r["t"] or 0.0) > t_ref:              # T 那一刻还不存在
                n_not_yet += 1
                continue
            g = r["gone_at"]
            if g is None and r["status"] not in ("active", "competing"):
                # 老库没记「何时离开现状」，只记了当前 status → 按当前 status 处理，
                # 并在 as_of 统计里单列 unknown_timing：不确定的事不冒充结论。
                n_unknown += 1
                continue
            if g is not None and g <= t_ref:              # T 之前就已经被覆盖/归档
                n_gone += 1
                continue
            n_at += 1
            subj = r["subject"] or f"#{r['id']}"
            if subj not in best or (r["t"], r["id"]) > best[subj]:
                best[subj] = (r["t"], r["id"])
        cur_ids = {v[1] for v in best.values()}

    raw_hits = []
    _now_e = datetime.now().timestamp()
    for r in conn.execute("SELECT * FROM nodes"):
        # 契约 G2：T 早于条目 t 时同样不返回该条 —— t 还在未来的条目，在任何 --at 视角下
        # 都还没发生。只砍「真实未来」：--at 指向过去时，T 之后但已发生的条目仍要能检索
        # （结果维检索靠这个），否则回溯会把已经发生的事实一起藏起来。
        if at_mode and float(r["t"] or 0.0) > _now_e:
            if pipeline == "v2":
                p_future += 1
            p_rej_valid += 1
            continue
        if pipeline == "v2" and not at_mode and float(r["t"] or 0.0) > _now_e:
            # v2 把「真实未来」单列：它不占当前检索的 topN，也不装作已经发生。
            p_future += 1
            p_rej_valid += 1
            continue
        if at_mode and r["subject"]:
            # 现状类条目按「当时」判定：T 之后才发生的现状，在 T 那一刻还不存在
            if float(r["t"] or 0.0) > t_ref:
                p_rej_valid += 1
                continue
            is_cur = r["id"] in cur_ids
            if a.status == "auto" and not is_cur:
                p_rej_valid += 1
                continue
            if a.status == "superseded" and is_cur:
                p_rej_valid += 1
                continue
        elif at_mode and a.status == "auto":
            # 契约 H：无 subject 的条目（事件）没有「现状快照」可言，但它一样有
            # 「什么时候失效」—— gone_at 记的是归档发生的时刻。按当前 status 过滤
            # 会让「2024 年那条事件」在 2024 年的视角里消失，只因为它在 2026 年被压掉。
            # 判据：gone_at 为 NULL 或晚于 T → T 那一刻仍有效；否则那一刻已失效。
            _tomb = (r["zone"] or "hot") in HIDDEN_ZONES and not a.zone
            _g = r["gone_at"]
            if _g is not None and float(_g) <= t_ref:
                if not _tomb:
                    n_ev_gone += 1      # 那一刻已失效，被藏起来 —— 必须说出来
                p_rej_valid += 1
                continue
            if not _tomb:
                n_ev_active += 1
        elif r["status"] not in want:
            p_rej_valid += 1
            continue
        if a.branch and not (r["branch"] == a.branch or r["scope"] == "global"):
            p_rej_valid += 1
            continue
        if a.zone and (r["zone"] or "hot") not in [z.strip() for z in a.zone.split(",")]:
            p_rej_valid += 1
            continue
        # 墓碑与已抹正文终态默认检索不到：已受理/已完成删除的记忆
        # 不该在「我以前说过什么」里冒出来。
        if not a.zone and (r["zone"] or "hot") in HIDDEN_ZONES:
            p_rej_valid += 1
            continue
        p_valid += 1
        # 时间窗在事件过滤之前：先按 T 剪枝，再按事件标签剪枝，最后才算相似度。
        # 不带主体的事件不参与现状判定，所以不硬性过滤"未来"；v2 已在上方单列未来。
        if a.days is not None and (t_ref - r["t"]) / 86400.0 > a.days:
            p_time_pruned += 1
            continue
        p_time += 1
        if a.event and (r["event"] or "") != a.event:
            p_event_pruned += 1
            continue
        p_event += 1
        st = time_weight(r["t"], t_ref)                  # t_q·t_m，t_q≡1
        so = r_ref * float(r["outcome"] or 0.0)          # r_q·r_m，r_q 默认 0 → 休眠
        se = dot(e_q, unpack_real(r["v_text"]))          # cos(e_q, e_m)
        emo, _emo_row = affect_relevance(amap.get(r["id"], []), qtags)
        raw_hits.append((r, se, st, so, emo))
    # 情绪零命中必须降级，不许把全库分数腰斩：只有候选集里至少一条真的有
    # 相关情感观察时，α 才生效；否则退回纯时间权重，并明确告警。
    emotion_matched = sum(1 for _r, _se, _st, _so, emo in raw_hits if emo > 0) if qtags else 0
    emo_alpha_applied = emo_alpha if (qtags and emotion_matched > 0) else 0.0
    if qtags and emotion_matched == 0:
        print(f"[memtree] 情绪标签 {','.join(qtags)} 在本库零命中，本次未启用情绪权重。",
              file=sys.stderr)
    hits = []
    for r, se, st, so, emo in raw_hits:
        primary = ((1.0 - emo_alpha_applied) * st + emo_alpha_applied * emo) if qtags else st
        s = se * (primary + so) if a.mode == "and" else se * (0.5 + 0.5 * primary) + 0.3 * so
        hits.append((s, r, se, st, so, emo))
    hits.sort(key=lambda x: -x[0])
    # 语义完全不重合（se=0）时 Σ 也是 0：那不是命中，是噪声。
    # 打 5 条 Σ=+0.000 的假命中，比说"没查到"更贵 —— 它会诱导模型编出解释。
    # 噪声判据看「语义是否真的重合」：回溯视角下 Σ 会被时间权重压到接近 0，
    # 用 Σ 当门槛会把一条 4 年前、但确确实实是当时现状的记忆静默滤掉（审计实证的
    # --at 空手就是这么来的）。所以 --at 下按语义重合判噪声，不按 Σ。
    hits = [h for h in hits if (h[2] if at_mode else h[0]) > 1e-9]
    # 词面重合：随机投影词袋对"毫不相关"的两句话也会给出非零余弦，
    # 那不是命中而是噪声。重合为 0 的命中必须标注，否则模型会拿噪声当证据。
    qset = set(_terms(q_text))
    pre_rd, pipe_info = {}, None
    if pipeline == "v2":
        # 事件级逐级展开：先把「事件」当检索单元（无事件则单条为单元），
        # 只展开得分最高的前 N 个单元，再在成员内做混合相似度二次排序。
        # 这样正文只加载被展开的成员，不会为了排序把整库正文都读一遍。
        units = {}
        for h in hits:
            r = h[1]
            key = ("ev", r["event"]) if r["event"] else ("node", r["id"])
            units.setdefault(key, []).append(h)
        ranked_units = sorted(units.items(), key=lambda kv: -max(x[0] for x in kv[1]))
        chosen = ranked_units[:expand_n]
        skipped_units = ranked_units[expand_n:]
        units_skipped = len(skipped_units)
        members_dropped = sum(len(hs) for _k, hs in skipped_units)
        warn = (f"expand 上限丢弃 {members_dropped} 条（--expand 增大可纳入）"
                if members_dropped > 0 else None)
        expanded = [h for _k, hs in chosen for h in hs]
        for h in expanded:
            r = h[1]
            pre_rd[r["id"]] = readable(conn, r)
        reranked = []
        for s, r, se, st, so, emo in expanded:
            body = pre_rd[r["id"]][0]
            tset = set(_terms(body))
            ov = (len(qset & tset) / float(len(qset))) if qset else 0.0
            sim = 0.85 * se + 0.15 * ov
            primary = ((1.0 - emo_alpha_applied) * st + emo_alpha_applied * emo) if qtags else st
            s2 = sim * (primary + so) if a.mode == "and" else sim * (0.5 + 0.5 * primary) + 0.3 * so
            reranked.append((s2, r, se, st, so, emo))
        reranked.sort(key=lambda x: -x[0])
        top = reranked[: a.top]
        pipe_info = {
            "mode": "v2",
            "validity": {"in": p_in, "pruned": p_rej_valid,
                         "out": p_in - p_rej_valid, "future_hidden": p_future},
            "time_window": {"days": a.days, "in": p_valid,
                            "pruned": p_time_pruned, "out": p_time,
                            "anchor": "at" if at_mode else "now"},
            "event_filter": {"event": a.event, "in": p_time,
                             "pruned": p_event_pruned, "out": p_event},
            "similarity": {"coarse": "vector_cos", "hybrid": "0.85*cos+0.15*lexical",
                           "candidates": p_event, "kept": len(hits)},
            "ranking": {"time": round(1.0 - emo_alpha_applied if qtags else 1.0, 3),
                        "emotion": round(emo_alpha_applied if qtags else 0.0, 3),
                        "emotion_matched": emotion_matched,
                        "outcome": 1.0},
            "expand": {"units": len(units), "units_expanded": len(chosen),
                       "units_skipped": units_skipped,
                       "members_scored": len(expanded),
                       "members_dropped": members_dropped,
                       "bodies_loaded": len(pre_rd),
                       "warning": warn},
        }
    else:
        top = hits[: a.top]

    # 命中要给出的那段话（见 readable）：词面重合也用它算。
    # 正文已被抹掉、退到摘要的节点，若拿占位符去算重合，会误报
    # 「无词面重合·低置信」—— 那也是谎：明明有摘要可读。
    rd = {row["id"]: pre_rd.get(row["id"]) or readable(conn, row)
          for s, row, se, st, so, emo in top}

    def _ov(row):
        tset = set(_terms(rd[row["id"]][0]))
        return (len(qset & tset) / float(len(qset))) if qset else 0.0

    ovmap = {row["id"]: _ov(row) for s, row, se, st, so, emo in top}

    if top:
        # 访问热度（SPEC §4）：只记"距上次访问"，绝不累计调用次数 ——
        # 累计次数会让高频闲聊全变热，正是铁律二禁止的那种裁判。
        conn.executemany("UPDATE nodes SET accessed_at=? WHERE id=?",
                         [(datetime.now().timestamp(), h[1]["id"]) for h in top])
        conn.commit()
    if a.json:
        hits_out = []
        for s, r, se, st, so, emo in top:
            body, how = rd[r["id"]]
            hit = {
                "id": r["id"], "score": round(s, 3), "sem": round(se, 2), "time": round(st, 2),
                "out": round(so, 2),
                # --at 视角下报「当时」的 status：当时还是现状就是 active，
                # 当前 status 另放 status_now —— 两者并列才看得出覆盖发生在什么时候。
                "status": ("active" if at_mode and r["id"] in cur_ids else r["status"]),
                "status_now": r["status"],
                "subject": r["subject"], "event": r["event"], "zone": r["zone"],
                "addr": r["addr"],
                "overlap": round(ovmap[r["id"]], 2),
                "low_confidence": ovmap[r["id"]] == 0.0,
                # 命中必须能读回正文（G1）：冷库(hot=0)也直接解引用 —— 正文还在库里，
                # 「明明记过却检索不出来」是本项目最不该发生的事。
                # kind 说明给的是原文还是摘要/占位，摘要必带原文节点号（不许假装是原文）。
                "content": body,
                "content_kind": how["kind"],
                "cold": how["cold"],
                "summary_of": how.get("summary_of"),
                "summarized_into": how.get("summarized_into"),
                "content_cleared": bool(how.get("cleared")),
                "ts": r["ts_iso"]}
            if qtags:
                _e, _row = affect_relevance(amap.get(r["id"], []), qtags)
                hit["emotion"] = round(emo, 2)
                hit["affect"] = ({"tags": affect_parse_tags(_row["tags"]),
                                  "intensity": _row["intensity"], "valence": _row["valence"],
                                  "quote": _row["key_quote"], "source": _row["source"]}
                                 if _row else None)
            hits_out.append(hit)
        out = {"query": q_text, "t": a.at or now_iso(), "outcome": r_ref, "hits": hits_out}
        if qtags:
            out["emotion"] = {"tags": qtags, "matched": emotion_matched,
                              "alpha_applied": emo_alpha_applied}
            # 兼容旧字段：alpha 报请求值，实际是否生效看 emotion.alpha_applied。
            out["emotion_query"] = {"tags": qtags, "alpha": emo_alpha}
        if pipe_info:
            out["pipeline"] = pipe_info
        if at_mode:
            out["as_of"] = a.at
            out["as_of_stats"] = {"active": n_at, "not_yet": n_not_yet,
                                  "already_gone": n_gone, "unknown_timing": n_unknown,
                                  # 无 subject 条目的时点有效性单独计数（契约 H）：
                                  # 即使是 0 也出现，别让调用方分不清"没有"和"没算"
                                  "events_active": int(n_ev_active),
                                  "events_gone": int(n_ev_gone)}
            out["note"] = ("as_of 口径：按「覆盖/归档发生的时刻」(gone_at) 判定当时状态；"
                           "T 之后才发生的现状类条目不算当时现状；"
                           "gone_at 缺失的老数据按当前 status 处理并计入 unknown_timing")
        emit(conn, out)
        return
    def _gone_hint():
        # 隐藏必须说出来（契约 H ⑤）：那一刻已失效、因此没出现在结果里的事件条数。
        # 为 0 时一个字都不打（也不留空行）。
        if at_mode and n_ev_gone > 0:
            print(f"（另有 {n_ev_gone} 条事件在那一刻已失效）")

    if pipe_info:
        q = pipe_info
        print(f"[pipeline v2] 有效性 {q['validity']['in']}→{q['validity']['out']}"
              f" 时间窗 {q['time_window']['in']}→{q['time_window']['out']}"
              f" 事件 {q['event_filter']['in']}→{q['event_filter']['out']}"
              f" 展开单元 {q['expand']['units_expanded']}/{q['expand']['units']}"
              f" 未来隐藏 {q['validity']['future_hidden']}", file=sys.stderr)
        if q["expand"].get("warning"):
            print(f"[memtree] {q['expand']['warning']}", file=sys.stderr)
    if not top:
        print("(无命中) —— 记忆库里没有语义相关的条目，不要据此编造。"
              "若确定记过，换关键词或放宽 --days / --status any 再试")
        _gone_hint()
        return
    if top and all(v == 0.0 for v in ovmap.values()):
        print("(低置信) 没有任何词面重合 —— 下面的命中来自随机投影的噪声相似度，别当证据。")

    for s, r, se, st, so, emo in top:
        if at_mode:                                  # 回溯视角：以"当时"论现状
            if r["subject"]:
                is_cur = r["id"] in cur_ids
                flag = "「当时现状」" if is_cur else "「当时已过时」"
                glyph = GLYPH["active"] if is_cur else GLYPH["superseded"]
            else:
                # 契约 I：无 subject 的条目（事件）没有"现状"可言，给它打
                # 「当时已过时」是假信息。--at 下这类条目只说它自己的状态：
                # 不打「当时…」，也不打非回溯模式那套「…·不可当现状」后缀。
                flag = ""
                glyph = GLYPH.get(r["status"], "?")
        else:
            flag = "" if r["status"] == "active" else f"「{r['status']}·不可当现状」"
            glyph = GLYPH.get(r["status"], "?")
        body, how = rd[r["id"]]
        # 给的是摘要/占位/冷区都必须当场说出来（本项目原则：隐藏必须说出来）
        if how["kind"] == "摘要":
            ids = ",".join(f"#{i}" for i in (how.get("summary_of") or []))
            tag = f" ⟪摘要·原文{ids}⟫" if ids else " ⟪摘要⟫"
        elif how["kind"] == "占位":
            tag = " ⟪正文已清除·不可回溯⟫"
        elif how["cold"]:
            tag = " ❄冷·正文照读"
        else:
            tag = ""
        emo_tag = f" emo·{emo:.2f}" if qtags else ""
        print(f"{bar(s)} #{r['id']:<3} {glyph} {short_date(r['t'])} "
              f"t·{st:.2f} r·{so:+.2f} sem{se:+.2f}{emo_tag} Σ={s:+.3f} → "
              f"{clip(body, a.width)}{tag}"
              f"{' ⟦' + r['event'] + '⟧' if r['event'] else ''}"
              f"{' 「无词面重合·低置信」' if ovmap[r['id']] == 0.0 else ''} {flag}")
    _gone_hint()


def bar(s):
    n = max(1, min(5, int(round(s * 5))))
    return "▇" * n + "▁" * (5 - n)


def cmd_log(conn, a):
    rows = _rows(conn)
    if a.branch:
        rows = [r for r in rows if r["branch"] == a.branch]
    if not a.all:
        rows = [r for r in rows if r["status"] not in ("archived", "superseded")]
    rows = rows[: a.limit]
    now_e = datetime.now().timestamp()
    allbr = {r["id"]: r["branch"] for r in _rows(conn)}
    ref = datetime.now().astimezone()
    brief = getattr(a, "brief", False)
    for r in rows:
        if brief:
            # 精简模式：去掉地址、权重、分支与对齐空白。
            # 这些字段只在调试/校验时有用，Agent 读时间轴时是纯噪音（占一行 29%）。
            print(f"#{r['id']} {short_date(r['t'], ref)} {GLYPH.get(r['status'],'?')}"
                  f"{'🪦' if (r['zone'] or '') == 'tombstone' else ''} "
                  f"{clip(content_of(conn, r['addr'], True), a.width)}"
                  + (f" ({r['factor']})" if r["factor"] else ""))
            continue
        pb = allbr.get(r["parent_id"])
        fork = f"  ↳from {pb}" if pb and pb != r["branch"] else ""
        print(f"#{r['id']:<4} {r['ts_iso'][:16].replace('T',' ')} {GLYPH.get(r['status'],'?')}"
              f"{'🪦' if (r['zone'] or '') == 'tombstone' else ''} "
              f"{r['branch']:<9} w={weight(r, now_e):.2f} {r['addr']} {clip(content_of(conn, r['addr'], True), a.width)}"
              + (f"  ({r['factor']})" if r["factor"] else "") + fork)


def cmd_show(conn, a):
    r = node(conn, a.id)
    now_e = datetime.now().timestamp()
    b = conn.execute("SELECT * FROM blobs WHERE addr=?", (r["addr"],)).fetchone()
    print(f"#{r['id']}  {r['ts_iso']}  {GLYPH.get(r['status'])} {r['status']}")
    print(f"branch={r['branch']} parent={r['parent_id']} type={r['type']} scope={r['scope']}")
    print(f"分区: {r['zone'] or 'hot'}" + (f"  🪦冷却中({r['purge_reason'] or '无理由'})"
          if (r["zone"] or "") == "tombstone" else ""))
    print(f"三维: t={short_date(r['t'])}  outcome={r['outcome']:+.2f}  语义维={r['v_text'] and len(r['v_text'])//4}")
    print(f"权重: {weight(r, now_e):.3f}  (refs={r['refs']})")
    print(f"地址: {r['addr']}  正文: {'在热库' if b and b['hot']==1 else ('已转冷' if b else '已清除')}")
    print(f"content: {content_of(conn, r['addr'])}")
    if r["factor"]:
        print(f"factor : {r['factor']}")
    if r["supersedes"]:
        o = conn.execute("SELECT * FROM nodes WHERE id=?", (r["supersedes"],)).fetchone()
        if o:
            print(f"← 取代 #{o['id']}({short_date(o['t'])}) w={weight(o, now_e):.2f}: {clip(content_of(conn, o['addr']), 40)}")
    if r["superseded_by"]:
        n = conn.execute("SELECT * FROM nodes WHERE id=?", (r["superseded_by"],)).fetchone()
        if n:
            print(f"→ 被 #{n['id']}({short_date(n['t'])}) 取代")


def cmd_verify(conn, a):
    """地址自校验：地址 = sha256(正文)，取回时重算，任何篡改都验不过。"""
    r = conn.execute("SELECT * FROM blobs WHERE addr LIKE ?", (a.addr + "%",)).fetchall()
    if not r:
        emit(conn, {"addr": a.addr, "found": False, "note": "正文已清除，仅剩悬空地址"})
        return
    b = r[0]
    ok = addr_of(b["content"]) == b["addr"]
    emit(conn, {"addr": b["addr"], "found": True, "hot": b["hot"], "bytes": b["nbytes"],
                "sha256_ok": ok, "content": b["content"] if a.show else None})


def cmd_purge(conn, a):
    """两段式删除（SPEC §5.5）：先进墓碑区冷却，冷却期满才真删。

    旧实现一按就烧：地址还在、正文没了，不可恢复。删除是不可逆的决定，
    不可逆的决定必须留一段缓冲 —— 「手滑」和「确实要删」在这几天里会长得不一样。
    冷却期同时是撤回入口（--restore）；隐私/错误信息仍可 --now 立即删。
    """
    now_e = datetime.now().timestamp()
    # --now 是「立即真删」而不是「把本轮新进墓碑的删掉」。先把调用前就已在
    # 墓碑区的节点记下来，后面要单独计入 purged_existing。
    preexisting = (conn.execute(
        "SELECT id,addr FROM nodes WHERE zone='tombstone'").fetchall() if a.now else [])
    preexisting_ids = {r["id"] for r in preexisting}
    if a.gc:
        # 显式 GC：只回收「全库无人引用」的孤儿正文，只动 blobs 表，不删任何 nodes 行。
        # 不做自动触发 —— 回收是省空间的手段，删除是不可逆的决定，不可逆的事必须有人按。
        orph = orphan_addrs(conn)
        total = sum(r["nbytes"] or 0 for r in orph)
        out = {"gc_removed": 0, "bytes": total,
               "note": "只回收全库无人引用的孤儿正文；墓碑节点仍算引用者，冷却期内不会误删"}
        if a.dry_run:
            out["dry_run"] = True
            out["would_remove"] = len(orph)
        else:
            for r in orph:
                conn.execute("DELETE FROM blobs WHERE addr=?", (r["addr"],))
            conn.commit()
            out["gc_removed"] = len(orph)
        ignored = [k for k in ("apply", "now", "addr", "restore", "list")
                   if getattr(a, k, None)]
        if ignored:
            out["ignored"] = ignored
            out["note"] += "；--gc 独占本次调用，其余删除参数本次不生效"
        emit(conn, out)
        return
    if a.restore:
        r = node(conn, a.restore)
        b = conn.execute("SELECT hot,content FROM blobs WHERE addr=?", (r["addr"],)).fetchone()
        # 正文一旦被抹，撤回就不存在了。先判正文，再判 zone：
        # 老库里的幽灵可能 zone 还没结案，但 hot=2 已经是永久删除。
        if (r["zone"] or "hot") == "purged" or not b or b["hot"] == 2 or not b["content"]:
            sys.exit(f"[memtree] #{a.restore} 正文已永久删除，无法撤回")
        if (r["zone"] or "hot") != "tombstone":
            sys.exit(f"[memtree] #{a.restore} 不在墓碑区，无需撤回")
        age = max(0.0, now_e - r["t"]) / 86400.0
        conn.execute("UPDATE nodes SET zone=?, tombstoned_at=NULL, purge_reason=NULL WHERE id=?",
                     (zone_target(age, r["importance"], r["pinned"], r["label"]), a.restore))
        conn.commit()
        emit(conn, {"restored": a.restore,
                    "note": "冷却期内撤回：正文从未删除，分区按时间重算"})
        return
    if a.list:
        items = []
        for r in conn.execute("SELECT id,t,tombstoned_at,purge_reason,subject FROM nodes"
                              " WHERE zone='tombstone' ORDER BY tombstoned_at").fetchall():
            left = PURGE_COOLDOWN_DAYS - (now_e - (r["tombstoned_at"] or now_e)) / 86400.0
            items.append({"id": r["id"], "subject": r["subject"], "reason": r["purge_reason"],
                          "days_left": round(max(0.0, left), 2), "due": left <= 0})
        emit(conn, {"tombstones": len(items), "items": items,
                    "note": "冷却期内 purge --restore <id> 可撤回；到期由 purge --apply 真删"})
        return
    if a.apply:
        due = [r for r in conn.execute("SELECT id,addr,pinned,tombstoned_at FROM nodes"
                                       " WHERE zone='tombstone'").fetchall()
               if (now_e - (r["tombstoned_at"] or now_e)) / 86400.0 >= PURGE_COOLDOWN_DAYS]
        n = skipped_pinned = skipped_shared = 0
        for r in due:
            # 保护位在冷却期满后依然挡删；同一地址上任何一条（含墓碑区里的）打保护位
            # 都挡住这个 blob —— 计进 skipped_pinned，不重复计进 skipped_shared。
            if pinned_refs(conn, r["addr"]) > 0:
                skipped_pinned += 1
                continue
            if live_refs(conn, r["addr"]) > 0:   # 共用地址还有活引用 → 抹了就是删别人的数据
                skipped_shared += 1
                continue
            n += conn.execute("UPDATE blobs SET hot=2, content='' WHERE addr=? AND hot!=2",
                              (r["addr"],)).rowcount
            # 隐私级联：节点行保留作悬空地址，但情绪标签/原话必须一起消失，
            # 否则 purge 只删了正文、情感观察还留在 affect 表里。
            conn.execute("DELETE FROM affect WHERE node_id=?", (r["id"],))
            # 真删成功后离开墓碑区，进入 purged 终态。否则 --list 永远 due、
            # 再 --apply 永远 purged:0，墓碑列表成了不会结案的队列。
            conn.execute("UPDATE nodes SET zone='purged', tombstoned_at=NULL WHERE id=?",
                         (r["id"],))
        conn.commit()
        waiting = conn.execute("SELECT COUNT(*) c FROM nodes WHERE zone='tombstone'").fetchone()["c"]
        emit(conn, {"purged": n, "due": len(due), "skipped_pinned": skipped_pinned,
                    "skipped_shared": skipped_shared, "still_waiting": waiting,
                    "note": "冷却期满才真删：正文清除并转 purged 终态；"
                            "保护位/仍被引用的地址不抹正文"})
        return

    # 进墓碑区：--addr 指定一条；否则整批（已覆盖/归档、无保护位、非锚点）
    if a.addr:
        rows = conn.execute("SELECT id,addr,pinned,type,status,zone FROM nodes WHERE addr LIKE ?",
                            (a.addr + "%",)).fetchall()
        if not rows:
            sys.exit(f"[memtree] 没有节点引用地址 {a.addr}")
        held = [r for r in rows if r["pinned"] or r["type"] == ANCHOR]
        if held:
            sys.exit(f"[memtree] 拒绝 purge：#{held[0]['id']} 打保护位或是锚点 —— "
                     "保护位永不硬删（SPEC §3.1）；确需删除先 pin <id> --off")
    else:
        rows = conn.execute("SELECT id,addr FROM nodes WHERE status IN ('superseded','archived')"
                            " AND pinned=0 AND type!=? AND COALESCE(zone,'hot') NOT IN ('tombstone','purged')",
                            (ANCHOR,)).fetchall()
    if not rows and not a.now:
        emit(conn, {"tombstoned": 0, "note": "没有可删的候选"})
        return
    for r in rows:
        conn.execute("UPDATE nodes SET zone='tombstone', tombstoned_at=?, purge_reason=? WHERE id=?",
                     (now_e, a.reason, r["id"]))
    n_pinned = n_shared = 0
    if a.now:   # 隐私/错误信息：跳过冷却，立刻生效（跳过冷却 ≠ 跳过引用计数/保护位）
        all_rows = {r["id"]: r["addr"] for r in preexisting}
        all_rows.update({r["id"]: r["addr"] for r in rows})
        if not all_rows:
            emit(conn, {"purged_now": 0, "purged_existing": 0,
                        "skipped_pinned": 0, "skipped_shared": 0,
                        "reason": a.reason, "cooldown_skipped": True,
                        "note": "没有墓碑节点：库里既没有本轮可进墓碑的候选，也没有冷却中的墓碑"})
            return
        # 每条地址只判一次：同一地址上多条墓碑时，判定不能依赖遍历顺序
        # （先走到的那条会看到「后面那条还活着」，报出 skipped 却照样被抹）。
        by_addr = {}
        for nid, addr in all_rows.items():
            by_addr.setdefault(addr, []).append(nid)
        n_new = n_old = 0
        for addr in sorted(by_addr):
            if pinned_refs(conn, addr) > 0:      # 同一地址上有保护位（含墓碑区）→ 不抹
                n_pinned += 1
                continue
            if live_refs(conn, addr) > 0:
                n_shared += 1
                continue
            conn.execute("UPDATE blobs SET hot=2, content='' WHERE addr=? AND hot!=2", (addr,))
            ids = by_addr[addr]
            conn.executemany("DELETE FROM affect WHERE node_id=?", [(i,) for i in ids])
            conn.executemany(
                "UPDATE nodes SET zone='purged', tombstoned_at=NULL WHERE id=?",
                [(i,) for i in ids])
            n_old += sum(1 for i in ids if i in preexisting_ids)
            n_new += sum(1 for i in ids if i not in preexisting_ids)
        conn.commit()
        emit(conn, {"purged_now": n_new, "purged_existing": n_old,
                    "purged": n_new + n_old,
                    "skipped_pinned": n_pinned,
                    "skipped_shared": n_shared, "reason": a.reason,
                    "cooldown_skipped": True,
                    "note": "立即删除：所有墓碑节点一并抹正文并转 purged 终态；"
                            "保护位/仍被引用的地址不抹正文"})
        return
    conn.commit()
    emit(conn, {"tombstoned": len(rows), "cooldown_days": PURGE_COOLDOWN_DAYS,
                "due_at": datetime.fromtimestamp(now_e + PURGE_COOLDOWN_DAYS * 86400).strftime("%Y-%m-%d"),
                "note": "正文仍在库、已从检索与上下文消失；冷却期内 purge --restore <id> 撤回"})


# ------------------------------------------------------------------ 图
def cmd_graph(conn, a):
    nodes = [dict(r) for r in _rows(conn)]
    branches = [dict(b) for b in conn.execute("SELECT * FROM branches ORDER BY created_at, name")]
    if not nodes:
        print('```mermaid\ngitGraph\n    commit id: "empty"\n```')
        return
    keep = {n["id"] for n in nodes if n["status"] not in ("archived",)} if not a.all else {n["id"] for n in nodes}
    byid = {n["id"]: n for n in nodes}

    def resolve(pid):
        seen = set()
        while pid and pid not in keep and pid not in seen:
            seen.add(pid); pid = byid[pid]["parent_id"]
        return pid if pid in keep else None

    for n in nodes:
        if n["parent_id"] not in keep:
            n["parent_id"] = resolve(n["parent_id"])
    for b in branches:
        if b["fork_node"] not in keep:
            b["fork_node"] = resolve(b["fork_node"])
    nodes = [n for n in nodes if n["id"] in keep]
    kids, fork_map = {}, {}
    for n in nodes:
        kids.setdefault(n["parent_id"], []).append(n)
    for b in branches:
        if b["fork_node"] is not None:
            fork_map.setdefault(b["fork_node"], []).append(b)

    if a.style == "flow":
        lines = ["flowchart TD"]
        groups = {}
        for n in nodes:
            groups.setdefault(n["branch"], []).append(n)
        order = ["main"] + [b["name"] for b in branches if b["name"] != "main" and b["name"] in groups]
        for i, g in enumerate([x for x in order if x in groups]):
            lines.append('    subgraph sg%d["%s"]' % (i, g))
            for n in groups[g]:
                sh = ("([", "])") if n["parent_id"] is None else ("[", "]")
                mk = "" if n["status"] == "active" else "[%s] " % n["status"]
                lines.append('        n%d%s"%s#%d %s"%s' % (n["id"], sh[0], mk, n["id"],
                                                           clip(content_of(conn, n["addr"], True), 18), sh[1]))
            lines.append("    end")
        for n in nodes:
            if n["parent_id"]:
                lines.append("    n%d --> n%d" % (n["parent_id"], n["id"]))
        print("```mermaid"); print("\n".join(lines)); print("```")
        return

    lines, seen, seenb = ["gitGraph"], set(), {"main"}

    def nextc(n):
        for c in kids.get(n["id"], []):
            if c["branch"] == n["branch"] and c["id"] not in seen:
                return c
        return None

    def mt(n):
        try:
            return json.loads(n["meta"] or "{}").get("merged_branch")
        except Exception:
            return None

    def walk(n, d):
        while n and n["id"] not in seen:
            seen.add(n["id"])
            if n["type"] == "summary":
                n = nextc(n); continue
            pad, m = "    " * (d + 1), mt(n) if n["type"] == "merge" else None
            lines.append(pad + ('merge %s id: "c%d"' % (m, n["id"]) if m and m in seenb
                                else 'commit id: "c%d"' % n["id"]))
            for b in fork_map.get(n["id"], []):
                if b["name"] == n["branch"]:
                    continue
                st = next((c for c in kids.get(n["id"], []) if c["branch"] == b["name"]), None)
                if st is None:
                    continue
                lines.append(pad + "branch %s" % b["name"]); seenb.add(b["name"])
                walk(st, d + 1)
                lines.append(pad + "checkout %s" % n["branch"])
            n = nextc(n)

    for r in [n for n in nodes if n["parent_id"] is None]:
        walk(r, 0)
    print("```mermaid"); print("\n".join(lines)); print("```")


# ------------------------------------------------------------------ 压缩 / 维护
def is_conclusion(r):
    """「结论必留」（SPEC §5 ①）：结论是「这事到底怎么定」的那一句，压掉它等于记忆没了。

    判据不看措辞、看类型与结果：decision、带明确结果值的、锚点/情感标签、保护位。
    细节可以越老越粗，结论无论多老都必须保持原样 —— 这是梯度的下限。
    """
    return (r["type"] in ("decision", "anchor", "merge") or r["pinned"]
            or abs(float(r["outcome"] or 0.0)) > 0.0
            or (r["label"] in ("anchor", "emotional")))


def cmd_compress(conn, a):
    """事件内细节梯度压缩（SPEC §5 ①）：越新越细，结论必留。

    旧实现把一个分支里所有旧事件糊成一条摘要 —— 细节和结论一起没了，
    再想问「当时为什么这么定」就只能靠悬空地址。现在按事件分组：
    同事件内最新 keep_detail 条细节保留原文，更老的压成一行，结论永远不动。
    """
    t_now = datetime.now().timestamp()
    # 显式 --before/--days 沿用旧的单一截止时刻；未显式给定时才按类型分档。
    explicit_cut = (parse_ts(a.before).timestamp() if a.before
                    else t_now - a.days * 86400 if a.days is not None else None)

    def automatic_cut(r):
        # 情感锚点永不自动压缩；重要记忆 90 天，普通记忆 30 天。
        if r["label"] == "emotional" or r["type"] == "anchor":
            return None
        important = float(r["importance"] if r["importance"] is not None else 0.5) >= 0.7 or r["pinned"]
        return t_now - (90 if important else 30) * 86400

    br = a.branch or head_branch(conn)
    keep = set()
    for b in conn.execute("SELECT fork_node, head_id FROM branches"):
        keep.update(x for x in (b["fork_node"], b["head_id"]) if x)
    # pinned 走不到这层压缩：保护位永远只做 1~2 级压缩，不自动归档（SPEC §5.4）
    rows = []
    for r in _rows(conn):
        cut = explicit_cut if explicit_cut is not None else automatic_cut(r)
        if cut is None or r["t"] >= cut:
            continue
        if (r["status"] == "active"
            # 候选=事件本身，或带事件标签的条目：压缩必须在事件内部做，
            # 跨事件糊成一条就丢掉了「哪个结论属于哪件事」这层结构
            and (r["type"] == "event" or r["event"]) and r["type"] != "summary"
            and r["branch"] == br and r["id"] not in keep and not r["pinned"]
            # 归档区已经压过一轮了：再压一次只会得到摘要的摘要，信息不可逆丢失
            and (r["zone"] or "hot") != "archive"
            # 热度门（§4.1）：热度是计时器 —— 只有"久没被碰过"的候选才准压缩。
            # 最近被 recall 命中过的老事件热度仍高，会被这一条挡下来。
            # label='noise' 是结算产物：只有重复提及、没到情绪/确认阈值。
            # 它豁免热度门 —— 不是放宽标准，而是加速淘汰（§3.3）。
            # 未来条目按 min(t, now) 算是"刚写上去"，热度恒 1.0 —— 但"还没发生"不是
            # 豁免压缩的理由（审计实证：一条 2030 的事件永久免疫）。它和 noise 一样走快车道。
            and (a.heat is None or r["label"] == "noise" or float(r["t"] or 0.0) > t_now
                 or heat_of(r, t_now) <= a.heat)):
            rows.append(r)
    concl = [r for r in rows if is_conclusion(r)]
    detail = [r for r in rows if not is_conclusion(r)]

    groups = {}
    for r in sorted(detail, key=lambda r: (r["t"], r["id"])):
        groups.setdefault((r["event"] or r["subject"] or f"#{r['id']}"), []).append(r)

    done, skipped = [], []
    for key, rs in groups.items():
        keep_n = max(0, min(a.keep_detail, len(rs)))
        kept_ids = set()
        if keep_n:
            # "最新"指已发生的最新：未来的条目还没发生，不许抢占原文详情位
            past = [r for r in rs if float(r["t"] or 0.0) <= t_now]
            kept = past[len(past) - keep_n:] if len(past) > keep_n else past
            kept_ids = {r["id"] for r in kept}
            to_zip = [r for r in rs if r["id"] not in kept_ids]
        else:
            to_zip = rs
        if len(to_zip) < a.min_count:
            skipped.append({"event": key, "candidates": len(to_zip),
                            "why": f"可压 {len(to_zip)} 条 < --min-count {a.min_count}"})
            continue
        texts = [content_of(conn, r["addr"]) for r in to_zip]
        span = f"{short_date(to_zip[0]['t'])}~{short_date(to_zip[-1]['t'])}"
        body = a.text or (f"[压缩{len(to_zip)}条] " + "；".join(clip(t, 12) for t in texts[:4])
                          + ("…" if len(to_zip) > 4 else ""))
        addr = _put_blob(conn, body)
        evl = to_zip[-1]["event"]
        cur = conn.execute(
            """INSERT INTO nodes(t,outcome,subject,addr,v_text,type,scope,factor,
                                 status,branch,parent_id,meta,ts_iso,event)
               VALUES(?,0,?,?,?,'summary','global',?, 'active',?,?,?,?,?)""",
            (to_zip[0]["t"], evl or to_zip[0]["subject"], addr, pack_real(text_vec(body)),
             f"压:{span}/{len(to_zip)}条", br, to_zip[0]["parent_id"],
             json.dumps({"rolled": len(to_zip), "ids": [r["id"] for r in to_zip],
                         "event": evl, "span": span, "compressed_at": now_iso(),
                         "kept_detail": sorted(kept_ids) if keep_n else []}),
             # ts_iso 必须是它代表的事件时间（区间最老那条），不是生成时刻：
             # 「2024 年那段对话的摘要」显示成今天，就是让时间轴说谎。
             # 生成时刻要留，留在 meta.compressed_at 里。
             now_iso(datetime.fromtimestamp(to_zip[0]["t"]).astimezone()), evl))
        sid = cur.lastrowid
        for r in to_zip:
            conn.execute("""UPDATE nodes SET status='archived', rolled_into=?, gone_at=?
                            WHERE id=?""", (sid, t_now, r["id"]))
            _cold_blob(conn, r["addr"])
        done.append({"event": key, "summary_node": sid, "compressed": len(to_zip),
                     "span": span, "text": body,
                     "kept_detail": sorted(kept_ids) if keep_n else []})
    conn.commit()
    emit(conn, {"groups": done, "compressed": sum(d["compressed"] for d in done),
                "conclusions_preserved": [r["id"] for r in concl],
                "skipped": skipped,
                "note": "事件内梯度：最新 --keep-detail 条留原文、更老的压成一行、结论（decision/带结果/"
                        "锚点/保护位）无论多老都不压"})


def cmd_zone(conn, a):
    """分区维护。三种用法：看分布 / 单向降级 / 显式升级。"""
    now_e = datetime.now().timestamp()
    if a.set:
        if not a.id:
            sys.exit("[memtree] zone --set 需要 --id <节点号>")
        if a.set not in ZONES:
            sys.exit(f"[memtree] 未知分区: {a.set}（可选 {chr(47).join(ZONES)}）")
        r = node(conn, a.id)
        cur = r["zone"] or "hot"
        if a.set in HIDDEN_ZONES:
            sys.exit("[memtree] tombstone/purged 只能由 purge 流程进入，不能用 zone --set")
        if cur == "purged":
            sys.exit(f"[memtree] #{a.id} 正文已永久删除，不能改分区")
        if cur == "tombstone":
            sys.exit(f"[memtree] #{a.id} 已在墓碑区（已受理删除）：要用 purge --restore {a.id} 撤回，"
                     "不能用 zone --set 绕过冷却")
        conn.execute("UPDATE nodes SET zone=? WHERE id=?", (a.set, a.id))
        conn.commit()
        emit(conn, {"id": a.id, "from": cur, "to": a.set, "explicit": True,
                    "note": "升级只能显式：分区不因调用次数上浮（铁律二）"})
        return
    if a.migrate:
        moved, blocked = [], 0
        for r in conn.execute("SELECT id,t,zone,importance,pinned,label FROM nodes").fetchall():
            if (r["zone"] or "hot") in HIDDEN_ZONES:   # 删除流程/终态不参与时间迁移
                continue
            age = max(0.0, now_e - r["t"]) / 86400.0
            tgt = zone_target(age, r["importance"], r["pinned"], r["label"])
            cur = r["zone"] or "hot"
            if ZONE_RANK[tgt] > ZONE_RANK[cur]:
                conn.execute("UPDATE nodes SET zone=? WHERE id=?", (tgt, r["id"]))
                moved.append({"id": r["id"], "from": cur, "to": tgt})
            elif ZONE_RANK[tgt] < ZONE_RANK[cur]:
                # 只降不升：想让它回热区，必须有人显式按按钮（铁律一）
                blocked += 1
        conn.commit()
        emit(conn, {"migrated": len(moved), "down": moved[:20],
                    "kept_by_direction": blocked,
                    "note": "单向：自动只降级；升级用 zone --id <n> --set hot"})
        return
    dist = {z: 0 for z in ZONES}
    for r in conn.execute("SELECT zone,COUNT(*) c FROM nodes GROUP BY zone"):
        dist[r["zone"] or "hot"] = r["c"]
    emit(conn, {"zones": dist,
                "thresholds": {"hot": "<=7d", "warm": "7~90d",
                               "cold": f">90d 且 importance>={COLD_MIN_IMPORTANCE}（或保护位）",
                               "archive": ">90d 且重要度不够"},
                "next": "zone --migrate 单向降级；zone --id <n> --set hot 显式升级"})


def _heat_hist(conn):
    """热度分布：让"哪些旧了、哪些还被用到"变成可观测的事实，而不是感觉。"""
    t_now = datetime.now().timestamp()
    buckets = {"hot(>0.5)": 0, "warm(0.1~0.5)": 0, "cold(<=0.1)": 0}
    for r in conn.execute("SELECT t, accessed_at FROM nodes WHERE status='active'"):
        h = heat_of(r, t_now)
        buckets["hot(>0.5)" if h > 0.5 else "warm(0.1~0.5)" if h > 0.1 else "cold(<=0.1)"] += 1
    return buckets


def cmd_stats(conn, a):
    g = lambda q: conn.execute(q).fetchall()
    orph = orphan_addrs(conn)      # 孤儿正文：不用跑 GC 也能知道有多少可回收
    emit(conn, {
        "db": db_path(a),
        "nodes": g("SELECT COUNT(*) c FROM nodes")[0]["c"],
        "by_status": {r["status"]: r["c"] for r in g("SELECT status,COUNT(*) c FROM nodes GROUP BY status")},
        "by_type": {r["type"]: r["c"] for r in g("SELECT type,COUNT(*) c FROM nodes GROUP BY type")},
        "blobs": {"hot": g("SELECT COUNT(*) c FROM blobs WHERE hot=1")[0]["c"],
                  "cold": g("SELECT COUNT(*) c FROM blobs WHERE hot=0")[0]["c"],
                  "purged": g("SELECT COUNT(*) c FROM blobs WHERE hot=2")[0]["c"],
                  "orphans": len(orph),
                  "orphan_bytes": sum(r["nbytes"] or 0 for r in orph)},
        "protected": {"pinned": g("SELECT COUNT(*) c FROM nodes WHERE pinned=1")[0]["c"],
                      "anchor": g("SELECT COUNT(*) c FROM nodes WHERE type='anchor'"
                                  " AND status='active'")[0]["c"]},
        "heat": _heat_hist(conn),
        "by_label": {r["label"] or "null": r["c"]
                     for r in g("SELECT label,COUNT(*) c FROM nodes GROUP BY label")},
        "by_zone": {r["zone"] or "hot": r["c"]
                    for r in g("SELECT zone,COUNT(*) c FROM nodes GROUP BY zone")},
        "tombstone": {"pending": g("SELECT COUNT(*) c FROM nodes WHERE zone='tombstone'")[0]["c"],
                      "due": g("SELECT COUNT(*) c FROM nodes WHERE zone='tombstone'"
                               " AND tombstoned_at IS NOT NULL"
                               f" AND tombstoned_at <= {datetime.now().timestamp() - PURGE_COOLDOWN_DAYS * 86400}")[0]["c"]},
        "pending_signals": g("SELECT COUNT(*) c FROM signals WHERE settled=0")[0]["c"],
        "vec_dims": VEC_D,
        "note": "热度只用于触发压缩（§4.1），不参与排序；分区只随时间单向降级、升级须显式；"
                f"硬删除两段式（墓碑区冷却 {PURGE_COOLDOWN_DAYS:g} 天）；锚点/保护位不压缩、不裁剪、不硬删",
    })


def cmd_export(conn, a):
    data = {"nodes": [{k: v for k, v in dict(r).items() if not k.startswith("v_")} for r in _rows(conn)],
            "branches": [dict(r) for r in conn.execute("SELECT * FROM branches")],
            "blobs": [dict(r) for r in conn.execute("SELECT * FROM blobs")]}
    out = json.dumps(data, ensure_ascii=False, indent=1)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(out)
        emit(conn, {"exported": a.out, "nodes": len(data["nodes"])})
    else:
        print(out)


# ------------------------------------------------------------------ CLI
def main(argv=None):
    p = argparse.ArgumentParser(prog="memtree", description="三维时间轴记忆库 v2（时间×结果×语义 + 内容寻址）")
    p.add_argument("--db", help="数据库路径（默认 .workbuddy/memory/memtree.db）")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, h):
        s = sub.add_parser(name, help=h)
        s.set_defaults(fn=fn)
        return s

    s = add("init", lambda c, a: (c.commit(), emit(c, {"db": db_path(a), "ok": True})), "初始化")

    s = add("commit", cmd_commit, "写入一条记忆（三维 + 内容寻址 + 权重覆盖）")
    s.add_argument("content")
    s.add_argument("--subject", help="同一主体参与权重比较")
    s.add_argument("--event", help="所属事件标签（受控短标签 ≤24 字；同一件事的多次提及共用一个事件名）")
    s.add_argument("--type", default="event",
                   choices=["event", "fact", "pref", "decision", "hypothesis", "summary", "merge",
                            ANCHOR])
    s.add_argument("--outcome", type=float, help="结果值 [-1,1]：+成功/有效，-失败/无效")
    s.add_argument("--refs", type=int, default=0, help="初始可信度引用次数（重复陈述可累加）")
    s.add_argument("--importance", type=float,
                   help="重要度 [0,1]，默认 0.5。只决定老了进冷区还是归档区，不参与排序")
    s.add_argument("--scope", choices=["global", "branch"])
    s.add_argument("--branch", default=None)
    s.add_argument("--parent", type=int)
    s.add_argument("--factor")
    s.add_argument("--ts")
    s.add_argument("--meta")
    s.add_argument("--no-supersede", action="store_true")
    s.add_argument("--source", default="stated",
                   choices=["stated", "roleplay", "inferred", "system"],
                   help="内容来源；roleplay 不进情感锚点")
    s.add_argument("--pin", dest="pinned", action="store_true",
                   help="打保护位：永不压缩归档、永不硬删、永不从 context 裁剪")
    s.add_argument("--quiet", "-q", action="store_true")

    s = add("signal", cmd_signal, "记一条采样信号（只入队，不做决策）")
    s.add_argument("node", type=int)
    s.add_argument("--type", required=True, choices=list(SIGNAL_TYPES))
    s.add_argument("--intensity", type=float, default=0.0)
    s.add_argument("--quote", help="用户原话（关键金句）")
    s.add_argument("--tags", help="情感标签（仅 emotional_peak；逗号分隔，中文别名可用）")
    s.add_argument("--valence", type=float, help="效价 [-1,1]：负=难受，正=愉快")

    s = add("affect", cmd_affect, "情感观察：set/show/list/clear（结构化标签+强度+效价）")
    sa = s.add_subparsers(dest="action", required=True)
    q = sa.add_parser("set", help="给记忆加一条情感观察")
    q.add_argument("node", type=int); q.add_argument("--tags", required=True)
    q.add_argument("--intensity", type=float); q.add_argument("--valence", type=float)
    q.add_argument("--quote"); q.add_argument("--ts")
    q.add_argument("--source", default="stated",
                   choices=["stated", "roleplay", "inferred", "system"])
    q = sa.add_parser("show", help="看一条记忆的全部情感观察")
    q.add_argument("node", type=int); q.add_argument("--json", action="store_true")
    q = sa.add_parser("list", help="按时间列出情感观察")
    q.add_argument("--tags"); q.add_argument("--limit", type=int, default=30)
    q = sa.add_parser("clear", help="清掉一条记忆的全部情感观察")
    q.add_argument("node", type=int)

    s = add("settle", cmd_settle, "日终结算：signals → label（一次性 + 审计）")
    s.add_argument("--json", action="store_true")

    s = add("label", cmd_label, "手动打标签 anchor|emotional|noise|clear")
    s.add_argument("node", type=int); s.add_argument("value")
    s.add_argument("--reason")

    s = add("reinforce", cmd_reinforce, "强化一条记忆（提升可信度权重）")
    s.add_argument("id", type=int)
    s.add_argument("--times", type=int, default=1)
    s.add_argument("--resolve", action="store_true", help="同时判定它为胜者")

    s = add("branch", cmd_branch, "从某节点分叉")
    s.add_argument("name"); s.add_argument("--from", dest="var_from", type=int)
    s.add_argument("--src", default=None); s.add_argument("--force", action="store_true")

    s = add("checkout", cmd_checkout, "切换/回退 HEAD")
    s.add_argument("name"); s.add_argument("--at", type=int)

    s = add("merge", cmd_merge, "合并分支")
    s.add_argument("name"); s.add_argument("--into", default="main")
    s.add_argument("--summary"); s.add_argument("--factor")

    s = add("context", cmd_context, "生成压缩记忆块")
    s.add_argument("--branch"); s.add_argument("--budget", type=int, default=650)
    s.add_argument("--recent", type=int, default=3); s.add_argument("--width", type=int, default=40)
    s.add_argument("--json", action="store_true"); s.add_argument("--verbose", "-v", action="store_true")
    s.add_argument("--persona-file", help="人格卡路径（默认 <db>.persona.md）")

    s = add("recall", cmd_recall, "三维检索（时间×结果×语义）")
    s.add_argument("query")
    s.add_argument("--at", help="以哪个时间点为基准（默认现在），如 2026-09-15")
    s.add_argument("--outcome", type=float, help="期望结果值 [-1,1]")
    s.add_argument("--days", type=float, help="时间窗：只要 ±N 天内")
    s.add_argument("--event", help="只在此事件内检索（先剪枝，再算相似度）")
    s.add_argument("--zone", help="只看这些分区：hot,warm,cold,archive,tombstone（逗号分隔）")
    s.add_argument("--mode", default="and", choices=["and", "mix"],
                   help="and=内积定位（默认），mix=语义优先（时间只做微调）")
    s.add_argument("--branch"); s.add_argument("--top", type=int, default=5)
    s.add_argument("--status", default="auto", choices=["auto", "active", "any", "superseded", "archived", "competing"])
    s.add_argument("--emotion", help="情绪相关性：查询标签（逗号分隔）；不填则情绪维休眠")
    s.add_argument("--emotion-weight", type=float, default=0.5,
                   help="情绪权重 α（默认 0.5，仅 --emotion 时生效；时间占 1-α）")
    s.add_argument("--pipeline", choices=["legacy", "v2"], default="legacy",
                   help="检索路径：legacy=现单遍打分（默认），v2=分层剪枝+事件展开")
    s.add_argument("--expand", type=int,
                   help="v2 最多展开多少个检索单元（默认 max(top*3,20)）")
    s.add_argument("--width", type=int, default=44); s.add_argument("--json", action="store_true")

    s = add("log", cmd_log, "时间轴列表（含权重与地址）")
    s.add_argument("--branch"); s.add_argument("--limit", type=int, default=30)
    s.add_argument("--width", type=int, default=40); s.add_argument("--all", action="store_true")
    s.add_argument("--brief", action="store_true", help="精简模式：只留 id/日期/状态/内容，省约 45%%")

    s = add("show", cmd_show, "单节点详情")
    s.add_argument("id", type=int)

    s = add("verify", cmd_verify, "按地址校验正文完整性")
    s.add_argument("addr"); s.add_argument("--show", action="store_true")

    s = add("purge", cmd_purge, "两段式删除：先进墓碑区冷却 7 天，期满才真删")
    s.add_argument("--addr", help="按地址进墓碑区（不填=整批已覆盖/归档且无保护位的）")
    s.add_argument("--apply", action="store_true", help="冷却期满的真删（唯一不可逆入口）")
    s.add_argument("--list", action="store_true", help="看墓碑区排队情况与剩余天数")
    s.add_argument("--restore", type=int, metavar="ID", help="冷却期内撤回一条（正文没删过）")
    s.add_argument("--now", action="store_true", help="跳过冷却立即删：隐私/错误信息")
    s.add_argument("--gc", action="store_true",
                   help="显式回收全库无人引用的孤儿正文（只动 blobs 表，不删节点）")
    s.add_argument("--dry-run", action="store_true", help="配合 --gc：只报可回收数，不删")
    s.add_argument("--reason", help="删除理由（隐私/错误/用户要求）——记进审计，删完也留着")

    s = add("zone", cmd_zone, "分区：看分布 / 单向降级 / 显式升级")
    s.add_argument("id", type=int, nargs="?")
    s.add_argument("--set", choices=ZONES, help="显式指定分区（升级唯一入口）")
    s.add_argument("--migrate", action="store_true", help="按时间单向降级（只降不升）")
    s.add_argument("--json", action="store_true")

    s = add("pin", cmd_pin, "打/取消保护位（重要但低频的冷信息）")
    s.add_argument("id", type=int)
    s.add_argument("--off", action="store_true", help="取消保护位")

    s = add("graph", cmd_graph, "输出 Mermaid 图")
    s.add_argument("--style", default="git", choices=["git", "flow"])
    s.add_argument("--all", action="store_true")

    s = add("compress", cmd_compress, "事件内细节梯度压缩：越新越细，结论必留")
    s.add_argument("--before"); s.add_argument("--days", type=int, default=None,
                   help="显式统一时间窗（覆盖默认分档：普通 30 天 / 重要 90 天 / 情感锚点永不自动压缩）")
    s.add_argument("--min-count", type=int, default=3); s.add_argument("--text")
    s.add_argument("--keep-detail", type=int, default=1,
                   help="同一事件内保留原文细节的条数（最新 N 条），更老的压成一行摘要")
    s.add_argument("--heat", type=float,
                   help="热度门（0~1）：只压缩热度低于该值的候选；不填则只按时间裁")
    s.add_argument("--branch", help="默认跟随当前 HEAD（原实现写死 main，exp 分支的旧事件永远压不到）")

    s = add("persona", cmd_persona, "人格卡：硬/软/可变三槽（改硬槽要 --force，超预算按最旧挤出）")
    pa = s.add_subparsers(dest="action", required=True)

    def padd(name, h):
        ps = pa.add_parser(name, help=h)
        # --db 与 --persona-file 在这里也认一遍：子命令后面跟 --db 才是人的手顺，
        # argparse 只在属性不存在时套默认值，所以与全局 --db 并存不会互相覆盖。
        # default=SUPPRESS 是关键：写成默认 None 会把"全局 --db"覆盖成 None
        # （实测：memtree --db X.db persona show 的卡路径会掉回 DEFAULT_DB）。
        ps.add_argument("--db", default=argparse.SUPPRESS)
        ps.add_argument("--persona-file", default=argparse.SUPPRESS,
                        help="卡文件路径（默认 <db>.persona.md）")
        ps.set_defaults(fn=cmd_persona)
        return ps

    ps = padd("show", "看当前卡正文；--at 看某个时刻的卡")
    ps.add_argument("--json", action="store_true"); ps.add_argument("--at")

    ps = padd("set", "加一条（硬槽需 --force；超预算按最旧挤出）")
    ps.add_argument("text"); ps.add_argument("--slot", required=True, choices=list(PERSONA_SLOTS))
    ps.add_argument("--force", action="store_true"); ps.add_argument("--reason")

    ps = padd("drop", "删一条（硬槽需 --force）")
    ps.add_argument("text"); ps.add_argument("--slot", required=True, choices=list(PERSONA_SLOTS))
    ps.add_argument("--force", action="store_true"); ps.add_argument("--reason")

    ps = padd("log", "人格改动审计（时间倒序）")
    ps.add_argument("--limit", type=int, default=20); ps.add_argument("--json", action="store_true")

    s = add("stats", cmd_stats, "统计")
    s = add("export", cmd_export, "导出 JSON")
    s.add_argument("--out")

    a = p.parse_args(argv)
    conn = connect(a)
    try:
        a.fn(conn, a)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
