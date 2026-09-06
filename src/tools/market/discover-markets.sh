#!/usr/bin/env bash
# Public market discovery. Bash 4+, jq, GNU timeout, and the selected venue CLIs.
set -euo pipefail
usage() {
  echo 'Usage: discover-markets.sh TICKER [TICKER ...] [--product spot|perpetual|all] [--quote CURRENCY|ALL]' >&2
  exit 2
}
tickers=(); product=all; quote_override=''; quote_set=0
venues=(aster binance bitget gate hyperliquid kraken lighter okx-cex)
declare -A seen_tickers=()
while (( $# )); do
  case "$1" in
    --product) [[ $# -ge 2 ]] || usage; product=$2; shift 2 ;;
    --quote) [[ $# -ge 2 ]] || usage; quote_override=${2^^}; quote_set=1; shift 2 ;;
    --*) usage ;;
    *) value=${1^^}; [[ $value =~ ^[A-Z0-9]+$ ]] || usage
       if [[ -z ${seen_tickers[$value]:-} ]]; then tickers+=("$value"); seen_tickers[$value]=1; fi
       shift ;;
  esac
done
(( ${#tickers[@]} )) || usage
[[ $product == spot || $product == perpetual || $product == all ]] || usage
if (( quote_set )); then
  [[ $quote_override =~ ^[A-Z0-9]+$ ]] || usage
  [[ $quote_override != ALL ]] || quote_override=''
fi
for dependency in jq timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
umask 077
cache_dir=${FX_MARKET_CACHE_DIR:-}
[[ -z $cache_dir ]] || mkdir -p -- "$cache_dir"
scratch_root=$(mktemp -d)
workers=()
trap 'rm -rf -- "$scratch_root"' EXIT
trap 'for pid in "${workers[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM

seed() { printf '%s\n' "$2" >"$scratch/$1.json"; }
# Each public request has one owner. Failure preserves its seeded empty shape.
fetch() (
  name=$1; validation=$2; source=$3; shift 3
  printf '%s\n' "$source" >"$scratch/$name.source"
  cache_file=''
  if [[ -n $cache_dir ]]; then
    cache_key=$(printf '%s\0' "$@" | sha256sum | cut -d' ' -f1)
    cache_file="$cache_dir/$cache_key.json"
    if [[ -f $cache_file ]] && jq -e --argjson now "$(date +%s)" '.storedAt <= $now and ($now-.storedAt)<60' "$cache_file" >/dev/null 2>&1; then
      if jq '.data' "$cache_file" >"$scratch/$name.raw" && jq -e "$validation" "$scratch/$name.raw" >/dev/null 2>&1; then
        mv "$scratch/$name.raw" "$scratch/$name.json"
        return
      fi
    fi
  fi
  timeout --kill-after=2s 25s "$@" >"$scratch/$name.raw" 2>"$scratch/$name.stderr" &
  child=$!
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 130' INT TERM
  if ! wait "$child"; then
    echo 'Public query failed or timed out; coverage unresolved' >"$scratch/$name.error"
  elif ! jq -e "$validation" "$scratch/$name.raw" >/dev/null 2>&1; then
    echo 'API error or malformed catalog; coverage unresolved' >"$scratch/$name.error"
  else
    mv "$scratch/$name.raw" "$scratch/$name.json"
    if [[ -n $cache_file ]]; then
      cache_tmp=$(mktemp "$cache_dir/.pending.XXXXXX")
      if jq --argjson now "$(date +%s)" '{storedAt:$now,data:.}' "$scratch/$name.json" >"$cache_tmp"; then mv "$cache_tmp" "$cache_file"; else rm -f "$cache_tmp"; fi
    fi
  fi
)
launch() { fetch "$@" & pids+=("$!"); }
wait_queries() { for pid in "${pids[@]}"; do wait "$pid"; done; pids=(); }

fetch_aster() {
  seed catalog '{"symbols":[]}'
  if [[ $product != spot ]]; then
    launch catalog '(has("code")|not) and (.symbols|type=="array" and length>0) and all(.symbols[]; (.status|type=="string") and (if .status=="TRADING" then all(.symbol,.baseAsset,.quoteAsset,.marginAsset,.contractType;type=="string" and length>0) else true end))' 'https://fapi.asterdex.com/fapi/v3/exchangeInfo' curl -fsS --max-time 20 https://fapi.asterdex.com/fapi/v3/exchangeInfo
  fi
  wait_queries
}
match_aster() {
  jq --arg ticker "$ticker" --arg quote "$quote" '{markets:[.symbols[]|select(.status=="TRADING" and .contractType=="PERPETUAL" and .baseAsset==$ticker and ($quote=="" or .quoteAsset==$quote))|{symbol,baseAsset,quoteAsset,marginAsset,contractType,status,underlyingType,underlyingSubType,channel,product:"perpetual"}]}' "$scratch/catalog.json"
}

fetch_binance() {
  seed spot '{"symbols":[]}'; seed futures '{"symbols":[]}'; seed assets '{"data":[]}'
  check='(.symbols|type=="array" and length>0) and all(.symbols[];(.symbol|type=="string") and (.baseAsset|type=="string") and (.quoteAsset|type=="string") and (.status|type=="string"))'
  if [[ $product != perpetual ]]; then
    launch spot "$check" 'https://api.binance.com/api/v3/exchangeInfo' binance-cli spot exchange-info --symbol-status TRADING --show-permission-sets false
    launch assets '.success==true and (.data|type=="array" and length>0) and all(.data[];(.assetCode|type=="string"))' 'https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset' binance-cli request GET https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset
  fi
  if [[ $product != spot ]]; then
    launch futures "$check and all(.symbols[];(.contractType|type==\"string\"))" 'https://fapi.binance.com/fapi/v1/exchangeInfo' binance-cli futures-usds exchange-information
  fi
  wait_queries
}

match_binance() {
jq -n --arg ticker "$ticker" --arg quote "$quote" --arg product "$product" \
  --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson errors "$errors" \
  --slurpfile spot "$scratch/spot.json" --slurpfile futures "$scratch/futures.json" --slurpfile assets "$scratch/assets.json" '
  # Preserve the complete input; only add recognized denomination-prefix candidates.
  [$ticker, ("1000"+$ticker), ("1000000"+$ticker), ("1M"+$ticker)] as $bases |
  [$assets[0].data[] | select(.uq == $ticker and ((.tags // []) | index("bStocks")) != null
    and .trading == true and .delisted == false and (.test == 0 or .test == "0")) | .assetCode] as $bstocks |
  {venue:"binance",ticker:$ticker,quoteAsset:(if $quote == "" then null else $quote end),product:$product,queriedAt:$queriedAt,
   sources: ([if $product != "perpetual" then "https://api.binance.com/api/v3/exchangeInfo", "https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset" else empty end,
     if $product != "spot" then "https://fapi.binance.com/fapi/v1/exchangeInfo" else empty end]),
   markets: ([
     $spot[0].symbols[] | . as $m |
     select(.status == "TRADING" and .isSpotTradingAllowed == true and ($quote == "" or .quoteAsset == $quote)) |
     select(($bases | index($m.baseAsset)) != null or ($bstocks | index($m.baseAsset)) != null) |
     {symbol,baseAsset,quoteAsset,status,product:"spot",
       representation:(if ($bstocks | index($m.baseAsset)) != null then "tokenized_stock" else "spot_asset" end)}
   ] + [
     $futures[0].symbols[] | . as $m |
     select(($bases | index($m.baseAsset)) != null and .status == "TRADING" and ($quote == "" or .quoteAsset == $quote)
       and (.contractType == "PERPETUAL" or .contractType == "TRADIFI_PERPETUAL")) |
     {symbol,baseAsset,quoteAsset,marginAsset,status,contractType,product:"perpetual",representation:"derivative"}
   ] | sort_by(.product,.symbol)),errors:$errors}'
}

fetch_bitget() {
categories=()
[[ $product == perpetual ]] || categories+=(SPOT)
if [[ $product != spot ]]; then
  [[ -n $quote && $quote != USDT ]] || categories+=(USDT-FUTURES)
  [[ -n $quote && $quote != USDC ]] || categories+=(USDC-FUTURES)
  if [[ -n $quote && $quote != USDT && $quote != USDC ]]; then
    echo 'Perpetual discovery supports USDT-FUTURES and USDC-FUTURES only' >"$scratch/perpetual-scope.error"
  fi
fi
for category in "${categories[@]}"; do
  check='(.code==null or .code=="00000") and (.data|type=="array") and all(.data[]; (.symbol|type=="string") and (.baseCoin|type=="string") and (.quoteCoin|type=="string") and (.status|type=="string"))'
  seed "$category" '{"data":[]}'
  launch "$category" "$check and all(.data[];.category==\"$category\")" "https://api.bitget.com/api/v3/market/instruments?category=$category" bgc market --action instruments --category "$category"
done
wait_queries
seed empty '{"data":[]}'
jq -s '[.[].data[]]' "$scratch"/*.json >"$scratch/catalog.tmp"
mv "$scratch/catalog.tmp" "$scratch/catalog.json"
}

match_bitget() {
jq --arg ticker "$ticker" --arg quote "$quote" '
  [$ticker,"1000"+$ticker,"1000000"+$ticker,"1M"+$ticker] as $bases |
  [.[] | . as $m | (.baseCoin|ascii_upcase) as $base |
   select(($bases|index($base))!=null or (.category=="SPOT" and .symbolType=="stock" and $base==("R"+$ticker))) |
   select($quote=="" or .quoteCoin==$quote) |
   select(["online","limit_open","limit_close","restrictedAPI"]|index($m.status)) |
   select(.category=="SPOT" or .type=="perpetual") |
   {symbol,category,baseAsset:.baseCoin,quoteAsset:.quoteCoin,status,
    product:(if .category=="SPOT" then "spot" else "perpetual" end),assetClass:.symbolType,
    restrictions:(if .status=="online" then [] elif .status=="limit_open" then ["Opening restricted"] elif .status=="limit_close" then ["Closing restricted"] else ["API trading restricted"] end),
    priceDecimals:.pricePrecision,sizeDecimals:.quantityPrecision,priceStep:.priceMultiplier,sizeStep:.quantityMultiplier,
    minBaseAmount:.minOrderQty,minQuoteAmount:.minOrderAmount,maxLeverage:.maxLeverage,
    offTime,limitOpenTime}] | unique_by(.category,.symbol)
  ' "$scratch/catalog.json"
}

fetch_gate() {
for name in spot perpetual stock; do echo '[]' >"$scratch/$name.json"; done
if [[ $product != perpetual ]]; then
  launch spot 'type=="array" and all(.[];(.id|type=="string") and (.base|type=="string") and (.quote|type=="string") and (.trade_status|type=="string"))' 'https://api.gateio.ws/api/v4/spot/currency_pairs' gate-cli cex spot market pairs --format json
fi
if [[ $product != spot ]]; then
  if [[ -z $quote || $quote == USDT ]]; then
    launch perpetual 'type=="array" and all(.[];(.name|type=="string") and (.status|type=="string") and (.type|type=="string"))' 'https://api.gateio.ws/api/v4/futures/usdt/contracts' gate-cli cex futures market contracts --settle usdt --format json
  else
    echo 'Perpetual discovery covers USDT-settled contracts only' >"$scratch/perpetual-scope.error"
  fi
fi
wait_queries

for ticker in "${tickers[@]}"; do
  seed "stock-$ticker" '[]'
  if jq -e --arg base "${ticker}G" --arg quote "$quote" 'any(.[];.base==$base and ($quote=="" or .quote==$quote))' "$scratch/spot.json" >/dev/null; then
    launch "stock-$ticker" ".currency==\"${ticker}G\" and (.category|type==\"array\")" "https://api.gateio.ws/api/v4/spot/currencies/${ticker}G" gate-cli cex spot market currency --currency "${ticker}G" --format json
  fi
done
wait_queries
for ticker in "${tickers[@]}"; do
  jq 'if type=="object" then [.] else . end' "$scratch/stock-$ticker.json" >"$scratch/stock-$ticker.tmp"
  mv "$scratch/stock-$ticker.tmp" "$scratch/stock-$ticker.json"
done
}

match_gate() {
jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile spot "$scratch/spot.json" --slurpfile perps "$scratch/perpetual.json" --slurpfile stock "$scratch/stock-$ticker.json" '
  [$ticker,"1000"+$ticker,"1000000"+$ticker,"1M"+$ticker] as $bases |
  (any($stock[0][];(.category|index("stocks"))!=null or (.category|index("gstocks"))!=null)) as $gstock |
  ([ $spot[0][] | . as $m | (.base|ascii_upcase) as $base |
    select(($bases|index($base))!=null or
      ($base==($ticker+"X") and ((.base_name//"")|test("xstock";"i"))) or
      ($base==($ticker+"ON") and ((.base_name//"")|test("ondo.*tokenized";"i"))) or
      ($base==($ticker+"G") and $gstock)) |
    select($quote=="" or .quote==$quote) |
    select(["tradable","buyable","sellable"]|index($m.trade_status)) |
    {symbol:.id,baseAsset:.base,quoteAsset:.quote,baseName:.base_name,product:"spot",status:.trade_status,
     representation:(if (.base_name//""|test("[0-9]+x(Long|Short)";"i")) then "leveraged_token" elif ($base==($ticker+"G") and $gstock) or (.base_name//""|test("xstock|ondo.*tokenized";"i")) then "tokenized_stock" else "spot_asset" end),
     restrictions:(if .trade_status=="buyable" then ["Buy only"] elif .trade_status=="sellable" then ["Sell only"] else [] end),
     marketType:.type,priceDecimals:.precision,sizeDecimals:.amount_precision,minBaseAmount:.min_base_amount,minQuoteAmount:.min_quote_amount,
     buyStart:.buy_start,sellStart:.sell_start,delistingTime:.delisting_time} ] +
   [ $perps[0][] | (.name|split("_")) as $parts | ($parts[0]|ascii_upcase) as $base |
     select($parts|length==2) | select(($bases|index($base))!=null or (.contract_type=="stocks" and $base==($ticker+"X"))) |
     select(.status=="trading" and (.in_delisting//false)==false) |
     {symbol:.name,baseAsset:$parts[0],quoteAsset:$parts[1],settlementAsset:"USDT",product:"perpetual",status,
      contractType:.type,assetClass:.contract_type,contractSize:.quanto_multiplier,priceStep:.order_price_round,
      minContracts:.order_size_min,maxContracts:.order_size_max,maxLeverage:.leverage_max,
      delistingTime:.delisting_time,delistedTime:.delisted_time,restrictions:[]} ]) | unique_by(.product,.symbol)
  '
}

fetch_kraken() {
seed spot '{}'; seed stocks '{}'; seed perpetual '{"instruments":[]}'; seed tickers '{"tickers":[]}' 
if [[ $product != perpetual ]]; then
  check='type=="object" and (has("error")|not) and all(.[]; (.altname|type=="string") and (.wsname|type=="string") and (.base|type=="string") and (.aclass_base|type=="string") and (.status|type=="string"))'
  launch spot "$check" 'https://api.kraken.com/0/public/AssetPairs' kraken pairs -o json
  launch stocks "$check" 'https://api.kraken.com/0/public/AssetPairs?asset_class=tokenized_asset' kraken pairs --asset-class tokenized_asset -o json
fi
if [[ $product != spot ]]; then
  launch perpetual '.result=="success" and (.instruments|type=="array") and all(.instruments[];(.symbol|type=="string") and (.base|type=="string") and (.quote|type=="string") and (.tradeable|type=="boolean") and (.isExpired|type=="boolean"))' 'https://futures.kraken.com/derivatives/api/v3/instruments' kraken futures instruments -o json
  launch tickers '.result=="success" and (.tickers|type=="array") and all(.tickers[];(.symbol|type=="string") and (.suspended|type=="boolean"))' 'https://futures.kraken.com/derivatives/api/v3/tickers' kraken futures tickers -o json
fi
wait_queries
jq -s '.[0]+.[1]' "$scratch/spot.json" "$scratch/stocks.json" >"$scratch/pairs-original.json"
for name in spot stocks; do jq '[.[]]' "$scratch/$name.json" >"$scratch/$name.tmp"; mv "$scratch/$name.tmp" "$scratch/$name.json"; done
for name in perpetual tickers; do
  field=instruments; [[ $name != tickers ]] || field=tickers
  jq --arg field "$field" '.[$field]' "$scratch/$name.json" >"$scratch/$name.tmp"
  mv "$scratch/$name.tmp" "$scratch/$name.json"
done
}

match_kraken() {
jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile spot "$scratch/spot.json" --slurpfile stocks "$scratch/stocks.json" --slurpfile perps "$scratch/perpetual.json" --slurpfile tickers "$scratch/tickers.json" '
  def canonical: ascii_upcase | if .=="XBT" then "BTC" elif .=="XDG" then "DOGE" else . end;
  ($ticker|canonical) as $target | ($quote|canonical) as $currency |
  ([$spot[0][], $stocks[0][] | . as $m | (.wsname|split("/")) as $pair |
    select($pair|length==2) | ($pair[0]|canonical) as $base |
    select($base==$target or (.aclass_base=="tokenized_asset" and ($pair[0]|endswith("x")) and $base==($target+"X"))) |
    select($quote=="" or ($pair[1]|canonical)==$currency) |
    select(["online","post_only","limit_only","reduce_only"]|index($m.status)) |
    {symbol:.altname,baseAsset:$pair[0],quoteAsset:$pair[1],wsname,product:"spot",status,assetClass:.aclass_base,
     representation:(if .aclass_base=="tokenized_asset" then "tokenized_stock" else "spot_asset" end),
     restrictions:(if .status=="post_only" then ["Resting limit orders only"] elif .status=="limit_only" then ["Limit orders only"] elif .status=="reduce_only" then ["Reduce only"] else [] end),
     priceDecimals:.pair_decimals,sizeDecimals:.lot_decimals,minBaseAmount:.ordermin,minQuoteAmount:.costmin,tickSize:.tick_size}] +
   [$perps[0][] | . as $m | select((.base|canonical)==$target and ($quote=="" or (.quote|canonical)==$currency)) |
    select(.tradeable==true and .isExpired==false and (.symbol|test("^P[FI]_"))) |
    [$tickers[0][]|select((.symbol|ascii_upcase)==($m.symbol|ascii_upcase) and .tag=="perpetual" and .suspended==false)] as $live |
    select($live|length==1) |
    {symbol,baseAsset:.base,quoteAsset:.quote,product:"perpetual",status:(if .postOnly then "post_only" else "online" end),
     contractType:.type,contractSize,tickSize,sizeDecimals:.contractValueTradePrecision,
     restrictions:(if .postOnly then ["Resting limit orders only"] else [] end),
     platformsPermitted,countriesBanned}]) | unique_by(.product,.symbol,.status)
  '
# A missing ticker for a matching unexpired perpetual is an unresolved status check.
if [[ $product != spot && ! -f $scratch/tickers.error && ! -f $scratch/perpetual.error ]]; then
  missing=$(jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile perps "$scratch/perpetual.json" --slurpfile tickers "$scratch/tickers.json" '
    def canonical: ascii_upcase | if .=="XBT" then "BTC" elif .=="XDG" then "DOGE" else . end;
    [$perps[0][]|. as $m|select((.base|canonical)==($ticker|canonical) and ($quote=="" or (.quote|canonical)==($quote|canonical)) and .tradeable==true and .isExpired==false and (.symbol|test("^P[FI]_")))|
     select(any($tickers[0][];(.symbol|ascii_upcase)==($m.symbol|ascii_upcase))|not)|.symbol]|join(", ")')
  [[ $missing == '""' ]] || printf 'Missing perpetual market status: %s\n' "$missing" >"$scratch/status-$ticker.error"
fi
}

fetch_lighter() {
  seed catalog '{"order_books":[]}'
  launch catalog '

  .code==200 and (.order_books|type=="array") and
  all(.order_books[];
    (.symbol|type=="string" and length>0) and
    (.market_id|type=="number") and (.status|type=="string") and
    (.market_type=="spot" or .market_type=="perp") and
    (if .market_type=="spot" then (.symbol|split("/")|length==2 and all(.[];length>0)) else true end))
  
' 'https://mainnet.zklighter.elliot.ai/api/v1/orderBooks?filter=all' purr lighter markets --market-type all
  wait_queries
}

match_lighter() {
jq --arg ticker "$ticker" --arg currency "$quote" --arg product "$product" \
  --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson errors "$errors" '
  {venue:"lighter",ticker:$ticker,currencyFilter:(if $currency=="" then null else $currency end),
   product:$product,queriedAt:$queriedAt,
   sources:["https://mainnet.zklighter.elliot.ai/api/v1/orderBooks?filter=all",
            "https://docs.lighter.xyz/trading/unified-trading-accounts"],
   markets:[.order_books[] | select(.status=="active") |
     (if .market_type=="spot" then "spot" else "perpetual" end) as $kind |
     select($product=="all" or $product==$kind) |
     (.symbol|split("/")[0]) as $base |
     ($base|ascii_upcase) as $normalized |
     select($normalized==$ticker or ($kind=="perpetual" and $normalized==("1000"+$ticker))) |
     # The current purr public mainnet uses USDC settlement for perpetuals.
     # Perp quote_asset_id=0 is a placeholder, not a Spot token index.
     (if $kind=="spot" then (.symbol|split("/")[1]) else "USDC" end) as $settlement |
     select($currency=="" or ($settlement|ascii_upcase)==$currency) |
     {symbol,marketId:.market_id,product:$kind,status,baseAsset:$base,
      quoteAsset:(if $kind=="spot" then $settlement else null end),
      settlementAsset:(if $kind=="perpetual" then $settlement else null end),
      sizeDecimals:.supported_size_decimals,priceDecimals:.supported_price_decimals,
      quoteDecimals:.supported_quote_decimals,minBaseAmount:.min_base_amount,
      minQuoteAmount:.min_quote_amount,orderQuoteLimit:.order_quote_limit,
      multiplier:.multiplier} ] | unique_by(.marketId),errors:$errors}
  ' "$scratch/catalog.json"
}


fetch_okx() {
  seed spot '[]'; seed swap '[]'
  check='type=="array" and all(.[];(.instId|type=="string") and (.instType|type=="string") and (.state|type=="string") and (.baseCcy|type=="string") and (.quoteCcy|type=="string"))'
  if [[ $product != perpetual ]]; then
    launch spot "$check and all(.[];.instType==\"SPOT\")" 'https://www.okx.com/api/v5/public/instruments?instType=SPOT' okx market instruments --instType SPOT --site global --json
  fi
  if [[ $product != spot ]]; then
    launch swap "$check and all(.[];.instType==\"SWAP\" and (.ctType|type==\"string\") and (.ctValCcy|type==\"string\") and (.settleCcy|type==\"string\"))" 'https://www.okx.com/api/v5/public/instruments?instType=SWAP' okx market instruments --instType SWAP --site global --json
  fi
  wait_queries
  jq -s 'add' "$scratch/spot.json" "$scratch/swap.json" >"$scratch/instruments.json"
}

match_okx() {
jq --arg ticker "$ticker" --arg quote "$quote" --arg product "$product" --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson errors "$errors" '
  {venue:"okx-cex",ticker:$ticker,quoteAsset:(if $quote=="" then null else $quote end),product:$product,queriedAt:$queriedAt,
   sources:["https://www.okx.com/api/v5/aigc/mcp/market-filter","https://www.okx.com/api/v5/public/instruments"],
   markets:[.[] | select(.state=="live") |
     if .instType=="SPOT" and (.baseCcy==$ticker or (.instCategory=="3" and .baseCcy==("X"+$ticker))) then
       {symbol:.instId,baseAsset:.baseCcy,quoteAsset:.quoteCcy,status:.state,product:"spot",representation:(if .instCategory=="3" then "tokenized_stock" else "spot_asset" end),lotSz,minSz,tickSz}
     elif .instType=="SWAP" and .ctType=="linear" and .ctValCcy==$ticker then
       {symbol:.instId,baseAsset:.ctValCcy,quoteAsset:.settleCcy,status:.state,product:"perpetual",representation:"derivative",ctType,ctVal,ctValCcy,lotSz,minSz,tickSz}
     else empty end | select($quote=="" or .quoteAsset==$quote)] | unique_by(.product,.symbol),errors:$errors}' "$scratch/instruments.json"
}


fetch_hyperliquid() {
  seed spot '[{"tokens":[],"universe":[]},[]]'; seed dexes '[]'; seed metas '[]'; seed perps '[]'
  spot_check='type=="array" and (.[0].tokens|type=="array" and length>0) and (.[0].universe|type=="array") and all(.[0].tokens[];(.index|type=="number") and (.name|type=="string") and (.szDecimals|type=="number")) and all(.[0].universe[];(.name|type=="string") and (.index|type=="number") and (.tokens|type=="array" and length==2))'
  launch spot "$spot_check" 'https://api.hyperliquid.xyz/info' purr hyperliquid markets --kind spot
  if [[ $product != spot ]]; then
    launch dexes 'type=="array" and length>0 and .[0]==null and all(.[1:][];(.name|type=="string"))' 'https://api.hyperliquid.xyz/info' curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"type":"perpDexs"}' https://api.hyperliquid.xyz/info
    launch metas 'type=="array" and length>0 and all(.[];(.universe|type=="array") and (.collateralToken|type=="number") and all(.universe[];(.name|type=="string") and (.szDecimals|type=="number")))' 'https://api.hyperliquid.xyz/info' curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"type":"allPerpMetas"}' https://api.hyperliquid.xyz/info
  fi
  wait_queries
  if [[ $product != spot && ! -f $scratch/dexes.error && ! -f $scratch/metas.error ]]; then
    if jq -ne --slurpfile dexes "$scratch/dexes.json" --slurpfile metas "$scratch/metas.json" '($dexes[0]|length)==($metas[0]|length)' >/dev/null; then
      jq -n --slurpfile dexes "$scratch/dexes.json" --slurpfile metas "$scratch/metas.json" '
        [$metas[0]|to_entries[]|.key as $dexIndex|.value as $meta|
         $meta.universe|to_entries[]|{asset:.value,collateralToken:$meta.collateralToken,
         dex:(if $dexIndex==0 then "default" else $dexes[0][$dexIndex].name end),
         assetId:(if $dexIndex==0 then .key else 100000+$dexIndex*10000+.key end)}]' >"$scratch/perps.json"
    else
      echo 'Perpetual metadata and DEX indices could not be aligned' >"$scratch/coverage.error"
    fi
  fi
}
match_hyperliquid() {
  jq -n --arg ticker "$ticker" --arg currency "$quote" --arg product "$product" \
    --arg queriedAt "$queried_at" --argjson errors '[]' \
    --slurpfile spot "$scratch/spot.json" --slurpfile perps "$scratch/perps.json" '
# Keep actual market identifiers and currency roles separate.
def base_matches($name):
  ($name|ascii_upcase) as $base | $base==$ticker or $base==("K"+$ticker);
def spot_matches($token):
  ($token.name|ascii_upcase) as $base |
  $base==$ticker or
  ($base==("U"+$ticker) and (($token.fullName // "")|startswith("Unit "))) or
  ($base==($ticker+"X") and (($token.fullName // "")|ascii_downcase|contains("xstock")));
($spot[0][0].tokens // []) as $tokens |
[$spot[0][0].universe[]? | . as $pair |
  [$tokens[]|select(.index==$pair.tokens[0])] as $base |
  [$tokens[]|select(.index==$pair.tokens[1])] as $quote |
  {pair:$pair,base:$base[0],quote:$quote[0]}] as $pairs |
[$perps[0][] |
  select(.asset==null or base_matches(.asset.name|split(":")|last)) |
  . as $row | [$tokens[]|select(.index==$row.collateralToken)] as $collateral |
  . + {collateral:$collateral[0]}] as $perpRows |
{venue:"hyperliquid",ticker:$ticker,currencyFilter:(if $currency=="" then null else $currency end),product:$product,
 queriedAt:$queriedAt,sources:["https://api.hyperliquid.xyz/info"],
 markets:([
   if $product!="perpetual" then $pairs[] |
     select(.base!=null and .quote!=null and spot_matches(.base)) |
     select($currency=="" or (.quote.name|ascii_upcase)==$currency) |
     {symbol:(.base.name+"/"+.quote.name),pairId:.pair.name,assetId:(10000+.pair.index),product:"spot",
      baseAsset:.base.name,baseFullName:(.base.fullName // null),quoteAsset:.quote.name,collateralAsset:null,
      szDecimals:.base.szDecimals,status:"listed"}
   else empty end
 ] + [
   $perpRows[] | select(.asset!=null and .asset.isDelisted!=true and .collateral!=null and (.assetId|type)=="number") |
   select($currency=="" or (.collateral.name|ascii_upcase)==$currency) |
   {symbol:.asset.name,dex,assetId,product:"perpetual",baseAsset:(.asset.name|split(":")|last),
    quoteAsset:null,collateralAsset:.collateral.name,szDecimals:.asset.szDecimals,maxLeverage:.asset.maxLeverage,
    onlyIsolated:(.asset.onlyIsolated // false),marginMode:(.asset.marginMode // null),status:"active"}
 ] | unique_by(.product,.assetId)),
 errors:($errors + [
   if $product!="perpetual" then $pairs[]|select(.base==null or .quote==null)|{query:"spot",message:"Unresolved pair token metadata",symbol:.pair.name} else empty end
 ] + [
   $perpRows[] | select(.asset==null or (.asset.isDelisted!=true and (.collateral==null or (.assetId|type)!="number"))) |
   {query:"perpetual",symbol:(.symbol // .asset.name),dex,message:"Exact instrument or collateral metadata is unavailable"}
 ])}
'
}


run_venue() {
  venue=$1; scratch="$scratch_root/$venue"; mkdir "$scratch"
  pids=()
  trap - EXIT
  trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
  quote=USDT; currency_role=quote; supported='["spot","perpetual"]'
  case "$venue" in
    aster) quote=''; cli=curl; supported='["perpetual"]'; fn=aster ;;
    binance) cli=binance-cli; fn=binance ;;
    bitget) cli=bgc; fn=bitget ;;
    gate) cli=gate-cli; fn=gate ;;
    hyperliquid) quote=USDC; currency_role=spot_quote_or_perpetual_collateral; cli=purr; fn=hyperliquid ;;
    kraken) quote=USD; cli=kraken; fn=kraken ;;
    lighter) quote=USDC; currency_role=spot_quote_or_perpetual_settlement; cli=purr; fn=lighter ;;
    okx-cex) cli=okx; fn=okx ;;
  esac
  (( ! quote_set )) || quote=$quote_override
  errors='[]'; started_ms=$(date +%s%3N)
  : >"$scratch/matches.jsonl"
  if ! command -v "$cli" >/dev/null || { [[ $venue == hyperliquid ]] && ! command -v curl >/dev/null; }; then
    echo 'Required venue CLI is unavailable; coverage unresolved' >"$scratch/dependency.error"
  else
    "fetch_$fn"
    for ticker in "${tickers[@]}"; do
      "match_$fn" >"$scratch/match-$ticker.json"
      jq -c --arg ticker "$ticker" '
        if type=="array" then {ticker:$ticker,markets:.,errors:[]} else {ticker:$ticker,markets,errors:(.errors//[])} end
      ' "$scratch/match-$ticker.json" >>"$scratch/matches.jsonl"
    done
  fi
  shopt -s nullglob
  for file in "$scratch"/*.error; do
    name=${file##*/}; name=${name%.error}
    errors=$(jq -cn --argjson errors "$errors" --arg query "$name" --arg message "$(cat "$file")" '$errors+[{query:$query,message:$message}]')
  done
  sources='[]'
  for file in "$scratch"/*.source; do
    sources=$(jq -cn --argjson sources "$sources" --arg source "$(cat "$file")" '$sources+[$source]')
  done
  elapsed_ms=$(( $(date +%s%3N) - started_ms ))
  jq -s --arg venue "$venue" --arg quote "$quote" --arg role "$currency_role" --arg product "$product" \
    --argjson supported "$supported" --argjson elapsedMs "$elapsed_ms" --argjson errors "$errors" --argjson sources "$sources" '
    {venue:$venue,scope:{currency:(if $quote=="" then null else $quote end),currencyRole:$role,supportedProducts:$supported,requestedProduct:$product},elapsedMs:$elapsedMs,
     sources:($sources|unique),results:map({ticker,markets}),
     errors:($errors+[.[]|.ticker as $ticker|.errors[]|.+{ticker:$ticker}])}
  ' "$scratch/matches.jsonl" >"$scratch_root/$venue.json"
}

queried_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for venue in "${venues[@]}"; do
  run_venue "$venue" >"$scratch_root/$venue.stdout" 2>"$scratch_root/$venue.stderr" &
  workers+=("$!")
done
files=()
for index in "${!workers[@]}"; do
  venue=${venues[$index]}
  if ! wait "${workers[$index]}"; then
    jq -n --arg venue "$venue" '{venue:$venue,scope:null,elapsedMs:null,sources:[],results:[],errors:[{query:"worker",message:"Venue processing failed; coverage unresolved"}]}' >"$scratch_root/$venue.json"
  fi
  files+=("$scratch_root/$venue.json")
done
workers=()
if [[ ${FX_MARKET_MODE:-discover} == candles ]]; then
  run_candles "${files[@]}"
  exit $?
fi
if [[ ${FX_MARKET_MODE:-discover} == routes ]]; then
  run_routes "${files[@]}"
  exit $?
fi
tickers_json=$(printf '%s\n' "${tickers[@]}" | jq -Rsc 'split("\n")[:-1]')
jq -s --argjson tickers "$tickers_json" '
  # Discovery hands off exact order selectors, not a snapshot of order sizing rules.
  def order_market($venue):
    . as $market |
    {venue:$venue,symbol,product:(if .product=="perpetual" then "perp" else .product end)} +
    (if $venue=="bitget" then {category} else {} end) +
    (if $venue=="gate" and .product=="perpetual" then {settlementAsset} else {} end) +
    (if $venue=="hyperliquid" then {assetId} + (if .dex!=null then {dex} else {} end) else {} end) +
    (if $venue=="kraken" and .assetClass=="tokenized_asset" then {assetClass} else {} end) +
    (if $venue=="lighter" then {marketId} else {} end) +
    (($market.restrictions // []) +
      (if $market.onlyIsolated==true or $market.marginMode=="noCross" then ["isolated_only"] else [] end) |
      unique | if length>0 then {restrictions:.} else {} end);
  . as $venues |
  {results:[$tickers[]|. as $ticker|{ticker:$ticker,markets:[$venues[]|.venue as $venue|.results[]|select(.ticker==$ticker)|.markets[]|order_market($venue)]}],
   errors:[$venues[]|.venue as $venue|.errors[]|.+{venue:$venue}]}
' "${files[@]}" >"$scratch_root/result.json"
cat "$scratch_root/result.json"
jq -e '.errors|length==0' "$scratch_root/result.json" >/dev/null
