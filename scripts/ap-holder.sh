#!/usr/bin/env bash
# 复刻 gsbench 201 的 AP 负载：游标持有型排序
# 用法: ap-holder.sh <work_mem_kb> <range_end> <hold_seconds> <holder_id>
export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"

WM_KB="${1:?work_mem kB}"; RANGE="${2:?range_end}"; HOLD="${3:-120}"; HID="${4:-0}"

gsql -d postgres -p 15432 -v ON_ERROR_STOP=0 <<SQL 2>&1
BEGIN;
SET LOCAL work_mem='${WM_KB}kB';
SET LOCAL query_dop=1;
DECLARE apc${HID} NO SCROLL CURSOR FOR
  SELECT id,sort_key,payload FROM gsbench.sort_data
   WHERE dist_key BETWEEN 1 AND ${RANGE}
   ORDER BY payload,sort_key DESC,id;
FETCH 1 FROM apc${HID};
SELECT pg_sleep(${HOLD});
COMMIT;
SQL
