#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
venue=gate; default_quote=USDT; cli=gate-cli
source "$script_dir/catalog-common.sh" "$@"
for name in spot perpetual stock; do echo '[]' >"$scratch/$name.json"; done
if [[ $product != perpetual ]]; then
  fetch spot 'type=="array" and all(.[];(.id|type=="string") and (.base|type=="string") and (.quote|type=="string") and (.trade_status|type=="string"))' '.' 'https://api.gateio.ws/api/v4/spot/currency_pairs' gate-cli cex spot market pairs --format json &
  pids+=("$!")
fi
if [[ $product != spot ]]; then
  if [[ -z $quote || $quote == USDT ]]; then
    fetch perpetual 'type=="array" and all(.[];(.name|type=="string") and (.status|type=="string") and (.type|type=="string"))' '.' 'https://api.gateio.ws/api/v4/futures/usdt/contracts' gate-cli cex futures market contracts --settle usdt --format json &
    pids+=("$!")
  else
    echo 'Perpetual discovery covers USDT-settled contracts only' >"$scratch/perpetual-scope.error"
  fi
fi
wait_queries
# G-suffix candidates need stock classification, not just a matching suffix.
if jq -e --arg base "${ticker}G" 'any(.[];.base==$base)' "$scratch/spot.json" >/dev/null; then
  fetch stock ".currency==\"${ticker}G\" and (.category|type==\"array\")" '[.]' "https://api.gateio.ws/api/v4/spot/currencies/${ticker}G" gate-cli cex spot market currency --currency "${ticker}G" --format json
fi
jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile spot "$scratch/spot.json" --slurpfile perps "$scratch/perpetual.json" --slurpfile stock "$scratch/stock.json" '
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
  ' >"$scratch/markets.json"
finish
