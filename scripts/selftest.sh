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

export MEMTREE_DB="${MEMTREE_DB:-$(mktemp -d)/mt_selftest.db}"
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

echo
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
