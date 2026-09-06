# Embedded route orchestration; catalog workers and all independent book reads run in parallel.
route_error() { jq -cn --arg venue "$1" --arg symbol "$2" --arg message "$3" '{venue:$venue,symbol:$symbol,message:$message}'; }
route_book() (
  local m=$1 index=$2 venue symbol kind dir meta='{}' fee=null size=1 extra=0 fee_asset=base source='' step=0 minq=0 minv=0
  venue=$(jq -r .venue <<<"$m"); symbol=$(jq -r .symbol <<<"$m"); kind=$(jq -r .product <<<"$m")
  dir="$scratch_root/routes/$index"; mkdir -p "$dir"
  echo null >"$dir/book.json"
  fail() { route_error "$venue" "$symbol" "$1" >"$dir/error.json"; }
  if jq -e '(.status|ascii_downcase|test("post.?only|reduce|halt|cancel")) or ((.restrictions//[])|length>0)' <<<"$m" >/dev/null; then
    fail 'Market restricts immediate opening orders'; exit 0
  fi
  if ! jq -en --argjson m "$m" --argjson input "$route_input" --slurpfile rates "$scratch_root/routes/rates.json" "$candle_jq $route_math"'
    quote_ccy($m) as $q | if $q==($input.currency//"USDT") then 1 else usd($rates[0];$q)/usd($rates[0];($input.currency//"USDT")) end' >/dev/null 2>&1; then
    fail 'Live quote-currency conversion unavailable'; exit 0
  fi
  case "$venue" in
    aster)
      source='https://docs.asterdex.com/trading/perpetuals/fees-and-specs/fees'
      meta=$(jq -c --arg s "$symbol" '.symbols[]|select(.symbol==$s)' "$scratch_root/aster/catalog.json")
      fee=$(jq -nr --argjson m "$meta" 'if (($m.underlyingSubType//[])|index("STOCK"))!=null then 0.002 else 0.0004 end')
      market_read "$dir/book.json" curl -fsS --max-time 20 "https://fapi.asterdex.com/fapi/v1/depth?symbol=$symbol&limit=100"
      ;;
    binance)
      if [[ $kind == spot ]]; then
        source='https://www.binance.com/en/fee/trading'; fee=0.001
        meta=$(jq -c --arg s "$symbol" '.symbols[]|select(.symbol==$s)' "$scratch_root/binance/spot.json")
        market_read "$dir/book.json" binance-cli spot depth --symbol "$symbol" --limit 100
      else
        source='https://www.binance.com/en/fee/futureFee'; fee=0.0005
        meta=$(jq -c --arg s "$symbol" '.symbols[]|select(.symbol==$s)' "$scratch_root/binance/futures.json")
        market_read "$dir/book.json" binance-cli futures-usds order-book --symbol "$symbol" --limit 100
      fi ;;
    bitget)
      source='https://www.bitget.com/support/articles/12560603892734'
      local category; category=$(jq -r .category <<<"$m")
      meta=$(jq -c --arg s "$symbol" '.data[]|select(.symbol==$s)' "$scratch_root/bitget/$category.json")
      fee=$(jq -r --arg kind "$kind" '.takerFeeRate // (if $kind=="spot" then 0.001 else null end)' <<<"$meta")
      step=$(jq -r '.quantityMultiplier // pow(10;-(.quantityPrecision|tonumber))' <<<"$meta")
      minq=$(jq -r '.minOrderQty // 0' <<<"$meta"); minv=$(jq -r '.minOrderAmount // 0' <<<"$meta")
      market_read "$dir/book.json" bgc market --action orderbook --category "$category" --symbol "$symbol" --limit 100
      ;;
    gate)
      source='https://www.gate.com/docs/developers/apiv4/en/'
      if [[ $kind == spot ]]; then
        meta=$(jq -c --arg s "$symbol" '.[]|select(.id==$s)' "$scratch_root/gate/spot.json")
        fee=$(jq -r 'try ((.fee|tonumber)/100) catch null' <<<"$meta")
        step=$(jq -nr --argjson m "$meta" 'pow(10;-($m.amount_precision//0))')
        minq=$(jq -r '.min_base_amount // 0' <<<"$meta"); minv=$(jq -r '.min_quote_amount // 0' <<<"$meta")
        market_read "$dir/book.json" gate-cli cex spot market orderbook --pair "$symbol" --depth 100 --format json
      else
        meta=$(jq -c --arg s "$symbol" '.[]|select(.name==$s)' "$scratch_root/gate/perpetual.json")
        if [[ $(jq -r .type <<<"$meta") != direct ]]; then fail 'Only linear base-denominated contracts can be compared'; exit 0; fi
        fee=$(jq -r '.taker_fee_rate // null' <<<"$meta"); size=$(jq -r '.quanto_multiplier // null' <<<"$meta"); step=$size
        minq=$(jq -nr --argjson m "$meta" '($m.order_size_min|tonumber)*($m.quanto_multiplier|tonumber)')
        market_read "$dir/book.json" gate-cli cex futures market orderbook --contract "$symbol" --settle usdt --depth 100 --format json
      fi ;;
    kraken)
      source='https://www.kraken.com/features/fee-schedule'; fee_asset=quote
      if [[ $kind == spot ]]; then
        meta=$(jq -c --arg s "$symbol" '[.[]|select(.altname==$s)]|unique_by(.fees,.lot_decimals,.ordermin,.costmin,.status)|if length==1 then .[0] else {} end' "$scratch_root/kraken/pairs-original.json")
        fee=$(jq -r 'try ((.fees[0][1]|tonumber)/100) catch null' <<<"$meta")
        step=$(jq -nr --argjson m "$meta" 'pow(10;-($m.lot_decimals//0))')
        minq=$(jq -r '.ordermin // 0' <<<"$meta"); minv=$(jq -r '.costmin // 0' <<<"$meta")
        args=(kraken orderbook "$symbol" --count 100 -o json)
        if [[ $(jq -r '.assetClass//""' <<<"$m") == tokenized_asset ]]; then args+=(--asset-class tokenized_asset); fi
        market_read "$dir/book.json" "${args[@]}"
      else
        meta=$(jq -c --arg s "$symbol" '.[]|select(.symbol==$s)' "$scratch_root/kraken/perpetual.json")
        if [[ $symbol != PF_* && $symbol != pf_* ]]; then fail 'Inverse or unverified contract size'; exit 0; fi
        # Flexible futures order size is base units, contractSize is not a multiplier for this book.
        fee=0.0005; size=1
        step=$(jq -nr --argjson m "$meta" 'pow(10;-($m.contractValueTradePrecision//0))')
        market_read "$dir/book.json" kraken futures orderbook "$symbol" -o json
      fi ;;
    hyperliquid)
      source='https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees'; extra=0.0005
      if [[ $kind == perpetual && $(jq -r .dex <<<"$m") != default ]]; then fail 'HIP-3 fee scale and growth-mode fee not verified'; exit 0; fi
      if [[ $kind == spot ]]; then fee=0.0007; else fee=0.00045; fi
      step=$(jq -nr --argjson m "$m" 'pow(10;-($m.szDecimals//0))')
      market_read "$dir/book.json" purr hyperliquid l2 --coin "$(jq -r '.pairId//.symbol' <<<"$m")"
      ;;
    lighter)
      source='https://docs.lighter.xyz/trading/trading-fees'; extra=0.0005; fee_asset=quote
      market_read "$dir/meta.json" purr lighter market --market "$symbol" --market-type "$(if [[ $kind == spot ]]; then echo spot; else echo perp; fi)"
      meta=$(cat "$dir/meta.json"); fee=$(jq -r '.taker_fee//null' <<<"$meta")
      # API fee values are percentages (0.0000 for Standard accounts).
      fee=$(jq -nr --arg f "$fee" 'try (($f|tonumber)/100) catch null')
      step=$(jq -nr --argjson m "$meta" 'pow(10;-($m.supported_size_decimals//0))')
      minq=$(jq -r '.min_base_amount//0' <<<"$meta"); minv=$(jq -r '.min_quote_amount//0' <<<"$meta")
      market_read "$dir/book.json" purr lighter order-book-depth --market "$symbol" --market-type "$(if [[ $kind == spot ]]; then echo spot; else echo perp; fi)" --limit 100
      ;;
    okx-cex)
      source='https://www.okx.com/help/trading-fee-rules-faq'
      meta=$(jq -c --arg s "$symbol" '.[]|select(.instId==$s)' "$scratch_root/okx-cex/instruments.json")
      if [[ $(jq -r '.ruleType//"normal"' <<<"$meta") != normal ]]; then fail 'Special fee/product group not verified'; exit 0; fi
      if [[ $kind == spot ]]; then fee=0.001
      else
        if [[ $(jq -r .ctType <<<"$meta") != linear ]]; then fail 'Only linear base-denominated swaps can be compared'; exit 0; fi
        fee=0.0005; size=$(jq -r '.ctVal|tonumber' <<<"$meta")
      fi
      step=$(jq -nr --argjson m "$meta" --argjson size "$size" '($m.lotSz|tonumber)*$size')
      minq=$(jq -nr --argjson m "$meta" --argjson size "$size" '($m.minSz|tonumber)*$size')
      market_read "$dir/book.json" okx market orderbook "$symbol" --sz 100 --site global --json
      ;;
  esac
  if [[ $venue == binance || $venue == aster ]]; then
    step=$(jq -r '[.filters[]?|select(.filterType=="LOT_SIZE")|.stepSize][0]//0' <<<"$meta")
    minq=$(jq -r '[.filters[]?|select(.filterType=="LOT_SIZE")|.minQty][0]//0' <<<"$meta")
    minv=$(jq -r '[.filters[]?|select(.filterType=="MIN_NOTIONAL" or .filterType=="NOTIONAL")|(.minNotional//.notional)][0]//0' <<<"$meta")
  fi
  if ! jq -e --arg f "$fee" --arg size "$size" '($f|tonumber)>=0 and ($f|tonumber)<1 and ($size|tonumber)>0' <<<null >/dev/null 2>&1; then fail 'Applicable public fee or base-size unit unavailable'; exit 0; fi
  for field in step minq minv; do
    value=${!field}
    printf -v "$field" '%s' "$(jq -nr --arg v "$value" 'try ($v|tonumber) catch 0')"
  done
  # Raw venue books are converted once, with common reference FX and underlying units.
  if ! jq -en --argjson m "$m" --argjson fee "$fee" --argjson size "$size" --argjson extra "$extra" \
      --arg feeAsset "$fee_asset" --arg feeSource "$source" --argjson step "$step" --argjson minq "$minq" --argjson minv "$minv" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson input "$route_input" \
      --slurpfile book "$dir/book.json" --slurpfile rates "$scratch_root/routes/rates.json" "$candle_jq $route_math"'
      ($book[0]) as $raw | ($raw|if type=="array" then . elif .result=="success" then . else rows end) as $b |
      (quote_ccy($m)) as $quote | (if $quote==($input.currency//"USDT") then 1 else usd($rates[0];$quote)/usd($rates[0];($input.currency//"USDT")) end) as $rate |
      exposure($m) as $exp |
      (if $m.venue=="hyperliquid" then {asks:[$b.levels[1][]|[.px,.sz]],bids:[$b.levels[0][]|[.px,.sz]]}
       elif $m.venue=="lighter" then {asks:[$b.asks[]|[.price,.remaining_base_amount]],bids:[$b.bids[]|[.price,.remaining_base_amount]]}
       elif $m.venue=="gate" and $m.product!="spot" then {asks:[$b.asks[]|[.p,.s]],bids:[$b.bids[]|[.p,.s]]}
       elif $m.venue=="kraken" and $m.product=="spot" then ($b|to_entries[0].value)
       elif $m.venue=="kraken" then $b.orderBook
       elif $m.venue=="okx-cex" then $b[0]
       elif $m.venue=="bitget" then {asks:$b.a,bids:$b.b}
       else $b end) as $d |
      depth($d.asks;$size;$exp;$rate;false) as $asks | depth($d.bids;$size;$exp;$rate;true) as $bids |
      select(($asks|length)>0 and ($bids|length)>0 and $asks[0].price >= $bids[0].price) |
      {id:($m.venue+":"+$m.symbol+":"+$m.product),venue:$m.venue,symbol:$m.symbol,product:$input.product,
       quote:$quote,quotedAt:$now,fee:$fee,extraFee:$extra,feeAsset:$feeAsset,feeSource:$feeSource,
       step:($step*$exp),minQuantity:($minq*$exp),minValue:($minv*$rate),asks:$asks,bids:$bids,
       routing:($m|{category,assetId,pairId,dex,marketId,assetClass,settlementAsset}|with_entries(select(.value!=null)))}' >"$dir/candidate.json" 2>"$dir/normalize.stderr"; then
    rm -f "$dir/candidate.json"; fail 'Order book, currency rate, or product units could not be verified'
  fi
)

run_routes() {
  local file index=0 m pid
  mkdir -p "$scratch_root/routes"
  jq -s '[.[]|.venue as $v|.results[]|.ticker as $t|.markets[]|.+{venue:$v,ticker:$t}]' "$@" >"$scratch_root/routes/markets.json"
  pids=()
  market_launch "$scratch_root/routes/fx-stats.json" curl -fsS --max-time 20 'https://api.binance.com/api/v3/ticker/24hr'
  market_launch "$scratch_root/routes/fx-books.json" curl -fsS --max-time 20 'https://api.binance.com/api/v3/ticker/bookTicker'
  wait_queries
  # ticker/price includes stale delisted fiat pairs. Require recent activity and a usable two-sided book.
  jq -n --argjson now "$(date +%s%3N)" --slurpfile stats "$scratch_root/routes/fx-stats.json" --slurpfile books "$scratch_root/routes/fx-books.json" "$route_math"'
    live_rates(($stats[0]//[]);($books[0]//[]);$now)' >"$scratch_root/routes/rates.json"
  workers=()
  if [[ $(jq -r .product <<<"$route_input") == spot ]]; then
    onchain_routes >"$scratch_root/routes/onchain.stdout" 2>"$scratch_root/routes/onchain.stderr" & workers+=("$!")
  fi
  while IFS= read -r m; do
    route_book "$m" "$index" & workers+=("$!"); index=$((index+1))
    # Bound CLI process fan-out for large multi-quote crypto catalogs.
    if (( ${#workers[@]} >= 12 )); then wait "${workers[0]}" || true; workers=("${workers[@]:1}"); fi
  done < <(jq -c '.[]' "$scratch_root/routes/markets.json")
  for pid in "${workers[@]}"; do wait "$pid" || true; done
  workers=()
  # Every failed worker remains an explicit exclusion, never an empty success.
  for ((index=0; index<$(jq length "$scratch_root/routes/markets.json"); index++)); do
    if [[ ! -s $scratch_root/routes/$index/candidate.json && ! -s $scratch_root/routes/$index/error.json ]]; then
      m=$(jq -c ".[$index]" "$scratch_root/routes/markets.json")
      route_error "$(jq -r .venue <<<"$m")" "$(jq -r .symbol <<<"$m")" 'Route worker failed' >"$scratch_root/routes/$index/error.json"
    fi
  done
  shopt -s nullglob
  local candidates=("$scratch_root/routes/"*/candidate.json) errors=("$scratch_root/routes/"[0-9]*/error.json)
  if (( ${#candidates[@]} )); then jq -s . "${candidates[@]}" >"$scratch_root/routes/books.json"; else echo '[]' >"$scratch_root/routes/books.json"; fi
  if (( ${#errors[@]} )); then jq -s . "${errors[@]}" >"$scratch_root/routes/errors.json"; else echo '[]' >"$scratch_root/routes/errors.json"; fi
  if [[ ! -s $scratch_root/routes/onchain.json ]]; then
    if [[ $(jq -r .product <<<"$route_input") == spot ]]; then
      echo '{"routes":[],"errors":[{"query":"onchain","message":"Issuer/quote worker failed; coverage unresolved"}]}' >"$scratch_root/routes/onchain.json"
    else echo '{"routes":[],"errors":[]}' >"$scratch_root/routes/onchain.json"; fi
  fi
  jq -n --argjson input "$route_input" --slurpfile c "$scratch_root/routes/books.json" --slurpfile chains "$scratch_root/routes/onchain.json" \
    --slurpfile errors "$scratch_root/routes/errors.json" --slurpfile coverage <(jq -s '[.[]|.venue as $v|.errors[]|.+{venue:$v}]' "$@") "$route_math"'
    ($input.amount|tonumber) as $amount |
    ([$c[0][]|(.asks[0].price+.bids[0].price)/2]|sort) as $mids |
    (if ($mids|length)>0 then $mids[(($mids|length)/2|floor)] else null end) as $mark |
    (if $mark!=null then $amount/$mark else null end) as $target |
    ([$c[0][]|select(.step<=$target)|.step]|max//0) as $grid |
    (if $input.product=="perp" and $mark!=null then round_down($target;$grid) else null end) as $quantity |
    [$c[0][]|. as $candidate | try
       (if $input.product=="spot" then spot(.;$amount) else perpetual(.;$quantity;$input.direction) end)
       catch {error:{venue:$candidate.venue,symbol:$candidate.symbol,message:.}}] as $computed |
    ([$computed[]|select(.error==null)] + $chains[0].routes | sort_by(.effectivePrice) |
      if $input.direction=="short" then reverse else . end) as $routes |
    {results:[{ticker:($input.ticker|ascii_upcase),product:$input.product,direction:($input.direction//"buy"),amount:$input.amount,
      currency:($input.currency//"USDT"),amountBasis:(if $input.product=="spot" then "total_budget" else "position_notional" end),
      selected:($routes[0].id//null),routes:$routes,
      comparisonQuantity:$quantity,
      assumptions:(["Indicative public/default-tier taker quotes; excludes fee promotions and discounts; refresh before execution",
       "Funds already at each route; excludes transfers, conversions into funding assets, and account-specific discounts",
       "No account readiness check; Hyperliquid/Lighter include the Pieverse 0.05% execution fee"]+
       (if $input.product=="perp" then ["Opening cost only; funding, margin and closing fees excluded; common quantity rounded to venue lot steps"] else [] end))}],
     errors:($coverage[0]+$errors[0]+[$computed[]|select(.error!=null)|.error]+$chains[0].errors)}'
}
