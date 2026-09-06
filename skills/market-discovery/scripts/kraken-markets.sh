#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venue=kraken; default_quote=USD; cli=kraken
source "$script_dir/catalog-common.sh" "$@"
for name in spot stocks perpetual tickers; do echo '[]' >"$scratch/$name.json"; done
if [[ $product != perpetual ]]; then
  check='type=="object" and (has("error")|not) and all(.[]; (.altname|type=="string") and (.wsname|type=="string") and (.base|type=="string") and (.aclass_base|type=="string") and (.status|type=="string"))'
  fetch spot "$check" '[.[]]' 'https://api.kraken.com/0/public/AssetPairs' kraken pairs -o json &
  pids+=("$!")
  fetch stocks "$check" '[.[]]' 'https://api.kraken.com/0/public/AssetPairs?asset_class=tokenized_asset' kraken pairs --asset-class tokenized_asset -o json &
  pids+=("$!")
fi
if [[ $product != spot ]]; then
  fetch perpetual '.result=="success" and (.instruments|type=="array") and all(.instruments[];(.symbol|type=="string") and (.base|type=="string") and (.quote|type=="string") and (.tradeable|type=="boolean") and (.isExpired|type=="boolean"))' '.instruments' 'https://futures.kraken.com/derivatives/api/v3/instruments' kraken futures instruments -o json &
  pids+=("$!")
  fetch tickers '.result=="success" and (.tickers|type=="array") and all(.tickers[];(.symbol|type=="string") and (.suspended|type=="boolean"))' '.tickers' 'https://futures.kraken.com/derivatives/api/v3/tickers' kraken futures tickers -o json &
  pids+=("$!")
fi
wait_queries
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
  ' >"$scratch/markets.json"
# A missing ticker for a matching unexpired perpetual is an unresolved status check.
if [[ $product != spot && ! -f $scratch/tickers.error && ! -f $scratch/perpetual.error ]]; then
  missing=$(jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile perps "$scratch/perpetual.json" --slurpfile tickers "$scratch/tickers.json" '
    def canonical: ascii_upcase | if .=="XBT" then "BTC" elif .=="XDG" then "DOGE" else . end;
    [$perps[0][]|. as $m|select((.base|canonical)==($ticker|canonical) and ($quote=="" or (.quote|canonical)==($quote|canonical)) and .tradeable==true and .isExpired==false and (.symbol|test("^P[FI]_")))|
     select(any($tickers[0][];(.symbol|ascii_upcase)==($m.symbol|ascii_upcase))|not)|.symbol]|join(", ")')
  [[ $missing == '""' ]] || printf 'Missing perpetual market status: %s\n' "$missing" >"$scratch/status.error"
fi
finish
