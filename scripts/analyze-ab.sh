#!/usr/bin/env bash
# A/B 对照分析：AMM 介入 vs 不介入，逐阶段并排
# 用法: analyze-ab.sh [STAMP]   缺省取最新一组
set -uo pipefail
DIR=${DIR:-/Users/sqlrush/memtest/artifacts/verify}
STAMP=${1:-$(ls -t "$DIR"/amm-ammon-*.csv 2>/dev/null | head -1 | sed 's/.*amm-ammon-\(.*\)\.csv/\1/')}
ON="$DIR/amm-ammon-$STAMP.csv"; OFF="$DIR/amm-ammoff-$STAMP.csv"
[[ -f "$ON" && -f "$OFF" ]] || { echo "找不到 $ON 或 $OFF" >&2; exit 1; }
echo "STAMP=$STAMP   ON=$(wc -l < "$ON") 行   OFF=$(wc -l < "$OFF") 行"

dump() {  # $1=csv $2=标签
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
    if($26+0>dr[s])dr[s]=$26+0
    if($27=="true")gh[s]++
    if($40!=""){if(!(s in hm)||$40+0<hm[s])hm[s]=$40+0}
    if($34!=prev){if($35=="BORROW_FROM_BUFFER")b[s]++; if($35=="TP_RECOVERY")r[s]++} prev=$34
    fl=$5+0
  } END{
    for(s in n) printf "%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%.4f|%d|%d|%d|%.1f\n",
      tag,s,n[s],mn[s],mx[s],du[s],ap[s],ql[s],qa1[s]-qa0[s],qt1[s]-qt0[s],bp1[s]-bp0[s],
      dr[s],gh[s]+0,b[s]+0,r[s]+0,hm[s]
  }' "$1"
}

{ dump "$ON" ON; dump "$OFF" OFF; } | sort -t'|' -k2,2 -k1,1r > /tmp/ab.txt

echo
echo "======== 逐阶段并排（ON = AMM 介入 / OFF = 不介入）========"
printf "%-9s %-4s %5s %6s %6s %7s %4s %5s %5s %5s %6s %8s %4s %4s %4s %7s\n" \
  "阶段" "模式" "样本" "SB低" "SB高" "动已用" "AP" "队长" "入队" "超时" "反压" "drop峰" "热" "借" "还" "hit低%"
awk -F'|' '{printf "%-9s %-4s %5d %6d %6d %7d %4d %5d %5d %5d %6d %8.4f %4d %4d %4d %7.1f\n",
  $2,$1,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16}' /tmp/ab.txt

echo
echo "======== 全程汇总 ========"
for f in "$ON:ON" "$OFF:OFF"; do
  csv=${f%%:*}; tag=${f##*:}
  awk -F, -v t="$tag" 'NR>1{
    if($34!=""&&$34!="-"&&$34!=prev){if($35=="BORROW_FROM_BUFFER")b++; if($35=="TP_RECOVERY")r++} prev=$34
    if($3!=""&&$3+0>0){if(!mn||$3+0<mn)mn=$3+0; if($3+0>mx)mx=$3+0; fl=$5+0; cap=$4+0}
    if($7+0>du)du=$7+0; if($10+0>ap)ap=$10+0
    if(!(bpmin)||$14+0<bpmin)bpmin=$14+0; if($14+0>bpmax)bpmax=$14+0
    if(!(qamin)||$12+0<qamin)qamin=$12+0; if($12+0>qamax)qamax=$12+0
    if($40!=""&&(!hmn||$40+0<hmn))hmn=$40+0
  } END{
    printf "  %-4s SB %d→%d 借出深度=%d MB(%.1f%%) 距地板=%d 动已用峰=%d AP峰=%d 借=%d 还=%d 反压=%d 入队=%d hit低=%.1f%%\n",
      t,mx,mn,mx-mn,100*(mx-mn)/(cap-fl),mn-fl,du+0,ap+0,b+0,r+0,bpmax-bpmin,qamax-qamin,hmn
  }' "$csv"
done

echo
echo "======== TPS（Δt 归一化）========"
for f in "$ON:ON" "$OFF:OFF"; do
  csv=${f%%:*}; tag=${f##*:}
  awk -F, -v t="$tag" 'NR>1&&$2!="-"&&$37!=""&&$1!=""{
    if(pt>0&&$1-pt>0){v=$37/($1-pt); s=$2; n[s]++; sum[s]+=v} pt=$1
  } END{printf "  %-4s ",t; for(x in n) printf "%s=%.0f ",x,sum[x]/n[x]; printf "\n"}' "$csv"
done
