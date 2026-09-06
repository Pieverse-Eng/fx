# Public issuer discovery and indicative stock-buy quotes. Never loads a wallet or transaction.
bg_public() {
  local target=$1 path=$2 body=$3 timestamp sign
  timestamp=$(date +%s%3N)
  sign=$(printf 'POST%s%s%s' "$path" "$body" "$timestamp" | sha256sum); sign=${sign%% *}
  market_read "$target" curl -fsS --max-time 20 "https://copenapi.bgwapi.io$path" \
    -H 'Content-Type: application/json' -H 'channel: toc_agent' -H 'brand: toc_agent' \
    -H 'clientversion: 10.0.0' -H 'language: en' -H 'token: toc_agent' \
    -H "X-SIGN: 0x$sign" -H "X-TIMESTAMP: $timestamp" -d "$body"
}
chain_failure() { jq -cn --arg chain "$1" --arg issuer "$2" --arg message "$3" '{chain:$chain,issuer:$issuer,message:$message}'; }
quote_bg_stock() (
  local deployment=$1 index=$2 chain issuer dir input_contract input_symbol output_contract output_symbol rates budget ref usd_rate reserve=0 i amount body
  chain=$(jq -r .chain <<<"$deployment"); issuer=$(jq -r .issuer <<<"$deployment"); dir="$scratch_root/routes/chain-$index"; mkdir -p "$dir"
  fail() { chain_failure "$chain" "$issuer" "$1" >"$dir/error.json"; }
  input_contract=$(jq -r .inputContract <<<"$deployment"); input_symbol=$(jq -r .inputAsset <<<"$deployment")
  output_contract=$(jq -r .contract <<<"$deployment"); output_symbol=$(jq -r .symbol <<<"$deployment")
  body=$(jq -cn --arg c "$chain" --arg a "$input_contract" '{list:[{chain:$c,contract:$a}]}')
  bg_public "$dir/rate.json" /market/v3/coin/batchGetBaseInfo "$body"
  if ! usd_rate=$(jq -er 'select(.status==0)|.data.list[0].price|tonumber|select(.>0)' "$dir/rate.json"); then fail 'Payment-token USD rate unavailable'; exit 0; fi
  ref=$(jq -ner --argjson input "$route_input" --slurpfile rates "$scratch_root/routes/rates.json" "$route_math"'usd($rates[0];($input.currency//"USDT"))') || { fail 'Reference FX unavailable'; exit 0; }
  budget=$(jq -nr --argjson input "$route_input" --argjson rate "$ref" '($input.amount|tonumber)*$rate')
  # Iteratively reserve gas, then request a new nonlinear quote for the reduced input.
  for i in 0 1 2; do
    amount=$(jq -nr --argjson budget "$budget" --argjson reserve "$reserve" --argjson rate "$usd_rate" '((($budget-$reserve)/$rate*1000000)|floor)/1000000')
    if ! jq -e '.>0' <<<"$amount" >/dev/null; then fail 'Budget does not cover external gas'; exit 0; fi
    body=$(jq -cn --argjson d "$deployment" --arg amount "$amount" --arg now "$(date +%s%3N)" '
      "0x0000000000000000000000000000000000000001" as $address |
      {fromAddress:$address,toAddress:$address,fromChain:$d.chain,toChain:$d.chain,fromSymbol:$d.inputAsset,
       fromContract:$d.inputContract,fromAmount:$amount,toSymbol:$d.symbol,toContract:$d.contract,
       tab_type:"swap",publicKey:"",slippage:"",requestId:$now}')
    bg_public "$dir/quote.json" /swap-go/swapx/quote "$body"
    # Explicit provider warnings, missing gas or unknown extra fees cannot enter ranking.
    jq --argjson now "$(date +%s%3N)" '[select(.status==0)|.data.quoteResults[]?|
      select(.priceImpact.priceImpactWarn!="forbidden" and (.priceImpact.needConfirm//false)==false) |
      select((.rwaExpired//0)==0 and ((.rwaExpiredTimestamp//0)==0 or .rwaExpiredTimestamp>$now)) |
      select(.tradeFees==null or .tradeFees==[] or .tradeFees=={}) |
      select((try ((.gasFees.gasFeeAmountInUsd|tonumber)>=0) catch false) and (try ((.actualOutAmount//.outAmount|tonumber)>0) catch false))]' "$dir/quote.json" >"$dir/eligible.json"
    if [[ $(jq length "$dir/eligible.json") == 0 ]]; then fail 'No quote with verified output, gas and fee treatment (or provider forbids the route)'; exit 0; fi
    if (( i>0 )); then
      jq --argjson input "$amount" --argjson rate "$usd_rate" --argjson budget "$budget" \
        '[.[]|select(($input*$rate+(.gasFees.gasFeeAmountInUsd|tonumber)) <= $budget)]' "$dir/eligible.json" >"$dir/within.json"
      if [[ $(jq length "$dir/within.json") -gt 0 ]]; then break; fi
    fi
    reserve=$(jq '[.[]|.gasFees.gasFeeAmountInUsd|tonumber]|max|.*1.05+0.000001' "$dir/eligible.json")
  done
  if [[ ! -s $dir/within.json ]] || [[ $(jq length "$dir/within.json") == 0 ]]; then fail 'Gas-adjusted quote exceeds budget'; exit 0; fi
  jq --argjson d "$deployment" --argjson amount "$amount" --argjson rate "$usd_rate" --argjson ref "$ref" \
      --argjson budget "$budget" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [.[]|(.actualOutAmount//.outAmount|tonumber) as $out |
      ((.gasFees.gasFeeAmountInUsd|tonumber)/$ref) as $gas | (($amount*$rate)/$ref+$gas) as $spend |
      {id:($d.chain+":"+$d.contract+":"+(.market.id|tostring)),chain:$d.chain,issuer:$d.issuer,symbol:$d.symbol,product:"spot",
       contract:$d.contract,inputAsset:$d.inputAsset,inputContract:$d.inputContract,amountIn:($amount|tostring),
       provider:"bitget-wallet",route:.market.label,expectedQuantity:$out,spend:$spend,gas:$gas,
       unspent:($budget/$ref-$spend),effectivePrice:($spend/$out),quotedAt:$now,quoteType:"indicative"}] |
    sort_by(.effectivePrice)|.[0:1]' "$dir/within.json" >"$dir/routes.json"
)
quote_sol_stock() (
  local deployment=$1 index=$2 dir="$scratch_root/routes/chain-$2" ref usdc sol budget reserve=0 i amount multiplier body
  mkdir -p "$dir"
  fail() { chain_failure solana xstocks "$1" >"$dir/error.json"; }
  if [[ -z ${FX_PLATFORM_DFLOW_QUOTE_URL:-} || -z ${FX_PLATFORM_QUOTE_TOKEN:-} ]]; then fail 'DFlow broker capability unavailable'; exit 0; fi
  ref=$(jq -ner --argjson input "$route_input" --slurpfile rates "$scratch_root/routes/rates.json" "$route_math"'usd($rates[0];($input.currency//"USDT"))') || { fail 'Reference FX unavailable'; exit 0; }
  usdc=$(jq -er "$route_math"'usd(.;"USDC")' "$scratch_root/routes/rates.json") || { fail 'USDC/USD rate unavailable'; exit 0; }
  sol=$(jq -er "$route_math"'usd(.;"SOL")' "$scratch_root/routes/rates.json") || { fail 'SOL/USD rate unavailable'; exit 0; }
  market_read "$dir/multiplier.json" curl -fsS --max-time 20 "https://api.xstocks.fi/api/v2/public/assets/$(jq -r .symbol <<<"$deployment")/multiplier?network=Solana"
  multiplier=$(jq -er '.currentMultiplier|tonumber|select(.>0)' "$dir/multiplier.json") || { fail 'Solana exposure multiplier unavailable'; exit 0; }
  budget=$(jq -nr --argjson input "$route_input" --argjson ref "$ref" '($input.amount|tonumber)*$ref')
  for i in 0 1 2; do
    amount=$(jq -nr --argjson budget "$budget" --argjson reserve "$reserve" --argjson rate "$usdc" '(($budget-$reserve)/$rate*1000000)|floor|tostring')
    if ! jq -e 'tonumber>0 and tonumber<9007199254740991' <<<"\"$amount\"" >/dev/null; then fail 'Budget outside quote range'; exit 0; fi
    body=$(jq -cn --argjson d "$deployment" --arg amount "$amount" '{inputMint:$d.inputContract,outputMint:$d.contract,amount:$amount}')
    # Header content goes through stdin; the process list does not expose the capability.
    printf 'x-pieverse-market-quote-capability: %s\n' "$FX_PLATFORM_QUOTE_TOKEN" >"$dir/headers"
    market_read "$dir/quote.json" curl -fsS --max-time 20 "$FX_PLATFORM_DFLOW_QUOTE_URL" -H "@$dir/headers" -H 'Content-Type: application/json' -d "$body"
    rm -f "$dir/headers"
    if ! jq -e --argjson d "$deployment" --arg amount "$amount" '
      .ok==true and .data.inputMint==$d.inputContract and .data.outputMint==$d.contract and .data.inAmount==$amount and
      (.data.outAmount|tonumber)>0 and (.data.outputMintDecimals|type)=="number" and
      (.data.networkFeeLamports|tonumber)>=0' "$dir/quote.json" >/dev/null 2>&1; then fail 'DFlow returned no valid quote with network fees'; exit 0; fi
    local gas spend
    gas=$(jq -r --argjson sol "$sol" '(.data.networkFeeLamports|tonumber)/1000000000*$sol' "$dir/quote.json")
    spend=$(jq -nr --arg amount "$amount" --argjson rate "$usdc" --argjson gas "$gas" '($amount|tonumber)/1000000*$rate+$gas')
    if (( i>0 )) && jq -e --argjson spend "$spend" '.>=$spend' <<<"$budget" >/dev/null; then break; fi
    reserve=$(jq -nr --argjson gas "$gas" '$gas*1.05+0.000001')
  done
  if ! jq -e --argjson spend "$spend" '.>=$spend' <<<"$budget" >/dev/null; then fail 'Gas-adjusted quote exceeds budget'; exit 0; fi
  jq --argjson d "$deployment" --arg amount "$amount" --argjson multiplier "$multiplier" --argjson gas "$gas" \
    --argjson spend "$spend" --argjson budget "$budget" --argjson ref "$ref" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .data | ((.outAmount|tonumber)/pow(10;.outputMintDecimals)*$multiplier) as $shares |
    [{id:("solana:"+$d.contract+":dflow"),chain:"solana",issuer:"xstocks",symbol:$d.symbol,product:"spot",contract:$d.contract,
      inputAsset:"USDC",inputContract:$d.inputContract,amountIn:(($amount|tonumber)/1000000|tostring),provider:"dflow",route,
      expectedQuantity:$shares,spend:($spend/$ref),gas:($gas/$ref),unspent:(($budget-$spend)/$ref),
      effectivePrice:($spend/$ref/$shares),quotedAt:$now,quoteType:"indicative"}]' "$dir/quote.json" >"$dir/routes.json"
)
issuer_read() (
  local target=$1 url=$2 code
  code=$(timeout --kill-after=2s 25s curl -sS --max-time 20 -o "$target.body" -w '%{http_code}' "$url" 2>"$target.stderr") || code=000
  printf '%s' "$code" >"$target.status"
  if [[ $code == 200 ]] && jq -e 'type=="object"' "$target.body" >/dev/null 2>&1; then mv "$target.body" "$target"
  else echo null >"$target"; fi
)
onchain_routes() (
  shopt -s nullglob
  local dir="$scratch_root/routes/issuers" ticker index=0 d pid
  ticker=$(jq -r '.ticker|ascii_upcase' <<<"$route_input"); mkdir -p "$dir"
  pids=()
  issuer_read "$dir/xstocks.json" "https://api.xstocks.fi/api/v2/public/assets/${ticker}x" & pids+=("$!")
  market_launch "$dir/robinhood.json" curl -fsS --max-time 20 https://api.robinhood.com/rhj/assets
  market_launch "$dir/networks.json" curl -fsS --max-time 20 https://www.binance.com/bapi/capital/v1/public/capital/getNetworkCoinAll
  wait_queries
  jq -n --arg ticker "$ticker" --slurpfile x "$dir/xstocks.json" --slurpfile rh "$dir/robinhood.json" \
    --slurpfile bn "$scratch_root/binance/assets.json" --slurpfile nets "$dir/networks.json" '
    [($bn[0].data[]?|select(.uq==$ticker and .trading==true and .delisted==false and ((.tags//[])|index("bStocks"))!=null)) as $asset |
      $nets[0].data[]?|select(.coin==$asset.assetCode)|.networkList[]?|select(.network=="BSC" and (.contractAddress|length)>0) |
      # Non-unit issuer multipliers require verified semantics before cross-issuer ranking.
      select(($asset.ml|tonumber)==1) |
      {issuer:"bstocks",chain:"bnb",symbol:$asset.assetCode,contract:.contractAddress,inputAsset:"USDT",inputContract:"0x55d398326f99059fF775485246999027B3197955"}] +
    [($x[0]|select(.underlyingSymbol==$ticker and .isTradingHalted==false)) as $asset |
      $asset.deployments[]?|select(.network=="BinanceSmartChain" or .network=="Solana") |
      . as $dep | .stablecoins[]?|select(.symbol=="USDC") |
      {issuer:"xstocks",chain:(if $dep.network=="Solana" then "solana" else "bnb" end),symbol:$asset.symbol,
       contract:$dep.address,inputAsset:"USDC",inputContract:.address}] +
    [$rh[0].assets[]?|select(.tokenSymbol==$ticker and .status=="ASSET_STATUS_ACTIVE" and (.currentMultiplier|tonumber)==1) |
      . as $asset | .deployments[]?|select(.chainId==4663) |
      {issuer:"robinhood",chain:"robinhood",symbol:$asset.tokenSymbol,contract:.contractAddress,inputAsset:"USDG",
       inputContract:"0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"}]' >"$dir/deployments.json"
  pids=()
  while IFS= read -r d; do
    if [[ $(jq -r .chain <<<"$d") == solana ]]; then quote_sol_stock "$d" "$index" &
    else quote_bg_stock "$d" "$index" & fi
    pids+=("$!"); index=$((index+1))
  done < <(jq -c '.[]' "$dir/deployments.json")
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  for ((index=0; index<$(jq length "$dir/deployments.json"); index++)); do
    if [[ ! -s $scratch_root/routes/chain-$index/routes.json && ! -s $scratch_root/routes/chain-$index/error.json ]]; then
      d=$(jq -c ".[$index]" "$dir/deployments.json")
      chain_failure "$(jq -r .chain <<<"$d")" "$(jq -r .issuer <<<"$d")" 'Quote worker failed' >"$scratch_root/routes/chain-$index/error.json"
    fi
  done
  # No issuer match is normal for crypto; registry failures remain visible instead of proving absence.
  : >"$dir/coverage.jsonl"
  if ! jq -e '.assets|type=="array"' "$dir/robinhood.json" >/dev/null; then
    chain_failure robinhood robinhood 'Issuer catalog unavailable' >>"$dir/coverage.jsonl"
  fi
  if ! jq -e '.data|type=="array"' "$dir/networks.json" >/dev/null; then
    chain_failure bnb bstocks 'Issuer deployment catalog unavailable' >>"$dir/coverage.jsonl"
  fi
  if [[ $(cat "$dir/xstocks.json.status") != 404 ]] && ! jq -e --arg t "$ticker" '.underlyingSymbol==$t and (.deployments|type)=="array"' "$dir/xstocks.json" >/dev/null; then
    chain_failure bnb/solana xstocks 'Issuer lookup failed; stock deployment coverage unresolved' >>"$dir/coverage.jsonl"
  fi
  jq -n --arg t "$ticker" --slurpfile bn "$scratch_root/binance/assets.json" --slurpfile rh "$dir/robinhood.json" '
    ($bn[0].data[]?|select(.uq==$t and ((.tags//[])|index("bStocks"))!=null and (try ((.ml|tonumber)!=1) catch true))|
      {chain:"bnb",issuer:"bstocks",message:"Non-unit or unknown token exposure multiplier is not supported"}),
    ($rh[0].assets[]?|select(.tokenSymbol==$t and (try ((.currentMultiplier|tonumber)!=1) catch true))|
      {chain:"robinhood",issuer:"robinhood",message:"Non-unit or unknown token exposure multiplier is not supported"})' >>"$dir/coverage.jsonl"
  jq -s . "$dir/coverage.jsonl" >"$dir/errors.json"
  local parts=("$scratch_root/routes/"chain-*/routes.json) failures=("$scratch_root/routes/"chain-*/error.json)
  if (( ${#parts[@]} )); then jq -s add "${parts[@]}" >"$dir/routes.json"; else echo '[]' >"$dir/routes.json"; fi
  if (( ${#failures[@]} )); then jq -s . "${failures[@]}" >"$dir/failures.json"; else echo '[]' >"$dir/failures.json"; fi
  jq -n --slurpfile routes "$dir/routes.json" --slurpfile failures "$dir/failures.json" --slurpfile errors "$dir/errors.json" \
    '{routes:$routes[0],errors:($failures[0]+$errors[0])}' >"$scratch_root/routes/onchain.json"
)
