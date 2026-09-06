#!/usr/bin/env bash
# Public catalog discovery only. Requires Bash 4+, binance-cli, jq, and GNU timeout.
set -euo pipefail
usage() { echo 'Usage: binance-markets.sh TICKER [--quote QUOTE|ALL (default USDT)] [--product spot|perpetual|all]' >&2; exit 2; }
[[ $# -gt 0 ]] || usage
ticker=${1^^}; shift
quote=USDT; product=all
while (( $# )); do
  case "$1" in
    --quote) [[ $# -ge 2 ]] || usage; quote=${2^^}; shift 2 ;;
    --product) [[ $# -ge 2 ]] || usage; product=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ $ticker =~ ^[A-Z0-9]+$ && $quote =~ ^[A-Z0-9]+$ ]] || usage
if [[ $quote == ALL ]]; then quote=''; fi
[[ $product == spot || $product == perpetual || $product == all ]] || usage
for dependency in binance-cli jq timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
fetch() {
  local name=$1 validation=$2; shift 2
  if ! timeout --kill-after=2s 25s "$@" >"$scratch/$name.json" 2>"$scratch/$name.stderr"; then
    echo 'Catalog command failed or timed out' >"$scratch/$name.error"
  elif ! jq -e "$validation" "$scratch/$name.json" >/dev/null 2>&1; then
    echo 'Catalog returned an API error, invalid JSON, or unexpected/empty data' >"$scratch/$name.error"
  fi
  if [[ -f $scratch/$name.error ]]; then
    echo '{"symbols":[],"data":[]}' >"$scratch/$name.json"
  fi
}
catalog_check='(.symbols | type == "array" and length > 0) and all(.symbols[]; (.symbol | type == "string") and (.baseAsset | type == "string") and (.quoteAsset | type == "string") and (.status | type == "string"))'
for name in spot futures assets; do echo '{"symbols":[],"data":[]}' >"$scratch/$name.json"; done
if [[ $product != perpetual ]]; then
  fetch spot "$catalog_check" binance-cli spot exchange-info --symbol-status TRADING --show-permission-sets false &
  pids+=("$!")
  fetch assets '(.success == true) and (.data | type == "array" and length > 0) and all(.data[]; (.assetCode | type == "string"))' binance-cli request GET https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset &
  pids+=("$!")
fi
if [[ $product != spot ]]; then
  fetch futures "$catalog_check and all(.symbols[]; (.contractType | type == \"string\"))" binance-cli futures-usds exchange-information &
  pids+=("$!")
fi
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
errors='[]'
for name in spot futures assets; do
  if [[ -f $scratch/$name.error ]]; then
    errors=$(jq -cn --argjson errors "$errors" --arg catalog "$name" --arg message "$(cat "$scratch/$name.error")" '$errors + [{catalog:$catalog,message:$message}]')
  fi
done
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
[[ $errors == '[]' ]]
