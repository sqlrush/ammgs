#!/usr/bin/env bash
# 第四章取数：每个 step 输出「目标 / 未开 AMM / 开 AMM」三段所需的全部指标
# 用法: analyze-ch4.sh [STAMP]
set -uo pipefail
DIR=${DIR:-/Users/sqlrush/memtest/artifacts/verify}
STAMP=${1:-$(ls -t "$DIR"/amm-ammon-*.csv 2>/dev/null | head -1 | sed 's/.*amm-ammon-\(.*\)\.csv/\1/')}
ON="$DIR/amm-ammon-$STAMP.csv"; OFF="$DIR/amm-ammoff-$STAMP.csv"
[[ -f "$ON" && -f "$OFF" ]] || { echo "找不到 $STAMP 的数据" >&2; exit 1; }

echo "STAMP=$STAMP"
[[ -f "$DIR/fleet-$STAMP.txt" ]] && echo "会话数: $(cat "$DIR/fleet-$STAMP.txt")"

# 列: 3=active_mb 5=sb_min 7=dyn_used 10=ap_count 11=queue_len 12=q_admit
#     13=q_timeout 14=bp_cnt 26=drop 27=guard 34=event_id 35=action 37=dxact 40=hit%
dump() {
  awk -F, -v tag="$2" 'NR>1&&$2!="-"&&$3!=""&&$3+0>0{
    s=$2; n[s]++
    if(!(s in mn)||$3+0<mn[s])mn[s]=$3+0
    if($3+0>mx[s])mx[s]=$3+0
    if($7+0>du[s])du[s]=$7+0
    if($10+0>ap[s])ap[s]=$10+0
    if($11+0>ql[s])ql[s]=$11+0
    if(!(s in qa0)||$12+0<qa0[s])qa0[s]=$12+0
    if($12+0>qa1[s])qa1[s]=$12+0
    if(!(s in qt0)||$13+0<qt0[s])qt0[s]=$13+0
    if($13+0>qt1[s])qt1[s]=$13+0
    if(!(s in bp0)||$14+0<bp0[s])bp0[s]=$14+0
    if($14+0>bp1[s])bp1[s]=$14+0
    if($40!=""){if(!(s in hm)||$40+0<hm[s])hm[s]=$40+0; hs[s]+=$40; hn[s]++}
    if($34!=prev){if($35=="BORROW_FROM_BUFFER")b[s]++; if($35=="TP_RECOVERY")r[s]++} prev=$34
    if(pt>0&&$1-pt>0&&$37!=""){tps[s]+=$37/($1-pt); tn[s]++}
    pt=$1
  } END{
    for(s in n) printf "%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%.1f|%.1f|%.0f\n",
      tag,s,n[s],mn[s],mx[s],du[s],ap[s],ql[s],qa1[s]-qa0[s],qt1[s]-qt0[s],bp1[s]-bp0[s],
      b[s]+0,(hn[s]?hs[s]/hn[s]:0),hm[s],(tn[s]?tps[s]/tn[s]:0)
  }' "$1"
}

{ dump "$OFF" OFF; dump "$ON" ON; } | sort -t'|' -k2,2 -k1,1 > /tmp/ch4.txt

echo
printf "%-10s %-4s %5s %6s %6s %7s %5s %5s %5s %5s %6s %5s %8s %8s %8s\n" \
  阶段 模式 样本 SB低 SB高 动已用 AP峰 队长 入队 超时 反压 借 hit均 hit低 TPS
awk -F'|' '{printf "%-10s %-4s %5d %6d %6d %7d %5d %5d %5d %5d %6d %5d %8.1f %8.1f %8.0f\n",
  $2,$1,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15}' /tmp/ch4.txt

echo
echo "======== 全程汇总 ========"
for f in "$OFF:OFF" "$ON:ON"; do
  csv=${f%%:*}; tag=${f##*:}
  awk -F, -v t="$tag" 'NR>1{
    if($34!=""&&$34!=prev){if($35=="BORROW_FROM_BUFFER")b++; if($35=="TP_RECOVERY")r++} prev=$34
    if($3!=""&&$3+0>0){if(!mn||$3+0<mn)mn=$3+0; if($3+0>mx)mx=$3+0; fl=$5+0}
    if($7+0>du)du=$7+0; if($10+0>ap)ap=$10+0
    if(!bp0||$14+0<bp0)bp0=$14+0; if($14+0>bp1)bp1=$14+0
    if(!qa0||$12+0<qa0)qa0=$12+0; if($12+0>qa1)qa1=$12+0
    if(!qt0||$13+0<qt0)qt0=$13+0; if($13+0>qt1)qt1=$13+0
  } END{printf "  %-4s SB %d→%d 借出%d MB 距地板%d 动已用峰%d AP峰%d 借%d 还%d 反压%d 入队%d 超时%d\n",
    t,mx,mn,mx-mn,mn-fl,du+0,ap+0,b+0,r+0,bp1-bp0,qa1-qa0,qt1-qt0}' "$csv"
done

echo
echo "======== TP 吞吐（gsbench operations）========"
for t in ammoff ammon; do
  for seg in s1234 s5; do
    f="$DIR/tp-${t}-${seg}-$STAMP.log"
    [[ -f "$f" ]] && printf "  %-7s %-6s ops=%-8s errors=%s\n" "$t" "$seg" \
      "$(grep -o '"metric":"operations","target":0,"actual":[0-9]*' "$f" | grep -o '[0-9]*$')" \
      "$(grep -o '"metric":"errors","target":0,"actual":[0-9]*' "$f" | grep -o '[0-9]*$')"
  done
done

echo
echo "======== AP 会话内存错误/降级 ========"
for t in ammoff ammon; do
  f="$DIR/ap-${t}-$STAMP.log"
  [[ -f "$f" ]] && echo "  [$t] 错误 $(grep -cE 'ERROR|FATAL' "$f") 条；会话启动记录：$(grep -c 'actual=' "$f") 次"
done
