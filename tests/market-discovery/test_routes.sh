#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
math=$(cat "$root/src/tools/market/route_math.jq")
jq -ne "$math"'
  {venue:"bitget",symbol:"RCRCLUSDT",product:"spot",category:"SPOT",effectivePrice:100,fees:1,quotedAt:"fixture",id:"venue"} as $venue |
  {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1",provider:"fixture",inputContract:"0x2",gas:1,effectivePrice:101} as $chain |
  (comparison_result([$venue,$chain];[]) == {
    bestRoute:{venue:"bitget",symbol:"RCRCLUSDT",product:"spot",category:"SPOT"},
    rankedRoutes:[{venue:"bitget",symbol:"RCRCLUSDT",product:"spot",category:"SPOT",costRank:1},
      {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1",provider:"fixture",costRank:2}],gaps:[]}) and
  (comparison_result([$chain,$venue];[]).bestRoute == {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1"}) and
  (comparison_result([$venue+{venue:"hyperliquid",assetId:110109,dex:"xyz"},$chain];[]).bestRoute.assetId == 110109) and
  (comparison_result([$venue,$chain];[{venue:"kraken",symbol:"CRCLxUSD",message:"Unavailable book"}]).gaps == ["kraken / CRCLxUSD: Unavailable book"]) and
  (comparison_result([];[]) == {bestRoute:null,rankedRoutes:[],gaps:["No eligible route with a valid quote"]}) and
  (comparison_result([$venue];[]).gaps == ["Only one eligible route; comparative minimum not established"])
' >/dev/null
echo 'Compact route selection, chain symbols, routing identifiers and comparison gaps passed.'
jq -ne "$math"'
  {venue:"gate",symbol:"BTC_USDT",product:"perp",effectivePrice:99} as $gate |
  {venue:"binance",symbol:"BTCUSDT",product:"perp",effectivePrice:100} as $binance |
  {venue:"hyperliquid",symbol:"BTC",product:"perp",assetId:0,effectivePrice:101} as $hl |
  comparison_result([$gate,$binance,$binance+{symbol:"BTCUSDC",effectivePrice:100.5},$hl];[]) as $result |
  ($result.rankedRoutes|map(.venue)==["gate","binance","hyperliquid"]) and
  ($result.rankedRoutes|map(select(.venue=="binance" or .venue=="hyperliquid"))|.[0].venue=="binance") and
  ($result.rankedRoutes[0].costRank < $result.rankedRoutes[1].costRank) and
  ($result.rankedRoutes[-1].assetId==0) and
  ($result.rankedRoutes|map(select(.venue=="kraken"))==[]) and
  (comparison_result([$gate,$binance+{effectivePrice:99},$hl];[]).rankedRoutes|map(.costRank)==[1,1,2]) and
  (comparison_result([$hl,$binance,$gate];[]).rankedRoutes|map(.venue)==["hyperliquid","binance","gate"]) and
  (comparison_result([$hl,$binance,$gate];[]).rankedRoutes|map(.costRank)==[1,2,3]) and
  (all($result.rankedRoutes[]; has("effectivePrice")==false and has("fees")==false))
' >/dev/null
jq -ne "$math"'
  {issuer:"xstocks",chain:"bnb",symbol:"CRCLx",contract:"0x1",provider:"bitget-wallet",product:"spot",effectivePrice:100} as $first |
  comparison_result([$first,$first+{issuer:"bstocks",symbol:"CRCLB",contract:"0x2",effectivePrice:101},
    $first+{chain:"solana",contract:"mint",provider:"dflow",effectivePrice:102}];[]) as $result |
  ($result.rankedRoutes|length==2) and
  ($result.rankedRoutes[0]|.contract=="0x1" and .provider=="bitget-wallet") and
  ($result.rankedRoutes[1]|.chain=="solana" and .provider=="dflow")
' >/dev/null
echo 'Configured-venue selection, strict cheaper alternatives, ties, shorts and route deduplication passed.'
jq -ne "$math"'
  def close($expected): (. - $expected)|fabs <= 1e-12*($expected|fabs);
  {id:"precise",venue:"binance",symbol:"BTCUSDT",product:"perp",quote:"USDT",quotedAt:"fixture",
   step:0.001,minQuantity:0,minValue:0,fee:0,extraFee:0,feeAsset:"quote",feeSource:"fixture",
   asks:[{price:100,quantity:10}],bids:[{price:99,quantity:10}]} as $c |
  (round_down(0.3;0.1)|close(0.3)) and
  (round_down(0.043;0.001)|close(0.043)) and
  (round_down(0.29;0.01)|close(0.29)) and
  (round_down(0.58;0.02)|close(0.58)) and
  (round_down(0.0429;0.001)|close(0.042)) and
  (round_down(0.042999999;0.001)|close(0.042)) and
  (round_down(0.3;0)|close(0.3)) and
  (all([0.00000001,0.000001,0.001,0.01,0.05,0.1,1,1000][];
    . as $step | all(range(1;1000); . as $lots |
      (round_down($lots*$step;$step)|close($lots*$step)) and
      (round_down(($lots+0.25)*$step;$step)|close($lots*$step)) and
      (round_down(round_down($lots*$step;$step);$step)|close($lots*$step))))) and
  (perpetual($c;0.043;"long").expectedQuantity|close(0.043)) and
  (perpetual($c;0.043;"short").expectedQuantity|close(0.043)) and
  (spot($c;4.3).expectedQuantity|close(0.043)) and
  (spot($c;4.2999999).expectedQuantity|close(0.042)) and
  (all(range(1;200); . as $lot |
    [range(100)|{price:1,quantity:($lot/1000)}] as $levels |
    (spot($c+{asks:$levels};$lot/10).expectedQuantity|close($lot/10)) and
    (walk_quantity($levels;$lot/10).quantity|close($lot/10)))) and
  ((try perpetual($c;0.0435;"long") catch .)|startswith("Lot step")) and
  ((try round_down(1e16;0.001) catch .)=="Lot count exceeds safe floating-point precision")
' >/dev/null
echo 'Lot rounding boundaries, scales, idempotence and spot/perp regressions passed.'
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
snapshot_math=$(cat "$root/src/tools/market/snapshot_math.jq")
source "$root/src/tools/market/market-snapshots.sh"
source "$root/src/tools/market/compare-trade-routes.sh"
market_read() {
  if [[ $1 == */funding.json || $1 == */oi.json ]]; then echo null >"$1"
  elif [[ $1 == */meta.json && $2 == curl && $* == *gateio* ]]; then
    jq '.[0]' "$scratch_root/gate/perpetual.json" >"$1"
  else cp "$scratch_root/book-fixture.json" "$1"; fi
}
route_input='{"ticker":"BTC","product":"perp","direction":"long","amount":"1000"}'
for venue in aster binance bitget gate hyperliquid kraken lighter okx-cex; do
  mkdir -p "$scratch_root/$venue"
  m=$(jq -cn --arg venue "$venue" '{ticker:"BTC",baseAsset:"BTC",quoteAsset:"USDT",venue:$venue,symbol:"BTCUSDT",product:"perpetual",status:"online",dex:"default",szDecimals:4,category:"USDT-FUTURES"}')
  echo '{"asks":[[100,20]],"bids":[[99,20]]}' >"$scratch_root/book-fixture.json"
  case "$venue" in
    aster) echo '{"symbols":[{"symbol":"BTCUSDT","quoteAsset":"USDT","marginAsset":"USDT","contractType":"PERPETUAL","filters":[]}]}' >"$scratch_root/aster/catalog.json";;
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

# Exercise the production adapter, not a copy of the fee classification.
echo '{"USDTUSD":"1","USD1USDT":"1","UUSDT":"1"}' >"$scratch_root/routes/rates.json"
echo '{"asks":[[100,20]],"bids":[[99,20]]}' >"$scratch_root/book-fixture.json"
while read -r symbol quote tags symbol_type expected; do
  m=$(jq -cn --arg symbol "$symbol" --arg quote "$quote" --argjson tags "$tags" --argjson type "$symbol_type" '
    {venue:"aster",ticker:"ASSET",symbol:$symbol,baseAsset:"ASSET",quoteAsset:$quote,marginAsset:$quote,
     product:"perpetual",contractType:"PERPETUAL",status:"TRADING",underlyingSubType:$tags,symbolType:$type,filters:[]}')
  jq -n --argjson m "$m" '{symbols:[$m]}' >"$scratch_root/aster/catalog.json"
  route_book "$m" "fee-$symbol"
  if [[ $expected == null ]]; then
    jq -e '.message=="Applicable public fee or base-size unit unavailable"' "$scratch_root/routes/fee-$symbol/error.json" >/dev/null
    [[ ! -e $scratch_root/routes/fee-$symbol/candidate.json ]]
  else
    jq -e --argjson fee "$expected" '.fee==$fee' "$scratch_root/routes/fee-$symbol/candidate.json" >/dev/null
  fi
done <<'CASES'
TRXUSDT USDT ["Top"] 0 0.0004
TSLAUSDT USDT ["STOCK"] 1 0.00009
SPYUSDT USDT ["ETF"] 1 0.00009
XAUUSDT USDT ["Commodities"] 1 0.00009
BTCUSD1 USD1 [] 0 0.00005
SNDKUSD1 USD1 ["STOCK","AOS2","USD1-RWA"] 1 0.00009
XAUUSD1 USD1 ["Commodities","USD1-RWA"] 1 0.00009
UNKNOWNUSD1 USD1 [] 2 null
BTCU U ["AOS2"] 0 null
OPENAIUSDT USDT ["pre-launch","STOCK"] 1 null
CASES
# At equal books, correcting the RWA fee changes the long AND short winner.
jq -ne --slurpfile a "$scratch_root/routes/fee-TSLAUSDT/candidate.json" "$math"'
  $a[0] as $aster | ($aster+{venue:"binance",fee:0.0005}) as $binance |
  ([perpetual($aster;2;"long"),perpetual($binance;2;"long")]|sort_by(.effectivePrice)) as $long |
  ([perpetual($aster;2;"short"),perpetual($binance;2;"short")]|sort_by(.effectivePrice)|reverse) as $short |
  (comparison_result($long;[]).bestRoute.venue=="aster") and
  (comparison_result($short;[]).bestRoute.venue=="aster") and
  (($long[0].fees-0.018)|fabs<1e-12) and
  (perpetual($aster+{fee:0.002};2;"long").effectivePrice > $long[1].effectivePrice)
' >/dev/null
echo 'Aster crypto, RWA, USD1, unknown fee exclusions and cost ranking regressions passed.'

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

# HIP-3 official positive-fee examples, including growth scales above one.
market_read() {
  if [[ $1 == */funding.json || $1 == */oi.json ]]; then echo null >"$1"
  elif [[ $1 == */meta.json && $2 == curl && $* == *gateio* ]]; then
    jq '.[0]' "$scratch_root/gate/perpetual.json" >"$1"
  else cp "$scratch_root/book-fixture.json" "$1"; fi
}
route_input='{"ticker":"QCOM","product":"perp","direction":"long","amount":"1000"}'
echo '{"levels":[[{"px":99,"sz":20}],[{"px":100,"sz":20}]]}' >"$scratch_root/book-fixture.json"
for example in 'disabled 0 0.00045' 'disabled 0.5 0.000675' 'disabled 1 0.0009' 'disabled 3 0.0027' 'enabled 1 0.00009' 'enabled 3.01 0.0002709'; do
  read -r growth scale expected <<<"$example"
  m=$(jq -cn --arg g "$growth" --arg s "$scale" '{ticker:"QCOM",venue:"hyperliquid",symbol:"xyz:QCOM",product:"perpetual",status:"active",dex:"xyz",collateralAsset:"USDC",quoteAsset:"USDT",baseAsset:"QCOM",szDecimals:2,growthMode:$g,deployerFeeScale:$s}')
  route_book "$m" "hip3-$growth-$scale"
  jq -e --argjson f "$expected" '((.fee-$f)|fabs)<0.0000000001 and .extraFee==0.0005' "$scratch_root/routes/hip3-$growth-$scale/candidate.json" >/dev/null
done
route_book "$(jq 'del(.growthMode)' <<<"$m")" hip3-missing
jq -e '.message=="HIP-3 fee scale or growth mode unavailable"' "$scratch_root/routes/hip3-missing/error.json" >/dev/null
echo 'HIP-3 scale, growth mode and missing metadata passed.'

# Snapshots preserve liquidity evidence independently from fees and missing data.
jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"bitget",symbol:"H100USDT",product:"perpetual",quoteAsset:"USDT",ticker:"H100",category:"USDT-FUTURES"} as $m |
  snapshot($m;{data:{a:[[2.655,75]],b:[[2.652,1430]]}};
    {data:[{fundingRate:"0",fundingRateInterval:"8",nextUpdate:"1789056000000"}]};
    {data:{openInterestList:[{size:"8408"}]}};null;1;false;"fixture") as $s |
  ($s.funding.status=="available" and $s.funding.value==0 and $s.funding.intervalHours==8) and
  ($s.openInterest.value==8408 and $s.openInterest.unit=="base") and
  ($s.book.bidDepth1Pct>3000 and $s.book.bestBid==2.652) and
  (snapshot($m;null;null;null;null;1;false;"fixture")|.book.status=="unknown" and .funding.status=="unknown") and
  (snapshot($m;{data:{a:[],b:[]}};null;null;null;1;false;"fixture")|.book.status=="empty" and .book.bidDepth1Pct==0) and
  (snapshot($m;{data:{a:[[2.655,75]],b:[[2.652,"bad"]]}};null;null;null;1;false;"fixture")|.book.status=="unknown") and
  (snapshot($m+{product:"spot"};{data:{a:[],b:[]}};null;null;null;1;false;"fixture")|.funding.status=="not_applicable" and .openInterest.status=="not_applicable")
' >/dev/null
jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"gate",symbol:"H100_USDT",product:"perpetual",quoteAsset:"USDT",ticker:"H100"} as $m |
  snapshot($m;{asks:[{p:2.675,s:156}],bids:[{p:2.632,s:4}]};null;null;
    {funding_rate:"0",funding_interval:28800,position_size:795};0.01;false;"fixture") as $s |
  ($s.funding.intervalHours==8 and $s.openInterest.unit=="contracts" and $s.openInterest.contractMultiplier==0.01) and
  (($s.nativeBook.bids[0].quantity-0.04)|fabs<0.000001) and
  (snapshot($m;null;null;null;{funding_rate:"0",position_size:795};null;true;"fixture")|.funding.value==0 and .openInterest.value==795 and .book.status=="unknown")
' >/dev/null
# A $3000 sale fits Bitget best bid, while Gate partial depth must not produce a full-fill estimate.
jq -ne "$math"'
  {id:"H100",venue:"bitget",symbol:"H100USDT",product:"perp",quote:"USDT",quotedAt:"fixture",
   step:1,minQuantity:1,minValue:0,fee:0.0006,extraFee:0,feeAsset:"quote",feeSource:"fixture",
   asks:[{price:2.655,quantity:75}],bids:[{price:2.652,quantity:1430}]} as $c |
  (perpetual($c;1130;"short")|.estimatedFillPrice==2.652 and (.depthSlippageBps|fabs)<0.000001) and
  (try perpetual($c+{bids:[{price:2.632,quantity:4}]};1130;"short") catch .)=="Insufficient displayed depth"
' >/dev/null
echo 'Funding units, zero versus unknown, malformed and empty books, contract multipliers and H100 fill regressions passed.'
jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"hyperliquid",symbol:"xyz:H100",product:"perpetual",collateralAsset:"USDC",ticker:"H100"} as $m |
  snapshot($m;{levels:[[],[]]};null;null;
    [{universe:[{name:"BTC"},{name:"xyz:H100"}]},[{funding:"9",openInterest:"9"},{funding:"0.00001",openInterest:"100",markPx:"2.65"}]];
    1;false;"fixture") as $hl |
  ($hl.funding.value==0.00001 and $hl.funding.intervalHours==1 and $hl.openInterest.quoteValue==265) and
  (snapshot($m+{venue:"lighter",marketId:182};{asks:[],bids:[]};
    {funding_rates:[{market_id:182,exchange:"other",rate:9},{market_id:182,exchange:"lighter",rate:-0.02}]};null;{open_interest:500};1;false;"fixture")|
    .funding.value== -0.02 and .funding.unit=="provider_native" and .openInterest.value==500) and
  (snapshot($m+{venue:"kraken",symbol:"PF_XBTUSD",quoteAsset:"USD"};{result:"success",orderBook:{asks:[],bids:[]}};null;null;
    {tickers:[{symbol:"PF_XBTUSD",fundingRate:1.36,fundingRatePrediction:0.87,openInterest:2155}]};1;false;"fixture")|
    .funding.value==1.36 and .funding.unit=="provider_native" and .funding.prediction==0.87 and .openInterest.value==2155) and
  (snapshot($m+{venue:"okx-cex",quoteAsset:"USDT"};[{asks:[[100,100]],bids:[[99,100]]}];
    [{fundingRate:"0.0001",fundingTime:"100000000",nextFundingTime:"128800000"}];[{oi:"1000",oiCcy:"10",oiUsd:"1000"}];[{markPx:"100"}];0.01;false;"fixture")|
    .funding.intervalHours==8 and .openInterest.usdValue==1000 and .book.bidDepth1Pct==99 and .markPrice==100)
' >/dev/null
jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"bitget",symbol:"H100USDT",product:"perpetual",quoteAsset:"USDT",ticker:"H100"} as $m |
  {product:"perp",amount:"3000",direction:"short",currency:"USDT"} as $input |
  snapshot($m;{data:{a:[[2.655,75]],b:[[2.652,1430]]}};null;null;null;1;false;"fixture") as $s |
  (displayed_fill($s;$input;{})|.fullyFillable and .depthSlippageBps==0) and
  (displayed_fill($s+{nativeBook:{asks:[{price:2.655,quantity:75}],bids:[{price:2.652,quantity:4}]}};$input;{})|.fullyFillable==false) and
  (displayed_fill($s;$input+{currency:"USD"};{})|.status=="unknown")
' >/dev/null
echo 'All derivative field mappings and fee-independent displayed-fill estimates passed.'
