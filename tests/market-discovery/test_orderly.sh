#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Load the actual discovery functions without starting the venue workers.
source <(sed '/^queried_at=/,$d' "$root/src/tools/market/discover-markets.sh") ETH
scratch="$scratch_root/orderly"; mkdir "$scratch"
cat >"$scratch/catalog.json" <<'JSON'
[{"symbol":"PERP_ETH_USDC","status":"ACTIVE"},
 {"symbol":"PERP_HOOD_USDC_mythos","display_symbol_name":"HOOD","broker_id":"mythos","status":"ACTIVE"},
 {"symbol":"PERP_HOOD_USDC_other","status":"ACTIVE"},
 {"symbol":"PERP_MSTR_USDC_mythos","status":"ACTIVE"},
 {"symbol":"PERP_XAU_USDC","display_symbol_name":"XAU (Gold)","status":"ACTIVE"},
 {"symbol":"PERP_1000BONK_USDC","status":"ACTIVE"},
 {"symbol":"PERP_ETHFI_USDC","status":"ACTIVE"},
 {"symbol":"PERP_SKHYNIX_USDC_mythos","status":"ACTIVE"},
 {"symbol":"PERP_SKHY_USDC_mythos","status":"ACTIVE"},
 {"symbol":"PERP_OLD_USDC","status":"HALTED"}]
JSON
quote=USDC
for ticker in ETH HOOD MSTR XAU BONK; do
 match_orderly >"$scratch/result.json"
 jq -e '.markets|length>0' "$scratch/result.json" >/dev/null
done
ticker=ETH; match_orderly | jq -e '.markets|length==1 and .[0].symbol=="PERP_ETH_USDC"' >/dev/null
ticker=HOOD; match_orderly | jq -e '.markets|length==2 and .[0].symbol=="PERP_HOOD_USDC_mythos"' >/dev/null
ticker=BONK; match_orderly | jq -e '.markets[0].baseAsset=="1000BONK"' >/dev/null
ticker=SKHX; match_orderly | jq -e '.markets|length==1 and .[0].symbol=="PERP_SKHYNIX_USDC_mythos"' >/dev/null
ticker=OLD; match_orderly | jq -e '.markets==[]' >/dev/null
ticker=UNKNOWN; match_orderly | jq -e '.markets==[]' >/dev/null
ticker=ETH; quote=USDT; match_orderly | jq -e '.markets==[]' >/dev/null
source "$root/src/tools/market/get-market-candles.sh"
math=$(cat "$root/src/tools/market/route_math.jq")
snap=$(cat "$root/src/tools/market/snapshot_math.jq")
jq -ne "$candle_jq $math $snap"'
 {venue:"orderly",symbol:"PERP_1000BONK_USDC",ticker:"BONK",baseAsset:"1000BONK",quoteAsset:"USDC",product:"perpetual",funding_period:4,status:"ACTIVE"} as $m |
 {asks:[{price:"101",quantity:"2"}],bids:[{price:"99",quantity:"3"}],ts:1234} as $b |
 {est_funding_rate:0.0002,last_funding_rate:0.0001,next_funding_time:999,open_interest:5,mark_price:100,index_price:99,"24h_amount":700} as $meta |
 snapshot($m;$b;null;null;$meta;1;false;"now") as $s |
 $s.symbol==$m.symbol and $s.exposureMultiplier==1000 and
 $s.funding.intervalHours==4 and $s.funding.kind=="estimated" and $s.funding.value==0.0002 and $s.funding.lastSettledRate==0.0001 and
 $s.openInterest.unit=="base" and $s.openInterest.quoteValue==500 and
 $s.volume24h.value==700 and $s.volume24h.unit=="USDC" and $s.book.askLevels==1 and $s.book.sourceTime==1234 and
 (snapshot($m;null;null;null;null;1;false;"now") | .funding.status=="unknown" and .openInterest.status=="unknown" and .book.status=="unknown") and
 (snapshot($m;{asks:[],bids:[]};null;null;$meta;1;false;"now").book.status=="empty")
' >/dev/null
echo 'Orderly native symbols, suffixes, exact matching, multipliers, funding, OI and depth passed.'
