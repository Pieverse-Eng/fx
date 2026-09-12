chain_failure() { jq -cn --arg chain "$1" --arg issuer "$2" --arg message "$3" '{chain:$chain,issuer:$issuer,message:$message}'; }
issuer_read() (
  local target=$1 url=$2 code
  code=$(timeout --kill-after=2s 25s curl -sS --max-time 20 -o "$target.body" -w '%{http_code}' "$url" 2>"$target.stderr") || code=000
  printf '%s' "$code" >"$target.status"
  if [[ $code == 200 ]] && jq -e 'type=="object"' "$target.body" >/dev/null 2>&1; then mv "$target.body" "$target"
  else echo null >"$target"; fi
)
# Public deployment catalogs shared by discovery and cost comparison. No quotes or wallet access.
issuer_catalogs() (
  local dir=$1 a b
  mkdir -p "$dir"
  issuer_read "$dir/robinhood.json" https://api.robinhood.com/rhj/assets & a=$!
  issuer_read "$dir/networks.json" https://www.binance.com/bapi/capital/v1/public/capital/getNetworkCoinAll & b=$!
  wait "$a"; wait "$b"
)
issuer_discover() (
  local ticker=$1 dir=$2 catalogs=$3
  mkdir -p "$dir"
  issuer_read "$dir/xstocks.json" "https://api.xstocks.fi/api/v2/public/assets/${ticker}x"
  jq -n --arg ticker "$ticker" --slurpfile x "$dir/xstocks.json" --slurpfile rh "$catalogs/robinhood.json" \
    --slurpfile bn "$scratch_root/binance/assets.json" --slurpfile nets "$catalogs/networks.json" '
    [($bn[0].data[]?|select(.uq==$ticker and .trading==true and .delisted==false and ((.tags//[])|index("bStocks"))!=null)) as $asset |
      $nets[0].data[]?|select(.coin==$asset.assetCode)|.networkList[]?|select(.network=="BSC" and (.contractAddress|length)>0) |
      {issuer:"bstocks",chain:"bnb",symbol:$asset.assetCode,contract:.contractAddress,exposureMultiplier:(try ($asset.ml|tonumber) catch null),inputAsset:"USDT",inputContract:"0x55d398326f99059fF775485246999027B3197955"}] +
    [($x[0]|select(.underlyingSymbol==$ticker and .isTradingHalted==false)) as $asset |
      $asset.deployments[]?|select(.network=="BinanceSmartChain" or .network=="Solana") |
      . as $dep | .stablecoins[]?|select(.symbol=="USDC") |
      {issuer:"xstocks",chain:(if $dep.network=="Solana" then "solana" else "bnb" end),symbol:$asset.symbol,
       contract:$dep.address,inputAsset:"USDC",inputContract:.address}] +
    [$rh[0].assets[]?|select(.tokenSymbol==$ticker and .status=="ASSET_STATUS_ACTIVE") |
      . as $asset | .deployments[]?|select(.chainId==4663) |
      {issuer:"robinhood",chain:"robinhood",symbol:$asset.tokenSymbol,contract:.contractAddress,exposureMultiplier:(try ($asset.currentMultiplier|tonumber) catch null),inputAsset:"USDG",
       inputContract:"0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"}]' >"$dir/deployments.json"
  # No issuer match is normal for crypto; registry failures remain visible instead of proving absence.
  : >"$dir/coverage.jsonl"
  if ! jq -e '.assets|type=="array"' "$catalogs/robinhood.json" >/dev/null; then
    chain_failure robinhood robinhood 'Issuer catalog unavailable' >>"$dir/coverage.jsonl"
  fi
  if ! jq -e '.data|type=="array"' "$catalogs/networks.json" >/dev/null; then
    chain_failure bnb bstocks 'Issuer deployment catalog unavailable' >>"$dir/coverage.jsonl"
  fi
  if [[ $(cat "$dir/xstocks.json.status") != 404 ]] && ! jq -e --arg t "$ticker" '.underlyingSymbol==$t and (.deployments|type)=="array"' "$dir/xstocks.json" >/dev/null; then
    chain_failure bnb/solana xstocks 'Issuer lookup failed; stock deployment coverage unresolved' >>"$dir/coverage.jsonl"
  fi
  if ! jq -e '.data|type=="array"' "$scratch_root/binance/assets.json" >/dev/null || [[ -f $scratch_root/binance/assets.error ]]; then
    chain_failure bnb bstocks 'Issuer asset catalog unavailable' >>"$dir/coverage.jsonl"
  fi
  jq -s . "$dir/coverage.jsonl" >"$dir/errors.json"
)
