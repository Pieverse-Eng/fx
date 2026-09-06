#!/usr/bin/env bash
# Public mainnet discovery. Requires Bash 4+, purr, jq, and GNU timeout.
set -euo pipefail
usage() { echo 'Usage: lighter-markets.sh TICKER [--quote CURRENCY|ALL (default USDC)] [--product spot|perpetual|all]' >&2; exit 2; }
[[ $# -gt 0 ]] || usage
ticker=${1^^}; shift
currency=USDC; product=all
while (( $# )); do
  case "$1" in
    --quote) [[ $# -ge 2 ]] || usage; currency=${2^^}; shift 2 ;;
    --product) [[ $# -ge 2 ]] || usage; product=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ $ticker =~ ^[A-Z0-9]+$ && $currency =~ ^[A-Z0-9]+$ ]] || usage
[[ $product == spot || $product == perpetual || $product == all ]] || usage
[[ $currency != ALL ]] || currency=''
for dependency in purr jq timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
errors='[]'
if ! timeout --kill-after=2s 25s purr lighter markets --market-type all >"$scratch/catalog.json" 2>"$scratch/stderr"; then
  errors='[{"query":"markets","message":"Public catalog query failed or timed out; coverage unresolved"}]'
elif ! jq -e '
  .code==200 and (.order_books|type=="array") and
  all(.order_books[];
    (.symbol|type=="string" and length>0) and
    (.market_id|type=="number") and (.status|type=="string") and
    (.market_type=="spot" or .market_type=="perp") and
    (if .market_type=="spot" then (.symbol|split("/")|length==2 and all(.[];length>0)) else true end))
  ' "$scratch/catalog.json" >/dev/null 2>&1; then
  errors='[{"query":"markets","message":"Invalid public catalog; coverage unresolved"}]'
fi
[[ $errors == '[]' ]] || echo '{"order_books":[]}' >"$scratch/catalog.json"
jq --arg ticker "$ticker" --arg currency "$currency" --arg product "$product" \
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
[[ $errors == '[]' ]]
