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
TF23STAT=$(mktemp)
$M stats >"$TF23STAT"
SPEND=$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); print(d["tombstone"]["pending"])' "$TF23STAT")
DPEND=$($PY -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("select count(*) from nodes where zone=\"tombstone\"").fetchone()[0])' "$MEMTREE_DB")
chk "stats 报墓碑待删（与库内实际 pending 一致）" "'$SPEND'=='$DPEND'"
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert {"pending","due"} <= set(d["tombstone"])' "$TF23STAT" && { PASS=$((PASS+1)); echo "  ok   stats 同时报到期数（due 键存在）"; } || { FAIL=$((FAIL+1)); echo "  FAIL stats 缺 tombstone.due"; }

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

echo
echo "[25] 删除路径加固（保护位 / 共享地址 / pin 墓碑）"
# 契约：A 抹正文前先查引用计数（除墓碑区外任何 zone 都算活引用，含 archived/superseded）；
# B --apply 候选必须 pinned=0；C pin 墓碑报错退出；D --apply 报 skipped_pinned/skipped_shared；
# E --now 同样受 A 约束。这里全部直连临时库造历史状态，不靠实现自觉。
jget() { "$PY" -c "import json,sys;d=json.load(sys.stdin);print(d.get('$1',''))"; }
gechk() {  # gechk <实际值> <下限> <描述>
  if [ -n "$1" ] && [ "$1" -ge "$2" ] 2>/dev/null; then
    PASS=$((PASS+1)); echo "  ok   $3"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $3 (实际='$1')"
  fi
}
addr_of_id() { "$PY" - "$MEMTREE_DB" "$1" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
}
aged() { "$PY" - "$MEMTREE_DB" "$1" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set tombstoned_at=? where id=?", (time.time() - 8 * 86400, int(sys.argv[2])))
c.commit()
EOF
}

# ---------- (1) 共享地址：两条活节点共用一份正文，删一条不能带走另一条 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest4.db"
$M init >/dev/null
S1=$($M commit "共享正文：预算批下来了" --type fact --subject sh.a --source stated -q | tail -1)
S2=$($M commit "共享正文：预算批下来了" --type fact --subject sh.b --source inferred -q | tail -1)
$M commit "预算后来被砍了" --type fact --subject sh.a -q >/dev/null   # 让 S1 变 superseded
chk "两条不同 --source 的节点共用同一地址（内容寻址真的去重了）" "c.execute(\"select count(distinct addr) from nodes where id in ($S1,$S2)\").fetchone()[0]==1"
SHADDR=$(addr_of_id "$S1")
$M purge >/dev/null
chk "批量 purge 只把被覆盖的 S1 送进墓碑区，S2 不受牵连" "c.execute(\"select zone from nodes where id=$S1\").fetchone()[0]=='tombstone' and c.execute(\"select zone from nodes where id=$S2\").fetchone()[0]!='tombstone'"
aged "$S1"
SOUT=$($M purge --apply)
chk "共享地址仍有活引用 → 正文没被抹（这是不可恢复的数据丢失）" "c.execute(\"select length(content) from blobs where addr=?\", ('$SHADDR',)).fetchone()[0]>0"
$M verify "$SHADDR" | grep -q '"sha256_ok": true' && { PASS=$((PASS+1)); echo "  ok   共享地址正文完好（sha256 未损）"; } || { FAIL=$((FAIL+1)); echo "  FAIL 共享地址正文被抹，sha256 校验崩了"; }
SKS=$(echo "$SOUT" | jget skipped_shared)
gechk "$SKS" 1 "输出 skipped_shared ≥ 1（D：共享地址不抹正文要能看见）"
SNOTE=$(echo "$SOUT" | jget note)
echo "$SNOTE" | grep -q "保护位" && echo "$SNOTE" | grep -q "引用" && { PASS=$((PASS+1)); echo "  ok   note 说明「保护位/仍被引用的地址不抹正文」"; } || { FAIL=$((FAIL+1)); echo "  FAIL note 没说清为什么不抹（note='$SNOTE'）"; }
"$PY" - "$MEMTREE_DB" "$S2" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set status='superseded' where id=?", (int(sys.argv[2]),))
c.commit()
EOF
SOUT2=$($M purge --apply)
chk "superseded 的活引用同样保护正文（转冷不等于删除）" "c.execute(\"select length(content) from blobs where addr=?\", ('$SHADDR',)).fetchone()[0]>0"

# ---------- (2) 保护位：墓碑里的 pinned=1，冷却期满也不能抹 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest5.db"
$M init >/dev/null
P1=$($M commit "保护位正文：她生日 3 月 12 日" --type fact --subject pin.a -q | tail -1)
$M commit "覆盖 pin.a" --type fact --subject pin.a -q >/dev/null
$M purge >/dev/null
"$PY" - "$MEMTREE_DB" "$P1" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set pinned=1, tombstoned_at=? where id=?", (time.time() - 8 * 86400, int(sys.argv[2])))
c.commit()
EOF
chk "造出历史状态：墓碑 + 保护位 + 已过冷却期" "c.execute(\"select zone,pinned from nodes where id=$P1\").fetchone()[:2]==('tombstone',1)"
POUT=$($M purge --apply)
chk "墓碑里的保护位在冷却期满后依然挡删（正文还在）" "c.execute(\"select length(b.content) from nodes n join blobs b on n.addr=b.addr where n.id=$P1\").fetchone()[0]>0"
PKP=$(echo "$POUT" | jget skipped_pinned)
gechk "$PKP" 1 "输出 skipped_pinned ≥ 1（手滑删了还能靠保护位救回来）"

# ---------- (3) pin 墓碑必须报错：保护位在墓碑里没有效力，不能假装打得进去 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest6.db"
$M init >/dev/null
T1=$($M commit "临时口令 4321" --type event --subject pin.err -q | tail -1)
TADDR=$(addr_of_id "$T1")
$M purge --addr "$TADDR" --reason 隐私 >/dev/null
PERR=$($M pin $T1 2>&1); PRC=$?
[ "$PRC" -ne 0 ] && { PASS=$((PASS+1)); echo "  ok   pin 墓碑退出码非 0（当前 $PRC）"; } || { FAIL=$((FAIL+1)); echo "  FAIL pin 墓碑静默成功（退出码 0）"; }
echo "$PERR" | grep -q "墓碑" && { PASS=$((PASS+1)); echo "  ok   报错提示是墓碑区"; } || { FAIL=$((FAIL+1)); echo "  FAIL 报错里没提墓碑（stderr='$PERR'）"; }
chk "pin 失败后库里 pinned 仍是 0（没有留下假保护位）" "c.execute(\"select pinned from nodes where id=$T1\").fetchone()[0]==0"

# ---------- (4) 正常删除回归：无共享无保护的墓碑到期，正文确实要抹 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest7.db"
$M init >/dev/null
Z1=$($M commit "单独正文：只有这一条引用" --type fact --subject solo.a -q | tail -1)
$M commit "覆盖 solo.a" --type fact --subject solo.a -q >/dev/null
$M purge >/dev/null
aged "$Z1"
ZOUT=$($M purge --apply)
chk "正常删除回归：无共享无保护，冷却期满正文确实被抹、hot=2" "c.execute(\"select hot,content from blobs where addr=(select addr from nodes where id=$Z1)\").fetchone()[:2]==(2,'')"
ZKP=$(echo "$ZOUT" | jget skipped_pinned); ZKS=$(echo "$ZOUT" | jget skipped_shared)
chk "该删的没被拦住（skipped_pinned/skipped_shared 都是 0）" "'$ZKP'=='0' and '$ZKS'=='0'"
ZP=$(echo "$ZOUT" | jget purged)
gechk "$ZP" 1 "purged 计数 ≥ 1（删除路径没被整条挡死）"

# ---------- (5) 转冷节点（status=archived、hot=0）仍算活引用 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest8.db"
$M init >/dev/null
R1=$($M commit "共享正文：压掉的也要能回溯" --type fact --subject cold.a -q | tail -1)
R2=$($M commit "共享正文：压掉的也要能回溯" --type fact --subject cold.b -q | tail -1)
$M commit "覆盖 cold.b" --type fact --subject cold.b -q >/dev/null
$M purge >/dev/null
chk "批量 purge 只把 R2 送进墓碑区，R1 还活着" "c.execute(\"select zone from nodes where id=$R1\").fetchone()[0]!='tombstone' and c.execute(\"select zone from nodes where id=$R2\").fetchone()[0]=='tombstone'"
"$PY" - "$MEMTREE_DB" "$R1" "$R2" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
r1, r2 = int(sys.argv[2]), int(sys.argv[3])
c.execute("update nodes set status='archived', zone='cold' where id=?", (r1,))
c.execute("update blobs set hot=0 where addr=(select addr from nodes where id=?)", (r1,))
c.execute("update nodes set tombstoned_at=? where id=?", (time.time() - 8 * 86400, r2))
c.commit()
EOF
chk "造出历史状态：R1 已转冷归档（hot=0），R2 墓碑到期" "c.execute(\"select status,zone from nodes where id=$R1\").fetchone()[:2]==('archived','cold')"
CLADDR=$(addr_of_id "$R1")
ROUT=$($M purge --apply)
chk "转冷/归档节点仍算活引用 → 正文没被抹（回溯时还要读）" "c.execute(\"select length(content) from blobs where addr=?\", ('$CLADDR',)).fetchone()[0]>0"
RKS=$(echo "$ROUT" | jget skipped_shared)
gechk "$RKS" 1 "转冷引用也算 skipped_shared ≥ 1"

# ---------- (6) --now：跳过冷却不等于跳过引用计数 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest9.db"
$M init >/dev/null
N1=$($M commit "共享正文：隐私场景" --type fact --subject now.a --source stated -q | tail -1)
N2=$($M commit "共享正文：隐私场景" --type fact --subject now.b --source inferred -q | tail -1)
$M commit "覆盖 now.a" --type fact --subject now.a -q >/dev/null
NADDR=$(addr_of_id "$N1")
$M purge --now --reason 隐私 >/dev/null
chk "--now 确实把 N1 送进墓碑区（没整条跳掉）" "c.execute(\"select zone from nodes where id=$N1\").fetchone()[0]=='tombstone'"
chk "--now 也查引用计数：N2 还活着就不抹正文" "c.execute(\"select length(content) from blobs where addr=?\", ('$NADDR',)).fetchone()[0]>0"
U1=$($M commit "唯一引用：错误信息" --type fact --subject now.c -q | tail -1)
$M commit "覆盖 now.c" --type fact --subject now.c -q >/dev/null
$M purge --now --reason 隐私 >/dev/null
chk "--now 唯一引用照删（隐私没有缓冲期）" "c.execute(\"select hot,content from blobs where addr=(select addr from nodes where id=$U1)\").fetchone()[:2]==(2,'')"


# ---------- (7) 契约 F：该 addr 上有 pinned 节点（墓碑区里的也算）就不抹 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest10.db"
$M init >/dev/null
F1=$($M commit "共享正文：保护位落在墓碑里" --type fact --subject f.a --source stated -q | tail -1)
F2=$($M commit "共享正文：保护位落在墓碑里" --type fact --subject f.b --source inferred -q | tail -1)
$M commit "覆盖 f.a" --type fact --subject f.a -q >/dev/null
$M commit "覆盖 f.b" --type fact --subject f.b -q >/dev/null
$M purge >/dev/null
chk "F 前置：两条共用同一地址的节点都进了墓碑区（墓碑外已无活引用）" "c.execute(\"select count(*) from nodes where id in ($F1,$F2) and zone='tombstone'\").fetchone()[0]==2 and c.execute(\"select count(distinct addr) from nodes where id in ($F1,$F2)\").fetchone()[0]==1"
FADDR=$(addr_of_id "$F1")
"$PY" - "$MEMTREE_DB" "$F1" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set pinned=1 where id=?", (int(sys.argv[2]),))
c.execute("update nodes set tombstoned_at=? where zone='tombstone'", (time.time() - 8 * 86400,))
c.commit()
EOF
chk "F 前置：一条墓碑 pinned=1，两条都过冷却期" "c.execute(\"select count(*) from nodes where id in ($F1,$F2) and tombstoned_at is not null\").fetchone()[0]==2 and c.execute(\"select pinned from nodes where id=$F1\").fetchone()[0]==1"
FOUT=$($M purge --apply)
chk "F1：墓碑外无活引用，但地址上有 pinned → 正文仍在" "c.execute(\"select length(content) from blobs where addr=?\", ('$FADDR',)).fetchone()[0]>0"
$M verify "$FADDR" | grep -q '"sha256_ok": true' && { PASS=$((PASS+1)); echo "  ok   F1：正文完好（sha256 未损）"; } || { FAIL=$((FAIL+1)); echo "  FAIL F1：正文被抹，sha256 校验崩了"; }
FKP=$(echo "$FOUT" | jget skipped_pinned)
gechk "$FKP" 1 "F1：保护位优先计入 skipped_pinned（同 addr 不重复计数）"
chk "F1：判定按 addr 走 —— 同一地址的两条墓碑一条都没被抹" "c.execute(\"select count(*) from nodes n join blobs b on n.addr=b.addr where n.id in ($F1,$F2) and length(b.content)>0\").fetchone()[0]==2"
"$PY" - "$MEMTREE_DB" "$F1" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set pinned=0 where id=?", (int(sys.argv[2]),))
c.commit()
EOF
FOUT2=$($M purge --apply)
chk "F2 回归：保护位撤掉且墓碑外无活引用 → 正文确实被抹、hot=2" "c.execute(\"select hot,content from blobs where addr=?\", ('$FADDR',)).fetchone()[:2]==(2,'')"
FKP2=$(echo "$FOUT2" | jget skipped_pinned)
chk "F2 回归：这次 skipped_pinned 是 0（F 没把删除路径挡死）" "'$FKP2'=='0'"

# ---------- (8) 计数归属：保护位与活引用重叠时优先计 skipped_pinned（--now 路径） ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest11.db"
$M init >/dev/null
G1=$($M commit "共享正文：--now 也要看保护位" --type fact --subject g.a --source stated -q | tail -1)
G2=$($M commit "共享正文：--now 也要看保护位" --type fact --subject g.b --source inferred -q | tail -1)
GADDR=$(addr_of_id "$G1")
"$PY" - "$MEMTREE_DB" "$G1" "$G2" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set pinned=1 where id=?", (int(sys.argv[2]),))
c.execute("update nodes set status='superseded' where id=?", (int(sys.argv[3]),))
c.commit()
EOF
NOUT=$($M purge --now --reason 隐私)
chk "G 前置：--now 只把没保护位的那条送进墓碑" "c.execute(\"select zone from nodes where id=$G2\").fetchone()[0]=='tombstone' and c.execute(\"select zone from nodes where id=$G1\").fetchone()[0]!='tombstone'"
chk "保护位与活引用同时命中：正文仍在（--now 也不许带走）" "c.execute(\"select length(content) from blobs where addr=?\", ('$GADDR',)).fetchone()[0]>0"
NGKP=$(echo "$NOUT" | jget skipped_pinned)
NGKS=$(echo "$NOUT" | jget skipped_shared)
gechk "$NGKP" 1 "计数归属：--now 重叠时优先计 skipped_pinned"
chk "计数归属：--now 不重复计进 skipped_shared（这次是 0）" "'$NGKS'=='0'"

# ---------- (9) 计数归属：apply 路径重叠时同样优先计 skipped_pinned ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest12.db"
$M init >/dev/null
H1=$($M commit "共享正文：活引用与保护位撞一起" --type fact --subject h.a --source stated -q | tail -1)
H2=$($M commit "共享正文：活引用与保护位撞一起" --type fact --subject h.b --source inferred -q | tail -1)
$M commit "覆盖 h.b" --type fact --subject h.b -q >/dev/null
$M purge >/dev/null
HADDR=$(addr_of_id "$H1")
"$PY" - "$MEMTREE_DB" "$H1" "$H2" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set pinned=1 where id=?", (int(sys.argv[2]),))
c.execute("update nodes set tombstoned_at=? where id=?", (time.time() - 8 * 86400, int(sys.argv[3])))
c.commit()
EOF
HOUT=$($M purge --apply)
HKP=$(echo "$HOUT" | jget skipped_pinned)
HKS=$(echo "$HOUT" | jget skipped_shared)
gechk "$HKP" 1 "计数归属：apply 重叠时优先计 skipped_pinned"
chk "计数归属：apply 不重复计进 skipped_shared（这次是 0）" "'$HKS'=='0'"
chk "计数归属：正文仍活着（H1 活引用 + H2 墓碑保护位）" "c.execute(\"select length(content) from blobs where addr=?\", ('$HADDR',)).fetchone()[0]>0"

echo "[26] 批次三：recall --at 时点快照 / 未来条目不进现状"
# 契约 G1：--at T 是「T 那一刻的快照」——当时的现状按 t<=T 重算，T 之后才写的条目不得混进来。
# 契约 G2：t 在未来的条目进「未来」段、不进现状、不把真实现状压成「已废弃」；也不因 t 在未来而免疫压缩。
ochk() {  # ochk <描述> <输出文件> <python 表达式：out=全文, json=模块, cur=■现状区正文>
  if OUT_FILE="$2" "$PY" - "$MEMTREE_DB" "$3" <<'EOF'
import json, os, sys
expr = sys.argv[2]
out = open(os.environ["OUT_FILE"], encoding="utf-8", errors="replace").read()
def cur():
    # ■ 行尾的 (曾:…@日期) 是已废弃的旧正文，不能算进现状判定（不剥掉会假通过）
    return "".join(l.split("(曾:")[0] for l in out.splitlines() if l.startswith("\u25a0"))
sys.exit(0 if eval(expr, {"out": out, "json": json, "cur": cur}) else 1)
EOF
  then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"
  fi
}
TF=$(mktemp -d)

# ---------- G1：--at T 的时点快照 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest13.db"
$M init >/dev/null
A1=$($M commit "旧状态：住在杭州" --type fact --subject loc --ts 2025-01-01 -q | tail -1)
A2=$($M commit "新状态：搬到南京" --type fact --subject loc --ts 2025-06-01 -q | tail -1)
A3=$($M commit "新事实：换了工作" --type fact --subject job --ts 2025-06-01 -q | tail -1)
A4=$($M commit "古老状态：实习生" --type fact --subject role --ts 2024-01-01 -q | tail -1)
A5=$($M commit "后来状态：正式员工" --type fact --subject role --ts 2024-06-01 -q | tail -1)
chk "G1 前置：#A1 已被 #A2 覆盖（库里 superseded，t 分别 2025-01 / 2025-06）" "c.execute(\"select status from nodes where id=$A1\").fetchone()[0]=='superseded' and c.execute(\"select ts_iso from nodes where id=$A1\").fetchone()[0]=='2025-01-01' and c.execute(\"select ts_iso from nodes where id=$A2\").fetchone()[0]=='2025-06-01'"
# 查询按 subject 分组：多词跨主体查询会让冷门条目 se 掉到 0 被 hits>1e-9 滤掉，断言就会恒真/恒假
QLOC="住在杭州 搬到南京"
QROLE="实习生 正式员工"
QALL="住在杭州 搬到南京 换了工作 实习生 正式员工"
ATF="$TF/at.txt"; ROLEF="$TF/role.txt"; NOWF="$TF/now.txt"; ZEROF="$TF/zero.txt"; ZEROJ="$TF/zero.json"; ATJF="$TF/at.json"
$M recall "$QLOC" --at 2025-03-01 >"$ATF"
$M recall "$QROLE" --at 2025-03-01 >"$ROLEF"
$M recall "$QALL" --at 2023-01-01 >"$ZEROF"
$M recall "$QALL" --at 2023-01-01 --json >"$ZEROJ"
$M recall "$QLOC" --at 2025-03-01 --json >"$ATJF"
$M recall "$QLOC" >"$NOWF"
ochk "G1：T 之前已存在、T 之后才被覆盖的条目出现在 --at 2025-03-01 里" "$ATF" "'住在杭州' in out"
ochk "G1：该条目当时是现状（文本标记「当时现状」）" "$ATF" "'当时现状' in out"
ochk "G1：T 之后才写入的条目（搬到南京，同 subject）不出现" "$ATF" "'搬到南京' not in out"
ochk "G1：T 之后才写入的条目（换了工作，另一 subject）不出现" "$ATF" "'换了工作' not in out"
ochk "G1：T 之前就被覆盖的条目（实习生）不得当现状返回" "$ROLEF" "'实习生' not in out"
ochk "G1：T 之前已存在且未被覆盖的条目（正式员工）照常出现" "$ROLEF" "'正式员工' in out"
ochk "G1：--at 早于全部条目 → 无命中，不拿后写的冒充当时现状" "$ZEROF" "'无命中' in out"
ochk "G1 对照：不给 --at 时仍是当前语义（南京在、杭州不在）" "$NOWF" "'搬到南京' in out and '住在杭州' not in out"
ochk "G1：JSON 回显时点字段 t" "$ATJF" "json.loads(out)['t']=='2025-03-01'"
ochk "G1：JSON 的 as_of 必须等于传入值" "$ATJF" "json.loads(out).get('as_of')=='2025-03-01'"
ochk "G1：JSON 里该条 status 应为 active（当时它就是现状）" "$ATJF" "[h for h in json.loads(out)['hits'] if h['id']==$A1][0]['status']=='active'"
ochk "G1：JSON 里该条 content 是正文本身，不是「已转冷」占位" "$ATJF" "'住在杭州' in [h for h in json.loads(out)['hits'] if h['id']==$A1][0]['content']"

# ---------- G2：t 在未来的条目不许进现状 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest14.db"
$M init >/dev/null
P1=$($M commit "现在的状态：住在南京" --type fact --subject loc --ts 2025-06-01 -q | tail -1)
P2=$($M commit "未来计划：明年搬到苏州" --type fact --subject loc --ts 2030-06-01 -q | tail -1)
chk "G2 前置：#P2 的 t 在未来（2030-06-01）" "c.execute(\"select ts_iso from nodes where id=$P2\").fetchone()[0]=='2030-06-01'"
CTXF="$TF/ctx.txt"; FUTF="$TF/fut.txt"; FTNF="$TF/futnow.txt"; FEVF="$TF/futev.txt"; CPF="$TF/comp.json"
$M context --budget 4000 >"$CTXF"
$M recall "搬到苏州" --at 2029-01-01 >"$FUTF"
$M recall "住在南京" --at 2029-01-01 >"$FTNF"
ochk "G2：context 出现「未来」标记段（⏳）" "$CTXF" "'\u23f3' in out"
ochk "G2：■现状区不含未来条目正文（搬到苏州）" "$CTXF" "'搬到苏州' not in cur()"
ochk "G2：■现状区显示真实现状（住在南京），未被未来条目顶掉" "$CTXF" "'现在的状态：住在南京' in cur()"
ochk "G2：真实现状没被未来条目压成「(曾:…@日期)」已废弃" "$CTXF" "'(曾:现在的状态：住在南京' not in out"
ochk "G2：真实现状即使不进 ■ 也不许静默消失（输出里要能看到正文）" "$CTXF" "'住在南京' in out"
ochk "G2：recall --at 2029-01-01 不把未来条目（2030 的搬到苏州）当当时现状" "$FUTF" "'搬到苏州' not in out"
ochk "G2：recall --at 2029-01-01 仍给出当时的真实现状（住在南京）" "$FTNF" "'住在南京' in out"
E1=$($M commit "未来事件：搬家那天" --type event --event 搬家 --ts 2030-06-01 -q | tail -1)
E2=$($M commit "未来事件：搬家改到次日" --type event --event 搬家 --ts 2030-06-02 -q | tail -1)
$M recall "搬家那天 搬家改到次日" --at 2029-01-01 >"$FEVF"
ochk "G2：recall --at 2029-01-01（早于未来事件）不返回未来事件" "$FEVF" "'搬家那天' not in out and '搬家改到次日' not in out"
$M compress --before 2031-01-01 --min-count 1 --keep-detail 0 >"$CPF"
chk "G2：t 在未来的事件不免疫压缩（非 HEAD 那条压成 archived 且有 rolled_into）" "c.execute(\"select status from nodes where id=$E1\").fetchone()[0]=='archived' and c.execute(\"select rolled_into from nodes where id=$E1\").fetchone()[0] is not None"
ochk "G2：compress 报 compressed ≥ 1（未来事件真被压了）" "$CPF" "json.loads(out)['compressed']>=1"

# ---------- as_of 口径自证：空手必须能区分为「那时还没有」 ----------
ochk "as_of：json 带 as_of_stats 四个键（active/not_yet/already_gone/unknown_timing）" "$ATJF" "all(k in json.loads(out)['as_of_stats'] for k in ('active','not_yet','already_gone','unknown_timing'))"
ochk "as_of：--at 早于全部条目 → hits 为空、not_yet>0（不是「查不到」）" "$ZEROJ" "json.loads(out)['hits']==[] and json.loads(out)['as_of_stats']['not_yet']>0 and json.loads(out)['as_of']=='2023-01-01'"

# ---------- 深回溯的噪声门：时间权重把 Σ 压到 1e-16 量级，不许静默空手 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest15.db"
$M init >/dev/null
O1=$($M commit "四年前的状态：在阿里上班" --type fact --subject job --ts 2016-06-01 -q | tail -1)
O2=$($M commit "今年换了工作：去了字节" --type fact --subject job --ts 2026-03-01 -q | tail -1)
chk "深回溯 前置：#O1 是 2016 年的老现状，已被 #O2（今年）覆盖、正文转冷" "c.execute(\"select status from nodes where id=$O1\").fetchone()[0]=='superseded' and c.execute(\"select gone_at from nodes where id=$O1\").fetchone()[0] is not None and c.execute(\"select ts_iso from nodes where id=$O1\").fetchone()[0]=='2016-06-01'"
DEEPF="$TF/deep.txt"; DEEPJ="$TF/deep.json"
$M recall "在阿里上班 四年前的状态" --at 2020-06-01 --mode and >"$DEEPF"
$M recall "在阿里上班 四年前的状态" --at 2020-06-01 --mode and --json >"$DEEPJ"
ochk "深回溯：4 年前的老现状在 --at 2020-06-01 里必须命中（Σ 被时间权重压小也不许空手）" "$DEEPF" "'在阿里上班' in out"
ochk "深回溯：该条当时是现状（「当时现状」标记）" "$DEEPF" "'当时现状' in out"
ochk "深回溯：命中项带 low_confidence / overlap 字段（键必须在），且按键语义重合判据 se 判定" "$DEEPJ" "('low_confidence' in [h for h in json.loads(out)['hits'] if '在阿里上班' in (h.get('content') or '')][0]) and ('overlap' in [h for h in json.loads(out)['hits'] if '在阿里上班' in (h.get('content') or '')][0]) and [h for h in json.loads(out)['hits'] if '在阿里上班' in (h.get('content') or '')][0]['sem']>0.5"

# ---------- 覆盖者在未来：真实现状要补回 ■现状，并标明此刻仍是现状 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest16.db"
$M init >/dev/null
X1=$($M commit "现在的状态：住在南京" --type pref --subject loc --ts 2025-06-01 -q | tail -1)
X2=$($M commit "未来计划：搬到苏州" --type pref --subject loc --ts 2030-06-01 -q | tail -1)
# 1900000000 ≈ 2030-03（epoch），用来确认 gone_at 落在未来；chk 的作用域里没有 time 模块
chk "补回 前置：#X1 被 #X2（未来）压成 superseded、gone_at 在未来 —— 库里它已不是 active" "c.execute(\"select status from nodes where id=$X1\").fetchone()[0]=='superseded' and c.execute(\"select gone_at from nodes where id=$X1\").fetchone()[0]>1900000000 and c.execute(\"select status from nodes where id=$X2\").fetchone()[0]=='active' and c.execute(\"select ts_iso from nodes where id=$X2\").fetchone()[0]=='2030-06-01'"
CTX16="$TF/ctx16.txt"; CTXJ16="$TF/ctx16.json"
$M context --budget 4000 >"$CTX16"
$M context --budget 4000 --json >"$CTXJ16"
ochk "补回：■现状区显示南京这句正文，不是「[地址 … 已转冷]」占位" "$CTX16" "'现在的状态：住在南京' in cur() and '[地址' not in cur()"
ochk "补回：■现状那一行带「(覆盖者在未来·此刻仍是现状)」" "$CTX16" "'(覆盖者在未来·此刻仍是现状)' in cur()"
ochk "补回：未来那条（搬到苏州）不得进 ■现状" "$CTX16" "'搬到苏州' not in cur()"
ochk "补回：全文有「⏳ 未来 1 条尚未发生」" "$CTX16" "'\u23f3 未来 1 条尚未发生' in out"
ochk "补回：context --json 的 total.future == 1" "$CTXJ16" "json.loads(out)['total']['future']==1"

echo "[27] 批次五+六：去重共用地址不许误伤活条目 + purge --gc 只回收孤儿正文"
TF27=$(mktemp -d)

# ---------- G1：共用同一内容地址时，活着的胜者不许被标成「已转冷」 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest17.db"
$M init >/dev/null
D1=$($M commit "住在南京" --type pref --subject loc -q | tail -1)
D2=$($M commit "住在南京" --type pref --subject loc -q | tail -1)
DADDR=$("$PY" -c "import sqlite3,os;print(sqlite3.connect(os.environ['MEMTREE_DB']).execute('select addr from nodes where id=' + str($D2)).fetchone()[0])")
chk "G1 前置：两条正文一字不差 → 共用同一内容地址，后者覆盖前者" "c.execute(\"select count(distinct addr) from nodes where id in ($D1,$D2)\").fetchone()[0]==1 and c.execute(\"select status from nodes where id=$D2\").fetchone()[0]=='active' and c.execute(\"select status from nodes where id=$D1\").fetchone()[0]=='superseded'"
chk "G1：该地址在库里仍是热正文（hot=1 且正文非空）—— 转冷按「还有没有活节点」判，不看地址" "c.execute(\"select hot from blobs where addr='$DADDR'\").fetchone()[0]==1 and c.execute(\"select length(content) from blobs where addr='$DADDR'\").fetchone()[0]>0"
SHOW2="$TF27/show2.txt"; $M show $D2 >"$SHOW2"
ochk "G1：show 胜者 #$D2 显示「在热库」+ 正文原文，不许出现「已转冷」" "$SHOW2" "'在热库' in out and '住在南京' in out and '已转冷' not in out"
VER2="$TF27/ver2.json"; $M verify "$DADDR" --show >"$VER2"
ochk "G1：verify --show 返回 hot==1、content 是原文、sha256 未损" "$VER2" "json.loads(out)['hot']==1 and json.loads(out)['content']=='住在南京' and json.loads(out)['sha256_ok']"

# 反向回归：别把转冷整个删了 —— 不共用地址的普通覆盖，败者仍要转冷
N1=$($M commit "旧状态：在杭州" --type pref --subject city2 -q | tail -1)
N2=$($M commit "新状态：在苏州" --type pref --subject city2 -q | tail -1)
chk "G1 反向回归：不共用地址的普通覆盖，败者照样转冷（hot=0）、胜者仍热（省空间机制还在）" "c.execute(\"select b.hot from nodes n join blobs b on b.addr=n.addr where n.id=$N1\").fetchone()[0]==0 and c.execute(\"select b.hot from nodes n join blobs b on b.addr=n.addr where n.id=$N2\").fetchone()[0]==1"
SHOWN1="$TF27/shown1.txt"; $M show $N1 >"$SHOWN1"
ochk "G1 反向回归：败者 #$N1 的 show 标记「正文: 已转冷」（回溯读 content 仍在，但热区确实没了）" "$SHOWN1" "'正文: 已转冷' in out and '正文: 在热库' not in out"

# 语义边界：zone=cold 但 status=active 的节点仍算现状 —— _cold_blob 按 status 判，不按 zone 判
H1=$($M commit "冷区边界：周会改到周四" --type event --subject cb --event 周会 --ts 2026-01-01 -q | tail -1)
H2=$($M commit "冷区边界：周会改到周四" --type event --subject cb --event 周会 --ts 2026-01-02 -q | tail -1)
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set zone='cold'")   # 分区降级到 cold，但状态仍是 active
c.commit()
EOF
$M compress --before 2026-06-01 --min-count 1 --keep-detail 0 >"$TF27/cmp27.json"
chk "G1 边界 前置：#$H1 被压缩成 archived、（同地址的）#$H2 仍 active 且都在 cold 区" "c.execute(\"select status from nodes where id=$H1\").fetchone()[0]=='archived' and c.execute(\"select status from nodes where id=$H2\").fetchone()[0]=='active' and c.execute(\"select zone from nodes where id=$H2\").fetchone()[0]=='cold' and c.execute(\"select count(distinct addr) from nodes where id in ($H1,$H2)\").fetchone()[0]==1"
chk "G1 边界：zone=cold 但 status=active 的节点照样保护正文（压掉同地址的另一条也不许转冷）" "c.execute(\"select hot from blobs where addr=(select addr from nodes where id=$H2)\").fetchone()[0]==1"
SHOWH="$TF27/showh.txt"; $M show $H2 >"$SHOWH"
ochk "G1 边界：cold 区的现状节点 show 仍是「在热库」+ 正文可读" "$SHOWH" "'在热库' in out and '冷区边界：周会改到周四' in out and '已转冷' not in out"

# ---------- G2：purge --gc 只回收全库无人引用的孤儿正文 ----------
export MEMTREE_DB="$(mktemp -d)/mt_selftest18.db"
$M init >/dev/null
# 造三种「不是孤儿」的引用者：转冷的历史节点、墓碑区节点、compress 压出的 archived 节点
$M commit "旧状态：在杭州" --type pref --subject a -q >/dev/null
$M commit "新状态：在南京" --type pref --subject a -q >/dev/null
GT=$($M commit "墓碑正文：临时密码" --type fact --subject t -q | tail -1)
GTADDR=$("$PY" -c "import sqlite3,os;print(sqlite3.connect(os.environ['MEMTREE_DB']).execute('select addr from nodes where id=' + str($GT)).fetchone()[0])")
$M purge --addr "$GTADDR" --reason 隐私 >/dev/null
for i in 1 2 3 4; do $M commit "开会第 $i 次：结论 $i" --type event --subject mtg27 --event 周会27 --ts 2026-01-0$i -q >/dev/null; done
$M compress --before 2026-06-01 --min-count 1 --keep-detail 0 >/dev/null
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into blobs(addr,content,nbytes,hot,created_at) values('orphan0001','没人要的孤儿正文',30,1,'2026-01-01')")
c.commit()
EOF
chk "G2 前置：手工插入的孤儿地址确实没有任何节点引用" "c.execute(\"select count(*) from blobs where addr='orphan0001'\").fetchone()[0]==1 and c.execute(\"select count(*) from nodes where addr='orphan0001'\").fetchone()[0]==0"
chk "G2 前置：库里同时存在三类合法引用者（转冷 history / 墓碑 / archived）" "c.execute(\"select count(*) from nodes where status='archived'\").fetchone()[0]>=1 and c.execute(\"select count(*) from nodes where zone='tombstone'\").fetchone()[0]==1 and c.execute(\"select count(*) from nodes n join blobs b on b.addr=n.addr where n.status='superseded' and b.hot=0\").fetchone()[0]>=1"
NB=$("$PY" -c "import sqlite3,os;print(sqlite3.connect(os.environ['MEMTREE_DB']).execute('select count(*) from nodes').fetchone()[0])")
$M stats >"$TF27/stats27.json"
ochk "G2：stats 的 blobs.orphans>=1（不跑 GC 也能看见可回收量）" "$TF27/stats27.json" "json.loads(out)['blobs']['orphans']>=1"
$M purge --gc --dry-run >"$TF27/gcdry.json"
ochk "G2：--dry-run 只报数：gc_removed==0 且 would_remove>=1" "$TF27/gcdry.json" "json.loads(out)['gc_removed']==0 and json.loads(out)['would_remove']>=1"
chk "G2：--dry-run 不许真删 —— 孤儿正文仍在库里" "c.execute(\"select count(*) from blobs where addr='orphan0001'\").fetchone()[0]==1"
$M purge --gc >"$TF27/gc1.json"
ochk "G2：purge --gc 返回 gc_removed==1" "$TF27/gc1.json" "json.loads(out)['gc_removed']==1"
chk "G2：孤儿正文真被删掉" "c.execute(\"select count(*) from blobs where addr='orphan0001'\").fetchone()[0]==0"
chk "G2 安全边界①：GC 只动 blobs 表 —— nodes 行数前后不变（$NB 行）" "c.execute(\"select count(*) from nodes\").fetchone()[0]==$NB"
chk "G2 安全边界②：墓碑区节点的正文不许被 GC 删（冷却期内还要能 --restore）" "c.execute(\"select count(*) from nodes n join blobs b on b.addr=n.addr where n.zone='tombstone' and length(b.content)>0\").fetchone()[0]==1"
chk "G2 安全边界③：compress 压出的 archived 节点（正文转冷 hot=0 但有节点引用）不许当孤儿" "c.execute(\"select count(*) from nodes n join blobs b on b.addr=n.addr where n.status='archived' and length(b.content)>0\").fetchone()[0]>=1"
$M purge --gc >"$TF27/gc2.json"
ochk "G2：再跑一次幂等 —— gc_removed==0" "$TF27/gc2.json" "json.loads(out)['gc_removed']==0"
$M purge --gc --apply >"$TF27/gcign.json"
ochk "G2：--gc 独占本次调用 —— 输出 ignored 含 apply、且 gc_removed==0" "$TF27/gcign.json" "'apply' in (json.loads(out).get('ignored') or []) and json.loads(out)['gc_removed']==0"
export MEMTREE_DB="$(mktemp -d)/mt_selftest19.db"
$M init >/dev/null
$M commit "干净库：一条正常记忆" --type fact --subject ok -q >/dev/null
$M purge --gc >"$TF27/gcnone.json"
ochk "G2 安全边界④：无孤儿库上跑 --gc 必须 gc_removed==0（不误伤活正文）" "$TF27/gcnone.json" "json.loads(out)['gc_removed']==0"
chk "G2 安全边界④：无孤儿库的活正文一条没少" "c.execute(\"select count(*) from blobs where hot=1\").fetchone()[0]>=1 and c.execute(\"select count(*) from nodes\").fetchone()[0]==1"

echo "[28] 契约 H：recall --at 下无 subject 条目（事件）按 gone_at 判「当时是否仍有效」"
TF28=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest20.db"
$M init >/dev/null
# 事件（无 subject）：E1 在 2026-06-01 失效（归档），E2 从不失效
E1=$($M commit "事件：年会定在三月" --type event --event 年会 --ts 2026-01-10 -q | tail -1)
E2=$($M commit "事件：团建定在十月" --type event --event 团建 --ts 2026-02-01 -q | tail -1)
# 现状类（带 subject）：用来断言契约 H 没把 [26] 的三态判定一起改坏
F1=$($M commit "旧状态：住在杭州" --type fact --subject loc28 --ts 2025-01-01 -q | tail -1)
F2=$($M commit "新状态：搬到南京" --type fact --subject loc28 --ts 2025-06-01 -q | tail -1)
GONE_E=$("$PY" -c 'import datetime;print(datetime.datetime(2026,6,1).timestamp())')
"$PY" - "$MEMTREE_DB" "$E1" "$GONE_E" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# 造历史状态：E1 在 2026-06-01 被归档（gone_at 记的是「离开现状/被压掉的时刻」）
c.execute("update nodes set status='archived', zone='archive', gone_at=? where id=?",
          (float(sys.argv[3]), int(sys.argv[2])))
c.commit()
EOF
chk "H 前置：#$E1 已失效（archived + gone_at=2026-06-01），#$E2 从未失效（gone_at 为空、active）" "c.execute(\"select status from nodes where id=$E1\").fetchone()[0]=='archived' and c.execute(\"select gone_at from nodes where id=$E1\").fetchone()[0] is not None and abs(c.execute(\"select gone_at from nodes where id=$E1\").fetchone()[0]-$GONE_E)<1 and c.execute(\"select gone_at from nodes where id=$E2\").fetchone()[0] is None and c.execute(\"select status from nodes where id=$E2\").fetchone()[0]=='active'"

# ---- H①：--at + 默认 status=auto，事件按 gone_at 判当时是否仍有效 ----
$M recall "年会定在三月" --at 2026-03-01 >"$TF28/e1_before.txt"
ochk "H①：失效前（--at 2026-03-01）事件 #$E1 照常查得到" "$TF28/e1_before.txt" "'年会定在三月' in out"
$M recall "年会定在三月" --at 2026-03-01 --json >"$TF28/e1_before.json"
ochk "H①：那一刻它还没失效 → events_gone==0 且 events_active>=1" "$TF28/e1_before.json" "json.loads(out)['as_of_stats']['events_gone']==0 and json.loads(out)['as_of_stats']['events_active']>=1"
$M recall "年会" --at 2026-08-01 >"$TF28/e1_after.txt"
ochk "H①：失效后（--at 2026-08-01）事件 #$E1 不返回" "$TF28/e1_after.txt" "'年会定在三月' not in out"
$M recall "年会" --at 2026-08-01 --json >"$TF28/e1_after.json"
ochk "H①：那一刻已失效 → hits 为空且 events_gone>=1" "$TF28/e1_after.json" "json.loads(out)['hits']==[] and json.loads(out)['as_of_stats']['events_gone']>=1"
$M recall "团建定在十月" --at 2026-03-01 >"$TF28/e2_a.txt"
ochk "H①：从未失效的 #$E2 在 --at 2026-03-01 查得到" "$TF28/e2_a.txt" "'团建定在十月' in out"
$M recall "团建定在十月" --at 2026-08-01 >"$TF28/e2_b.txt"
ochk "H①：从未失效的 #$E2 在 --at 2026-08-01 照样查得到（gone_at 为空不做时点判定）" "$TF28/e2_b.txt" "'团建定在十月' in out"

# ---- H④：events_active / events_gone 两个 int 键，为 0 也要在 ----
$M recall "年会定在三月" --at 2023-01-01 --json >"$TF28/zero.json"
ochk "H④：--at 早于全部条目时 events_active/events_gone 都在且都是 int（events_gone==0 也不许缺键、不许 null）" "$TF28/zero.json" "(lambda s: ('events_active' in s) and ('events_gone' in s) and type(s['events_active']) is int and type(s['events_gone']) is int and s['events_gone']==0)(json.loads(out)['as_of_stats'])"

# ---- H⑤：文本提示行逐字出现/不出现 ----
ochk "H⑤：events_gone>0 时追加逐字一行「（另有 1 条事件在那一刻已失效）」" "$TF28/e2_b.txt" "'（另有 1 条事件在那一刻已失效）' in out"
ochk "H⑤：events_gone==0 时不得出现这一行" "$TF28/e1_before.txt" "'条事件在那一刻已失效' not in out"
ochk "H⑤：无命中场景同样要把「藏了几条」说出来（不是静默空手）" "$TF28/e1_after.txt" "'(无命中)' in out and '（另有 1 条事件在那一刻已失效）' in out"

# ---- H②：显式 --status 保持旧行为（按当前 status 过滤，不做时点判断） ----
$M recall "年会定在三月" --at 2026-08-01 --status archived >"$TF28/exp_arch.txt"
ochk "H②：显式 --status archived 时旧行为不变 —— 那条 archived 事件照样返回" "$TF28/exp_arch.txt" "'年会定在三月' in out"
$M recall "年会定在三月" --at 2026-08-01 --status any >"$TF28/exp_any.txt"
ochk "H②：显式 --status any 时也不做时点判断" "$TF28/exp_any.txt" "'年会定在三月' in out"
$M recall "年会定在三月" --at 2026-08-01 --status archived --json >"$TF28/exp_arch.json"
ochk "H②：显式 --status 时 hits 里能看到该条（status_now 仍是 archived）" "$TF28/exp_arch.json" "any((h['content'] or '').find('年会定在三月')>=0 for h in json.loads(out)['hits'])"

# ---- H③：不带 --at 时行为与改动前一致 ----
$M recall "年会定在三月" >"$TF28/no_at_e1.txt"
ochk "H③：不带 --at → archived 事件不进 auto 结果（与改动前一致）" "$TF28/no_at_e1.txt" "'年会定在三月' not in out"
$M recall "团建定在十月" >"$TF28/no_at_e2.txt"
ochk "H③：不带 --at → 活事件照常命中" "$TF28/no_at_e2.txt" "'团建定在十月' in out"
$M recall "团建定在十月" --json >"$TF28/no_at.json"
ochk "H③：不带 --at 的 JSON 不出现 as_of_stats（时点统计只在回溯视角下给）" "$TF28/no_at.json" "'as_of_stats' not in json.loads(out)"

# ---- H⑥：反向断言 —— 带 subject 的现状三态判定不回退，hit 结构不加新键 ----
$M recall "住在杭州 搬到南京" --at 2025-03-01 >"$TF28/subj_0301.txt"
ochk "H⑥：带 subject 的 --at 现状快照仍然正确（2025-03 只有杭州，没有后来才写的南京）" "$TF28/subj_0301.txt" "'旧状态：住在杭州' in out and '搬到南京' not in out"
$M recall "搬到南京" --at 2025-08-01 >"$TF28/subj_0801.txt"
ochk "H⑥：覆盖发生后（--at 2025-08-01）现状换成南京" "$TF28/subj_0801.txt" "'新状态：搬到南京' in out"
ochk "H⑥：单条 hit 不加事件新键（events_active/events_gone 只在 as_of_stats 里）" "$TF28/e1_before.json" "not ({'events_active','events_gone'} & set(json.loads(out)['hits'][0].keys()))"

echo "[29] 契约 I：--at 下无 subject 条目（事件）不打现状标记（当时现状/当时已过时/不可当现状）"
TF29=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest21.db"
$M init >/dev/null
# 无 subject 的事件：#E1 一直有效；#E2 在 2026-06-01 失效（归档）
E1=$($M commit "年会定在三月" --type event --event 年会 --ts 2026-01-10 -q | tail -1)
E2=$($M commit "团建排在十月" --type event --event 团建 --ts 2026-02-01 -q | tail -1)
# 带 subject 的现状：#F1 被 #F2 覆盖 → 反向断言现状标记没被一起删干净
F1=$($M commit "旧状态：住在杭州" --type fact --subject loc29 --ts 2025-01-01 -q | tail -1)
F2=$($M commit "新状态：搬到南京" --type fact --subject loc29 --ts 2025-06-01 -q | tail -1)
GONE_E=$("$PY" -c 'import datetime;print(datetime.datetime(2026,6,1).timestamp())')
"$PY" - "$MEMTREE_DB" "$E2" "$GONE_E" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set status='archived', zone='archive', gone_at=? where id=?",
          (float(sys.argv[3]), int(sys.argv[2])))
c.commit()
EOF
chk "I 前置：#$E1 是 active 的无 subject 事件、#$E2 已失效（archived+gone_at）、#$F1 已被覆盖（superseded）" "c.execute(\"select status from nodes where id=$E1\").fetchone()[0]=='active' and c.execute(\"select subject from nodes where id=$E1\").fetchone()[0] is None and c.execute(\"select gone_at from nodes where id=$E2\").fetchone()[0] is not None and c.execute(\"select status from nodes where id=$F1\").fetchone()[0]=='superseded'"

# ---- 事件行在 --at 下：正文/事件名留着，现状标记一个字都不许有 ----
$M recall "年会定在三月" --at 2026-03-01 >"$TF29/ev_at.txt"
ochk "I①：--at 下事件行照样读得到正文（别把整行裁没了）" "$TF29/ev_at.txt" "'年会定在三月' in out"
ochk "I①：--at 下事件行不打「当时已过时」（它没有现状可过时）" "$TF29/ev_at.txt" "'当时已过时' not in out"
ochk "I①：--at 下事件行也不打「当时现状」" "$TF29/ev_at.txt" "'当时现状' not in out"
ochk "I①：--at 下事件行不带非回溯模式的「·不可当现状」后缀" "$TF29/ev_at.txt" "'不可当现状' not in out"
ochk "I①：事件行的 ⟦事件名⟧ 后缀仍在（标记去掉、信息不许少）" "$TF29/ev_at.txt" "'⟦年会⟧' in out"

# ---- 反向断言：带 subject 的现状标记不许被一起删干净 ----
$M recall "住在杭州" --at 2025-03-01 >"$TF29/sub_0301.txt"
ochk "I②：带 subject 且当时仍是现状 → 逐字「当时现状」仍在" "$TF29/sub_0301.txt" "'「当时现状」' in out and '旧状态：住在杭州' in out"
$M recall "住在杭州" --at 2025-08-01 --status any >"$TF29/sub_0801.txt"
ochk "I②：带 subject 且当时已被覆盖（--status any 才看得见旧行）→ 逐字「当时已过时」仍在" "$TF29/sub_0801.txt" "'「当时已过时」' in out and '「当时现状」' in out"

# ---- 不带 --at：事件行的状态后缀行为逐字不变 ----
$M recall "团建排在十月" --status any >"$TF29/ev_plain.txt"
ochk "I③：不带 --at 时事件行仍按当前 status 打「archived·不可当现状」，且不出现任何「当时…」标记" "$TF29/ev_plain.txt" "'「archived·不可当现状」' in out and '当时已过时' not in out and '当时现状' not in out"

# ---- JSON 结构不变：--at 与不带 --at 的 hit 键集合必须完全相同 ----
$M recall "年会定在三月" --json >"$TF29/ev_plain.json"
$M recall "年会定在三月" --at 2026-03-01 --json >"$TF29/ev_at.json"
KEYCMP=$("$PY" - "$TF29/ev_plain.json" "$TF29/ev_at.json" <<'EOF'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["hits"]
b = json.load(open(sys.argv[2], encoding="utf-8"))["hits"]
print(1 if a and b and sorted(a[0].keys()) == sorted(b[0].keys()) else 0)
EOF
)
chk "I④：--at 的 hit 键集合与不带 --at 完全相同（JSON 输出不变，不许偷偷加现状标记键）" "'$KEYCMP'=='1'"
ochk "I④：--at 的 hit 键集合钉死这 20 个键（往后加任何键都会红）" "$TF29/ev_at.json" "sorted(json.loads(out)['hits'][0].keys())==['addr','cold','content','content_cleared','content_kind','event','id','low_confidence','out','overlap','score','sem','status','status_now','subject','summarized_into','summary_of','time','ts','zone']"
ochk "I④：契约 H 不回退 —— --at 的 as_of_stats 仍给 events_active/events_gone 且都是 int" "$TF29/ev_at.json" "(lambda s: ('events_active' in s) and ('events_gone' in s) and type(s['events_active']) is int and type(s['events_gone']) is int)(json.loads(out)['as_of_stats'])"

# ---- 契约 H⑤ 与契约 I 不冲突：被 gone_at 藏掉时仍逐字报数 ----
$M recall "团建排在十月" --at 2026-08-01 >"$TF29/ev_gone.txt"
ochk "I⑤：事件被 gone_at 隐藏时提示行仍逐字出现，且该行不许被塞进现状标记" "$TF29/ev_gone.txt" "'（另有 1 条事件在那一刻已失效）' in out and '当时已过时' not in out"

# ---- 低置信（Σ=0 噪声）分支与 --at 同时使用 ----
$M recall "聚餐" --at 2026-03-01 >"$TF29/ev_lowconf.txt"
ochk "I⑥：--at 下低置信分支里的事件行同样一个字现状标记都没有（带 ⟦事件名⟧ 的行才判，非事件行照旧有标记）" "$TF29/ev_lowconf.txt" "(lambda ls: bool(ls) and not any(('当时已过时' in l) or ('当时现状' in l) or ('不可当现状' in l) for l in ls))([l for l in out.splitlines() if '⟦' in l])"
ochk "I⑥：这一跑确实落进了低置信分支，且带 subject 的行仍保留「当时现状」（对照，防止整库标记被删）" "$TF29/ev_lowconf.txt" "'(低置信)' in out and '「当时现状」' in out"

echo "[30] 契约 J：人格卡三槽预算 / 原子写 / --at 回看 / context 集成"
TF30=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest22.db"
PF="$MEMTREE_DB.persona.md"
card_has() { grep -c "$1" "$PF" 2>/dev/null | tail -1; }   # 卡文件里出现次数，文件不存在算 0
$M init >/dev/null
$M commit "她叫小满" --type anchor --subject id.name -q >/dev/null
$M commit "最近在做 memory-timeline" --type fact --subject work -q >/dev/null

# ---- J1：空卡 ----
$M persona show >"$TF30/empty.txt" 2>&1; SRC=$?
chk "J1：空卡 persona show 退出码为 0" "'$SRC'=='0'"
ochk "J1：空卡 persona show 打印 (卡为空)" "$TF30/empty.txt" "'(卡为空)' in out"
$M persona show --json >"$TF30/empty.json" 2>&1
ochk "J1：空卡 --json 三槽空数组 + est_tokens 0 + 预算 800/300/350/150（契约固定值）" "$TF30/empty.json" "(lambda d: d['slots']['hard']==[] and d['slots']['soft']==[] and d['slots']['var']==[] and d['est_tokens']==0 and d['total_budget']==800 and d['slot_budgets']=={'hard':300,'soft':350,'var':150} and d['path'].endswith('.persona.md'))(json.loads(out))"
$M context --budget 3000 >"$TF30/ctx_empty.txt"
ochk "J1：卡为空时不得出现 ⚓人格 内容行（图例符号不算卡内容）" "$TF30/ctx_empty.txt" "not any(l.startswith('⚓人格·') for l in out.splitlines())"

# ---- J2：硬槽必须 --force ----
$M persona set "称呼用户为老大" --slot hard >"$TF30/hard_reject.txt" 2>&1; HRC=$?
chk "J2：硬槽不带 --force 必须拒绝（非 0 退出，契约要求 2）" "'$HRC'!='0'"
ochk "J2：拒绝时说清为什么 —— 提示需要 --force 防人格漂移" "$TF30/hard_reject.txt" "('force' in out) and ('硬槽' in out)"
HAS_HARD=$(card_has "称呼用户为老大"); HAS_HARD=${HAS_HARD:-0}
chk "J2：拒绝时卡文件里不许出现该条" "'$HAS_HARD'=='0'"
chk "J2：拒绝时 persona_log 里没有 hard 的 add 记录" "c.execute(\"select count(*) from persona_log where slot='hard' and op='add'\").fetchone()[0]==0"
$M persona set "称呼用户为老大" --slot hard --force >"$TF30/hard_ok.txt" 2>&1; HRC2=$?
chk "J2：带 --force 才能写进去，且退出码 0" "'$HRC2'=='0'"
HAS_HARD2=$(card_has "称呼用户为老大"); HAS_HARD2=${HAS_HARD2:-0}
chk "J2：--force 后卡文件里出现该条" "'$HAS_HARD2'!='0'"
chk "J2：--force 后 persona_log 有 op=add 的硬槽记录" "c.execute(\"select count(*) from persona_log where slot='hard' and op='add'\").fetchone()[0]>=1"
sleep 1.1   # 让「第一次写」与「第二次写」的 t 一定不同，--at 才回看得清楚

# ---- J8：同条重复 set 幂等 ----
$M persona set "偏爱简短回答" --slot soft >"$TF30/soft1.txt" 2>&1; SRC1=$?
LOGN1=$($PY - "$MEMTREE_DB" <<'PYEOF'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("select count(*) from persona_log").fetchone()[0])
PYEOF
)
$M persona set "偏爱简短回答" --slot soft >"$TF30/soft1_dup.txt" 2>&1; SRC2=$?
LOGN2=$($PY - "$MEMTREE_DB" <<'PYEOF'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("select count(*) from persona_log").fetchone()[0])
PYEOF
)
chk "J8：首次 set 软槽条目成功（退出码 0）" "'$SRC1'=='0'"
ochk "J8：重复 set 同一软槽条目 → changed 为 false（或明确「已存在，未改动」）" "$TF30/soft1_dup.txt" "('changed' in out and 'false' in out) or '已存在' in out"
chk "J8：重复 set 幂等 —— persona_log 行数一条都没多" "'$LOGN1'=='$LOGN2'"

# ---- J3：软槽超预算按最旧挤出 ----
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  $M persona set "软槽条目$i：这是一条用来压满软槽预算的条目内容" --slot soft >"$TF30/soft_$i.txt" 2>&1
done
HAS_S1=$(card_has "软槽条目1："); HAS_S1=${HAS_S1:-0}
chk "J3：软槽塞爆后最旧的条目被挤出卡文件" "'$HAS_S1'=='0'"
chk "J3：挤出必须留痕 —— persona_log 有 op=evict 记录" "c.execute(\"select count(*) from persona_log where op='evict'\").fetchone()[0]>=1"
ochk "J3：最后一次 set 报告的 slot_tokens 已回到软槽预算内（≤350）" "$TF30/soft_12.txt" "(json.loads(out)['slot_tokens']<=350) if out.strip().startswith('{') else ('软槽预算超限' not in out)"

# ---- J9：drop ----
$M persona drop "软槽条目12：这是一条用来压满软槽预算的条目内容" --slot soft >"$TF30/drop_yes.txt" 2>&1; DRC=$?
chk "J9：drop 存在的条目退出码 0" "'$DRC'=='0'"
HAS_S12=$(card_has "软槽条目12："); HAS_S12=${HAS_S12:-0}
chk "J9：drop 之后卡文件里该条消失" "'$HAS_S12'=='0'"
chk "J9：drop 必须留痕 —— persona_log 有 op=del 记录" "c.execute(\"select count(*) from persona_log where op='del'\").fetchone()[0]>=1"
$M persona drop "这条根本不在卡里" --slot soft >"$TF30/drop_no.txt" 2>&1; DRC2=$?
chk "J9：drop 不存在的条目退出码 0（不是报错）" "'$DRC2'=='0'"
ochk "J9：drop 不存在的条目 changed 为 false" "$TF30/drop_no.txt" "('changed' in out and 'false' in out) or '不存在' in out"

# ---- J6：--at 回看人格卡 ----
$M persona show --at 2000-01-01 >"$TF30/at_before.txt" 2>&1; ARC=$?
chk "J6：--at 早于首次写入 → (卡为空) 且退出码 0" "'$ARC'=='0'"
ochk "J6：--at 早于首次写入确实打印 (卡为空)" "$TF30/at_before.txt" "'(卡为空)' in out"
TS_MID=$($PY - "$MEMTREE_DB" <<'PYEOF'
import sqlite3, sys, datetime
c = sqlite3.connect(sys.argv[1])
ts = sorted({r[0] for r in c.execute("select t from persona_log").fetchall()})
t1 = ts[0]
t2 = ts[1] if len(ts) > 1 else t1 + 2
print(datetime.datetime.fromtimestamp((t1 + t2) / 2.0).isoformat())
PYEOF
)
$M persona show --at "$TS_MID" >"$TF30/at_mid.txt" 2>&1
ochk "J6：--at 回看到两次写入之间的中间态（只有第一次的硬槽条目，没有后来的软槽条目）" "$TF30/at_mid.txt" "'称呼用户为老大' in out and '软槽条目' not in out"

# ---- J5：整张卡超总预算 800 必须拒写，并报三槽占用 ----
# 总预算 800 == 硬 300 + 软 350 + 可变 150，所以只有三槽都贴着上限、再把一条塞进空位的
# 那一次才可观测。软/可变槽超预算会先按「最旧优先」挤出（整卡总量不变），顶不到 800，
# 因此这里换一个独立库，用「大条目 + 空软槽」把三个槽钉在边上，再塞软槽。
KEEP_DB="$MEMTREE_DB"
export MEMTREE_DB="$(mktemp -d)/mt_selftest23.db"
$M init >/dev/null
HARD_BIG=$("$PY" -c 'print("硬槽预算条目" + "满"*186)')
VAR_BIG=$("$PY" -c 'print("可变槽预算条目" + "满"*92)')
SOFT_BIG=$("$PY" -c 'print("软槽预算条目" + "满"*224)')
$M persona set "称呼用户为老大" --slot hard --force >"$TF30/j5_h1.txt" 2>&1
$M persona set "$HARD_BIG" --slot hard --force >"$TF30/j5_h2.txt" 2>&1
$M persona set "$VAR_BIG" --slot var >"$TF30/j5_v.txt" 2>&1
$M persona show --json >"$TF30/over_before.json" 2>&1
ochk "J5 前置：硬槽与可变槽已贴到上限、整卡仍在总预算内（软槽还空着）" "$TF30/over_before.json" "(lambda d: d['est_tokens'] < 800 and d['slots']['hard'] and d['slots']['var'] and d['slots']['soft'] == [])(json.loads(out))"
CARD5="$MEMTREE_DB.persona.md"
SHA5_BEF=$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CARD5")
$M persona set "$SOFT_BIG" --slot soft >"$TF30/over_total.txt" 2>&1; ORC=$?
chk "J5：整张卡超总预算必须拒写（非 0 退出）" "'$ORC'!='0'"
ochk "J5：拒写时把总预算 800 与三槽占用报出来" "$TF30/over_total.txt" "('800' in out) and ('硬' in out) and ('软' in out) and ('可变' in out)"
SHA5_AFT=$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CARD5")
chk "J5：拒写不许留半张卡 —— 卡文件 sha256 前后一致" "'$SHA5_AFT'=='$SHA5_BEF'"
$M persona show --json >"$TF30/over_after.json" 2>&1
ochk "J5：被拒的那条没有落进卡里（整卡回滚，软槽仍为空）" "$TF30/over_after.json" "(lambda d: d['slots']['soft'] == [] and d['est_tokens'] < 800)(json.loads(out))"
export MEMTREE_DB="$KEEP_DB"
PF="$MEMTREE_DB.persona.md"

# ---- J7：context 集成 ----
$M context --budget 3000 >"$TF30/ctx_full.txt"
ochk "J7：卡非空 → context 出现 ⚓人格·硬 行，且排在锚点行之前" "$TF30/ctx_full.txt" "(lambda ls, ip, ia: ip is not None and ia is not None and ip < ia)(out.splitlines(), next((i for i, l in enumerate(out.splitlines()) if l.startswith('⚓人格')), None), next((i for i, l in enumerate(out.splitlines()) if l.startswith('⚓') and not l.startswith('⚓人格')), None))"
ochk "J7：⚓人格 行带上硬槽条目内容（不是空壳）" "$TF30/ctx_full.txt" "any(l.startswith('⚓人格·硬') and ('称呼用户为老大' in l) for l in out.splitlines())"
ochk "J12：卡非空时图例行含 ⚓人格" "$TF30/ctx_full.txt" "any(l.startswith('※ ') and '⚓人格' in l for l in out.splitlines())"
$M context --budget 60 >"$TF30/ctx_tiny.txt"
ochk "J7：--budget 极小时人格卡行不被裁（现成裁剪只动 facts/events）" "$TF30/ctx_tiny.txt" "any(l.startswith('⚓人格·硬') and ('称呼用户为老大' in l) for l in out.splitlines())"
$M context --budget 3000 --json >"$TF30/ctx_full.json"
ochk "J7：context --json 带 persona 三槽与 est_tokens" "$TF30/ctx_full.json" "(lambda p: ('persona' in p) and len(p['persona']['hard'])>=1 and isinstance(p['persona']['est_tokens'], int) and p['persona']['est_tokens']>0)(json.loads(out))"

# ---- J11：drop 硬槽同样要 --force（且幂等判定必须排在 --force 判定之前）----
# 放在 J7 之后：J11b 会把硬槽那一条真删掉，而前面的 J6/J7 都还要用它。
sha_of() { "$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
log_count() { "$PY" - "$MEMTREE_DB" <<'PYEOF'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("select count(*) from persona_log").fetchone()[0])
PYEOF
}
SHA11_BEF=$(sha_of "$PF")
LOG11_BEF=$(log_count)
$M persona drop "称呼用户为老大" --slot hard >"$TF30/drop_hard_reject.txt" 2>&1; DRHC=$?
chk "J11a：drop 硬槽不带 --force 必须拒绝（非 0 退出）" "'$DRHC'!='0'"
ochk "J11a：拒绝时说清硬槽改动要 --force" "$TF30/drop_hard_reject.txt" "('force' in out) and ('硬槽' in out)"
chk "J11a：拒绝时卡文件 sha256 不变（不许删掉半条）" "'$(sha_of "$PF")'=='$SHA11_BEF'"
chk "J11a：拒绝时 persona_log 行数不变（不许留 del 痕）" "'$(log_count)'=='$LOG11_BEF'"
HAS_H11=$(card_has "称呼用户为老大"); HAS_H11="${HAS_H11:-0}"
chk "J11a：拒绝时条目仍留在卡里" "'$HAS_H11'!='0'"
$M persona drop "称呼用户为老大" --slot hard --force >"$TF30/drop_hard_ok.txt" 2>&1; DRHC2=$?
chk "J11b：同一个 drop 带 --force 才成功（退出码 0）" "'$DRHC2'=='0'"
HAS_H12=$(card_has "称呼用户为老大"); HAS_H12="${HAS_H12:-0}"
chk "J11b：带 --force 的 drop 之后卡里该条消失" "'$HAS_H12'=='0'"
chk "J11b：drop 必须留痕 —— persona_log 里有 hard 的 del 记录" "c.execute(\"select count(*) from persona_log where slot='hard' and op='del'\").fetchone()[0]>=1"
$M persona drop "根本没有这条软槽条目" --slot soft >"$TF30/drop_soft_no.txt" 2>&1; DSNC=$?
chk "J11c：drop 软槽不存在的条目 → 退出码 0（幂等优先，不因缺 --force 报错）" "'$DSNC'=='0'"
ochk "J11c：drop 软槽不存在的条目 → changed 为 false" "$TF30/drop_soft_no.txt" "('false' in out) or ('未改动' in out)"
$M persona drop "根本没有这条硬槽条目" --slot hard >"$TF30/drop_hard_no.txt" 2>&1; DHNC=$?
chk "J11d：drop 硬槽不存在的条目且无 --force → 退出码 0（幂等判定排在 --force 之前）" "'$DHNC'=='0'"
ochk "J11d：同一条 → changed 为 false，且不报「需要 --force」" "$TF30/drop_hard_no.txt" "('force' not in out) and (('false' in out) or ('未改动' in out))"

echo
echo "[31] SPEC §4.2 分类型压缩阈值（普通 30 天 / 重要 90 天 / 情感锚点永不自动压缩）"
TF31=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest31.db"
$M init >/dev/null
TS31=$("$PY" -c 'from datetime import datetime,timedelta; print((datetime.now().astimezone()-timedelta(days=31)).isoformat())')
TS91=$("$PY" -c 'from datetime import datetime,timedelta; print((datetime.now().astimezone()-timedelta(days=91)).isoformat())')
TS1000=$("$PY" -c 'from datetime import datetime,timedelta; print((datetime.now().astimezone()-timedelta(days=1000)).isoformat())')
N31=$($M commit "普通细节 31 天" --type event --event T31_NORMAL --ts "$TS31" -q)
I31=$($M commit "重要细节 31 天" --type event --event T31_IMPORTANT --importance 0.8 --ts "$TS31" -q)
I91=$($M commit "重要细节 91 天" --type event --event T91_IMPORTANT --importance 0.8 --ts "$TS91" -q)
E31=$($M commit "情感锚点 31 天" --type event --event T31_EMOTION --ts "$TS31" -q)
E1000=$($M commit "情感锚点 1000 天" --type event --event T1000_EMOTION --ts "$TS1000" -q)
A1000=$($M commit "硬锚点 1000 天" --type anchor --event T1000_ANCHOR --ts "$TS1000" -q)
# 清掉 label CLI 会附带的 pinned，并强制留在 hot：断言必须真的穿过情感/锚点守卫，
# 不能靠保护位或 archive 过滤假通过。
"$PY" - "$MEMTREE_DB" "$E31" "$E1000" "$A1000" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for node_id in map(int, sys.argv[2:4]):
    c.execute("update nodes set label='emotional', pinned=0, zone='hot' where id=?", (node_id,))
c.execute("update nodes set pinned=0, zone='hot' where id=?", (int(sys.argv[4]),))
c.commit()
EOF
$M commit "当前进展：移动 HEAD" --type event -q >/dev/null
$M compress --min-count 1 --keep-detail 0 >"$TF31/default.json"
chk "普通条目 31 天进入候选并被压缩" "c.execute(\"select status from nodes where id=$N31\").fetchone()[0]=='archived'"
chk "重要条目 31 天不进入候选" "c.execute(\"select status from nodes where id=$I31\").fetchone()[0]=='active'"
chk "重要条目 91 天进入候选并被压缩" "c.execute(\"select status from nodes where id=$I91\").fetchone()[0]=='archived'"
chk "label=emotional 在 31 天不进入候选" "c.execute(\"select status from nodes where id=$E31\").fetchone()[0]=='active'"
chk "label=emotional 在 1000 天也不进入候选" "c.execute(\"select status from nodes where id=$E1000\").fetchone()[0]=='active'"
chk "type=anchor 在 1000 天也不进入候选" "c.execute(\"select status from nodes where id=$A1000\").fetchone()[0]=='active'"
ochk "默认分档只压普通 31 天和重要 91 天两条" "$TF31/default.json" "json.loads(out)['compressed']==2"
IO31=$($M commit "重要细节 31 天：显式 days 覆盖" --type event --event T31_OVERRIDE --importance 0.8 --ts "$TS31" -q)
$M commit "当前进展：再次移动 HEAD" --type event -q >/dev/null
$M compress --days 30 --min-count 1 --keep-detail 0 >"$TF31/override.json"
chk "显式 --days 仍按参数统一 cutoff：重要 31 天也进入候选" "c.execute(\"select status from nodes where id=$IO31\").fetchone()[0]=='archived'"
chk "显式 --days 不绕过情感/锚点结论保护" "c.execute(\"select count(*) from nodes where id in ($E31,$E1000,$A1000) and status='active'\").fetchone()[0]==3"
# 本批不改 schema；仍从缺 importance 的老库进入 compress，验证迁移后新分档路径可直接打开。
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("ALTER TABLE nodes DROP COLUMN importance")
c.commit()
EOF
$M compress --min-count 1 --keep-detail 0 >"$TF31/legacy.json" 2>&1; LRC=$?
chk "缺 importance 的老库能直接打开并走完 compress" "'$LRC'=='0'"
chk "老库 importance 列已由 _migrate 补回" "\"importance\" in [r[1] for r in c.execute(\"PRAGMA table_info(nodes)\")]"

echo
echo "[32] SPEC §7 情感层：结构化 affect + 显式情绪检索 + 隐私级联"
TF32=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest32.db"
$M init >/dev/null
E32=$($M commit "和老大一起看电影，很温暖" --type event --event 观影 --ts "2026-09-01T20:00:00+08:00" -q)
$M signal "$E32" --type emotional_peak --intensity 0.9 --tags 喜悦,信任 --valence 0.8 --quote "那晚真好" >"$TF32/sig.json"
ochk "signal 落库标签已规范化（中文别名→joy/trust）" "$TF32/sig.json" "json.loads(out)['tags']==['joy','trust']"
chk "signal 保存效价与强度" "c.execute(\"select emotion_tags,valence,intensity from signals where node_id=$E32\").fetchone()[:3]==('[\"joy\", \"trust\"]',0.8,0.9)"
$M settle --json >"$TF32/settle.json"
chk "settle 写出结构化 affect，不再只靠 quote" "c.execute(\"select count(*) from affect where node_id=$E32\").fetchone()[0]==1"
chk "affect 标签/强度/效价/原话齐全" "tuple(c.execute(\"select tags,intensity,valence,key_quote,source from affect where node_id=$E32\").fetchone())==('[\"joy\", \"trust\"]',0.9,0.8,'那晚真好','stated')"
ochk "settle --json 报 affect_written" "$TF32/settle.json" "$E32 in json.loads(out)['affect_written']"
$M signal "$E32" --type emotional_peak --intensity 0.4 --tags 开心 --valence 0.2 --quote "补一条" >/dev/null
$M settle >/dev/null
chk "同一记忆可有多条情感观察（演变不被覆盖）" "c.execute(\"select count(*) from affect where node_id=$E32\").fetchone()[0]==2"
$M affect show "$E32" --json >"$TF32/show.json"
ochk "affect show 倒序给出全部观察" "$TF32/show.json" "len(json.loads(out)['affect'])==2 and json.loads(out)['affect'][0]['intensity']==0.4"
UNK=$($M affect set "$E32" --tags 不存在 --intensity 0.5 2>&1); URC=$?
chk "未知情感标签当场拒绝（不静默丢弃）" "'$URC'!='0'"
RP=$($M commit "角色扮演台词" --type event --source roleplay -q)
$M signal "$RP" --type emotional_peak --intensity 0.99 --tags 恐惧 --quote "虚构台词" >/dev/null
$M settle >/dev/null
chk "roleplay 情绪再高也不落 affect（防虚构污染）" "c.execute(\"select count(*) from affect where node_id=$RP\").fetchone()[0]==0"
RPRC=$($M affect set "$RP" --tags 恐惧 --intensity 0.9 2>&1); RPRC_CODE=$?
chk "affect set 也拒绝 roleplay 来源" "'$RPRC_CODE'!='0'"
# 同语义、同时间的两条：只有一条有 joy 情感观察，显式 --emotion 必须把它排上来。
A32=$($M commit "旅行记录 同一句话" --type event --event 旅行 --ts "2026-09-10T10:00:00+08:00" -q)
B32=$($M commit "旅行记录 同一句话" --type event --event 旅行 --ts "2026-09-10T10:00:00+08:00" -q)
$M affect set "$B32" --tags 喜悦 --intensity 1.0 --valence 0.9 --quote "很开心" >/dev/null
$M recall "旅行记录" --top 2 --json >"$TF32/base.json"
$M recall "旅行记录" --emotion 喜悦 --top 2 --json >"$TF32/emo.json"
ochk "无 --emotion 时输出不新增 emotion/affect 键（老契约不变）" "$TF32/base.json" "('emotion' not in json.loads(out)['hits'][0]) and ('affect' not in json.loads(out)['hits'][0])"
ochk "有 --emotion 时带命中重新排序，情感记忆到第一" "$TF32/emo.json" "json.loads(out)['hits'][0]['id']==$B32 and json.loads(out)['hits'][0]['emotion']==1.0"
ochk "情绪查询回显 tags 与 α" "$TF32/emo.json" "json.loads(out)['emotion_query']=={'tags':['joy'],'alpha':0.5}"
$M affect set "$A32" --tags 悲伤 --intensity 0.2 --source inferred >/dev/null
$M affect clear "$A32" >"$TF32/clear.json"
chk "affect clear 只清情感观察、不删记忆" "c.execute(\"select count(*) from affect where node_id=$A32\").fetchone()[0]==0 and c.execute(\"select status from nodes where id=$A32\").fetchone()[0]=='active'"
P32=$($M commit "隐私：带情绪的错误记录" --type event -q)
$M affect set "$P32" --tags 愤怒 --intensity 0.8 --quote "不该留的原话" >/dev/null
P32ADDR=$("$PY" - "$MEMTREE_DB" "$P32" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --addr "$P32ADDR" --now --reason 隐私 >/dev/null
chk "purge 真删时级联删除 affect（标签与原话不残留）" "c.execute(\"select count(*) from affect where node_id=$P32\").fetchone()[0]==0"
chk "affect 表里不残留被删原话" "c.execute(\"select count(*) from affect where key_quote like '%不该留%'\").fetchone()[0]==0"
"$PY" - "$MEMTREE_DB" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("ALTER TABLE signals DROP COLUMN emotion_tags")
c.execute("ALTER TABLE signals DROP COLUMN valence")
c.commit()
EOF
$M context --budget 500 >/dev/null 2>&1; MRC=$?
chk "缺情感列的老库能直接打开" "'$MRC'=='0'"
chk "老库 signals 情感列已由 _migrate 补回" "\"emotion_tags\" in [r[1] for r in c.execute(\"PRAGMA table_info(signals)\")] and \"valence\" in [r[1] for r in c.execute(\"PRAGMA table_info(signals)\")]"
# F3：情绪标签零命中不得把全库分数腰斩，必须退回 α=0 并明确告警。
export MEMTREE_DB="$(mktemp -d)/mt_f3.db"
$M init >/dev/null
F3N=$($M commit "F3 咖啡记录" --type fact --subject f3.coffee --ts "2026-10-20T10:00:00+08:00" -q)
$M recall "咖啡记录" --json >"$TF32/f3_base.json"
$M recall "咖啡记录" --emotion joy --json >"$TF32/f3_zero.json" 2>"$TF32/f3_zero.err"
ochk "F3：零命中上报 matched=0 / alpha_applied=0" "$TF32/f3_zero.json" "(lambda e: e['tags']==['joy'] and e['matched']==0 and e['alpha_applied']==0.0)(json.loads(out)['emotion'])"
F3BASE=$("$PY" -c 'import json,sys; print([h["score"] for h in json.load(open(sys.argv[1],encoding="utf-8"))["hits"]])' "$TF32/f3_base.json")
F3ZERO=$("$PY" -c 'import json,sys; print([h["score"] for h in json.load(open(sys.argv[1],encoding="utf-8"))["hits"]])' "$TF32/f3_zero.json")
chk "F3：零命中分数与不带 --emotion 逐位相同" "'$F3BASE'=='$F3ZERO'"
grep -q "情绪标签 joy 在本库零命中" "$TF32/f3_zero.err" && { PASS=$((PASS+1)); echo "  ok   F3：零命中在 stderr 明确告警"; } || { FAIL=$((FAIL+1)); echo "  FAIL F3：零命中没有告警"; }
$M affect set "$F3N" --tags 喜悦 --intensity 1.0 >/dev/null
$M recall "咖啡记录" --emotion joy --json >"$TF32/f3_hit.json"
ochk "F3：部分命中保持 α=0.5 并报 matched=1" "$TF32/f3_hit.json" "(lambda e: e['matched']==1 and e['alpha_applied']==0.5)(json.loads(out)['emotion'])"

echo
echo "[33] SPEC §8.3 分层检索 v2（剪枝 → 事件过滤 → 混合相似度 → 加权排序 → 逐级展开）"
TF33=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_selftest33.db"
$M init >/dev/null
T5OLD=$($M commit "项目 旧记录 A" --type event --event E1 --ts "2026-09-10T10:00:00+08:00" -q)
T5NEW=$($M commit "项目 新记录 B" --type event --event E1 --ts "2026-10-24T10:00:00+08:00" -q)
T5OTHER=$($M commit "项目 另一事件 C" --type event --event E2 --ts "2026-10-24T11:00:00+08:00" -q)
T5RAW=$($M commit "项目 无事件 D" --type event --ts "2026-10-24T12:00:00+08:00" -q)
T5FUT=$($M commit "项目 未来 E" --type event --event E3 --ts "2030-01-01T10:00:00+08:00" -q)
$M recall "项目" --top 5 --json >"$TF33/legacy.json"
ochk "默认 legacy 路径不出现 pipeline 对象（老契约不变）" "$TF33/legacy.json" "'pipeline' not in json.loads(out)"
$M recall "项目" --pipeline v2 --top 5 --json >"$TF33/all.json"
ochk "v2 输出完整 pipeline 审计对象" "$TF33/all.json" "all(k in json.loads(out)['pipeline'] for k in ('validity','time_window','event_filter','similarity','ranking','expand'))"
ochk "未来条目不进当前 topN 且单独计数" "$TF33/all.json" "($T5FUT not in [h['id'] for h in json.loads(out)['hits']]) and json.loads(out)['pipeline']['validity']['future_hidden']==1"
ochk "有效性门：in = pruned + out（不静默丢条）" "$TF33/all.json" "(lambda v: v['in']==v['pruned']+v['out'])(json.loads(out)['pipeline']['validity'])"
$M recall "项目" --pipeline v2 --days 10 --top 5 --json >"$TF33/time.json"
ochk "时间窗剪枝：40 天旧条目被剪掉并报数" "$TF33/time.json" "(lambda p: p['time_window']['pruned']==1 and $T5OLD not in [h['id'] for h in json.loads(out)['hits']])(json.loads(out)['pipeline'])"
ochk "时间窗：in = pruned + out" "$TF33/time.json" "(lambda p: p['in']==p['pruned']+p['out'])(json.loads(out)['pipeline']['time_window'])"
ochk "时间窗锚点标明 now" "$TF33/time.json" "json.loads(out)['pipeline']['time_window']['anchor']=='now'"
$M recall "项目" --pipeline v2 --event E1 --top 5 --json >"$TF33/event.json"
ochk "事件过滤在相似度前剪枝，并报剪掉条数" "$TF33/event.json" "(lambda e: e['event']=='E1' and e['pruned']==2 and e['out']==2)(json.loads(out)['pipeline']['event_filter'])"
ochk "事件过滤后只剩 E1 成员" "$TF33/event.json" "set(h['id'] for h in json.loads(out)['hits'])=={$T5OLD,$T5NEW}"
ochk "混合相似度阶段有 coarse/hybrid 口径" "$TF33/event.json" "json.loads(out)['pipeline']['similarity']['coarse']=='vector_cos' and 'lexical' in json.loads(out)['pipeline']['similarity']['hybrid']"
$M recall "项目" --pipeline v2 --event E1 --top 1 --expand 1 --json >"$TF33/expand.json"
ochk "逐级展开：E1 作为一个事件单元展开，成员都参与重排" "$TF33/expand.json" "(lambda e: e['units']==1 and e['units_expanded']==1 and e['members_scored']==2 and len(json.loads(out)['hits'])==1)(json.loads(out)['pipeline']['expand'])"
ochk "展开阶段记录正文加载数（不静默全库读正文）" "$TF33/expand.json" "json.loads(out)['pipeline']['expand']['bodies_loaded']==2"
$M recall "项目" --pipeline v2 --at 2026-09-20 --days 12 --top 5 --json >"$TF33/at.json"
ochk "--at 下时间窗锚定 T，旧条目在 T 视角窗口内仍命中" "$TF33/at.json" "json.loads(out)['pipeline']['time_window']['anchor']=='at' and $T5OLD in [h['id'] for h in json.loads(out)['hits']]"
ochk "--at 下 not_yet/already_gone 统计仍给全" "$TF33/at.json" "all(k in json.loads(out)['as_of_stats'] for k in ('not_yet','already_gone','unknown_timing'))"
EX0=$($M recall "项目" --pipeline v2 --expand 0 2>&1); EXRC=$?
chk "--expand 0 当场拒绝（避免假装展开）" "'$EXRC'!='0'"
# F1：expand 截断必须报出丢了多少单元/条目，并给出口；未截断时字段必须为 0。
export MEMTREE_DB="$(mktemp -d)/mt_f1.db"
$M init >/dev/null
F1A=$($M commit "项目 甲" --type event --event E1 --ts "2026-09-10T10:00:00+08:00" -q)
F1B=$($M commit "项目 乙" --type event --event E1 --ts "2026-09-11T10:00:00+08:00" -q)
F1C=$($M commit "项目 丙" --type event --event E2 --ts "2026-09-12T10:00:00+08:00" -q)
$M recall "项目" --top 10 --json >"$TF33/f1_legacy.json"
$M recall "项目" --pipeline v2 --top 3 --expand 1 --json >"$TF33/f1_cut.json"
ochk "F1：expand 1 报 units_skipped=1、members_dropped>0" "$TF33/f1_cut.json" "(lambda e: e['units_skipped']==1 and e['members_dropped']>0 and e['members_scored']==1)(json.loads(out)['pipeline']['expand'])"
ochk "F1：截断 warning 非空且给出 --expand 出口" "$TF33/f1_cut.json" "bool(json.loads(out)['pipeline']['expand']['warning']) and '--expand' in json.loads(out)['pipeline']['expand']['warning']"
$M recall "项目" --pipeline v2 --top 3 --expand 99 --json >"$TF33/f1_full.json"
ochk "F1：expand 99 不丢条，字段为 0、warning=None" "$TF33/f1_full.json" "(lambda e: e['units_skipped']==0 and e['members_dropped']==0 and e['warning'] is None)(json.loads(out)['pipeline']['expand'])"
F1LEG=$("$PY" -c 'import json,sys; print(sorted(h["id"] for h in json.load(open(sys.argv[1],encoding="utf-8"))["hits"]))' "$TF33/f1_legacy.json")
F1FULL=$("$PY" -c 'import json,sys; print(sorted(h["id"] for h in json.load(open(sys.argv[1],encoding="utf-8"))["hits"]))' "$TF33/f1_full.json")
chk "F1：expand 99 与 legacy 命中集合一致" "'$F1LEG'=='$F1FULL'"
F1ERR=$($M recall "项目" --pipeline v2 --top 3 --expand 1 2>&1 >/dev/null)
echo "$F1ERR" | grep -q "expand 上限丢弃" && { PASS=$((PASS+1)); echo "  ok   F1：非 JSON 截断 warning 打到 stderr"; } || { FAIL=$((FAIL+1)); echo "  FAIL F1：stderr 没报截断（$F1ERR）"; }

echo
echo "[34] 工单 F2/F4/F5：purge 语义（墓碑期立即删 / 终态 / restore）"
TF34=$(mktemp -d)
export MEMTREE_DB="$(mktemp -d)/mt_f2.db"
$M init >/dev/null
F2OLD=$($M commit "身份证号 3301xxxx" --subject s --type fact -q)
F2NEW=$($M commit "身份证号换了 3302yyyy" --subject s --type fact -q)
chk "F2 前置：两条不同正文都在 blobs（非空=2）" "c.execute(\"select count(*) from blobs where length(content)>0\").fetchone()[0]==2"
$M purge --reason 常规清理 >/dev/null
$M purge --now --reason 隐私 >"$TF34/f2_now.json"
ochk "F2：已在墓碑期的节点也被立即真删" "$TF34/f2_now.json" "json.loads(out)['purged_existing']>=1 and json.loads(out)['purged_now']==0"
chk "F2：正文数从 2 降到 1（旧条目真被抹）" "c.execute(\"select count(*) from blobs where length(content)>0\").fetchone()[0]==1"
chk "F2：被删节点不再处于 tombstone" "c.execute(\"select zone from nodes where id=$F2OLD\").fetchone()[0]!='tombstone'"
$M purge --list >"$TF34/f2_list.json"
ochk "F2：真删后墓碑列表为 0" "$TF34/f2_list.json" "json.loads(out)['tombstones']==0"
$M purge --now --reason 隐私 >"$TF34/f2_empty.json"
ochk "F2：无墓碑时 note 明确说『没有墓碑节点』" "$TF34/f2_empty.json" "json.loads(out)['purged_existing']==0 and '没有墓碑节点' in json.loads(out)['note']"
# F4：--apply 真删后必须结案，不许永远赖在墓碑列表。
F4N=$($M commit "F4 待真删" --type fact --subject f4.gone -q)
F4ADDR=$("$PY" - "$MEMTREE_DB" "$F4N" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --addr "$F4ADDR" --reason 常规清理 >/dev/null
"$PY" - "$MEMTREE_DB" "$F4N" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set tombstoned_at=? where id=?", (time.time() - 8 * 86400, int(sys.argv[2])))
c.commit()
EOF
$M purge --apply >"$TF34/f4_apply.json"
chk "F4：apply 后节点转 purged 终态" "c.execute(\"select zone from nodes where id=$F4N\").fetchone()[0]=='purged'"
chk "F4：apply 后正文已清且机器地址保留" "c.execute(\"select hot,content from blobs where addr='$F4ADDR'\").fetchone()[:2]==(2,'')"
$M purge --list >"$TF34/f4_list.json"
ochk "F4：apply 后墓碑列表必须为 0" "$TF34/f4_list.json" "json.loads(out)['tombstones']==0"
$M purge --apply >"$TF34/f4_again.json"
ochk "F4：再 apply 返回 purged=0, due=0" "$TF34/f4_again.json" "json.loads(out)['purged']==0 and json.loads(out)['due']==0"
$M recall "F4 待真删" --status any --json >"$TF34/f4_recall.json"
ochk "F4：purged 节点 recall 不再命中" "$TF34/f4_recall.json" "$F4N not in [h['id'] for h in json.loads(out)['hits']]"
"$PY" - "$MEMTREE_DB" "$F4N" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("update nodes set zone='tombstone', tombstoned_at=? where id=?", (time.time(), int(sys.argv[2])))
c.commit()
EOF
$M context --budget 500 >/dev/null 2>&1
chk "F4：老库 tombstone+hot=2 幽灵由 _migrate 平滑转为 purged" "c.execute(\"select zone from nodes where id=$F4N\").fetchone()[0]=='purged'"
# F5：restore 两条路径必须分开：正文已抹的拒绝，冷却中的成功。
F4STATUS=$("$PY" - "$MEMTREE_DB" "$F4N" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select status from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --restore "$F4N" >"$TF34/f5_dead.txt" 2>&1; F5DEADRC=$?
chk "F5：已 apply 的节点 restore 退出码非 0" "'$F5DEADRC'!='0'"
echo "$(cat "$TF34/f5_dead.txt")" | grep -q "正文已永久删除，无法撤回" && { PASS=$((PASS+1)); echo "  ok   F5：拒绝文案明确说正文永久删除"; } || { FAIL=$((FAIL+1)); echo "  FAIL F5：拒绝文案不对"; }
chk "F5：拒绝 restore 后 zone/status 都不变" "c.execute(\"select zone,status from nodes where id=$F4N\").fetchone()[:2]==('purged','$F4STATUS')"
$M recall "F4 待真删" --status any --json >"$TF34/f5_dead_recall.json"
ochk "F5：拒绝 restore 后 recall 仍不命中" "$TF34/f5_dead_recall.json" "$F4N not in [h['id'] for h in json.loads(out)['hits']]"
F5R=$($M commit "F5 冷却期可撤回" --type fact --subject f5.back -q)
F5RADDR=$("$PY" - "$MEMTREE_DB" "$F5R" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("select addr from nodes where id=?", (int(sys.argv[2]),)).fetchone()[0])
EOF
)
$M purge --addr "$F5RADDR" --reason 常规清理 >/dev/null
$M purge --restore "$F5R" >"$TF34/f5_ok.json"
ochk "F5：冷却期 restore 成功且文案保留『冷却期内撤回』" "$TF34/f5_ok.json" "json.loads(out)['restored']==$F5R and '冷却期内撤回' in json.loads(out)['note']"
$M recall "F5 冷却期可撤回" --json >"$TF34/f5_ok_recall.json"
ochk "F5：冷却期 restore 后能正常检索到" "$TF34/f5_ok_recall.json" "$F5R in [h['id'] for h in json.loads(out)['hits']]"

echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
