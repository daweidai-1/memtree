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
for i in 1 2 3; do $M commit "旧事件$i" --type event --ts "2026-08-0${i}T10:00:00+08:00" -q >/dev/null; done
$M commit "当前进展" --type event -q >/dev/null
$M compress --days 40 --min-count 3 >/dev/null
chk "生成 summary" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==1"
chk "旧事件不再 active" "c.execute(\"select count(*) from nodes where status='active' and addr in (select addr from blobs where content like '旧事件%')\").fetchone()[0]==0"

echo "[8] 物理清除"
$M purge >/dev/null
chk "被覆盖正文已物理删除" "c.execute(\"select count(*) from blobs where hot=2 and content=''\").fetchone()[0]>=1"

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
$M compress --days 30 --min-count 1 --heat 0.5 >/dev/null
chk "刚被召回的老事件不被压缩" "c.execute(\"select count(*) from nodes where type='summary'\").fetchone()[0]==0"
$M commit "从没被碰过的四月老事件 方案R" --type event --ts "2026-04-01T10:00:00+08:00" -q >/dev/null
$M commit "当前进展" --type event -q >/dev/null
$M compress --days 30 --min-count 1 --heat 0.5 >/dev/null
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
$M compress --days 30 --min-count 1 --heat 0.1 >/dev/null
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
echo
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
