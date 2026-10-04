# Public facts only. Native observations below retain their existing freshness and rules.
platform_catalog_read() (
  local kind=$1 owner=$2 destination=$3 underlying=${4:-} attempt page cursor revision total count url code previous
  local root=${FX_MARKET_CATALOG_URL%/}
  [[ $root =~ ^https?://[^[:space:]]+$ ]] || return 1
  for attempt in 1 2; do
    cursor='';revision='';total='';count=0;previous=''
    : >"$destination.items"
    for ((page=0;page<200;page++)); do
      url="$root/$kind/$owner/$(if [[ $kind == venues ]];then echo instruments;else echo assets;fi)?environment=mainnet&limit=500"
      [[ -z $underlying ]] || url+="&underlying=$(jq -nr --arg u "$underlying" '$u|@uri')"
      [[ -z $cursor ]] || url+="&cursor=$(jq -nr --arg c "$cursor" '$c|@uri')"
      code=$(curl -sS --max-time 20 -o "$destination.page" -w '%{http_code}' "$url") || return 1
      [[ $code != 409 ]] || break
      [[ $code == 200 ]] || return 1
      jq -e --arg owner "$owner" --arg kind "$kind" '
       .schemaVersion==1 and (.revision|type=="string" and length>0) and
       (.total|type=="number" and .>=0 and .<=100000 and floor==.) and
       (.nextCursor==null or (.nextCursor|type=="string" and length>0 and length<=2048)) and
       (.items|type=="array" and length<=500) and all(.items[];
         (.id|type=="string" and length>0) and
         (if $kind=="venues" then .venue==$owner and (.binding|type=="object") and
           (.base|type=="string") and (.quote|type=="string") and (.nativeSymbol|type=="string") and
           (.product=="spot" or .product=="perp") and (.aliases|type=="array")
          else .issuer==$owner and (.contract|type=="string") and (.chain|type=="string") end))
      ' "$destination.page" >/dev/null || return 1
      if [[ -z $revision ]];then
        revision=$(jq -r .revision "$destination.page");total=$(jq -r .total "$destination.page")
      elif [[ $(jq -r .revision "$destination.page") != "$revision" || $(jq -r .total "$destination.page") != "$total" ]];then break
      fi
      jq -c '.items[]' "$destination.page" >>"$destination.items"
      count=$((count+$(jq '.items|length' "$destination.page")))
      (( count<=total )) || return 1
      cursor=$(jq -r '.nextCursor//""' "$destination.page")
      if [[ -z $cursor ]];then
        ((count==total)) || return 1
        jq -se 'length==(map(.id)|unique|length)' "$destination.items" >/dev/null || return 1
        jq -s . "$destination.items" >"$destination.complete"
        mv "$destination.complete" "$destination"
        return
      fi
      [[ $cursor != "$previous" && $count != 0 ]] || return 1
      previous=$cursor
    done
  done
  return 1
)
platform_fetch() {
  mkdir -p "$scratch/platform"
  printf '%s\n' "${FX_MARKET_CATALOG_URL%/}/venues/$(if [[ $venue == okx-cex ]];then echo okx;else echo "$venue";fi)/instruments" >"$scratch/platform.source"
  if ! platform_catalog_read venues "$(if [[ $venue == okx-cex ]];then echo okx;else echo "$venue";fi)" "$scratch/platform/facts.json";then
    echo 'Platform market catalog unavailable; coverage unresolved' >"$scratch/platform.error"
    return 1
  fi
}
platform_match() (
  local target=$ticker candidate native_ticker native_symbol native_id current matches
  : >"$scratch/platform-matches.jsonl"
  while IFS= read -r candidate;do
    native_ticker=$(jq -r .base <<<"$candidate")
    native_symbol=$(jq -r .nativeSymbol <<<"$candidate")
    # Gate's formatter consumes the latest currency restriction evidence.
    [[ $fn != gate || -f $scratch/stock-$native_ticker.json ]] || echo '[]' >"$scratch/stock-$native_ticker.json"
    ticker=$native_ticker
    "match_$fn" >"$scratch/native-match.json"
    ticker=$target
    jq --arg venue "$venue" --argjson candidate "$candidate" '
      (if type=="array" then . else .markets end)[] |
      select(if $venue=="hyperliquid" then .assetId==$candidate.binding.assetId
        elif $venue=="lighter" then .marketId==$candidate.binding.marketId
        elif $venue=="kraken" then .symbol==($candidate.binding.altname//$candidate.nativeSymbol)
        else .symbol==$candidate.nativeSymbol end)
    ' "$scratch/native-match.json" | jq -c . >>"$scratch/platform-matches.jsonl"
  done < <(jq -c --arg ticker "$target" --arg quote "$quote" --arg product "$product" '
    .[] | select($product=="all" or .product==(if $product=="perpetual" then "perp" else $product end)) |
    select($quote=="" or (.quote|ascii_upcase)==$quote) |
    select(any(([.base]+.aliases+
      (if .baseRepresentation.verification=="verified" then (.baseRepresentation.asset.aliases//[]) else [] end))[];
      ascii_upcase==$ticker))
  ' "$scratch/platform/facts.json")
  jq -s '{markets:unique_by(.product,.symbol,.assetId,.marketId),errors:[]}' "$scratch/platform-matches.jsonl"
)
platform_authorize_issuer() (
  local issuer=$1 deployments=$2 errors=$3 facts=$4 underlying=$5
  if ! platform_catalog_read issuers "$issuer" "$facts" "$underlying";then
    jq --arg issuer "$issuer" '.+[{issuer:$issuer,message:"Platform issuer catalog unavailable; coverage unresolved"}]' "$errors" >"$errors.tmp";mv "$errors.tmp" "$errors"
    jq --arg issuer "$issuer" 'map(select(.issuer!=$issuer))' "$deployments" >"$deployments.tmp";mv "$deployments.tmp" "$deployments"
    return
  fi
  jq --arg issuer "$issuer" --slurpfile facts "$facts" '
    def chain:if .=="bnb" then "eip155:56" elif .=="robinhood" then "eip155:4663" elif .=="solana" then "solana:mainnet" else . end;
    map(. as $deployment | select(.issuer!=$issuer or any($facts[0][];
      .verification=="verified" and .listed==true and .issuer==$deployment.issuer and
      .chain==($deployment.chain|chain) and
      (if .chain|startswith("eip155:") then (.contract|ascii_downcase)==($deployment.contract|ascii_downcase) else .contract==$deployment.contract end))))
  ' "$deployments" >"$deployments.tmp";mv "$deployments.tmp" "$deployments"
)
