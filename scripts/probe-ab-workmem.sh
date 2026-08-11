#!/usr/bin/env bash
# A/B 补充探针：两种模式下测量同一个排序算子真实拿到多少内存
#
# 必要性：native_auto_mode=off 时 AMM 不再记账（dyn_used 恒 0），
#         所以"AP 有没有拿到内存"不能靠 AMM 遥测判断，必须直接量算子。
# 手段：对 gsbench 201 的同一条排序跑 EXPLAIN(ANALYZE)，读 Sort 节点的
#       "Sort Method" 与 "Memory/Disk" 用量。两模式唯一变量是 native_auto_mode。
set -uo pipefail
export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"
P=15432
RANGE=${RANGE:-112347}     # AMM 关闭时校准出的 512MB 档区间

q() { gsql -d postgres -p $P -At -c "$1" 2>/dev/null; }

probe() {   # $1 = on|off
  gsql -d postgres -p $P -c "ALTER SYSTEM SET gs_amm_native_auto_mode=$1;" >/dev/null 2>&1
  q "SELECT pg_reload_conf();" >/dev/null; sleep 2
  local got; got=$(q "SHOW gs_amm_native_auto_mode;")
  echo "──────────────────────────────────────────────"
  echo "native_auto_mode = $got   （申请 work_mem = 512MB，区间 1..$RANGE）"
  echo "──────────────────────────────────────────────"
  gsql -d postgres -p $P <<SQL 2>&1 | grep -iE "Sort Method|Sort Key|external|Memory:|Disk:|actual time|Total runtime|rows=" | head -12
BEGIN;
SET LOCAL work_mem='524288kB';
SET LOCAL query_dop=1;
SET LOCAL explain_perf_mode=normal;
EXPLAIN (ANALYZE, BUFFERS)
SELECT id,sort_key,payload FROM gsbench.sort_data
 WHERE dist_key BETWEEN 1 AND $RANGE
 ORDER BY payload,sort_key DESC,id;
ROLLBACK;
SQL
  echo "  AMM 侧记账: $(q "SELECT pg_catalog.gs_amm_status();" | tr ' ' '\n' | grep -E '^last_grant_mb|^dynamic_used_mb' | tr '\n' ' ')"
  echo
}

echo "=========== A 组：AMM 介入 ==========="
probe on
echo "=========== B 组：AMM 不介入 ==========="
probe off
echo "=========== 复原 ==========="
gsql -d postgres -p $P -c "ALTER SYSTEM SET gs_amm_native_auto_mode=on;" >/dev/null 2>&1
q "SELECT pg_reload_conf();" >/dev/null
echo "native_auto_mode = $(q 'SHOW gs_amm_native_auto_mode;')"
