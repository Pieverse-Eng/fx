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
      {issuer:"bstocks",chain:"bnb",symbol:"CRCLB",contract:"0x1",provider:"fixture",costRank:2,gas:1,effectivePrice:101}],gaps:[]}) and
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
  {issuer:"xstocks",chain:"bnb",symbol:"CRCLx",contract:"0x1",provider:"pancakeswap",product:"spot",effectivePrice:100} as $first |
  comparison_result([$first,$first+{effectivePrice:100.5},
    $first+{issuer:"bstocks",symbol:"CRCLB",contract:"0x2",effectivePrice:101},
    $first+{chain:"solana",contract:"mint",provider:"dflow",effectivePrice:102}];[]) as $result |
  ($result.rankedRoutes|length==3) and
  ($result.rankedRoutes[0]|.contract=="0x1" and .provider=="pancakeswap") and
  ($result.rankedRoutes[1]|.contract=="0x2" and .issuer=="bstocks" and .provider=="pancakeswap") and
  ($result.rankedRoutes[2]|.chain=="solana" and .provider=="dflow")
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
echo '{"USDTUSD":"1","BNBUSD":"500","ETHUSD":"2000","USDGUSD":"1"}' >"$scratch_root/routes/rates.json"
route_input='{"ticker":"CRCL","product":"spot","amount":"1000"}'
fixture_mode=success
FX_PLATFORM_EVM_QUOTE_URL=http://fixture/evm-quote
FX_PLATFORM_QUOTE_TOKEN=fixture-capability
market_read() {
  local target=$1 body=${!#}
  if [[ $body == *Ticker?pair=USDGUSD ]]; then
    echo '{"result":{"USDGUSD":{"a":["1.002"],"b":["1.000"],"v":["1","10"]}}}' >"$target"
    return
  fi
  jq -n --argjson body "$body" --arg mode "$fixture_mode" '
    ($body.fromAmount|tonumber) as $a |
    {ok:($mode!="unavailable"),data:($body+{
      provider:(if $body.chainId==56 then "pancakeswap" else "uniswap" end),
      toToken:(if $mode=="wrongtoken" then "0xwrong" else $body.toToken end),
      inputDecimals:18,outputDecimals:18,amountOut:(($a/100-pow($a/1000;2))*1e18|tostring),
      networkFeeWei:(if $mode=="missinggas" then null else "4000000000000000" end),
      route:{protocol:"v3",router:"0x1b81D678ffb9C0263b24A97847620C99d213eB14",fees:[2500],encodedPath:"0xfixture",path:[$body.fromToken,$body.toToken]}})}' >"$target"
  jq -c . <<<"$body" >>"$scratch_root/requests.jsonl"
}
d='{"chain":"bnb","issuer":"bstocks","symbol":"CRCLB","contract":"0x1","inputAsset":"USDT","inputContract":"0x2"}'
quote_evm_stock "$d" 0
jq -e '.[0].spend<=1000 and .[0].gas==2 and .[0].amountIn!="1000" and .[0].expectedQuantity>0 and .[0].route.protocol=="v3" and .[0].route.fees==[2500] and .[0].route.encodedPath=="0xfixture"' "$scratch_root/routes/chain-0/routes.json" >/dev/null
[[ $(wc -l <"$scratch_root/requests.jsonl") == 2 ]]
fixture_mode=unavailable; quote_evm_stock "$d" 1
[[ -s $scratch_root/routes/chain-1/error.json && ! -e $scratch_root/routes/chain-1/routes.json ]]
fixture_mode=missinggas; quote_evm_stock "$d" 2
[[ -s $scratch_root/routes/chain-2/error.json && ! -e $scratch_root/routes/chain-2/routes.json ]]
fixture_mode=wrongtoken; quote_evm_stock "$d" 3
[[ -s $scratch_root/routes/chain-3/error.json && ! -e $scratch_root/routes/chain-3/routes.json ]]
fixture_mode=success; quote_evm_stock "$(jq '.chain="robinhood"|.issuer="robinhood"|.inputAsset="USDG"' <<<"$d")" 4
jq -e '.[0].provider=="uniswap" and .[0].spend<=1000' "$scratch_root/routes/chain-4/routes.json" >/dev/null
mkdir -p "$scratch_root/kraken"
echo '{"USDGUSD":{"altname":"USDGUSD","wsname":"USDG/USD","status":"online"}}' >"$scratch_root/kraken/pairs-original.json"
jq 'del(.USDGUSD)' "$scratch_root/routes/rates.json" >"$scratch_root/rates.tmp"
mv "$scratch_root/rates.tmp" "$scratch_root/routes/rates.json"
quote_evm_stock "$(jq '.chain="robinhood"|.issuer="robinhood"|.inputAsset="USDG"' <<<"$d")" 5
jq -e '.[0].provider=="uniswap" and (.[0].amountIn|tonumber)<992 and .[0].spend<=1000' "$scratch_root/routes/chain-5/routes.json" >/dev/null
echo 'Direct DEX selection, nonlinear budget re-quote, missing gas and token identity tests passed.'
# Adapter tests exercise full normalization, including array-shaped OKX and Kraken success envelopes.
snapshot_math=$(cat "$root/src/tools/market/snapshot_math.jq")
source "$root/src/tools/market/market-snapshots.sh"
source "$root/src/tools/market/compare-trade-routes.sh"
market_read() {
  if [[ $1 == */funding.json || $1 == */oi.json ]]; then echo null >"$1"
  elif [[ $1 == */meta.json && $2 == curl && $* == *gateio* ]]; then
    [[ $* == *'X-Gate-Size-Decimal: 1'* ]]
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

# A 10 USDT PEPE request fits fractional contracts but not one whole contract.
m='{"ticker":"PEPE","baseAsset":"PEPE","quoteAsset":"USDT","venue":"gate","symbol":"PEPE_USDT","product":"perpetual","status":"trading"}'
echo '{"asks":[{"p":"0.00000328","s":"100.5"}],"bids":[{"p":"0.00000327","s":"100.5"}]}' >"$scratch_root/book-fixture.json"
for minimum in '"0.1"' '0.1' '"1"' '"10"' '0' 'null'; do
  jq -n --argjson minimum "$minimum" '[{name:"PEPE_USDT",type:"direct",quanto_multiplier:"10000000",
    taker_fee_rate:"0.00075",order_size_min:$minimum}]' >"$scratch_root/gate/perpetual.json"
  index="gate-lot-${minimum//\"/}"
  route_book "$m" "$index"
  if [[ $minimum == 0 || $minimum == null ]]; then
    jq -e '.message=="Gate contract quantity constraints unavailable"' "$scratch_root/routes/$index/error.json" >/dev/null
    continue
  fi
  jq -e --argjson minimum "$minimum" '
    .minQuantity==(($minimum|tonumber)*10000000) and
    .step==([1,($minimum|tonumber)]|min)*10000000 and
    .asks[0].quantity==1005000000' "$scratch_root/routes/$index/candidate.json" >/dev/null
  if [[ $minimum == *0.1* ]]; then
    jq -e "$math"'perpetual_notional(.;10;"long") |
      .expectedQuantity==3000000 and (.openingValue-9.84|fabs)<1e-10' "$scratch_root/routes/$index/candidate.json" >/dev/null
    jq -e "$math"'perpetual_notional(.;10;"short") |
      .expectedQuantity==3000000 and (.openingValue-9.81|fabs)<1e-10' "$scratch_root/routes/$index/candidate.json" >/dev/null
  else
    if jq -e "$math"'perpetual_notional(.;10;"long")' "$scratch_root/routes/$index/candidate.json" >/dev/null 2>&1; then
      echo 'Whole-contract minimum unexpectedly accepted a fractional lot' >&2; exit 1
    fi
  fi
done
echo 'Gate fractional contracts, integer minimums and missing quantity constraints passed.'

# Kraken no longer publishes fee tiers in AssetPairs. Use the correct public schedule.
route_input='{"ticker":"BTC","product":"spot","amount":"1000","currency":"USD"}'
echo '{"PAIR":{"asks":[[100,20,0]],"bids":[[99,20,0]]}}' >"$scratch_root/book-fixture.json"
while read -r base quote asset_class fees expected; do
  m=$(jq -cn --arg base "$base" --arg quote "$quote" --arg cls "$asset_class" '
    {venue:"kraken",ticker:$base,baseAsset:$base,quoteAsset:$quote,symbol:"PAIR",product:"spot",status:"online",assetClass:$cls}')
  route_input=$(jq --arg quote "$quote" '.currency=$quote' <<<"$route_input")
  jq -n --arg base "$base" --arg quote "$quote" --arg cls "$asset_class" --argjson fees "$fees" '
    [{altname:"PAIR",wsname:($base+"/"+$quote),aclass_base:$cls,fees:$fees,
      lot_decimals:8,ordermin:"0.0001",costmin:"0.5",status:"online"}]' >"$scratch_root/kraken/pairs-original.json"
  index="kraken-$base-$quote-$asset_class-${fees//[^a-zA-Z0-9]/}"
  route_book "$m" "$index"
  if [[ $expected == null ]]; then
    [[ -s $scratch_root/routes/$index/error.json && ! -e $scratch_root/routes/$index/candidate.json ]]
  else
    jq -e --argjson expected "$expected" '.fee==$expected and .feeAsset=="quote"' "$scratch_root/routes/$index/candidate.json" >/dev/null
    if [[ $fees == '[]' || $fees == null ]]; then
      jq -e '.feeSource|contains("public entry-tier taker estimate")' "$scratch_root/routes/$index/candidate.json" >/dev/null
    fi
    jq -e "$math"'spot(.;1000) | .expectedQuantity>0 and .spend<=1000' "$scratch_root/routes/$index/candidate.json" >/dev/null
  fi
done <<'CASES'
XBT USD currency [] 0.008
XBT USDT currency [] 0.008
ETH USD currency null 0.008
USDT USD currency [] 0.002
USDC USDT currency [] 0.002
EUR USD currency [] 0.002
USDG USD currency [] 0.0001
XBT USDG currency [] 0.008
WBTC XBT currency [] 0.002
TBTC BTC currency [] 0.002
WBTC USD currency [] 0.008
AAPLx USD tokenized_asset [] 0.001
USDE USD currency [] null
USD1 USD currency [] null
EURR USD currency [] null
XBT USD unknown [] null
XBT USD currency [[0,0.16]] 0.0016
XBT USD currency [[0,0]] 0
USDE USD currency [[0,0]] 0
CASES
echo 'Kraken public taker schedules, API fee precedence and spot budget estimates passed.'
route_input='{"ticker":"BTC","product":"perp","direction":"long","amount":"1000"}'

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
    {funding_rates:[{market_id:182,exchange:"other",rate:9},{market_id:182,exchange:"lighter",rate:-0.02}]};
    {order_book_details:[{market_id:999,open_interest:99,mark_price:"99"},{market_id:182,open_interest:500,mark_price:"2.8040"}]};
    {taker_fee:"0.0000"};1;false;"fixture")|
    .funding.value== -0.0025 and .funding.unit=="ratio" and .funding.intervalHours==1 and .openInterest.value==500 and .openInterest.unit=="base" and .openInterest.basis=="single_sided" and .openInterest.quoteValue==1402 and .markPrice==2.804) and
  (snapshot($m+{venue:"kraken",symbol:"PF_XBTUSD",quoteAsset:"USD"};{result:"success",orderBook:{asks:[],bids:[]}};null;null;
    {tickers:[{symbol:"PF_XBTUSD",fundingRate:1.36,fundingRatePrediction:0.87,openInterest:2155}]};1;false;"fixture")|
    .funding.status=="unknown" and .funding.unit=="ratio" and (.funding|has("prediction")|not) and .openInterest.value==2155) and
  (snapshot($m+{venue:"okx-cex",quoteAsset:"USDT"};[{ts:"1789056000000",asks:[[100,100]],bids:[[99,100]]}];
    [{fundingRate:"0.0001",fundingTime:"100000000",nextFundingTime:"128800000"}];[{oi:"1000",oiCcy:"10",oiUsd:"1000"}];[{markPx:"100"}];0.01;false;"fixture")|
    .funding.intervalHours==8 and .openInterest.usdValue==1000 and .book.bidDepth1Pct==99 and .markPrice==100 and .book.sourceTime=="1789056000000")
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
jq -ne "$candle_jq $math $snapshot_math"'
  {asks:[{price:101,quantity:1}],bids:[{price:100,quantity:1}]} as $book |
  (book_summary($book)|.bidBandComplete==false and .askBandComplete==false) and
  (book_summary($book+{bids:($book.bids+[{price:98,quantity:1}])})|.bidBandComplete==true and .bidDepth1Pct==100)
' >/dev/null
echo 'Depth band coverage does not assume a common venue level limit.'

jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"binance",symbol:"1000SHIBUSDT",baseAsset:"1000SHIB",ticker:"SHIB",product:"perpetual",quoteAsset:"USDT"} as $m |
  snapshot($m;{time:1789056000000,asks:[[0.012,100]],bids:[[0.011,100]]};null;null;null;1;false;"fixture") as $s |
  ($s.nativeBaseAsset=="1000SHIB" and $s.underlying=="SHIB" and $s.exposureMultiplier==1000 and $s.book.bestAsk==0.012 and $s.book.sourceTime==1789056000000) and
  (depth([[$s.nativeBook.asks[0].price,$s.nativeBook.asks[0].quantity]];1;$s.exposureMultiplier;1;false)[0] |
    .quantity==100000 and ((.price-0.000012)|fabs)<1e-12)
' >/dev/null
echo 'Native versus underlying units and object/array book timestamps passed.'

jq -ne "$math"'
  {id:"sized",venue:"binance",symbol:"TESTUSDT",product:"perp",quote:"USDT",quotedAt:"fixture",
   step:0.1,minQuantity:0,minValue:0,fee:0.001,extraFee:0,feeAsset:"quote",feeSource:"fixture",
   asks:[{price:101,quantity:100}],bids:[{price:99,quantity:100}]} as $a |
  ($a+{venue:"bitget",step:0.01,asks:[{price:121,quantity:100}],bids:[{price:119,quantity:100}]}) as $b |
  all(["long","short"][]; . as $direction |
    perpetual_notional($a;3000;$direction) as $ra |
    perpetual_notional($b;3000;$direction) as $rb |
    $ra.expectedQuantity==30 and $rb.expectedQuantity==25 and
    $ra.expectedQuantity*100==3000 and $rb.expectedQuantity*120==3000 and
    $ra.estimatedFillPrice==(if $direction=="short" then 99 else 101 end) and
    (($ra.effectivePrice-($ra.estimatedFillPrice*(if $direction=="short" then 0.999 else 1.001 end)))|fabs)<1e-10) and
  (perpetual_notional($b+{step:3};3000;"short")|.expectedQuantity==24) and
  ((try perpetual_notional($b+{step:30};3000;"short") catch {error:.})|has("error"))
' >/dev/null
echo 'Each venue sizes its own notional, rounds its own lots, and separates fill from fee-adjusted price.'

# Hourly funding ratios preserve direction and zero; OI is native-base, one-sided.
jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"lighter",symbol:"1000PEPE",ticker:"PEPE",baseAsset:"1000PEPE",marketId:3,product:"perpetual",quoteAsset:"USDC",exposureMultiplier:1000} as $m |
  all([0.000024,-0.000024,0,null][]; . as $rate |
    snapshot($m;null;{funding_rates:[{market_id:3,exchange:"other",rate:9},{market_id:4,exchange:"lighter",rate:9},{market_id:3,exchange:"lighter",rate:$rate}]};
      {order_book_details:[{market_id:3,open_interest:200,mark_price:0.01}]};null;1;false;"fixture") as $s |
    $s.funding.value==(if $rate==null then null else $rate/8 end) and
    $s.funding.status==(if $rate==null then "unknown" else "available" end) and
    $s.funding.intervalHours==1 and $s.funding.positiveRatePays=="long_to_short" and
    $s.openInterest.baseAmount==200 and $s.openInterest.quoteValue==2) and
  all([0,null][]; . as $oi |
    snapshot($m;null;null;{order_book_details:[{market_id:3,open_interest:$oi,mark_price:100}]};null;1;false;"fixture") |
    .openInterest.value==$oi and .openInterest.quoteValue==(if $oi==null then null else 0 end)) and
  (snapshot($m+{product:"spot"};null;null;null;null;1;false;"fixture") |
    .funding.status=="not_applicable" and .openInterest.status=="not_applicable")
' >/dev/null
# Kraken relative-rate OHLC closes must be paired with a recent source timestamp.
jq -ne "$candle_jq $math $snapshot_math"'
  "2026-09-11T10:05:00Z" as $now | ($now|fromdateiso8601|.*1000) as $clock |
  {errors:[],result:{timestamp:[$clock-300000,$clock-3900000],data:{relativeRate:[[9,10,-10,"-0.000003"],[8,9,0,"0.000001"]]}}} as $f |
  {venue:"kraken",symbol:"pf_xbtusd",ticker:"BTC",product:"perpetual",quoteAsset:"USD"} as $m |
  (snapshot($m;null;$f;null;{tickers:[{symbol:"pf_xbtusd",fundingRate:2,fundingRatePrediction:3,markPrice:100}]};1;false;$now)|
    .funding.value== -0.000003 and .funding.intervalHours==1 and .funding.unit=="ratio" and
    .funding.sourceTime==$clock-300000 and (.funding|has("prediction")|not)) and
  all([0,0.000003,-0.000003][]; . as $rate |
    kraken_relative_funding(($f|.result.data.relativeRate[0][3]=$rate);$now)|.value==$rate and .status=="available") and
  all([null,{},($f|.errors=["unavailable"]),($f|.result.timestamp=[]),
    ($f|.result.timestamp[0]=$clock+3600000),($f|.result.timestamp|=map(.-10800000)),
    ($f|.result.data.relativeRate[0]=[1,2,3]),($f|.result.data.relativeRate[0][3]="bad"),
    ($f|.result.data.relativeRate[0][3]=null)][];
    kraken_relative_funding(.;$now)|.value==null and .status=="unknown") and
  (snapshot($m+{symbol:"PI_XBTUSD"};null;$f;null;{tickers:[{symbol:"PI_XBTUSD",fundingRate:2}]};1;true;$now)|
    .funding.unit=="provider_native" and .funding.intervalHours==null) and
  (snapshot($m+{product:"spot"};null;$f;null;null;1;false;$now)|.funding.status=="not_applicable")
' >/dev/null
echo 'Lighter hourly funding and single-sided OI; Kraken relative funding freshness and failure regressions passed.'

jq -ne "$candle_jq $math $snapshot_math"'
  {venue:"kraken",symbol:"PI_XBTUSD",ticker:"BTC",baseAsset:"XBT",quoteAsset:"USD",product:"perpetual",contractType:"futures_inverse",contractSize:1,sizeDecimals:0} as $m |
  snapshot($m;{result:"success",orderBook:{asks:[[100,100],[200,100]],bids:[[100,100],[50,100]]}};null;null;
    {tickers:[{symbol:"PI_XBTUSD",markPrice:100,openInterest:200}]};1;false;"fixture") as $s |
  {inverse:true,contractValue:1,contractStep:1,settlementAsset:"XBT",fee:0.0005,extraFee:0,asks:$s.nativeBook.asks,bids:$s.nativeBook.bids} as $c |
  ($s.book.askDepth1Pct==100 and $s.book.bidDepth1Pct==100 and
   $s.nativeBook.asks[1].quantity==0.5 and $s.openInterest.quoteValue==200 and $s.openInterest.baseAmount==2 and $s.settlementAsset=="XBT") and
  (snapshot($m;null;null;null;{tickers:[{symbol:"PI_XBTUSD",markPrice:100}]};1;false;"fixture")|.openInterest.status=="unknown" and .openInterest.quoteValue==null) and
  (perpetual_notional($c;200.9;"long")|.contracts==200 and .expectedQuantity==1.5 and .openingValue==200 and .fees==0.1 and ((.estimatedFillPrice-200/1.5)|fabs)<1e-9 and .settlementFee==0.00075) and
  (perpetual_notional($c;200;"short")|.contracts==200 and .expectedQuantity==3 and .fees==0.1 and .effectivePrice<.estimatedFillPrice) and
  ((try perpetual_notional($c;201;"long") catch {error:.})|has("error")) and
  ((try perpetual_notional($c;0.9;"short") catch {error:.})|has("error")) and
  (perpetual_notional($c+{contractValue:0.99,asks:[{price:99,quantity:2}],bids:[{price:98,quantity:2}]};100;"long")|.contracts==101 and .openingValue==99.99) and
  (kraken_inverse($m+{contractSize:null})|not) and (kraken_inverse($m+{contractType:"unknown"})|not)
' >/dev/null
jq -ne "$candle_jq"'
  [{key:"USDTZUSD",altname:"USDTUSD",wsname:"USDT/USD",status:"online"},
   {key:"ZEURZUSD",altname:"EURUSD",wsname:"EUR/USD",status:"online"},
   {key:"USDJPY",altname:"USDJPY",wsname:"USD/JPY",status:"online"},
   {key:"XXBTZUSD",altname:"XBTUSD",wsname:"XBT/USD",status:"online"}] as $pairs |
  {USDTZUSD:{a:[0.99],b:[0.99],v:[1,1]},EURUSD:{a:[1.1],b:[1.1],v:[1,1]},USDJPY:{a:[150],b:[150],v:[1,1]},XXBTZUSD:{a:[100],b:[100],v:[1,1]}} as $kr |
  [{symbol:"BNBUSDT",lastPrice:500,count:1,closeTime:1000000},{symbol:"USDTBRL",lastPrice:5,count:1,closeTime:1000000},{symbol:"OLDUSDT",lastPrice:9,count:1,closeTime:1}] as $bn |
  {symbols:[{symbol:"BNBUSDT",baseAsset:"BNB",quoteAsset:"USDT",status:"TRADING"},{symbol:"USDTBRL",baseAsset:"USDT",quoteAsset:"BRL",status:"TRADING"},{symbol:"OLDUSDT",baseAsset:"OLD",quoteAsset:"USDT",status:"TRADING"}]} as $catalog |
  reference_rates($pairs;$kr;$bn;$catalog;1000000) as $r |
  ($r.USD==1 and $r.USDT==0.99 and $r.EUR==1.1 and $r.JPY==1/150 and $r.BTC==100 and $r.BNB==495 and $r.BRL==0.198 and $r.OLD==null and $r.USDC==null) and
  (reference_rates($pairs;($kr|.USDJPY.b=[151]);$bn;$catalog;1000000)|.JPY==null) and
  (reference_rates($pairs;($kr|.USDTZUSD.v=[0,0]);$bn;$catalog;1000000)|.USDT==null and .BNB==null) and
  (reference_rates(($pairs|map(.status="cancel_only"));$kr;$bn;$catalog;1000000)=={USD:1})
' >/dev/null
echo 'Inverse quote-contract fills and direct/reversed currency conversions passed.'

# Cross rates use independent anchors, prefer active depth, and retain unknowns.
jq -ne "$candle_jq"'
  [{key:"btc",wsname:"XBT/USD",status:"online"},{key:"jpy",wsname:"XBT/JPY",status:"online"},
   {key:"usdr",wsname:"XBT/USDR",status:"online"}] as $pairs |
  {btc:{a:[100],b:[100],v:[1,1]},jpy:{a:[15000],b:[15000],v:[1,1]},usdr:{a:[9000],b:[1],v:[0,0]}} as $kr |
  reference_rates($pairs;$kr;[];{symbols:[]};1000000) as $r |
  $r.JPY==1/150 and $r.USDR==null and
  (reference_rates($pairs;($kr|.jpy.b=[10000]);[];{symbols:[]};1000000)|.JPY==null)
' >/dev/null
jq -ne "$candle_jq"'
  {USD:1,USDT:0.99,USDC:1.001,GUSD:0.8} as $rates |
  [{id:"GUSD_USDT",base:"GUSD",quote:"USDT",trade_status:"tradable"}] as $pairs |
  [{currency_pair:"GUSD_USDT",lowest_ask:0.999,highest_bid:0.998,quote_volume:1000}] as $tickers |
  [{tokens:[{index:360,name:"USDH"},{index:0,name:"USDC"}],universe:[{tokens:[360,0],name:"@230"}]},
   [{coin:"@999",midPx:9,dayNtlVlm:999},{coin:"@230",midPx:0.998,dayNtlVlm:1000}]] as $hl |
  venue_reference_rates($rates;$pairs;$tickers;$hl) as $r |
  ($r.GUSD==0.8 and $r.USDH==null and (($r.venues.gate.GUSD-0.9985*0.99)|fabs)<1e-12 and $r.venues.hyperliquid.USDH==0.998*1.001) and
  ((reference_rate($r;{venue:"gate",quoteAsset:"GUSD"})-0.9985*0.99)|fabs)<1e-12 and
  (reference_rate($r;{venue:"kraken",quoteAsset:"GUSD"})==0.8) and
  (venue_reference_rates($rates;$pairs;($tickers|.[0].quote_volume=0);$hl)|.venues.gate.GUSD==null) and
  (venue_reference_rates($rates;$pairs;($tickers|.[0].highest_bid=0.5);$hl)|.venues.gate.GUSD==null) and
  (venue_reference_rates($rates;($pairs|.[0].trade_status="untradable");$tickers;$hl)|.venues.gate.GUSD==null) and
  (venue_reference_rates($rates;$pairs;$tickers;($hl|.[1][1].midPx=null))|.venues.hyperliquid.USDH==null) and
  (venue_reference_rates($rates;$pairs;$tickers;($hl|.[0].tokens+=[{index:999,name:"USDH"}]))|.venues.hyperliquid.USDH==null) and
  (venue_reference_rates($rates;$pairs;$tickers;($hl|.[1][1].coin="@231"))|.venues.hyperliquid.USDH==null) and
  (venue_reference_rates($rates;null;{error:"unavailable"};{error:"unavailable"})|.USD==1 and .USDT==0.99 and .venues=={gate:{},hyperliquid:{}})
' >/dev/null
echo 'Cross-quote fallback, venue token identity and invalid conversion data regressions passed.'
