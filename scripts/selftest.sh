#!/usr/bin/env bash
# memtree v2 自检：三维检索 / 时间权重覆盖 / 内容寻址 / 分支 / 压缩
# 用法: bash scripts/selftest.sh
set -u
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SD")"

PY=""
for c in "${MEMTREE_PY:-}" python3 python py; do
  [ -n "$c" ] || continue
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "找不到 python，请设 MEMTREE_PY"; exit 2; }

# 一律用自己的临时库：继承来的 MEMTREE_DB 会让断言跑在别处的库上（曾因此 19 项假失败）
export MEMTREE_DB="$(mktemp -d)/mt_selftest.db"
rm -f "$MEMTREE_DB"*
M="$PY $ROOT/scripts/memtree.py"
PASS=0; FAIL=0

chk() {  # chk <描述> <python 表达式，c=连接, text=按关键字取正文>
  if "$PY" - "$MEMTREE_DB" "$2" <<'EOF'
import sqlite3, sys
db, expr = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
def text(kw):
    r = c.execute("""select b.content from nodes n join blobs b on n.addr=b.addr
                     where b.content like ?""", (f"%{kw}%",)).fetchone()
    return r[0] if r else ""
sys.exit(0 if eval(expr, {"c": c, "text": text}) else 1)
EOF
  then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"
  fi
}

echo "DB=$MEMTREE_DB"

echo "[1] 时间权重覆盖（越新越大）"
$M commit "喜欢美式" --type fact --subject t.coffee --outcome 0.5 --ts "2026-09-15T10:00:00+08:00" -q >/dev/null
$M commit "改喝拿铁" --type fact --subject t.coffee --outcome 0.5 --ts "2026-10-17T10:00:00+08:00" -q >/dev/null
chk "旧事实变 superseded" "c.execute('select status from nodes where id=1').fetchone()[0]=='superseded'"
chk "新事实带墓碑" "'曾:' in (c.execute('select factor from nodes where id=2').fetchone()[0] or '')"
chk "同 subject 只剩 1 条 active" "c.execute(\"select count(*) from nodes where subject='t.coffee' and status='active'\").fetchone()[0]==1"
chk "旧正文转冷 hot=0" "c.execute('select b.hot from nodes n join blobs b on n.addr=b.addr where n.id=1').fetchone()[0]==0"

echo "[2] 乱序补录：旧时间不该覆盖新时间"
$M commit "补录：8月其实喜欢冷萃" --type fact --subject t.coffee --outcome 0.5 --ts "2026-08-01T10:00:00+08:00" >/dev/null
chk "补录的旧记录被压制" "c.execute('select status from nodes where id=3').fetchone()[0]=='superseded'"
chk "现状仍是拿铁" "c.execute(\"select count(*) from nodes where status='active' and subject='t.coffee'\").fetchone()[0]==1 and text('拿铁')!=''"

echo "[3] 三维检索：时间×结果×语义"
$M commit "方案A 上线成功 延迟降到 100ms" --type decision --subject t.plan --outcome 0.9 --ts "2026-09-10T10:00:00+08:00" -q >/dev/null
$M commit "方案B 内存泄漏失败" --type event --outcome -0.9 --ts "2026-09-20T10:00:00+08:00" -q >/dev/null
R1=$($M recall "方案" --at "2026-09-10" --outcome 0.9 --top 1)
R2=$($M recall "方案" --at "2026-09-10" --outcome -0.9 --top 1)
echo "$R1" | grep -q "上线成功" && { PASS=$((PASS+1)); echo "  ok   结果维=成功 → 命中方案A"; } || { FAIL=$((FAIL+1)); echo "  FAIL 结果维=成功 未命中"; }
echo "$R2" | grep -q "内存泄漏" && { PASS=$((PASS+1)); echo "  ok   结果维=失败 → 命中方案B"; } || { FAIL=$((FAIL+1)); echo "  FAIL 结果维=失败 未命中"; }

echo "[4] 内容寻址"
ADDR=$($M log --all --limit 8 | grep "改喝拿铁" | awk '{print $7}')
$M verify "$ADDR" | grep -q '"sha256_ok": true' && { PASS=$((PASS+1)); echo "  ok   地址=sha256(正文)，校验通过"; } || { FAIL=$((FAIL+1)); echo "  FAIL 地址校验 ($ADDR)"; }

echo "[5] 分支"
$M checkout main >/dev/null
$M branch exp --from 1 >/dev/null
$M checkout exp >/dev/null
$M commit "试方案X" --type hypothesis --ts "2026-10-02T09:00:00+08:00" -q >/dev/null
chk "分支节点归属正确" "c.execute('select branch from nodes order by id desc limit 1').fetchone()[0]=='exp'"
$M checkout main >/dev/null
$M merge exp --summary "结论：X 不可行" >/dev/null
chk "分支标记 merged" "c.execute(\"select status from branches where name='exp'\").fetchone()[0]=='merged'"
chk "分支成员归档" "c.execute(\"select status from nodes where branch='exp'\").fetchone()[0]=='archived'"

echo "[6] context 预算与图例"
OUT=$($M context --budget 650)
echo "$OUT" | grep -q "禁止当作现状" && { PASS=$((PASS+1)); echo "  ok   图例存在"; } || { FAIL=$((FAIL+1)); echo "  FAIL 图例"; }
LEN=$(printf %s "$OUT" | wc -c)
[ "$LEN" -le 750 ] && { PASS=$((PASS+1)); echo "  ok   context ${LEN}B ≤ 750"; } || { FAIL=$((FAIL+1)); echo "  FAIL 超预算 ${LEN}"; }
echo "$OUT" | grep -qE "^■ t.coffee: 改喝拿铁" && { PASS=$((PASS+1)); echo "  ok   现状行正确"; } || { FAIL=$((FAIL+1)); echo "  FAIL 现状行"; }

echo "[7] 压缩"
for i in 1 2 3; do $M commit "旧事件$i" --type event --event 旧事件轴 --ts "2026-08-0${i}T10:00:00+08:00" -q >/dev/null; done
$M commit "当前进展" --type event -q >/dev/null
# 本用例表达的是「一个事件内的候选全部被压」：显式 --keep-detail 0 才退化成全压，
# 默认 keep-detail 1 会留最新一条原文（梯度语义，见 [24]）。
$M compress --days 40 --min-count 3 --keep-detail 0 >/dev/null
chk "生成 summary" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==1"
chk "旧事件不再 active" "c.execute(\"select count(*) from nodes where status='active' and addr in (select addr from blobs where content like '旧事件%')\").fetchone()[0]==0"

echo "[8] 物理清除（两段式：批量 purge 先进墓碑区）"
$M purge >/dev/null
chk "整批 purge 只进墓碑区，正文还在（有冷却期）" "c.execute(\"select count(*) from nodes where zone='tombstone'\").fetchone()[0]>=1 and c.execute(\"select count(*) from blobs where hot=2\").fetchone()[0]==0"
chk "墓碑区的正文仍可读（撤回时用得上）" "c.execute(\"select count(*) from nodes n join blobs b on n.addr=b.addr where n.zone='tombstone' and length(b.content)>0\").fetchone()[0]>=1"

echo "[9] 出图"
$M graph | grep -q "gitGraph" && { PASS=$((PASS+1)); echo "  ok   git 图"; } || { FAIL=$((FAIL+1)); echo "  FAIL git 图"; }
$M graph --style flow | grep -q "flowchart TD" && { PASS=$((PASS+1)); echo "  ok   flow 图"; } || { FAIL=$((FAIL+1)); echo "  FAIL flow 图"; }

echo "[10] 参数校验（脏值要当场拒绝，不能入库）"
export MEMTREE_DB="$(mktemp -d)/mt_selftest2.db"
$M init >/dev/null
$M commit "越界结果值" --outcome 5 >/dev/null 2>&1 && R=0 || R=1
[ "$R" -eq 1 ] && { PASS=$((PASS+1)); echo "  ok   --outcome 5 被拒绝"; } || { FAIL=$((FAIL+1)); echo "  FAIL --outcome 5 入库了"; }
ERR=$($M commit "坏时间戳" --ts "不是时间" 2>&1)
echo "$ERR" | grep -q "Traceback" && { FAIL=$((FAIL+1)); echo "  FAIL 非法 --ts 泄漏 traceback"; } || { PASS=$((PASS+1)); echo "  ok   非法 --ts 报错干净"; }
chk "脏值没有入库" "c.execute('select count(*) from nodes').fetchone()[0]==0"

echo "[11] 未来时间戳不得霸榜"
$M commit "笔误写成 2030 的方案Z" --type event --ts "2030-01-01T10:00:00+08:00" -q >/dev/null
$M commit "上周真实落地的方案Z" --type event --ts "2026-10-01T10:00:00+08:00" -q >/dev/null
echo "$($M recall "方案Z" --top 1)" | grep -q "上周真实落地" && { PASS=$((PASS+1)); echo "  ok   未来笔误不霸榜（|Δt| 对称衰减）"; } || { FAIL=$((FAIL+1)); echo "  FAIL 2030 笔误仍在首位"; }

echo "[12] 保护位（不裁剪 / 不压缩 / 不硬删）"
$M commit "她生日是 3 月 12 日" --type fact --subject p.birth --pin -q >/dev/null
chk "pinned 已落库" "c.execute(\"select pinned from nodes where subject='p.birth'\").fetchone()[0]==1"
for i in $(seq 1 30); do $M commit "噪声事实$i 用来把预算撑满" --type fact --subject "n.$i" -q >/dev/null; done
SMALL=$($M context --budget 200)
echo "$SMALL" | grep -q "生日是 3 月 12 日" && { PASS=$((PASS+1)); echo "  ok   保护位扛住预算裁剪"; } || { FAIL=$((FAIL+1)); echo "  FAIL 保护位被裁掉了"; }
echo "$SMALL" | grep -q "★钉" && { PASS=$((PASS+1)); echo "  ok   保护位有标记"; } || { FAIL=$((FAIL+1)); echo "  FAIL 无 ★钉 标记"; }
echo "$SMALL" | grep -q "还有 .* 条未展开" && { PASS=$((PASS+1)); echo "  ok   溢出有显式标记"; } || { FAIL=$((FAIL+1)); echo "  FAIL 截断静默无标记"; }
AH=$($M export | "$PY" -c "import json,sys;d=json.load(sys.stdin);print([n['addr'] for n in d['nodes'] if n['pinned']==1][0])")
$M purge --addr "$AH" >/dev/null 2>&1 && R=0 || R=1
[ "$R" -eq 1 ] && { PASS=$((PASS+1)); echo "  ok   purge 被保护位拒绝"; } || { FAIL=$((FAIL+1)); echo "  FAIL 保护位的正文被 purge 了"; }

echo "[13] 硬锚点（不被现状吞掉）"
$M commit "她叫小满" --type anchor --subject id.name -q >/dev/null
$M commit "最近改口说自己叫小蛮" --type fact --subject id.name -q >/dev/null
chk "锚点仍 active" "c.execute(\"select status from nodes where subject='id.name' and type='anchor'\").fetchone()[0]=='active'"
ACTX=$($M context --budget 900)
echo "$ACTX" | grep -q "⚓ id.name: 她叫小满" && { PASS=$((PASS+1)); echo "  ok   锚点独立成段"; } || { FAIL=$((FAIL+1)); echo "  FAIL 锚点没显示"; }
echo "$ACTX" | grep -q "⚑锚点未变" && { PASS=$((PASS+1)); echo "  ok   现状标出与锚点的张力"; } || { FAIL=$((FAIL+1)); echo "  FAIL 缺 ⚑ 标记"; }

echo "[14] 非 ASCII（emoji / 假名）不是死数据"
$M commit "她说「🎂 想吃蛋糕」🎉 ゆめ" --type event --subject e.cake -q >/dev/null
NONA=$($M recall "🎂 蛋糕")
echo "$NONA" | grep -q "想吃蛋糕" && { PASS=$((PASS+1)); echo "  ok   emoji 记忆可召回"; } || { FAIL=$((FAIL+1)); echo "  FAIL emoji 记忆召回不到"; }
echo "$NONA" | grep -q "sem+0.00" && { FAIL=$((FAIL+1)); echo "  FAIL 零向量（sem 恒 0）"; } || { PASS=$((PASS+1)); echo "  ok   向量非零"; }

echo "[15] 热度只做压缩计时器"
$M commit "五月的老事件 方案Q" --type event --ts "2026-05-01T10:00:00+08:00" -q >/dev/null
$M recall "方案Q" >/dev/null
chk "accessed_at 已记录" "c.execute(\"select count(*) from nodes where accessed_at is not null\").fetchone()[0]>=1"
$M compress --days 30 --min-count 1 --heat 0.5 --keep-detail 0 >/dev/null
chk "刚被召回的老事件不被压缩" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==0"
$M commit "从没被碰过的四月老事件 方案R" --type event --ts "2026-04-01T10:00:00+08:00" -q >/dev/null
$M commit "当前进展" --type event -q >/dev/null
# 同上：本用例验的是热度门，所以显式全压（--keep-detail 0），让唯一变量只剩热度
$M compress --days 30 --min-count 1 --heat 0.5 --keep-detail 0 >/dev/null
chk "久未访问的老事件被压缩" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==1"

echo "[16] 采样 → 结算 → 打标签（动态因子的第二职责）"
# 两条同为"老事件 + 刚被访问过(heat≈1)"的对照，只差一个 label
IDA=$($M commit "老事件X 需打标 方案U" --type event --ts "2026-04-01T10:00:00+08:00" -q)
IDB=$($M commit "老事件Y 纯噪音 方案V" --type event --ts "2026-04-02T10:00:00+08:00" -q)
$M commit "当前进展" --type event -q >/dev/null
$M signal "$IDA" --type user_confirm --quote "这个重要" >/dev/null
$M signal "$IDB" --type repeat_mention >/dev/null
chk "结算前没有任何 label" "c.execute('select count(*) from nodes where label is not null').fetchone()[0]==0"
$M settle >/dev/null
chk "user_confirm 判成 anchor" "c.execute('select label from nodes where id=$IDA').fetchone()[0]=='anchor'"
chk "anchor 自动拿保护位" "c.execute('select pinned from nodes where id=$IDA').fetchone()[0]==1"
chk "只有重复提及判成 noise" "c.execute('select label from nodes where id=$IDB').fetchone()[0]=='noise'"
chk "noise 不拿保护位" "c.execute('select pinned from nodes where id=$IDB').fetchone()[0]==0"
chk "结算留了审计行" "c.execute('select count(*) from settle_log').fetchone()[0]>=2"
chk "信号结算后清空" "c.execute('select count(*) from signals where settled=0').fetchone()[0]==0"
# 本用例验的是 noise 豁免热度门，同样显式全压，别让 keep-detail 混进来
$M compress --days 30 --min-count 1 --heat 0.1 --keep-detail 0 >/dev/null
chk "noise 豁免热度门被压缩" "c.execute('select status from nodes where id=$IDB').fetchone()[0]=='archived'"
chk "anchor 不被压缩" "c.execute('select status from nodes where id=$IDA').fetchone()[0]=='active'"

echo "[17] 角色扮演污染防护（虚构不进情感锚点）"
IDR=$($M commit "角色扮演台词 我妈妈也走了" --type fact --subject rp.mom --source roleplay -q)
$M signal "$IDR" --type emotional_peak --intensity 0.9 >/dev/null
$M settle >/dev/null
chk "roleplay 情绪再高也不打标" "c.execute('select label from nodes where id=$IDR').fetchone()[0] is None"
chk "roleplay 不被 pin" "c.execute('select pinned from nodes where id=$IDR').fetchone()[0]==0"
chk "source_type 已落库" "c.execute('select source_type from nodes where id=$IDR').fetchone()[0]=='roleplay'"

echo "[18] 手动标签与升/降噪"
IDL=$($M commit "手工标注目标 方案W" --type fact --subject t.manual -q)
$M label "$IDL" noise --reason "测试" >/dev/null
chk "手动 noise 生效" "c.execute('select label from nodes where id=$IDL').fetchone()[0]=='noise'"
$M label "$IDL" anchor >/dev/null
chk "手动 anchor 带上保护位" "c.execute('select pinned from nodes where id=$IDL').fetchone()[0]==1"
$M label "$IDL" clear >/dev/null
chk "clear 只清标签不动保护位" "c.execute('select label from nodes where id=$IDL').fetchone()[0] is None"

echo "[19] 事件层（SPEC §2.2 最小版）"
$M commit "转岗去做基础设施" --type fact --subject job.role --event 转岗 --ts "2026-08-01T10:00:00+08:00" -q >/dev/null
$M commit "转岗第一天，交接了三周" --type event --event 转岗 --ts "2026-08-01T18:00:00+08:00" -q >/dev/null
$M commit "两个月后又聊转岗，说比预想累" --type event --event 转岗 --ts "2026-10-05T18:00:00+08:00" -q >/dev/null
$M commit "同时期在装修厨房" --type event --event 装修 --ts "2026-09-10T18:00:00+08:00" -q >/dev/null
chk "event 已落库" "c.execute(\"select count(*) from nodes where event='转岗'\").fetchone()[0]==3"
ECTX=$($M context --budget 3000)
echo "$ECTX" | grep -q "转岗 08-01~10-05 3条" && { PASS=$((PASS+1)); echo "  ok   事件轴聚合出跨期区间"; } || { FAIL=$((FAIL+1)); echo "  FAIL 事件轴没聚合/区间不对"; }
echo "$ECTX" | grep -q "⟦转岗⟧" && { PASS=$((PASS+1)); echo "  ok   现状挂在事件下"; } || { FAIL=$((FAIL+1)); echo "  FAIL 现状没标事件"; }
EREC=$($M recall "转岗" --event 装修 --top 5)
echo "$EREC" | grep -q "转岗第一天" && { FAIL=$((FAIL+1)); echo "  FAIL --event 没剪枝（别的事件混进来了）"; } || { PASS=$((PASS+1)); echo "  ok   recall --event 先剪枝"; }
$M commit "事件名超长的库" --event "这是一个明显超过二十四个字符的极长事件标签测试用例名称" >/dev/null 2>&1 || true
chk "超长事件名没有入库" "c.execute(\"select count(*) from nodes where event like '%极长事件%'\").fetchone()[0]==0"

echo "[20] 老库升级不炸（缺列自动补，索引必须在补列之后建）"
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DROP INDEX IF EXISTS idx_ev")             # 模拟旧版本：连索引都没有
c.execute("ALTER TABLE nodes DROP COLUMN event")     # 模拟旧版本建的库
c.commit()
EOF
$M context --budget 500 >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "  ok   缺列的老库能打开"; } || { FAIL=$((FAIL+1)); echo "  FAIL 老库升级直接报错"; }
chk "event 列已补回" "\"event\" in [r[1] for r in c.execute(\"PRAGMA table_info(nodes)\")]"
chk "idx_ev 索引已建" "c.execute(\"select count(*) from sqlite_master where type='index' and name='idx_ev'\").fetchone()[0]==1"
echo "[21] 五档分区（SPEC §3/§4：时间单向降级，升级必须显式）"
$M commit "热区刚写的事实" --type fact --subject z.hot --importance 0.9 -q >/dev/null
$M commit "二十天前的温区事实" --type fact --subject z.warm --ts "2026-10-05T10:00:00+08:00" -q >/dev/null
$M commit "两百天前但重要：家人纪念日" --type fact --subject z.cold --importance 0.95 --ts "2026-04-01T10:00:00+08:00" -q >/dev/null
IDARC=$($M commit "两百天前不重要：随口一提的天气" --type fact --subject z.arc --ts "2026-04-02T10:00:00+08:00" -q | tail -1)
IDPIN=$($M commit "两百天前的保护位记忆" --type fact --subject z.pin --pin --ts "2026-04-03T10:00:00+08:00" -q | tail -1)
$M zone --migrate >/dev/null
chk "热区仍在热区" "c.execute(\"select zone from nodes where subject='z.hot'\").fetchone()[0]=='hot'"
chk "20 天降成温区" "c.execute(\"select zone from nodes where subject='z.warm'\").fetchone()[0]=='warm'"
chk "200 天且重要 → 冷区（保护区）" "c.execute(\"select zone from nodes where subject='z.cold'\").fetchone()[0]=='cold'"
chk "200 天不重要 → 归档区" "c.execute(\"select zone from nodes where subject='z.arc'\").fetchone()[0]=='archive'"
chk "保护位把下限卡在冷区，不进归档" "c.execute(\"select zone from nodes where id=$IDPIN\").fetchone()[0]=='cold'"
ZM1=$($M zone --migrate)
echo "$ZM1" | grep -q '"migrated": 0' && { PASS=$((PASS+1)); echo "  ok   migrate 幂等（重跑 0 变动）"; } || { FAIL=$((FAIL+1)); echo "  FAIL migrate 不幂等"; }
$M zone $IDARC --set hot >/dev/null
chk "显式升级能回热区" "c.execute(\"select zone from nodes where id=$IDARC\").fetchone()[0]=='hot'"
$M zone --migrate >/dev/null
$M recall "随口一提的天气" --top 1 >/dev/null
$M recall "随口一提的天气" --top 1 >/dev/null
$M recall "随口一提的天气" --top 1 >/dev/null
$M zone --migrate >/dev/null
chk "被反复调用也不能升区（铁律二：热度不是裁判）" "c.execute(\"select zone from nodes where id=$IDARC\").fetchone()[0]=='archive'"
ZCTX=$($M context --budget 3000)
echo "$ZCTX" | grep -q "冷区/归档 .* 条未加载" && { PASS=$((PASS+1)); echo "  ok   冷/归档未加载必须明说"; } || { FAIL=$((FAIL+1)); echo "  FAIL 冷区被静默隐藏"; }
echo "$ZCTX" | grep -q "家人纪念日" && { FAIL=$((FAIL+1)); echo "  FAIL 冷区不该默认进上下文"; } || { PASS=$((PASS+1)); echo "  ok   冷区默认不占上下文"; }
ZX=$($M recall "保护位记忆" --zone cold --top 3)
echo "$ZX" | grep -q "保护位记忆" && { PASS=$((PASS+1)); echo "  ok   recall --zone cold 显式可查"; } || { FAIL=$((FAIL+1)); echo "  FAIL --zone 过滤失效"; }
MZ=$($M stats)
echo "$MZ" | grep -q '"by_zone"' && { PASS=$((PASS+1)); echo "  ok   stats 有分区分布"; } || { FAIL=$((FAIL+1)); echo "  FAIL stats 缺 by_zone"; }

echo "[22] 老库补 zone/importance 列并按时间回填"
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("ALTER TABLE nodes DROP COLUMN zone")
c.execute("ALTER TABLE nodes DROP COLUMN importance")
c.commit()
EOF
$M context --budget 3000 >/dev/null 2>&1 && { PASS=$((PASS+1)); echo "  ok   缺 zone 列的老库能打开"; } || { FAIL=$((FAIL+1)); echo "  FAIL 老库缺 zone 直接报错"; }
chk "zone 列已补回" "\"zone\" in [r[1] for r in c.execute(\"PRAGMA table_info(nodes)\")]"
chk "补列后不是全 hot（已按时间回填）" "c.execute(\"select count(*) from nodes where zone!='hot'\").fetchone()[0]>0"
echo "[23] 墓碑区：删除两段式（墓碑 → 冷却 → 真删）"
TBSEC=$($M commit "临时密码是 9999" --type event --subject tb.secret -q | tail -1)
TBADDR=$("$PY" - "$MEMTREE_DB" "$TBSEC" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --addr "$TBADDR" --reason 隐私 >/dev/null
chk "进墓碑区：zone=tombstone 且正文还在（没删）" "c.execute(\"select n.zone,b.hot,length(b.content) from nodes n join blobs b on n.addr=b.addr where n.id=$TBSEC\").fetchone()[:2]==('tombstone',1)"
chk "墓碑有冷却到期时间戳" "c.execute(\"select tombstoned_at from nodes where id=$TBSEC\").fetchone()[0] is not None"
chk "删除理由被记下（删完也能审计）" "c.execute(\"select purge_reason from nodes where id=$TBSEC\").fetchone()[0]=='隐私'"
TCTX=$($M context --budget 3000)
echo "$TCTX" | grep -q "9999" && { FAIL=$((FAIL+1)); echo "  FAIL 墓碑正文泄漏进上下文"; } || { PASS=$((PASS+1)); echo "  ok   墓碑区不进上下文"; }
echo "$TCTX" | grep -q "墓碑区 .* 条已受理删除" && { PASS=$((PASS+1)); echo "  ok   墓碑区条数必须明说"; } || { FAIL=$((FAIL+1)); echo "  FAIL 墓碑区被静默隐藏"; }
echo "$TCTX" | grep -q "未加载 -" && { FAIL=$((FAIL+1)); echo "  FAIL 冷区计数算成负数"; } || { PASS=$((PASS+1)); echo "  ok   冷区计数不为负（墓碑与冷区分开算）"; }
$M recall "临时密码" --json | grep -q '"zone": "tombstone"' && { FAIL=$((FAIL+1)); echo "  FAIL 墓碑默认还能被检索到"; } || { PASS=$((PASS+1)); echo "  ok   墓碑默认检索不到"; }
$M recall "临时密码" --zone tombstone --json | grep -q '"zone": "tombstone"' && { PASS=$((PASS+1)); echo "  ok   recall --zone tombstone 显式可查"; } || { FAIL=$((FAIL+1)); echo "  FAIL 墓碑区查不到"; }
$M purge --list | grep -q '"days_left"' && { PASS=$((PASS+1)); echo "  ok   purge --list 报剩余冷却天数"; } || { FAIL=$((FAIL+1)); echo "  FAIL --list 缺 days_left"; }
TAP=$($M purge --apply)
echo "$TAP" | grep -q '"due": 0' && { PASS=$((PASS+1)); echo "  ok   冷却未满不真删"; } || { FAIL=$((FAIL+1)); echo "  FAIL 冷却期被跳过"; }
chk "冷却未满正文仍在" "c.execute(\"select length(b.content) from nodes n join blobs b on n.addr=b.addr where n.id=$TBSEC\").fetchone()[0]>0"
$M purge --restore $TBSEC >/dev/null
chk "冷却期内可撤回，分区按时间重算（回 hot）" "c.execute(\"select zone from nodes where id=$TBSEC\").fetchone()[0]=='hot'"
TBPIN=$("$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where pinned=1 limit 1").fetchone()[0])
EOF
)
$M purge --addr "$TBPIN" >/dev/null 2>&1; [ $? -ne 0 ] && { PASS=$((PASS+1)); echo "  ok   保护位拒绝 purge"; } || { FAIL=$((FAIL+1)); echo "  FAIL 保护位被硬删了"; }
$M zone $TBSEC --set tombstone >/dev/null 2>&1; [ $? -ne 0 ] && { PASS=$((PASS+1)); echo "  ok   墓碑区不能用 zone --set 进入"; } || { FAIL=$((FAIL+1)); echo "  FAIL 绕过 purge 进了墓碑区"; }
$M purge --addr "$TBADDR" --reason 隐私 >/dev/null
"$PY" - "$MEMTREE_DB" "$TBSEC" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set tombstoned_at=? where id=?", (time.time() - 8 * 86400, int(sys.argv[2])))
c.commit()
EOF
$M zone --migrate >/dev/null
chk "时间迁移不动墓碑（删除流程不是老化）" "c.execute(\"select zone from nodes where id=$TBSEC\").fetchone()[0]=='tombstone'"
$M purge --apply >/dev/null
chk "冷却期满 → 真删：正文清空、只留悬空地址" "c.execute(\"select b.hot,b.content from nodes n join blobs b on n.addr=b.addr where n.id=$TBSEC\").fetchone()[:2]==(2,'')"
TBNOW=$($M commit "错误信息：不该留的" --type fact --subject tb.err -q | tail -1)
$M purge --addr "$TBADDR" --now --reason 隐私 >/dev/null   # addr 已清空 → 无候选，不该删别人
TBN2=$("$PY" - "$MEMTREE_DB" "$TBNOW" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --addr "$TBN2" --now --reason 隐私 >/dev/null
chk "--now 跳过冷却，立即真删（隐私没有缓冲期）" "c.execute(\"select b.hot from nodes n join blobs b on n.addr=b.addr where n.id=$TBNOW\").fetchone()[0]==2"
chk "stats 报墓碑待删/到期数" "c.execute(\"select count(*) from nodes where zone='tombstone'\").fetchone()[0]>=2"

echo
echo "[24] 事件内细节梯度压缩（SPEC §5 ①：越新越细，结论必留）"
export MEMTREE_DB="$(mktemp -d)/mt_selftest3.db"
$M init >/dev/null
# E1：4 条细节（同一事件，越新越细）+ 4 条「再老也不能压」的结论
D1=$($M commit "E1 细节一 最早" --type event --event E1 --ts "2026-03-01T10:00:00+08:00" -q)
$M commit "E1 细节二" --type event --event E1 --ts "2026-03-02T10:00:00+08:00" -q >/dev/null
D3=$($M commit "E1 细节三" --type event --event E1 --ts "2026-03-03T10:00:00+08:00" -q)
D4=$($M commit "E1 细节四 最新必须原文留着" --type event --event E1 --ts "2026-03-04T10:00:00+08:00" -q)
CD=$($M commit "E1 结论 拍板用方案甲" --type decision --event E1 --ts "2026-02-01T10:00:00+08:00" -q)
CO=$($M commit "E1 结论 上线成功 延迟达标" --type event --event E1 --outcome 0.8 --ts "2026-02-02T10:00:00+08:00" -q)
CL=$($M commit "E1 老事但带情感标签" --type event --event E1 --ts "2026-02-03T10:00:00+08:00" -q)
CA=$($M commit "E1 老事但带锚点标签" --type event --event E1 --ts "2026-02-04T10:00:00+08:00" -q)
CP=$($M commit "E1 老事但有保护位" --type event --event E1 --ts "2026-02-05T10:00:00+08:00" -q)
# E2：另一个事件，同样 4 条细节 —— 用来证明两个事件不会被糊成一条 summary
$M commit "E2 细节一" --type event --event E2 --ts "2026-03-01T11:00:00+08:00" -q >/dev/null
$M commit "E2 细节二" --type event --event E2 --ts "2026-03-02T11:00:00+08:00" -q >/dev/null
$M commit "E2 细节三" --type event --event E2 --ts "2026-03-03T11:00:00+08:00" -q >/dev/null
$M commit "E2 细节四 最新" --type event --event E2 --ts "2026-03-04T11:00:00+08:00" -q >/dev/null
# label 用 CLI 打会连带把保护位置 1（就绕过了 is_conclusion 的 label 分支），
# 所以这里直接落 label、清保护位 —— 要验的是「label=anchor/emotional 也算结论」这条判据本身。
"$PY" - "$MEMTREE_DB" "$CL" "$CA" "$CP" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set label='emotional', pinned=0 where id=?", (int(sys.argv[2]),))
c.execute("update nodes set label='anchor',    pinned=0 where id=?", (int(sys.argv[3]),))
c.execute("update nodes set pinned=1 where id=?", (int(sys.argv[4]),))
c.commit()
EOF
# 分支 head 本身不进候选池（正在写的这条不能被压走），所以先落一条「今天」的进展把 head 挪开
$M commit "当前进展" --type event -q >/dev/null
COUT=$($M compress --days 1 --min-count 3)
chk "同一事件里更老的 3 条细节被归档" "c.execute(\"select count(*) from nodes where event='E1' and type!='summary' and status='archived'\").fetchone()[0]==3"
chk "归档的细节 rolled_into 指向本事件的 summary" "c.execute(\"select rolled_into from nodes where id=$D1\").fetchone()[0]==c.execute(\"select id from nodes where type='summary' and event='E1'\").fetchone()[0]"
chk "被压细节的正文转冷 hot=0（不是删了）" "c.execute(\"select b.hot from nodes n join blobs b on n.addr=b.addr where n.id=$D3\").fetchone()[0]==0"
chk "同事件最新的 1 条细节保持 active" "c.execute(\"select status from nodes where id=$D4\").fetchone()[0]=='active'"
chk "保留细节的正文逐字原样" "c.execute(\"select b.content from nodes n join blobs b on n.addr=b.addr where n.id=$D4\").fetchone()[0]=='E1 细节四 最新必须原文留着'"
chk "summary 带着原事件标签 E1（事件轴不断）" "c.execute(\"select count(*) from nodes where type='summary' and event='E1'\").fetchone()[0]==1"
chk "summary 正文写明压了几条" "c.execute(\"select b.content from nodes n join blobs b on n.addr=b.addr where n.type='summary' and n.event='E1'\").fetchone()[0].startswith('[压缩3条]')"
chk "两个事件各自成条，没被合并成一条 summary" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==2 and c.execute(\"select count(*) from nodes where type='summary' and event='E2'\").fetchone()[0]==1"
chk "结论 type=decision 再老也 active" "c.execute(\"select status from nodes where id=$CD\").fetchone()[0]=='active'"
chk "结论 outcome!=0 再老也 active" "c.execute(\"select status from nodes where id=$CO\").fetchone()[0]=='active'"
chk "label=emotional 的旧事也是结论" "c.execute(\"select status from nodes where id=$CL\").fetchone()[0]=='active'"
chk "label=anchor 的旧事也是结论" "c.execute(\"select status from nodes where id=$CA\").fetchone()[0]=='active'"
chk "保护位的旧事根本没进候选池" "c.execute(\"select status from nodes where id=$CP\").fetchone()[0]=='active'"
chk "结论一条都没被卷进 summary" "c.execute(\"select count(*) from nodes where id in ($CD,$CO,$CL,$CA) and rolled_into is not null\").fetchone()[0]==0"
echo "$COUT" | grep -q '"conclusions_preserved"' && { PASS=$((PASS+1)); echo "  ok   输出 JSON 有 conclusions_preserved"; } || { FAIL=$((FAIL+1)); echo "  FAIL 输出缺 conclusions_preserved"; }
CPL=$(echo "$COUT" | "$PY" -c "import json,sys;print(','.join(map(str,sorted(json.load(sys.stdin)['conclusions_preserved']))))")
[ "$CPL" = "$CD,$CO,$CL,$CA" ] && { PASS=$((PASS+1)); echo "  ok   conclusions_preserved 正好是那 4 条结论"; } || { FAIL=$((FAIL+1)); echo "  FAIL conclusions_preserved=[$CPL]"; }
echo "$COUT" | grep -q '"compressed": 6' && { PASS=$((PASS+1)); echo "  ok   只压了细节 6 条（E1 3 + E2 3）"; } || { FAIL=$((FAIL+1)); echo "  FAIL compressed 计数不对"; }
# --keep-detail 0：显式要求退化回「全压」，同事件一条细节都不留
for i in 1 2 3; do $M commit "E3 细节$i" --type event --event E3 --ts "2026-03-0${i}T12:00:00+08:00" -q >/dev/null; done
$M commit "当前进展" --type event -q >/dev/null
$M compress --days 1 --min-count 3 --keep-detail 0 >/dev/null
chk "--keep-detail 0 时退化为全压（E3 无 active 细节，只剩 summary）" "c.execute(\"select count(*) from nodes where event='E3' and type!='summary' and status='active'\").fetchone()[0]==0 and c.execute(\"select count(*) from nodes where event='E3' and type!='summary'\").fetchone()[0]==3"
chk "--keep-detail 0 仍各事件各一条 summary" "c.execute(\"select count(*) from nodes where type='summary' and event='E3'\").fetchone()[0]==1"
chk "第二轮压缩不碰上一轮留下的最新细节" "c.execute(\"select status from nodes where id=$D4\").fetchone()[0]=='active'"

echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
