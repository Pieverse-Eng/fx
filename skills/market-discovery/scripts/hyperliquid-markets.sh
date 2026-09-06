#!/usr/bin/env bash
# Public discovery. Requires Bash 4+, purr, jq, curl, and GNU timeout.
set -euo pipefail
usage() { echo 'Usage: hyperliquid-markets.sh TICKER [--quote CURRENCY|ALL (default USDC)] [--product spot|perpetual|all]' >&2; exit 2; }
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
for dependency in purr jq curl timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
fetch() {
  local name=$1 validation=$2; shift 2
  if ! timeout --kill-after=2s 25s "$@" >"$scratch/$name.json" 2>"$scratch/$name.stderr"; then
    echo 'Public query failed or timed out' >"$scratch/$name.error"
  elif ! jq -e "$validation" "$scratch/$name.json" >/dev/null 2>&1; then
    echo 'Invalid public metadata; coverage unresolved' >"$scratch/$name.error"
  fi
  [[ ! -f $scratch/$name.error ]] || echo null >"$scratch/$name.json"
}
wait_queries() { for pid in "${pids[@]}"; do wait "$pid"; done; pids=(); }
meta_check='(.universe | type=="array") and all(.universe[]; (.name|type=="string") and (.szDecimals|type=="number"))'
spot_check='type=="array" and (.[0].tokens|type=="array" and length>0) and (.[0].universe|type=="array") and all(.[0].tokens[]; (.index|type=="number") and (.name|type=="string") and (.szDecimals|type=="number")) and all(.[0].universe[]; (.name|type=="string") and (.index|type=="number") and (.tokens|type=="array" and length==2))'
echo '{"matches":[]}' >"$scratch/search.json"
# Spot token indices also resolve perpetual collateral currencies.
fetch spot "$spot_check" purr hyperliquid markets --kind spot &
pids+=("$!")
if [[ $product != spot ]]; then
  fetch search '(.matches|type=="array") and all(.matches[]; (.kind=="spot" or .kind=="perp") and (.symbol|type=="string"))' purr hyperliquid search --query "$ticker" &
  pids+=("$!")
fi
wait_queries
echo '[]' >"$scratch/perps.json"
if [[ $product != spot ]]; then
  if jq -e '.==null or (.matches|length)>=10' "$scratch/search.json" >/dev/null; then
    # search has a fixed ten-result cap. These two Info methods recover every DEX.
    fetch dexes 'type=="array" and length>0 and .[0]==null and all(.[1:][]; (.name|type=="string"))' curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"type":"perpDexs"}' https://api.hyperliquid.xyz/info &
    pids+=("$!")
    fetch all-metas "type==\"array\" and all(.[]; $meta_check)" curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"type":"allPerpMetas"}' https://api.hyperliquid.xyz/info &
    pids+=("$!")
    wait_queries
    if jq -ne --slurpfile dexes "$scratch/dexes.json" --slurpfile metas "$scratch/all-metas.json" '$dexes[0]!=null and $metas[0]!=null and ($dexes[0]|length)==($metas[0]|length)' >/dev/null; then
      jq -n --slurpfile dexes "$scratch/dexes.json" --slurpfile metas "$scratch/all-metas.json" '
        [$metas[0]|to_entries[] | .key as $dexIndex | .value as $meta |
         $meta.universe|to_entries[] | {asset:.value,collateralToken:$meta.collateralToken,
         dex:(if $dexIndex==0 then "default" else $dexes[0][$dexIndex].name end),
         assetId:(if $dexIndex==0 then .key else 100000+$dexIndex*10000+.key end)}]' >"$scratch/perps.json"
    else
      echo 'Full perp metadata and DEX indices could not be aligned' >"$scratch/coverage.error"
    fi
  else
    jq --arg ticker "$ticker" '[.matches[] | select(.kind=="perp") | (.symbol|split(":")|last|ascii_upcase) as $base | select($base==$ticker or $base==("K"+$ticker))] | unique_by(.symbol)' "$scratch/search.json" >"$scratch/candidates.json"
    jq -r '.[].dex' "$scratch/candidates.json" | sort -u >"$scratch/dexes.txt"
    while IFS= read -r dex; do
      [[ $dex =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid DEX in search result' >"$scratch/coverage.error"; continue; }
      dex_args=(); [[ $dex == default ]] || dex_args=(--dex "$dex")
      fetch "meta-$dex" "type==\"array\" and (.[0] | $meta_check)" purr hyperliquid markets --kind perp "${dex_args[@]}" &
      pids+=("$!")
    done <"$scratch/dexes.txt"
    wait_queries
    while IFS= read -r dex; do
      [[ -f $scratch/meta-$dex.json ]] || continue
      jq -n --arg dex "$dex" --slurpfile candidates "$scratch/candidates.json" --slurpfile meta "$scratch/meta-$dex.json" '
        [$candidates[0][] | select(.dex==$dex) | . as $candidate |
         (($meta[0][0].universe // []) | map(select(.name==$candidate.symbol))) as $assets |
         {asset:($assets[0] // null),symbol:$candidate.symbol,dex:$dex,assetId:$candidate.assetId,collateralToken:$meta[0][0].collateralToken}]' >"$scratch/rows-$dex.json"
    done <"$scratch/dexes.txt"
    shopt -s nullglob
    rows=("$scratch"/rows-*.json)
    if (( ${#rows[@]} )); then jq -s 'add' "${rows[@]}" >"$scratch/perps.json"; fi
  fi
fi
errors='[]'
shopt -s nullglob
for file in "$scratch"/*.error; do
  name=${file##*/}; name=${name%.error}
  errors=$(jq -cn --argjson errors "$errors" --arg query "$name" --arg message "$(cat "$file")" '$errors+[{query:$query,message:$message}]')
done
jq -n --arg ticker "$ticker" --arg currency "$currency" --arg product "$product" \
  --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson errors "$errors" \
  --slurpfile spot "$scratch/spot.json" --slurpfile perps "$scratch/perps.json" \
  -f "$script_dir/hyperliquid-normalize.jq" >"$scratch/result.json"
cat "$scratch/result.json"
jq -e '.errors|length==0' "$scratch/result.json" >/dev/null
