#!/usr/bin/env bash
# AP 会话群工具 —— 按目标总内存自动补偿会话数
#
# 背景：单个 AP 会话申请 512 MB，但原生模式下实际占用约 463~475 MB（约 90%~93%）。
#       若按名义值换算会话数，实际压力会系统性偏低，导致场景跨不过分界点。
#
# 两个子命令：
#   measure                        在当前模式下实测单会话真实占用（MB），仅输出数字
#   start <目标MB> <每会话MB> ...   按 ⌈目标 ÷ 每会话⌉ 启动会话群
#
# 公平性要求：measure 必须在**原生模式**（native_auto_mode=off）下执行一次，
#   得到的会话数供 AMM 开启组与关闭组**共用**。若两组各自测量，
#   AMM 开启时排序落盘会使测量失真，且两组会跑不同的会话数，破坏对照。
set -uo pipefail

export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"
P=15432
VER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CMD="${1:?measure | start}"; shift

# ---- measure: 实测单会话真实占用 MB ----
# 用与压测完全相同的排序语句跑 EXPLAIN(ANALYZE)，解析 Sort 算子实得内存。
#   命中 "Memory: NkB" → 全内存完成，返回该值
#   命中 "Disk: NkB"   → 已落盘，说明当前模式拿不到内存，测量无效，返回 0
if [[ "$CMD" == "measure" ]]; then
  WM_KB="${1:?work_mem kB}"; RANGE="${2:?range_end}"
  plan=$(gsql -d postgres -p $P -At <<SQL 2>/dev/null
BEGIN;
SET LOCAL work_mem='${WM_KB}kB';
SET LOCAL query_dop=1;
SET LOCAL explain_perf_mode=normal;
EXPLAIN (ANALYZE, BUFFERS)
SELECT id,sort_key,payload FROM gsbench.sort_data
 WHERE dist_key BETWEEN 1 AND ${RANGE}
 ORDER BY payload,sort_key DESC,id;
ROLLBACK;
SQL
)
  mem_kb=$(grep -oE "Sort Method:[^)]*Memory: [0-9]+kB" <<<"$plan" | grep -oE "[0-9]+kB" | tr -d 'kB' | head -1)
  if [[ -n "$mem_kb" ]]; then
    echo $((mem_kb / 1024))
  else
    echo 0        # 落盘或无法解析：当前模式测量无效
  fi
  exit 0
fi

# ---- start: 启动会话群 ----
if [[ "$CMD" == "start" ]]; then
  TARGET_MB="${1:?目标总内存 MB}"
  PER_MB="${2:?每会话实测 MB}"
  WM_KB="${3:?work_mem kB}"
  RANGE="${4:?range_end}"
  HOLD="${5:-118}"
  LOG="${6:-/dev/null}"

  [[ "$PER_MB" -gt 0 ]] || { echo "[ap-fleet] 错误：每会话内存必须 > 0" >&2; exit 1; }

  SESSIONS=$(( (TARGET_MB + PER_MB - 1) / PER_MB ))
  [[ "$SESSIONS" -lt 1 ]] && SESSIONS=1
  NOMINAL=$(( (TARGET_MB + WM_KB/1024 - 1) / (WM_KB/1024) ))

  echo "[ap-fleet] 目标=${TARGET_MB}MB 每会话=${PER_MB}MB 名义=${NOMINAL} 实际启动=${SESSIONS}"
  echo "$(date -Is) target=${TARGET_MB}MB per_session=${PER_MB}MB nominal=${NOMINAL} actual=${SESSIONS}" >> "$LOG"

  for ((i=1;i<=SESSIONS;i++)); do
    nohup bash "$VER/ap-holder.sh" "$WM_KB" "$RANGE" "$HOLD" "$i" >> "$LOG" 2>&1 &
  done
  exit 0
fi

echo "未知子命令: $CMD" >&2
exit 1
