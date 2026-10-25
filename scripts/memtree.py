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
from datetime import datetime, timedelta

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

# ------------------------------------------------------------------ 常量
VEC_D = 128            # 事件（语义）向量维度：128 × float32 = 512B/条
TAU_DAYS = 45.0        # 时间权重半衰期（天）：w = 2^(-Δt/45)，越新越大
STATEFUL = ("fact", "pref", "decision")
GLYPH = {"active": "●", "superseded": "◐", "archived": "○", "competing": "◆"}
DEFAULT_DB = os.path.join(".workbuddy", "memory", "memtree.db")


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
    """时间量：查询时间唯一，所以它不做匹配，只做权重。Δt<0（未来）不计。"""
    t_q = t_q or datetime.now().timestamp()
    dt_days = max(0.0, (t_q - t_m) / 86400.0)
    return 0.5 ** (dt_days / TAU_DAYS)


def l2(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def text_vec(text, vec_d=None):
    """事件向量：每个 token 生成一条稠密 ±1 随机向量再叠加（随机投影式词袋）。
    必须稠密——稀疏哈希会让"没命中的维度"权重为 0，把另一维整段打空。"""
    d = vec_d or VEC_D
    v = [0.0] * d
    s = (text or "").lower()
    toks = re.findall(r"[a-z0-9_]+", s)
    for seg in re.findall(r"[\u4e00-\u9fff]+", s):
        toks += list(seg)
        toks += [seg[i:i + 2] for i in range(len(seg) - 1)]
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
        return datetime.strptime(str(s)[:19], "%Y-%m-%d %H:%M:%S").astimezone()


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
            refs          INTEGER NOT NULL DEFAULT 0,-- 被强化次数 → 可信度
            supersedes    INTEGER,
            superseded_by INTEGER,
            rolled_into   INTEGER,
            status        TEXT NOT NULL DEFAULT 'active',
            branch        TEXT NOT NULL DEFAULT 'main',
            parent_id     INTEGER,
            meta          TEXT,
            ts_iso        TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sub ON nodes(subject, status);
        CREATE INDEX IF NOT EXISTS idx_br  ON nodes(branch, t);
        CREATE INDEX IF NOT EXISTS idx_addr ON nodes(addr);

        CREATE TABLE IF NOT EXISTS branches(
            name TEXT PRIMARY KEY, fork_node INTEGER, head_id INTEGER,
            status TEXT NOT NULL DEFAULT 'open', merged_into TEXT, merged_at TEXT, created_at TEXT
        );
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        """
    )
    conn.execute("INSERT OR IGNORE INTO branches(name,status,created_at) VALUES('main','open',?)", (now_iso(),))
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


def emit(conn, obj, quiet=False):
    if not quiet:
        print(json.dumps(obj, ensure_ascii=False))


# ------------------------------------------------------------------ 权重
def weight(node_row, now_epoch=None):
    """权重只由时间决定：w = 2^(-Δt/τ)，越新越大，严格单调。"""
    now_epoch = now_epoch or datetime.now().timestamp()
    age_days = max(0.0, (now_epoch - node_row["t"]) / 86400.0)
    return 0.5 ** (age_days / TAU_DAYS)


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
    scope = a.scope or ("global" if ntype in ("fact", "pref") else "branch")
    subject = a.subject
    outcome = float(a.outcome if a.outcome is not None else 0.0)

    addr = _put_blob(conn, a.content)
    sem = text_vec(a.content)

    cur = conn.execute(
        """INSERT INTO nodes(t,outcome,subject,addr,v_text,type,scope,factor,refs,
                             status,branch,parent_id,meta,ts_iso)
           VALUES(?,?,?,?,?,?,?,?,?, 'active', ?,?,?,?)""",
        (t_epoch, outcome, subject, addr, pack_real(sem),
         ntype, scope, a.factor, int(a.refs or 0), bname, parent, a.meta, ts),
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
                conn.execute("UPDATE nodes SET status='superseded', superseded_by=? WHERE id=?",
                             (win["id"], r["id"]))
                conn.execute("UPDATE blobs SET hot=0 WHERE addr=?", (r["addr"],))
            decision = "supersede" if win["id"] == nid else "kept"
            rival = {"id": loser["id"], "w_lost": round(weight(loser), 3),
                     "w_win": round(weight(win), 3)}
            if win["id"] == nid:
                fac = a.factor or f"曾:{clip(loser_text, 14)}@{short_date(loser['ts_iso'])}"
                conn.execute("UPDATE nodes SET factor=?, supersedes=? WHERE id=?",
                             (fac, loser["id"], nid))

    conn.execute("UPDATE branches SET head_id=? WHERE name=?", (nid, bname))
    conn.commit()
    if a.quiet:
        print(nid)
    else:
        emit(conn, {"id": nid, "branch": bname, "addr": addr, "type": ntype,
                    "w": round(weight(node(conn, nid), datetime.now().timestamp()), 3),
                    "decision": decision, "rival": rival})


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
    conn.execute("UPDATE nodes SET status='archived' WHERE branch=? AND status IN ('active','competing')", (a.name,))
    for r in conn.execute("SELECT addr FROM nodes WHERE branch=? AND status='archived'", (a.name,)):
        conn.execute("UPDATE blobs SET hot=0 WHERE addr=?", (r["addr"],))
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
    facts, branches, events = [], [], []

    stateful = [r for r in _rows(conn, """SELECT * FROM nodes WHERE status IN ('active','competing')
                                          AND type IN ('fact','pref','decision')
                                          AND (scope='global' OR branch=?)""", (branch,))]
    wmap = _w(conn, stateful, now_e)

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
                line = f"■ {sub}: {clip(content_of(conn, r['addr'], True), a.width)}"
                if r["factor"]:
                    line += f"  ({r['factor']})"
                facts.append(line)
                continue
        if any(x["status"] == "competing" for x in rs):
            parts = " ⟷ ".join(f"{clip(content_of(conn, x['addr'], True), 16)}({wmap[x['id']]:.2f})" for x in rs[:3])
            facts.append(f"◆ {sub}: {parts} 冲突待定")
        else:
            r = rs[0]
            line = f"■ {sub}: {clip(content_of(conn, r['addr'], True), a.width)}"
            if r["factor"]:
                line += f"  ({r['factor']})"
            facts.append(line)

    for r in reversed(_rows(conn, """SELECT * FROM nodes WHERE status='active' AND type='hypothesis' AND branch=?""",
                            (branch,))):
        facts.append(f"◇ {r['subject'] or '假设'}: {clip(content_of(conn, r['addr'], True), a.width)}")

    for b in conn.execute("SELECT * FROM branches WHERE status='open' AND name!=? ORDER BY created_at", (branch,)):
        h = conn.execute("SELECT * FROM nodes WHERE id=?", (b["head_id"],)).fetchone() if b["head_id"] else None
        tip = clip(content_of(conn, h["addr"], True), 30) if h else "(空)"
        branches.append(f"○ {b['name']}#{b['head_id'] or '-'} {tip}")

    ev = [r for r in _rows(conn, """SELECT * FROM nodes WHERE status='active'
                                    AND type IN ('event','merge','summary')""") if r["branch"] == branch]
    picked = ev[-a.recent:] if a.recent else []
    picked += [r for r in ev if r["type"] == "summary" and r["id"] not in {p["id"] for p in picked}][-2:]
    for r in sorted(picked, key=lambda r: (r["t"], r["id"]), reverse=True):
        events.append(f"· {short_date(r['t'], ref)} {clip(content_of(conn, r['addr'], True), a.width)}")

    n_all = conn.execute("SELECT COUNT(*) c FROM nodes").fetchone()["c"]
    n_cold = conn.execute("SELECT COUNT(*) c FROM nodes WHERE status!='active'").fetchone()["c"]
    head = conn.execute("SELECT head_id FROM branches WHERE name=?", (branch,)).fetchone()["head_id"]
    legend = "※ ■现状 ◇假设 ○分支 ·事件  (曾:…@日期)=已废弃，禁止当作现状"
    lines = [f"【记忆 {ref.strftime('%Y-%m-%d')} | {branch}#{head or '-'} | {n_all}节点·冷{n_cold}】"]
    lines += facts + branches + events + legend.split("\n")

    def size(ls):
        return sum(len(x) + 1 for x in ls)

    def rebuild():
        return [lines[0]] + facts + branches + events + legend.split("\n")

    # 裁剪优先级：事件是时间轴的骨节，fact 是状态。
    # 先保住最近的 keep_ev 条事件 → 再砍 fact → 最后才动保底事件。
    # 原实现先砍 events 会把它砍光，输出退化成一坨静态事实、时间轴在上下文里消失。
    keep_ev = min(max(a.recent, 0), len(events))
    while size(rebuild()) > a.budget and len(events) > keep_ev:
        events.pop(); lines = rebuild()
    while size(rebuild()) > a.budget and len(facts) > 1:
        facts.pop(); lines = rebuild()
    while size(rebuild()) > a.budget and len(events) > 0:
        events.pop(); lines = rebuild()
    out = "\n".join(rebuild())
    if a.json:
        emit(conn, {"text": out, "chars": len(out), "est_tokens": est_tokens(out)})
    else:
        print(out)
        if a.verbose:
            print(f"\n[chars={len(out)} est_tokens≈{est_tokens(out)} budget={a.budget}]", file=sys.stderr)


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

    want = {"active", "competing"} if a.status == "auto" else \
           {"active", "competing", "superseded", "archived"} if a.status == "any" else {a.status}

    # 回溯到某个时刻时，覆盖关系要按"当时"重算：
    # 那一刻之前、同 subject 里时间最大的那条，才是当时的现状。
    at_mode = a.at is not None
    cur_ids = set()
    if at_mode:
        best = {}
        for r in conn.execute("SELECT id, subject, t FROM nodes WHERE t <= ?", (t_ref,)):
            if r["subject"] is None:
                continue
            if r["subject"] not in best or r["t"] > best[r["subject"]][1]:
                best[r["subject"]] = (r["id"], r["t"])
        cur_ids = {v[0] for v in best.values()}

    hits = []
    for r in conn.execute("SELECT * FROM nodes"):
        if at_mode and r["subject"]:
            is_cur = r["id"] in cur_ids
            if a.status == "auto" and not is_cur:
                continue
            if a.status == "superseded" and is_cur:
                continue
        elif r["status"] not in want:
            continue
        if a.branch and not (r["branch"] == a.branch or r["scope"] == "global"):
            continue
        # 不硬性过滤"未来"：事件的结果可能在事后才确定。
        # "当时的状态"由上面的 cur_ids 保证（同 subject 只留 t≤t_ref 的最大者）。
        if a.days is not None and (t_ref - r["t"]) / 86400.0 > a.days:
            continue
        st = time_weight(r["t"], t_ref)                  # t_q·t_m，t_q≡1
        so = r_ref * float(r["outcome"] or 0.0)          # r_q·r_m，r_q 默认 0 → 休眠
        se = dot(e_q, unpack_real(r["v_text"]))          # cos(e_q, e_m)
        s = se * (st + so) if a.mode == "and" else se * (0.5 + 0.5 * st) + 0.3 * so
        hits.append((s, r, se, st, so))
    hits.sort(key=lambda x: -x[0])
    top = hits[: a.top]
    if a.json:
        emit(conn, {"query": q_text, "t": a.at or now_iso(), "outcome": r_ref, "hits": [
            {"id": r["id"], "score": round(s, 3), "sem": round(se, 2), "time": round(st, 2),
             "out": round(so, 2), "status": r["status"],
             "subject": r["subject"], "addr": r["addr"], "content": content_of(conn, r["addr"], True),
             "ts": r["ts_iso"]} for s, r, se, st, so in top]})
        return
    if not top:
        print("(无命中)")
        return
    for s, r, se, st, so in top:
        if at_mode:                                  # 回溯视角：以"当时"论现状
            is_cur = r["id"] in cur_ids
            flag = "「当时现状」" if is_cur else "「当时已过时」"
            glyph = GLYPH["active"] if is_cur else GLYPH["superseded"]
        else:
            flag = "" if r["status"] == "active" else f"「{r['status']}·不可当现状」"
            glyph = GLYPH.get(r["status"], "?")
        print(f"{bar(s)} #{r['id']:<3} {glyph} {short_date(r['t'])} "
              f"t·{st:.2f} r·{so:+.2f} sem{se:+.2f} Σ={s:+.3f} → "
              f"{clip(content_of(conn, r['addr'], hot_only=not at_mode), a.width)} {flag}")


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
            print(f"#{r['id']} {short_date(r['t'], ref)} {GLYPH.get(r['status'],'?')} "
                  f"{clip(content_of(conn, r['addr'], True), a.width)}"
                  + (f" ({r['factor']})" if r["factor"] else ""))
            continue
        pb = allbr.get(r["parent_id"])
        fork = f"  ↳from {pb}" if pb and pb != r["branch"] else ""
        print(f"#{r['id']:<4} {r['ts_iso'][:16].replace('T',' ')} {GLYPH.get(r['status'],'?')} "
              f"{r['branch']:<9} w={weight(r, now_e):.2f} {r['addr']} {clip(content_of(conn, r['addr'], True), a.width)}"
              + (f"  ({r['factor']})" if r["factor"] else "") + fork)


def cmd_show(conn, a):
    r = node(conn, a.id)
    now_e = datetime.now().timestamp()
    b = conn.execute("SELECT * FROM blobs WHERE addr=?", (r["addr"],)).fetchone()
    print(f"#{r['id']}  {r['ts_iso']}  {GLYPH.get(r['status'])} {r['status']}")
    print(f"branch={r['branch']} parent={r['parent_id']} type={r['type']} scope={r['scope']}")
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
    """物理删除：正文从 blobs 移除，节点只留地址（悬空指针），不可恢复。"""
    if a.addr:
        cur = conn.execute("UPDATE blobs SET hot=2, content='' WHERE addr LIKE ?", (a.addr + "%",))
        conn.commit()
        emit(conn, {"purged_addr": a.addr, "rows": cur.rowcount})
        return
    rows = conn.execute("SELECT addr FROM nodes WHERE status IN ('superseded','archived')").fetchall()
    n = 0
    for r in rows:
        n += conn.execute("UPDATE blobs SET hot=2, content='' WHERE addr=? AND hot!=2", (r["addr"],)).rowcount
    conn.commit()
    emit(conn, {"purged": n, "note": "已覆盖/归档记忆的正文已物理删除，仅保留地址"})


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
def cmd_compress(conn, a):
    cut = parse_ts(a.before).timestamp() if a.before else datetime.now().timestamp() - a.days * 86400
    keep = set()
    for b in conn.execute("SELECT fork_node, head_id FROM branches"):
        keep.update(x for x in (b["fork_node"], b["head_id"]) if x)
    rows = [r for r in _rows(conn)
            if r["status"] == "active" and r["type"] == "event" and r["t"] < cut
            and r["branch"] == a.branch and r["id"] not in keep]
    if len(rows) < a.min_count:
        emit(conn, {"compressed": 0, "candidates": [r["id"] for r in rows]})
        return
    texts = [content_of(conn, r["addr"]) for r in rows]
    span = f"{short_date(rows[0]['t'])}~{short_date(rows[-1]['t'])}"
    body = a.text or f"[压缩{len(rows)}条] " + "；".join(clip(t, 12) for t in texts[:4]) + ("…" if len(rows) > 4 else "")
    addr = _put_blob(conn, body)
    t0 = rows[0]["t"]
    cur = conn.execute(
        """INSERT INTO nodes(t,outcome,subject,addr,v_text,type,scope,factor,
                             status,branch,parent_id,meta,ts_iso)
           VALUES(?,0,NULL,?,?,'summary','global',?, 'active',?,?,?,?)""",
        (t0, addr, pack_real(text_vec(body)),
         f"压:{span}/{len(rows)}条", a.branch, rows[0]["parent_id"],
         json.dumps({"rolled": len(rows), "ids": [r["id"] for r in rows]}), now_iso()))
    sid = cur.lastrowid
    for r in rows:
        conn.execute("UPDATE nodes SET status='archived', rolled_into=? WHERE id=?", (sid, r["id"]))
        conn.execute("UPDATE blobs SET hot=0 WHERE addr=?", (r["addr"],))
    conn.commit()
    emit(conn, {"summary_node": sid, "rolled": len(rows), "span": span, "text": body})


def cmd_stats(conn, a):
    g = lambda q: conn.execute(q).fetchall()
    emit(conn, {
        "db": db_path(a),
        "nodes": g("SELECT COUNT(*) c FROM nodes")[0]["c"],
        "by_status": {r["status"]: r["c"] for r in g("SELECT status,COUNT(*) c FROM nodes GROUP BY status")},
        "by_type": {r["type"]: r["c"] for r in g("SELECT type,COUNT(*) c FROM nodes GROUP BY type")},
        "blobs": {"hot": g("SELECT COUNT(*) c FROM blobs WHERE hot=1")[0]["c"],
                  "cold": g("SELECT COUNT(*) c FROM blobs WHERE hot=0")[0]["c"],
                  "purged": g("SELECT COUNT(*) c FROM blobs WHERE hot=2")[0]["c"]},
        "vec_dims": VEC_D,
        "note": "冷/已清除的正文不在检索与上下文路径上，只留地址",
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
    s.add_argument("--type", default="event",
                   choices=["event", "fact", "pref", "decision", "hypothesis", "summary", "merge"])
    s.add_argument("--outcome", type=float, help="结果值 [-1,1]：+成功/有效，-失败/无效")
    s.add_argument("--refs", type=int, default=0, help="初始可信度引用次数（重复陈述可累加）")
    s.add_argument("--scope", choices=["global", "branch"])
    s.add_argument("--branch", default=None)
    s.add_argument("--parent", type=int)
    s.add_argument("--factor")
    s.add_argument("--ts")
    s.add_argument("--meta")
    s.add_argument("--no-supersede", action="store_true")
    s.add_argument("--quiet", "-q", action="store_true")

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

    s = add("recall", cmd_recall, "三维检索（时间×结果×语义）")
    s.add_argument("query")
    s.add_argument("--at", help="以哪个时间点为基准（默认现在），如 2026-09-15")
    s.add_argument("--outcome", type=float, help="期望结果值 [-1,1]")
    s.add_argument("--days", type=float, help="时间窗：只要 ±N 天内")
    s.add_argument("--mode", default="and", choices=["and", "mix"],
                   help="and=内积定位（默认），mix=语义优先（时间只做微调）")
    s.add_argument("--branch"); s.add_argument("--top", type=int, default=5)
    s.add_argument("--status", default="auto", choices=["auto", "active", "any", "superseded", "archived", "competing"])
    s.add_argument("--width", type=int, default=44); s.add_argument("--json", action="store_true")

    s = add("log", cmd_log, "时间轴列表（含权重与地址）")
    s.add_argument("--branch"); s.add_argument("--limit", type=int, default=30)
    s.add_argument("--width", type=int, default=40); s.add_argument("--all", action="store_true")
    s.add_argument("--brief", action="store_true", help="精简模式：只留 id/日期/状态/内容，省约 45%%")

    s = add("show", cmd_show, "单节点详情")
    s.add_argument("id", type=int)

    s = add("verify", cmd_verify, "按地址校验正文完整性")
    s.add_argument("addr"); s.add_argument("--show", action="store_true")

    s = add("purge", cmd_purge, "物理删除已覆盖记忆的正文，只留地址")
    s.add_argument("--addr")

    s = add("graph", cmd_graph, "输出 Mermaid 图")
    s.add_argument("--style", default="git", choices=["git", "flow"])
    s.add_argument("--all", action="store_true")

    s = add("compress", cmd_compress, "旧事件压缩成摘要")
    s.add_argument("--before"); s.add_argument("--days", type=int, default=30)
    s.add_argument("--min-count", type=int, default=3); s.add_argument("--text")
    s.add_argument("--branch", default="main")

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
