#!/usr/bin/env bash
# AMM 开启 / 关闭 对照实验（A/B）
#
# 同一实例连续跑两遍五阶段编排，唯一变量：
#     gs_amm_native_auto_mode = on  →  AMM 介入内存管理
#     gs_amm_native_auto_mode = off →  原生 openGauss work_mem 行为
#
# 容量模型（见报告 §1.4）：
#     动态内存 2134 MB ≈ 4 个 512MB 会话
#     可迁移带宽 1536 MB = 3 个
#     合计 ≈ 7 个 → 三个分界点：4 个开始借 / 7 个到地板 / 超 7 个排队
#
# 五阶段目标：
#   ① 内存宽裕        2 会话 × 128MB          不借
#   ② 越过动态内存    目标 2134 MB            开始借
#   ③ 用尽可迁移带宽  目标 3670 MB            借出停止，到地板
#   ④ 借无可借        目标 5000 MB            进队列
#   ⑤ TP 侧加压       TP 2→8，AP 同 ④         共享池回升
#
# 会话数由 ap-fleet.sh 按实测单会话占用自动补偿；
# 测量在原生模式下只做一次，两组共用，以保证对照公平。
set -uo pipefail

BASE=/home/sqlrush/gsbench
VER=/mnt/mac/Users/sqlrush/memtest/vm/verify
ART=/mnt/mac/Users/sqlrush/memtest/artifacts/verify
STAGEFILE=/tmp/amm-stage
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$ART"
export GSBENCH_PASSWORD="${GSBENCH_PASSWORD:?需要 GSBENCH_PASSWORD}"

R_128MB=28086      # 128MB 档校准区间
R_512MB=112347     # 512MB 档校准区间

TARGET_S2=2134     # 越过动态内存
TARGET_S3=3670     # 用尽可迁移带宽
TARGET_S4=5000     # 借无可借

export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"

q() { gsql -d postgres -p 15432 -At -c "$1" 2>/dev/null; }
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

ap_stop() { pkill -f "ap-holder.sh" 2>/dev/null; pkill -f "pg_sleep" 2>/dev/null; sleep 2; }

pgrep -f "gsbench run" >/dev/null 2>&1 && { echo "ABORT: 已有 gsbench 在跑" >&2; exit 1; }

# ============ 步骤 0：原生模式下测量单会话占用（只做一次，两组共用）============
echo "[$(date -Is)] 测量单会话真实占用（原生模式）"
set_mode off >/dev/null
PER_MB=$(bash "$VER/ap-fleet.sh" measure 524288 "$R_512MB")
if [[ -z "$PER_MB" || "$PER_MB" -le 0 ]]; then
  echo "ABORT: 单会话占用测量失败（返回 $PER_MB），原生模式下不应落盘" >&2; exit 1
fi
S2=$(( (TARGET_S2 + PER_MB - 1) / PER_MB ))
S3=$(( (TARGET_S3 + PER_MB - 1) / PER_MB ))
S4=$(( (TARGET_S4 + PER_MB - 1) / PER_MB ))
echo "[$(date -Is)] 单会话=${PER_MB}MB → 会话数 step②=${S2} step③=${S3} step④/⑤=${S4}"
echo "$(date -Is) per_session=${PER_MB}MB s2=${S2} s3=${S3} s4=${S4}" > "$ART/fleet-$STAMP.txt"

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
  local APLOG="$ART/ap-${tag}-$STAMP.log"

  mark "tp_warmup"
  echo "[$(date -Is)] TP 2 worker / 9m"
  ( cd "$BASE" && ./gsbench run 101 --workers 2 --duration 9m > "$ART/tp-${tag}-s1234-$STAMP.log" 2>&1 ) &
  local TP=$!
  sleep 45

  # step ① 内存宽裕：固定 2 会话 × 128MB
  mark "stage1"
  echo "[$(date -Is)] stage1 内存宽裕：2 会话 × 128MB"
  for i in 1 2; do nohup bash "$VER/ap-holder.sh" 131072 "$R_128MB" 118 "$i" >> "$APLOG" 2>&1 & done
  sleep 120; ap_stop

  # step ②③④ 按目标总内存补偿会话数
  for spec in "stage2 $TARGET_S2 $S2" "stage3 $TARGET_S3 $S3" "stage4 $TARGET_S4 $S4"; do
    set -- $spec
    mark "$1"
    echo "[$(date -Is)] $1 目标=${2}MB"
    bash "$VER/ap-fleet.sh" start "$2" "$PER_MB" 524288 "$R_512MB" 118 "$APLOG"
    sleep 120
    ap_stop
  done
  wait $TP 2>/dev/null

  # step ⑤ TP 侧加压：AP 同 step④，TP 2→8
  mark "stage5"
  echo "[$(date -Is)] stage5 TP 2→8 worker，AP 同 step④"
  bash "$VER/ap-fleet.sh" start "$TARGET_S4" "$PER_MB" 524288 "$R_512MB" 118 "$APLOG"
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

echo "[$(date -Is)] A/B 开始 STAMP=$STAMP"
run_one on  "ammon"
sleep 30
run_one off "ammoff"
echo "[$(date -Is)] A/B 全部完成 STAMP=$STAMP"
