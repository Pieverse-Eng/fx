#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_root/src/tools/market/get-market-candles.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
now=1800001234000
duration=900000
open=$((now/duration*duration))
jq -n --argjson open "$open" --argjson duration "$duration" '[range(60;-1;-1)|[$open-.*$duration,100,103,98,102,12]]' >"$fixture/rows.json"
# Each actual venue response shape must normalize to the same closed/current series.
for venue in aster binance bitget gate hyperliquid kraken lighter okx-cex; do
  m=$(jq -cn --arg venue "$venue" '{ticker:"BTC",venue:$venue,symbol:"BTCUSDT",baseAsset:"BTC",product:"spot",quoteAsset:"USDT"}')
  case $venue in
    aster|binance) cp "$fixture/rows.json" "$fixture/input.json" ;;
    bitget) jq '{data:map(map(tostring))}' "$fixture/rows.json" >"$fixture/input.json" ;;
    gate) jq 'map([(.[0]/1000|tostring),"1224",(.[4]|tostring),(.[2]|tostring),(.[3]|tostring),(.[1]|tostring),(.[5]|tostring)])' "$fixture/rows.json" >"$fixture/input.json" ;;
    hyperliquid) jq 'map({t:.[0],o:.[1],h:.[2],l:.[3],c:.[4],v:.[5]})' "$fixture/rows.json" >"$fixture/input.json" ;;
    kraken) jq '{XXBTZUSD:map([.[0]/1000,.[1],.[2],.[3],.[4],"101",.[5],2]),last:0}' "$fixture/rows.json" >"$fixture/input.json" ;;
    lighter) jq '{code:200,c:map({t:.[0],o:.[1],h:.[2],l:.[3],c:.[4],v:.[5]})}' "$fixture/rows.json" >"$fixture/input.json" ;;
    okx-cex) jq --argjson open "$open" 'map(.+[12,1224,(if .[0]<$open then "1" else "0" end)])|reverse' "$fixture/rows.json" >"$fixture/input.json" ;;
  esac
  normalize_candles "$m" 15m "$fixture/input.json" "$now" >"$fixture/output.json"
  jq -e --argjson open "$open" '(.closed|length)==50 and (.current[0]==$open) and (.closed==(.closed|sort_by(.[0]))) and all(.closed[];.[1:]==[100,103,98,102,12])' "$fixture/output.json" >/dev/null
  # An API error must not look like empty successful market data.
  echo '{"code":"500","msg":"failed"}' >"$fixture/error.json"
  if normalize_candles "$m" 15m "$fixture/error.json" "$now" >/dev/null 2>&1; then echo "Expected $venue API error rejection"; exit 1; fi
done
# Contract multipliers and product-native volume units.
m='{"ticker":"PEPE","baseAsset":"1000PEPE","venue":"lighter","product":"perpetual"}'
jq '{code:200,c:map({t:.[0],o:.[1],h:.[2],l:.[3],c:.[4],v:.[5]})}' "$fixture/rows.json" >"$fixture/input.json"
normalize_candles "$m" 15m "$fixture/input.json" "$now" | jq -e '.closed[0][1:]==[0.1,0.103,0.098,0.102,12000]' >/dev/null
m='{"ticker":"PEPE","baseAsset":"1000PEPE","venue":"binance","product":"perpetual"}'
normalize_candles "$m" 15m "$fixture/rows.json" "$now" | jq -e '.closed[0][1:]==[0.1,0.103,0.098,0.102,12000]' >/dev/null
for pair in 'PEPE 1000PEPE 1000' 'MOG 1000000MOG 1000000' 'BABYDOGE 1MBABYDOGE 1000000' '1000PEPE 1000PEPE 1'; do
  read -r ticker base scale <<<"$pair"
  m=$(jq -cn --arg ticker "$ticker" --arg base "$base" '{ticker:$ticker,baseAsset:$base,venue:"aster",product:"perpetual"}')
  normalize_candles "$m" 15m "$fixture/rows.json" "$now" | jq -e --argjson scale "$scale" '.closed[0][1:]==[100/$scale,103/$scale,98/$scale,102/$scale,12*$scale]' >/dev/null
done
m='{"ticker":"BTC","baseAsset":"BTC","venue":"gate","product":"perpetual","contractSize":"0.01"}'
jq 'map({t:(.[0]/1000),o:.[1],h:.[2],l:.[3],c:.[4],v:.[5]})' "$fixture/rows.json" >"$fixture/input.json"
normalize_candles "$m" 15m "$fixture/input.json" "$now" | jq -e '.closed[0][5]==0.12' >/dev/null
m='{"ticker":"BTC","baseAsset":"BTC","venue":"kraken","symbol":"PI_XBTUSD","product":"perpetual"}'
jq '{candles:map({time:.[0],open:.[1],high:.[2],low:.[3],close:.[4],volume:.[5]})}' "$fixture/rows.json" >"$fixture/input.json"
normalize_candles "$m" 15m "$fixture/input.json" "$now" | jq -e 'all(.closed[];.[5]==null)' >/dev/null
# Latest-trade time is the trade time, never request time or a candle boundary.
echo '[{"price":"102","time":1800001233000}]' >"$fixture/trade.json"
normalize_trade '{"ticker":"BTC","baseAsset":"BTC","venue":"binance"}' "$fixture/trade.json" "$now" | jq -e '.price==102 and .time==1800001233000' >/dev/null
# The public boundary formats every timestamp, preserving milliseconds and missing data.
echo '{"results":[{"asOf":1788721732188,"lastTrade":{"price":102,"time":1788721200007},"timeframes":{"15m":{"closed":[[1788720300000,100,103,98,102,12]],"current":[1788721200000,102,103,101,102,1]},"1h":null,"4h":{"closed":[],"current":null}}},{"asOf":null,"lastTrade":null,"timeframes":{"15m":null,"1h":null,"4h":null}}],"errors":[]}' | format_candle_times >"$fixture/utc.json"
jq -e '.results[0] as $r |
  $r.asOf=="2026-09-06T19:08:52.188Z" and
  $r.lastTrade=={price:102,time:"2026-09-06T19:00:00.007Z"} and
  $r.timeframes["15m"].closed[0]==["2026-09-06T18:45:00.000Z",100,103,98,102,12] and
  $r.timeframes["15m"].current[0]=="2026-09-06T19:00:00.000Z" and
  $r.timeframes["1h"]==null and $r.timeframes["4h"].current==null and
  .results[1].asOf==null and .results[1].lastTrade==null and .errors==[]' "$fixture/utc.json" >/dev/null
# Invalid OHLC bounds fail instead of turning into model-visible invented candles.
echo '[[1799999100000,100,99,98,102,12]]' >"$fixture/bad.json"
if normalize_candles '{"ticker":"BTC","baseAsset":"BTC","venue":"binance"}' 15m "$fixture/bad.json" "$now" >/dev/null 2>&1; then exit 1; fi
echo 'Candle normalization passed for all eight venues, closed/current separation, price/volume units, and invalid data.'
# Compare actual adapter turnover fields, including Bitget platform-only rToken turnover.
scratch_root="$fixture/volume"; mkdir -p "$scratch_root/stats"
for venue in aster binance; do
  echo '{"perpetual":[{"symbol":"BTCUSDT","quoteVolume":"10"}]}' >"$scratch_root/stats/$venue.json"
  load_volume "{\"venue\":\"$venue\",\"symbol\":\"BTCUSDT\",\"product\":\"perpetual\"}" | jq -e '.volume==10' >/dev/null
done
venue=bitget
echo '{"SPOT":{"data":[{"symbol":"RIRENUSDT","turnover24h":"10000","platformTurnover24h":"12"}]}}' >"$scratch_root/stats/bitget.json"
load_volume '{"venue":"bitget","category":"SPOT","symbol":"RIRENUSDT"}' | jq -e '.volume==12' >/dev/null
venue=kraken
echo '{"spot":{"XXBTZUSD":{"v":["1","12"],"p":["1","2"]}},"pairs":[{"altname":"XBTUSD","key":"XXBTZUSD"}]}' >"$scratch_root/stats/kraken.json"
load_volume '{"venue":"kraken","product":"spot","symbol":"XBTUSD","wsname":"XBT/USD"}' | jq -e '.volume==24' >/dev/null
venue=gate
echo '{"perpetual":[{"contract":"BTC_USDT","volume_24h_quote":"20"}]}' >"$scratch_root/stats/gate.json"
load_volume '{"venue":"gate","product":"perpetual","symbol":"BTC_USDT"}' | jq -e '.volume==20' >/dev/null
venue=hyperliquid
echo '{"xyz":[{"universe":[{"name":"xyz:BTC"}]},[{"dayNtlVlm":"22"}]],"spot":[{"universe":[{"name":"@1"}]},[{"dayNtlVlm":"23"}]]}' >"$scratch_root/stats/hyperliquid.json"
load_volume '{"venue":"hyperliquid","dex":"xyz","product":"perpetual","symbol":"xyz:BTC"}' | jq -e '.volume==22' >/dev/null
load_volume '{"venue":"hyperliquid","product":"spot","pairId":"@1"}' | jq -e '.volume==23' >/dev/null
venue=lighter
echo '{"order_book_details":[{"market_id":1,"daily_quote_token_volume":24}]}' >"$scratch_root/stats/lighter.json"
load_volume '{"venue":"lighter","marketId":1}' | jq -e '.volume==24' >/dev/null
venue=okx-cex
echo '{"perpetual":[{"instId":"BTC-USDT-SWAP","volCcy24h":"10","last":"3"}]}' >"$scratch_root/stats/okx-cex.json"
load_volume '{"venue":"okx-cex","product":"perpetual","symbol":"BTC-USDT-SWAP"}' | jq -e '.volume==30 and .estimated' >/dev/null
# Highest-volume failure falls back as a whole market, never stitching venues across timeframes.
scratch_root="$fixture/fallback"; cache_dir="$fixture/logs"; mkdir -p "$scratch_root" "$cache_dir"
cat >"$scratch_root/ranked.json" <<'JSON'
[{"ticker":"BTC","baseAsset":"BTC","quoteAsset":"USDT","venue":"binance","symbol":"BTCUSDT","product":"perpetual","volumeUSD":100},
 {"ticker":"BTC","baseAsset":"BTC","quoteAsset":"USDT","venue":"bitget","symbol":"BTCUSDT","product":"perpetual","volumeUSD":50}]
JSON
fetch_candle() {
  local m=$1 tf=$2 file=$3 now=$4 duration=900000
  [[ $tf != 1h ]] || duration=3600000; [[ $tf != 4h ]] || duration=14400000
  if [[ $(jq -r '.venue' <<<"$m") == binance ]]; then echo null >"$file"; return; fi
  jq -n --argjson now "$now" --argjson duration "$duration" '{data:[range(60;-1;-1)|[($now/$duration|floor)*$duration-.*$duration,100,103,98,102,12]]}' >"$file"
}
fetch_last_trade() { jq -n --argjson now "$(date +%s%3N)" '{data:[{price:"102",ts:($now-1)}]}' >"$2"; }
wait_queries() { for pid in "${pids[@]}"; do wait "$pid"; done; pids=(); }
candle_asset BTC "$scratch_root/ranked.json"
jq -e '.errors==[] and (.result|has("source")|not) and (.result.timeframes|all(.[];.closed|length==50))' "$scratch_root/candles-BTC/result.json" >/dev/null
jq -se '.[0].venue=="binance" and .[0].usableTimeframes==0 and .[1].venue=="bitget" and .[1].usableTimeframes==3' "$cache_dir/candle-source-BTC.jsonl" >/dev/null
echo 'Volume adapters and whole-market fallback passed.'
# A failed diagnostic copy must not invalidate already-normalized candles.
rm -rf "$scratch_root/candles-BTC"
cp() {
  if [[ $2 == "$cache_dir/candle-source-BTC.jsonl" ]]; then
    echo 'cp: Permission denied (fixture)' >&2
    return 1
  fi
  command cp "$@"
}
candle_asset BTC "$scratch_root/ranked.json" 2>"$fixture/cache-warning"
unset -f cp
jq -e '.errors==[] and (.result.timeframes|all(.[];.closed|length==50))' "$scratch_root/candles-BTC/result.json" >/dev/null
grep -q 'Permission denied' "$fixture/cache-warning"
grep -q 'keeping market result' "$fixture/cache-warning"
# Real worker failures retain exit status and stderr, including failures before mkdir.
scratch_root="$fixture/worker-failure"; mkdir -p "$scratch_root"; tickers=(BTC)
echo '{"venue":"binance","results":[{"ticker":"BTC","markets":[{"symbol":"BTCUSD","product":"perpetual","quoteAsset":"USD"}]}],"errors":[]}' >"$fixture/discovery.json"
fetch_volumes() {
  mkdir -p "$scratch_root/stats"
  echo '[]' >"$scratch_root/stats/kraken-pairs.json"
  echo '{}' >"$scratch_root/stats/kraken-spot.json"
  echo '[]' >"$scratch_root/stats/binance-spot.json"
}
load_volume() { echo '{"volume":100}'; }
candle_asset() { echo 'worker-specific failure (fixture)' >&2; exit 23; }
run_candles "$fixture/discovery.json" >"$fixture/failed-result.json" 2>"$fixture/worker-stderr"
jq -e '.results[0].timeframes["15m"]==null and any(.errors[];.ticker=="BTC" and .exitCode==23)' "$fixture/failed-result.json" >/dev/null
grep -q 'worker-specific failure' "$fixture/worker-stderr"
grep -q 'BTC (exit 23)' "$fixture/worker-stderr"
echo 'Diagnostic cache failure isolation and worker error reporting passed.'
