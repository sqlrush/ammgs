#!/usr/bin/env bash
# TP 压力源存活看门狗（第三轮）
# 修正：openGauss 5.0.2 的 pg_stat_activity 没有 backend_type 列，
#       第二轮那条查询一直静默失败（被 2>/dev/null 吞掉），会话构成实际未采集到。
#       改用 application_name + state 分组，不引用 backend_type。
export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"
OUT="${1:?输出文件}"
PGLOG=$(ls -t /home/sqlrush/gauss-amm-data/pg_log/postgresql-*.log 2>/dev/null | head -1)
echo "watchdog3 start $(date -Is)  pg_log=$PGLOG" > "$OUT"
LAST=$(wc -l < "$PGLOG" 2>/dev/null || echo 0)

while true; do
  ts=$(date +%s)
  sess=$(gsql -d postgres -p 15432 -At -F'|' -c "
    SELECT COALESCE(application_name,'?'), COALESCE(state,'?'), count(*)
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid() AND datname IS NOT NULL
    GROUP BY 1,2 ORDER BY 3 DESC;" 2>&1 | tr '\n' ';')
  echo "$ts SESSIONS $sess" >> "$OUT"

  NOW=$(wc -l < "$PGLOG" 2>/dev/null || echo 0)
  if [[ "$NOW" -gt "$LAST" ]]; then
    tail -n $(( NOW - LAST )) "$PGLOG" 2>/dev/null \
      | grep -iE "FATAL|PANIC|ERROR|terminat|cancel|closed|reset" \
      | sed "s/^/$ts PGLOG /" >> "$OUT"
    LAST=$NOW
  fi
  sleep 3
done
