# Public observations are independent of fee eligibility and account configuration.
# The same native book feeds both the compact snapshot and route simulation.
market_snapshot() (
  local m=$1 dir=$2 venue symbol kind meta='{}' size=1 unsupported=false
  venue=$(jq -r .venue <<<"$m"); symbol=$(jq -r .symbol <<<"$m"); kind=$(jq -r .product <<<"$m")
  mkdir -p "$dir"
  local name
  for name in book funding oi meta; do echo null >"$dir/$name.json"; done
  case "$venue" in
    aster|binance)
      local host=https://fapi.binance.com
      [[ $venue != aster ]] || host=https://fapi.asterdex.com
      if [[ $kind == spot ]]; then
        market_read "$dir/book.json" binance-cli spot depth --symbol "$symbol" --limit 100
      else
        if [[ $venue == binance ]]; then market_read "$dir/book.json" binance-cli futures-usds order-book --symbol "$symbol" --limit 100
        else market_read "$dir/book.json" curl -fsS --max-time 15 "$host/fapi/v1/depth?symbol=$symbol&limit=100"; fi
        market_read "$dir/funding.json" curl -fsS --max-time 15 "$host/fapi/v1/premiumIndex?symbol=$symbol"
        market_read "$dir/oi.json" curl -fsS --max-time 15 "$host/fapi/v1/openInterest?symbol=$symbol"
        market_read "$dir/meta.json" curl -fsS --max-time 15 "$host/fapi/v1/fundingInfo"
      fi ;;
    bitget)
      market_read "$dir/book.json" bgc market --action orderbook --category "$(jq -r .category <<<"$m")" --symbol "$symbol" --limit 100
      if [[ $kind != spot ]]; then
        local url="https://api.bitget.com/api/v2/mix/market"
        market_read "$dir/funding.json" curl -fsS --max-time 15 "$url/current-fund-rate?symbol=$symbol&productType=$(jq -r .category <<<"$m")"
        market_read "$dir/oi.json" curl -fsS --max-time 15 "$url/open-interest?symbol=$symbol&productType=$(jq -r .category <<<"$m")"
        market_read "$dir/meta.json" curl -fsS --max-time 15 "$url/ticker?symbol=$symbol&productType=$(jq -r .category <<<"$m")"
      fi ;;
    gate)
      if [[ $kind == spot ]]; then
        market_read "$dir/book.json" gate-cli cex spot market orderbook --pair "$symbol" --depth 100 --format json
      else
        market_read "$dir/meta.json" curl -fsS --max-time 15 "https://api.gateio.ws/api/v4/futures/usdt/contracts/$symbol"
        meta=$(cat "$dir/meta.json"); size=$(jq -r '.quanto_multiplier // null' <<<"$meta")
        [[ $(jq -r .type <<<"$meta") == direct ]] || unsupported=true
        market_read "$dir/book.json" gate-cli cex futures market orderbook --contract "$symbol" --settle usdt --depth 100 --format json
      fi ;;
    hyperliquid)
      market_read "$dir/book.json" purr hyperliquid l2 --coin "$(jq -r '.pairId//.symbol' <<<"$m")"
      if [[ $kind != spot ]]; then
        local body
        body=$(jq -cn --arg dex "$(jq -r 'if .dex=="default" then "" else .dex end' <<<"$m")" '{type:"metaAndAssetCtxs",dex:$dex}')
        market_read "$dir/meta.json" curl -fsS --max-time 15 -H 'Content-Type: application/json' -d "$body" https://api.hyperliquid.xyz/info
      fi ;;
    lighter)
      market_read "$dir/meta.json" purr lighter market --market "$symbol" --market-type "$(if [[ $kind == spot ]]; then echo spot; else echo perp; fi)"
      local cached_book="$scratch_root/lighter/book-$(jq -r .marketId <<<"$m").json"
      if [[ -f $cached_book ]]; then cp "$cached_book" "$dir/book.json"
      else market_read "$dir/book.json" purr lighter order-book-depth --market "$symbol" --market-type "$(if [[ $kind == spot ]]; then echo spot; else echo perp; fi)" --limit 100; fi
      if [[ $kind != spot ]]; then
        market_read "$dir/oi.json" curl -fsS --max-time 15 "https://mainnet.zklighter.elliot.ai/api/v1/orderBookDetails?market_id=$(jq -r .marketId <<<"$m")"
        market_read "$dir/funding.json" curl -fsS --max-time 15 https://mainnet.zklighter.elliot.ai/api/v1/funding-rates
      fi ;;
    kraken)
      if [[ $kind == spot ]]; then
        local args=(kraken orderbook "$symbol" --count 100 -o json)
        if [[ $(jq -r '.assetClass//""' <<<"$m") == tokenized_asset ]]; then args+=(--asset-class tokenized_asset); fi
        market_read "$dir/book.json" "${args[@]}"
      else
        [[ $symbol == PF_* || $symbol == pf_* ]] || unsupported=true
        market_read "$dir/book.json" kraken futures orderbook "$symbol" -o json
        market_read "$dir/meta.json" curl -fsS --max-time 15 https://futures.kraken.com/derivatives/api/v3/tickers
      fi ;;
    okx-cex)
      meta=$(jq -c --arg s "$symbol" '.[]|select(.instId==$s)' "$scratch_root/okx-cex/instruments.json")
      if [[ $kind != spot ]]; then
        size=$(jq -r '.ctVal // null' <<<"$meta")
        [[ $(jq -r .ctType <<<"$meta") == linear ]] || unsupported=true
        market_read "$dir/funding.json" okx market funding-rate "$symbol" --site global --json
        market_read "$dir/oi.json" okx market open-interest --instType SWAP --instId "$symbol" --site global --json
        market_read "$dir/meta.json" okx market mark-price --instType SWAP --instId "$symbol" --site global --json
      fi
      market_read "$dir/book.json" okx market orderbook "$symbol" --sz 100 --site global --json
      ;;
  esac
  jq -n --argjson m "$m" --argjson size "$size" --argjson unsupported "$unsupported" \
    --argjson input "$route_input" --slurpfile rates "$scratch_root/routes/rates.json" \
    --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile b "$dir/book.json" --slurpfile f "$dir/funding.json" --slurpfile o "$dir/oi.json" --slurpfile meta "$dir/meta.json" \
    "$candle_jq $route_math $snapshot_math"'snapshot($m;$b[0];$f[0];$o[0];$meta[0];$size;$unsupported;$observedAt) |
      if $input.amount!=null then . + {depthEstimate:displayed_fill(.;$input;$rates[0])} else . end' >"$dir/snapshot.json"
)
