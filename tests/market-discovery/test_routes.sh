#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
math=$(cat "$root/src/tools/market/route_math.jq")
jq -ne "$math"'
  {venue:"bitget",symbol:"RCRCLUSDT",product:"spot",category:"SPOT",effectivePrice:100,fees:1,quotedAt:"fixture",id:"venue"} as $venue |
  {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1",provider:"fixture",inputContract:"0x2",gas:1,effectivePrice:101} as $chain |
  (comparison_result([$venue,$chain];[]) == {bestRoute:{venue:"bitget",symbol:"RCRCLUSDT",product:"spot",category:"SPOT"},gaps:[]}) and
  (comparison_result([$chain,$venue];[]).bestRoute == {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1"}) and
  (comparison_result([$venue+{venue:"hyperliquid",assetId:110109,dex:"xyz"},$chain];[]).bestRoute.assetId == 110109) and
  (comparison_result([$venue,$chain];[{venue:"kraken",symbol:"CRCLxUSD",message:"Unavailable book"}]).gaps == ["kraken / CRCLxUSD: Unavailable book"]) and
  (comparison_result([];[]) == {bestRoute:null,gaps:["No eligible route with a valid quote"]}) and
  (comparison_result([$venue];[]).gaps == ["Only one eligible route; comparative minimum not established"])
' >/dev/null
echo 'Compact route selection, chain symbols, routing identifiers and comparison gaps passed.'
jq -ne "$math"'
  def near($x): (. - $x)|fabs<1e-8;
  {id:"a",venue:"binance",symbol:"BTCUSDT",product:"spot",quote:"USDT",quotedAt:"2026-09-07T00:00:00Z",
   step:0,minQuantity:0,minValue:0,fee:0.01,extraFee:0,feeAsset:"base",feeSource:"fixture",
   asks:[{price:100,quantity:5},{price:110,quantity:10}],bids:[{price:99,quantity:15}]} as $c |
  (spot($c;1000)) as $base | (spot($c+{feeAsset:"quote"};1000)) as $quote |
  ($base.expectedQuantity|near((5+500/110)*0.99)) and ($base.spend|near(1000)) and
  ($quote.expectedQuantity|near(5+(1000/1.01-500)/110)) and ($quote.spend|near(1000)) and
  ((try spot($c;100000) catch .)=="Insufficient displayed depth") and
  ((try spot($c+{minValue:2000};1000) catch .)=="Below minimum order") and
  (perpetual($c;2;"long").effectivePrice|near(101)) and
  (perpetual($c;2;"short").effectivePrice|near(98.01)) and
  ((try perpetual($c+{step:1};2.5;"long") catch .)|startswith("Lot step")) and
  (depth([["100","2"]];0.01;1000;0.99;false)==[{price:0.099,quantity:20}]) and
  (usd({USDTUSD:"0.99",USDCUSDT:"1.02"};"USDC")|near(1.0098)) and
  ([usd({};"USDT")]|length==0)
' >/dev/null
# Nonlinear quotes: reduced budget must trigger another request, not rescale output.
source "$root/src/tools/market/get-market-candles.sh"
source "$root/src/tools/market/onchain-routes.sh"
route_math=$math
scratch_root=$(mktemp -d); trap 'rm -rf "$scratch_root"' EXIT
mkdir -p "$scratch_root/routes"
echo '{"USDTUSD":"1"}' >"$scratch_root/routes/rates.json"
route_input='{"ticker":"CRCL","product":"spot","amount":"1000"}'
fixture_mode=success
bg_public() {
  local target=$1 path=$2 body=$3
  if [[ $path == *batchGetBaseInfo ]]; then echo '{"status":0,"data":{"list":[{"price":"1"}]}}' >"$target"
  else
    jq -n --argjson body "$body" --arg mode "$fixture_mode" '
      ($body.fromAmount|tonumber) as $a |
      {status:0,data:{quoteResults:[{outAmount:($a/100 - pow($a/1000;2)),gasFees:{gasFeeAmountInUsd:(if $mode=="missinggas" then null else "2" end)},
      market:{id:"fixture",label:"Fixture AMM"},priceImpact:{priceImpactWarn:(if $mode=="forbidden" then "forbidden" else "none" end)}}]}}' >"$target"
    jq -c . <<<"$body" >>"$scratch_root/requests.jsonl"
  fi
}
d='{"chain":"bnb","issuer":"bstocks","symbol":"CRCLB","contract":"0x1","inputAsset":"USDT","inputContract":"0x2"}'
quote_bg_stock "$d" 0
jq -e '.[0].spend<=1000 and .[0].gas==2 and .[0].amountIn!="1000" and .[0].expectedQuantity>0' "$scratch_root/routes/chain-0/routes.json" >/dev/null
[[ $(wc -l <"$scratch_root/requests.jsonl") == 2 ]]
fixture_mode=forbidden; quote_bg_stock "$d" 1
[[ -s $scratch_root/routes/chain-1/error.json && ! -e $scratch_root/routes/chain-1/routes.json ]]
fixture_mode=missinggas; quote_bg_stock "$d" 2
[[ -s $scratch_root/routes/chain-2/error.json && ! -e $scratch_root/routes/chain-2/routes.json ]]
echo 'Route arithmetic, budget re-quote, missing gas and forbidden route tests passed.'
# Adapter tests exercise full normalization, including array-shaped OKX and Kraken success envelopes.
source "$root/src/tools/market/compare-trade-routes.sh"
market_read() { cp "$scratch_root/book-fixture.json" "$1"; }
route_input='{"ticker":"BTC","product":"perp","direction":"long","amount":"1000"}'
for venue in aster binance bitget gate hyperliquid kraken lighter okx-cex; do
  mkdir -p "$scratch_root/$venue"
  m=$(jq -cn --arg venue "$venue" '{ticker:"BTC",baseAsset:"BTC",quoteAsset:"USDT",venue:$venue,symbol:"BTCUSDT",product:"perpetual",status:"online",dex:"default",szDecimals:4,category:"USDT-FUTURES"}')
  echo '{"asks":[[100,20]],"bids":[[99,20]]}' >"$scratch_root/book-fixture.json"
  case "$venue" in
    aster) echo '{"symbols":[{"symbol":"BTCUSDT","filters":[]}]}' >"$scratch_root/aster/catalog.json";;
    binance) echo '{"symbols":[{"symbol":"BTCUSDT","filters":[]}]}' >"$scratch_root/binance/futures.json";;
    bitget)
      echo '{"data":[{"symbol":"BTCUSDT","takerFeeRate":"0.0006","quantityMultiplier":"0.001"}]}' >"$scratch_root/bitget/USDT-FUTURES.json"
      echo '{"data":{"a":[[100,20]],"b":[[99,20]]}}' >"$scratch_root/book-fixture.json";;
    gate)
      echo '[{"name":"BTCUSDT","type":"direct","quanto_multiplier":"0.01","taker_fee_rate":"0.00075","order_size_min":"1"}]' >"$scratch_root/gate/perpetual.json"
      echo '{"asks":[{"p":100,"s":2000}],"bids":[{"p":99,"s":2000}]}' >"$scratch_root/book-fixture.json";;
    hyperliquid) echo '{"levels":[[{"px":99,"sz":20}],[{"px":100,"sz":20}]]}' >"$scratch_root/book-fixture.json";;
    kraken)
      m=$(jq '.symbol="PF_XBTUSD"' <<<"$m")
      echo '[{"symbol":"PF_XBTUSD","contractValueTradePrecision":4}]' >"$scratch_root/kraken/perpetual.json"
      echo '{"result":"success","orderBook":{"asks":[[100,20]],"bids":[[99,20]]}}' >"$scratch_root/book-fixture.json";;
    lighter)
      echo '{"taker_fee":"0.0000","supported_size_decimals":4,"asks":[{"price":100,"remaining_base_amount":20}],"bids":[{"price":99,"remaining_base_amount":20}]}' >"$scratch_root/book-fixture.json";;
    okx-cex)
      echo '[{"instId":"BTCUSDT","ctType":"linear","ctVal":"0.01","lotSz":"0.01","minSz":"0.01"}]' >"$scratch_root/okx-cex/instruments.json"
      echo '[{"asks":[[100,2000]],"bids":[[99,2000]]}]' >"$scratch_root/book-fixture.json";;
  esac
  route_book "$m" "test-$venue"
  jq -e '.asks[0]=={price:100,quantity:20} and .bids[0]=={price:99,quantity:20} and .fee>=0' "$scratch_root/routes/test-$venue/candidate.json" >/dev/null
  if [[ $venue == hyperliquid || $venue == lighter ]]; then jq -e '.extraFee==0.0005' "$scratch_root/routes/test-$venue/candidate.json" >/dev/null; fi
done
echo 'All eight order-book adapter shapes and platform fees passed.'

jq -ne "$math"'
 live_rates([{symbol:"USDTUSD",count:2,closeTime:10000},{symbol:"GBPUSD",count:0,closeTime:10000},{symbol:"OLDUSD",count:10,closeTime:1}];
   [{symbol:"USDTUSD",bidPrice:"0.998",askPrice:"1",bidQty:"2",askQty:"2"},{symbol:"GBPUSD",bidPrice:"1.1",askPrice:"1.11",bidQty:"2",askQty:"2"},
    {symbol:"OLDUSD",bidPrice:"1",askPrice:"1",bidQty:"2",askQty:"2"}];309999) == {USDTUSD:0.999}
' >/dev/null
echo 'Stale/inactive FX pairs cannot enter cost rankings.'
# Solana requires a re-quote, token-mint identity, gas, and raw-unit multiplier normalization.
route_input='{"ticker":"CRCL","product":"spot","amount":"1000"}'
echo '{"USDTUSD":"1","USDCUSD":"1","SOLUSDT":"100"}' >"$scratch_root/routes/rates.json"
FX_PLATFORM_DFLOW_QUOTE_URL=https://fixture.invalid/quote
FX_PLATFORM_QUOTE_TOKEN=fixture-only-capability
sol_bad_mint=0
market_read() {
  local target=$1; shift
  if [[ $target == */multiplier.json ]]; then echo '{"currentMultiplier":2}' >"$target"; return; fi
  local body=''
  while (( $# )); do if [[ $1 == -d ]]; then body=$2; break; fi; shift; done
  jq -n --argjson body "$body" --argjson bad "$sol_bad_mint" '
   {ok:true,data:{inputMint:$body.inputMint,outputMint:(if $bad==1 then "wrong" else $body.outputMint end),inAmount:$body.amount,
     outAmount:"400000000",outputMintDecimals:8,networkFeeLamports:"10000000",route:"fixture"}}' >"$target"
  jq -c . <<<"$body" >>"$scratch_root/sol-requests.jsonl"
}
d='{"chain":"solana","issuer":"xstocks","symbol":"CRCLx","contract":"StockMint","inputAsset":"USDC","inputContract":"UsdcMint"}'
quote_sol_stock "$d" sol
jq -e '.[0].expectedQuantity==8 and .[0].gas==1 and .[0].spend<=1000' "$scratch_root/routes/chain-sol/routes.json" >/dev/null
[[ $(wc -l <"$scratch_root/sol-requests.jsonl") == 2 ]]
[[ ! -e $scratch_root/routes/chain-sol/headers ]]
sol_bad_mint=1; quote_sol_stock "$d" sol-bad
[[ -s $scratch_root/routes/chain-sol-bad/error.json && ! -e $scratch_root/routes/chain-sol-bad/routes.json ]]
echo 'Solana gas budget, re-quote, mint identity and raw-token multiplier tests passed.'
