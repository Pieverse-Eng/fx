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
       def text: type=="string" and length>0 and length<=256;
       def aliases: type=="array" and length<=64 and all(.[];text);
       def representation:
         (.id|text) and (.symbol|text) and (.aliases|aliases) and
         (.verification=="verified" or .verification=="unverified" or .verification=="conflict") and
         (.listed|type=="boolean") and (.unitsPerToken|type=="number" and .>0) and
         all(.chain,.contract,.issuer; .==null or text) and
         (.asset==null or ((.asset.id|text) and (.asset.symbol|text) and (.asset.aliases|aliases)));
       .schemaVersion==1 and (.revision|type=="string" and length>0) and
       (.total|type=="number" and .>=0 and .<=100000 and floor==.) and
       (.nextCursor==null or (.nextCursor|type=="string" and length>0 and length<=2048)) and
       (.items|type=="array" and length<=500) and all(.items[];
         (.id|type=="string" and length>0) and
         (if $kind=="venues" then .venue==$owner and .environment=="mainnet" and
           (.binding.instrumentId|text) and (.binding.nativeId|text) and
           all(.binding.assetId,.binding.marketId; .==null or (type=="number" and .>=0 and floor==.)) and
           (.binding.category==null or (.binding.category|text)) and
           (.base|text) and (.quote|text) and (.nativeSymbol|text) and
           (.product=="spot" or .product=="perp") and (.aliases|aliases) and
           (.baseRepresentation|representation) and (.exposureMultiplier|type=="number" and .>0) and
           (.status=="active" or .status=="listed" or .status=="halted" or .status=="delisted")
          else representation and .issuer==$owner and (.contract|text) and (.chain|text) end))
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
  local target=$ticker candidate native_ticker
  : >"$scratch/platform-matches.jsonl"
  : >"$scratch/platform-errors.jsonl"
  if ! jq -c --arg ticker "$target" --arg quote "$quote" --arg product "$product" '
    .[] | select($product=="all" or .product==(if $product=="perpetual" then "perp" else $product end)) |
    select(.status!="delisted") |
    select($quote=="" or (.quote|ascii_upcase)==$quote) |
    select(any(([.base]+.aliases+
      (if .baseRepresentation.verification=="verified" then (.baseRepresentation.asset.aliases//[]) else [] end))[];
      ascii_upcase==$ticker))
  ' "$scratch/platform/facts.json" >"$scratch/platform-candidates.jsonl"; then
    echo '{"markets":[],"errors":[{"message":"Platform identity data invalid; coverage unresolved"}]}'
    return
  fi
  while IFS= read -r candidate;do
    if [[ ${FX_MARKET_MODE:-discover} == routes ]] && ! jq -e '.baseRepresentation.verification=="verified" and .baseRepresentation.asset.id!=null' <<<"$candidate" >/dev/null;then
      jq -cn --argjson c "$candidate" '{symbol:$c.nativeSymbol,message:"Economic asset identity is unverified"}' >>"$scratch/platform-errors.jsonl"
      continue
    fi
    native_ticker=$(jq -r .base <<<"$candidate")
    [[ $venue != lighter ]] || native_ticker=$(jq -r '.nativeSymbol|split("/")[0]' <<<"$candidate")
    # Gate's formatter consumes the latest currency restriction evidence.
    [[ $fn != gate || -f $scratch/stock-$native_ticker.json ]] || echo '[]' >"$scratch/stock-$native_ticker.json"
    ticker=${native_ticker^^}
    if ! "match_$fn" >"$scratch/native-match.json";then
      jq -cn --argjson c "$candidate" '{symbol:$c.nativeSymbol,message:"Native observation failed; coverage unresolved"}' >>"$scratch/platform-errors.jsonl"
      ticker=$target; continue
    fi
    ticker=$target
    jq -c --arg venue "$venue" --arg mode "${FX_MARKET_MODE:-discover}" --argjson candidate "$candidate" '
      (if type=="array" then . else .markets end)[] |
      select((if .product=="perpetual" then "perp" else .product end)==$candidate.product) |
      select($venue!="bitget" or .category==$candidate.binding.category) |
      select(if $venue=="hyperliquid" then .assetId==$candidate.binding.assetId
        elif $venue=="lighter" then .marketId==$candidate.binding.marketId
        elif $venue=="kraken" then .symbol==($candidate.binding.altname//$candidate.nativeSymbol)
        else .symbol==$candidate.nativeSymbol end) |
      . + (if $mode=="routes" then {_catalog:{assetId:$candidate.baseRepresentation.asset.id,
        representationId:$candidate.baseRepresentation.id,unitsPerToken:$candidate.baseRepresentation.unitsPerToken,
        exposureMultiplier:$candidate.exposureMultiplier}} else {} end)
    ' "$scratch/native-match.json" >>"$scratch/platform-matches.jsonl" || return 1
    jq -c --argjson candidate "$candidate" '
      if type=="array" then empty else .errors[]? |
      select(.symbol==null or .symbol==$candidate.nativeSymbol or .symbol==("@"+$candidate.binding.nativeId)) end
    ' "$scratch/native-match.json" >>"$scratch/platform-errors.jsonl" || return 1
  done <"$scratch/platform-candidates.jsonl"
  jq -n --slurpfile m "$scratch/platform-matches.jsonl" --slurpfile e "$scratch/platform-errors.jsonl" '{markets:($m|unique_by(.product,.symbol,.assetId,.marketId)),errors:($e|unique)}'
)
platform_authorize_issuer() (
  local issuer=$1 deployments=$2 errors=$3 facts=$4 underlying=$5
  if ! platform_catalog_read issuers "$issuer" "$facts" "$underlying";then
    jq --arg issuer "$issuer" '.+[{issuer:$issuer,message:"Platform issuer catalog unavailable; coverage unresolved"}]' "$errors" >"$errors.tmp";mv "$errors.tmp" "$errors"
    jq -cn --arg issuer "$issuer" '{issuer:$issuer,message:"Platform issuer catalog unavailable; coverage unresolved"}' >>"$(dirname "$errors")/coverage.jsonl"
    jq --arg issuer "$issuer" 'map(select(.issuer!=$issuer))' "$deployments" >"$deployments.tmp";mv "$deployments.tmp" "$deployments"
    return
  fi
  jq --arg issuer "$issuer" --slurpfile facts "$facts" '
    def chain:if .=="bnb" then "eip155:56" elif .=="robinhood" then "eip155:4663" elif .=="solana" then "solana:mainnet" else . end;
    map(. as $deployment | if .issuer!=$issuer then . else
      [$facts[0][]|select(
      .verification=="verified" and .listed==true and .issuer==$deployment.issuer and
      .chain==($deployment.chain|chain) and
      (if .chain|startswith("eip155:") then (.contract|ascii_downcase)==($deployment.contract|ascii_downcase) else .contract==$deployment.contract end))] as $matched |
      select(($matched|length)==1 and $matched[0].asset.id!=null) |
      .+{_catalog:{assetId:$matched[0].asset.id,representationId:$matched[0].id,unitsPerToken:$matched[0].unitsPerToken}}
      end)
  ' "$deployments" >"$deployments.tmp";mv "$deployments.tmp" "$deployments"
)
