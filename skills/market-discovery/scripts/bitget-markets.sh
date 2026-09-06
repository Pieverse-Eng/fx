#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venue=bitget; default_quote=USDT; cli=bgc
source "$script_dir/catalog-common.sh" "$@"
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
  fetch "$category" "$check and all(.data[];.category==\"$category\")" '.data' "https://api.bitget.com/api/v3/market/instruments?category=$category" bgc market --action instruments --category "$category" &
  pids+=("$!")
done
wait_queries
echo '[]' >"$scratch/empty.json"
jq -s --arg ticker "$ticker" --arg quote "$quote" '
  [$ticker,"1000"+$ticker,"1000000"+$ticker,"1M"+$ticker] as $bases |
  [add[] | . as $m | (.baseCoin|ascii_upcase) as $base |
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
  ' "$scratch"/*.json >"$scratch/markets.tmp"
mv "$scratch/markets.tmp" "$scratch/markets.json"
finish
