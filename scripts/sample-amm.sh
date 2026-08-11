#!/usr/bin/env bash
# AMM 测试采样器：1 秒一次，输出 CSV
# 记录 共享池 / 动态池 大小变化 + TPS + buffer_hit
# 用法: sample-amm.sh <输出CSV> <阶段标记文件>
set -uo pipefail

export GAUSSHOME=/home/sqlrush/gauss-amm-src/mppdb_temp_install
export PATH="$GAUSSHOME/bin:$PATH"
export LD_LIBRARY_PATH="$GAUSSHOME/lib:$GAUSSHOME/lib/postgresql:$GAUSSHOME/lib/krb5"

OUT="${1:?需要输出文件}"
STAGEFILE="${2:-/tmp/amm-stage}"
PORT=15432

f() { grep -o "\b$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

echo "ts,stage,active_mb,max_mb,sb_min_mb,dyn_target_mb,dyn_used_mb,dyn_free_mb,grant_debt_mb,ap_count,ap_queue_len,ap_queue_admit,ap_queue_timeout,backpressure_cnt,bp_reason,buf_active_gr,buf_draining_gr,reclaiming_gr,free_gr,ap_reserved_gr,ap_active_gr,total_gr,gr_consistent,tp_baseline_tps,tp_recent_tps,tp_drop_ratio,tp_guard_hot,io_guard_hot,spill_rate,last_grant_mb,eff_grant_kb,eff_downgrade,grant_shrink,pool_event_id,pool_action,binding,tps,blks_hit,blks_read,buffer_hit_pct" > "$OUT"

prev_x=""; prev_hit=""; prev_read=""
while true; do
  ts=$(date +%s)
  stage=$(cat "$STAGEFILE" 2>/dev/null || echo "-")
  s=$(gsql -d postgres -p $PORT -At -c "SELECT pg_catalog.gs_amm_status();" 2>/dev/null)
  d=$(gsql -d postgres -p $PORT -At -F',' -c \
      "SELECT COALESCE(sum(xact_commit),0), COALESCE(sum(blks_hit),0), COALESCE(sum(blks_read),0) FROM pg_stat_database;" 2>/dev/null)
  if [[ -z "$s" ]]; then echo "$ts,$stage,SAMPLE_ERROR" >> "$OUT"; sleep 1; continue; fi

  x=$(cut -d, -f1 <<<"$d"); hit=$(cut -d, -f2 <<<"$d"); rd=$(cut -d, -f3 <<<"$d")
  tps=""; hitpct=""
  if [[ -n "$prev_x" ]]; then
    tps=$(( x - prev_x ))
    dh=$(( hit - prev_hit )); dr=$(( rd - prev_read )); tot=$(( dh + dr ))
    if (( tot > 0 )); then hitpct=$(awk -v a="$dh" -v b="$tot" 'BEGIN{printf "%.2f", a*100/b}'); fi
  fi
  prev_x="$x"; prev_hit="$hit"; prev_read="$rd"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$stage" \
    "$(f active_mb "$s")" "$(f max_mb "$s")" "$(f shared_buffers_min_mb "$s")" \
    "$(f dynamic_target_mb "$s")" "$(f dynamic_used_mb "$s")" "$(f dynamic_free_mb "$s")" \
    "$(f grant_debt_mb "$s")" "$(f active_ap_count "$s")" "$(f ap_queue_len "$s")" \
    "$(f ap_queue_admit_count "$s")" "$(f ap_queue_timeout_count "$s")" \
    "$(f backpressure_count "$s")" "$(f last_backpressure_reason "$s")" \
    "$(f buffer_active_granules "$s")" "$(f buffer_draining_granules "$s")" \
    "$(f reclaiming_granules "$s")" "$(f free_granules "$s")" \
    "$(f ap_reserved_granules "$s")" "$(f ap_active_granules "$s")" \
    "$(f total_granules "$s")" "$(f granule_state_consistent "$s")" \
    "$(f tp_baseline_tps "$s")" "$(f tp_recent_tps "$s")" \
    "$(f tp_raw_drop_ratio "$s")" "$(f tp_guard_hot "$s")" "$(f io_guard_hot "$s")" \
    "$(f temp_spill_mb_rate "$s")" "$(f last_grant_mb "$s")" \
    "$(f effective_grant_kb "$s")" "$(f effective_downgrade_count "$s")" \
    "$(f grant_shrink_count "$s")" "$(f pool_event_id "$s")" "$(f pool_event_action "$s")" \
    "$(f binding_constraint "$s")" "$tps" "$hit" "$rd" "$hitpct" \
    >> "$OUT"
  sleep 1
done
