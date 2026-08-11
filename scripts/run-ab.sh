#!/usr/bin/env bash
# AMM 开启 / 关闭 对照实验（A/B）
#
# 同一实例、同一天、同一套五阶段协议连续跑两遍，唯一变量：
#     gs_amm_native_auto_mode = on  →  AMM 介入内存管理
#     gs_amm_native_auto_mode = off →  原生 openGauss work_mem 行为
#
# 为什么是这个开关（gs_amm_query.cpp:862）：
#     if (!gs_amm_native_auto_mode || !top_level_executor) return false;
# 它正是决定 AMM 是否介入执行器内存分配的那道门闩。关掉后预测/准入/改写 work_mem 全部不执行，
# 而 AMM 的池遥测仍在，两组可用同一采样器、同一组指标直接对比。
#
# 五阶段对应 PPT step①~⑤，每阶段 2 分钟：
#   ① 内存富裕   TP2 + AP2 ×128MB
#   ② 触及上限   TP2 + AP2 ×512MB      ← 借内存
#   ③ 保护基准   TP2 + AP4 ×512MB      ← 触地板
#   ④ 反压排队   TP2 + AP8 ×512MB      ← 队列保护
#   ⑤ 基准突增   TP8 + AP8 ×512MB      ← TP 流量增加是否扩共享缓存
set -uo pipefail

BASE=/home/sqlrush/gsbench
VER=/mnt/mac/Users/sqlrush/memtest/vm/verify
ART=/mnt/mac/Users/sqlrush/memtest/artifacts/verify
STAGEFILE=/tmp/amm-stage
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$ART"
export GSBENCH_PASSWORD="${GSBENCH_PASSWORD:?需要 GSBENCH_PASSWORD}"

R_128MB=28086      # AMM 关闭时实测校准值：128MB 排序
R_512MB=112347     # AMM 关闭时实测校准值：512MB 排序（达标率 90.6%）

export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"

q()  { gsql -d postgres -p 15432 -At -c "$1" 2>/dev/null; }
set_mode() {
  gsql -d postgres -p 15432 -c "ALTER SYSTEM SET gs_amm_native_auto_mode=$1;" >/dev/null 2>&1
  q "SELECT pg_reload_conf();" >/dev/null
  sleep 2
  local got; got=$(q "SHOW gs_amm_native_auto_mode;")
  [[ "$got" == "$1" ]] || { echo "ABORT: native_auto_mode=$got，期望 $1" >&2; exit 1; }
  echo "$got"
}
restore() { set_mode on >/dev/null 2>&1 || true; echo "[$(date -Is)] 收尾：native_auto_mode=$(q 'SHOW gs_amm_native_auto_mode;')"; }
trap restore EXIT

ap_start() {
  local tag=$1 n=$2 wm=$3 rg=$4 hold=$5
  for ((i=1;i<=n;i++)); do
    nohup bash "$VER/ap-holder.sh" "$wm" "$rg" "$hold" "$i" >> "$ART/ap-${tag}-$STAMP.log" 2>&1 &
  done
}
ap_stop() { pkill -f "ap-holder.sh" 2>/dev/null; pkill -f "pg_sleep" 2>/dev/null; sleep 2; }

run_one() {          # $1 = on|off ; $2 = 标签
  local mode=$1 tag=$2
  echo "=============================================================="
  echo "[$(date -Is)] 组 $tag ：native_auto_mode=$(set_mode "$mode")"
  echo "=============================================================="
  q "SELECT pg_catalog.gs_amm_status();" > "$ART/prestate-${tag}-$STAMP.txt"

  echo "-" > "$STAGEFILE"
  nohup bash "$VER/sample-amm.sh" "$ART/amm-${tag}-$STAMP.csv" "$STAGEFILE" >/dev/null 2>&1 &
  local SAMPLER=$!
  nohup bash "$VER/tp-watchdog3.sh" "$ART/watchdog-${tag}-$STAMP.log" >/dev/null 2>&1 &
  local WD=$!
  sleep 3

  mark() { echo "$1" > "$STAGEFILE"; echo "$(date +%s) $(date -Is) STAGE=$1" >> "$ART/timeline-${tag}-$STAMP.txt"; }

  mark "tp_warmup"
  echo "[$(date -Is)] TP 2 worker / 9m"
  ( cd "$BASE" && ./gsbench run 101 --workers 2 --duration 9m > "$ART/tp-${tag}-s1234-$STAMP.log" 2>&1 ) &
  local TP=$!
  sleep 45

  for spec in "stage1 2 131072 $R_128MB" "stage2 2 524288 $R_512MB" \
              "stage3 4 524288 $R_512MB" "stage4 8 524288 $R_512MB"; do
    set -- $spec
    mark "$1"
    echo "[$(date -Is)] $1 : AP×$2 work_mem=$3kB range=$4"
    ap_start "$tag" "$2" "$3" "$4" 118
    sleep 120
    ap_stop
  done
  wait $TP 2>/dev/null

  mark "stage5"
  echo "[$(date -Is)] stage5 : TP 8 worker + AP×8"
  ap_start "$tag" 8 524288 "$R_512MB" 118
  ( cd "$BASE" && ./gsbench run 101 --workers 8 --duration 2m > "$ART/tp-${tag}-s5-$STAMP.log" 2>&1 )
  ap_stop

  mark "cooldown"
  echo "[$(date -Is)] 收尾观察 60s"
  sleep 60
  mark "-"
  kill $SAMPLER $WD 2>/dev/null
  q "SELECT pg_catalog.gs_amm_status();" > "$ART/poststate-${tag}-$STAMP.txt"
  echo "[$(date -Is)] 组 $tag 完成"
}

pgrep -f "gsbench run" >/dev/null 2>&1 && { echo "ABORT: 已有 gsbench 在跑" >&2; exit 1; }
echo "[$(date -Is)] A/B 开始 STAMP=$STAMP  jitter_limit=$(q 'SHOW gs_amm_tp_jitter_limit;')"

run_one on  "ammon"
sleep 30                     # 组间静默，让池与 guard 回到稳态
run_one off "ammoff"

echo "[$(date -Is)] A/B 全部完成 STAMP=$STAMP"
