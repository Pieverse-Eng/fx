#!/usr/bin/env bash
# Public discovery. Requires Bash 4+, okx, jq, and GNU timeout.
set -euo pipefail
usage() { echo 'Usage: okx-markets.sh TICKER [--quote QUOTE|ALL (default USDT)] [--product spot|perpetual|all]' >&2; exit 2; }
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
[[ $product == spot || $product == perpetual || $product == all ]] || usage
[[ $quote != ALL ]] || quote=''
for dependency in okx jq timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
fetch() {
  local name=$1 validation=$2; shift 2
  if ! timeout --kill-after=2s 25s okx "$@" --site global --json >"$scratch/$name.json" 2>"$scratch/$name.stderr"; then
    echo 'Public query failed or timed out' >"$scratch/$name.error"
  elif ! jq -e "$validation" "$scratch/$name.json" >/dev/null 2>&1; then
    echo 'Invalid, incomplete, or unexpected response; coverage unresolved' >"$scratch/$name.error"
  fi
  [[ ! -f $scratch/$name.error ]] || echo '[]' >"$scratch/$name.json"
}
wait_queries() { for pid in "${pids[@]}"; do wait "$pid"; done; pids=(); }
filter_check='type == "array" and length == 1 and (.[0].rows | type == "array") and (.[0].total | type == "number") and .[0].total == (.[0].rows | length) and all(.[0].rows[]; (.instId | type == "string") and (.instType | type == "string") and (.baseCcy | type == "string") and (.quoteCcy | type == "string"))'
instrument_check='type == "array" and all(.[]; (.instId | type == "string") and (.instType | type == "string") and (.state | type == "string") and (.baseCcy | type == "string") and (.quoteCcy | type == "string"))'
quote_args=()
[[ -z $quote ]] || quote_args=(--quoteCcy "$quote")
for name in spot swap stocks; do echo '[]' >"$scratch/$name.json"; done
if [[ $product != perpetual ]]; then
  fetch spot "$filter_check" market filter --instType SPOT --baseCcy "$ticker" "${quote_args[@]}" --limit 100 &
  pids+=("$!")
  fetch stocks "$instrument_check" market instruments-by-category --instCategory 3 --instType SPOT &
  pids+=("$!")
fi
if [[ $product != spot ]]; then
  fetch swap "$filter_check" market filter --instType SWAP --baseCcy "$ticker" "${quote_args[@]}" --ctType linear --limit 100 &
  pids+=("$!")
fi
wait_queries
# Only category-3 Spot metadata can establish the prefixed stock-token candidate.
jq --arg ticker "$ticker" --arg quote "$quote" '[.[] | select(.instType=="SPOT" and .instCategory=="3" and (.baseCcy==$ticker or .baseCcy==("X"+$ticker)) and ($quote=="" or .quoteCcy==$quote))]' "$scratch/stocks.json" >"$scratch/stock-matches.json"
jq -n --arg ticker "$ticker" --arg quote "$quote" --slurpfile spot "$scratch/spot.json" --slurpfile swap "$scratch/swap.json" --slurpfile stocks "$scratch/stock-matches.json" '
  [$spot[0][] | .rows[] | select(.instType=="SPOT")] + [$swap[0][] | .rows[] | select(.instType=="SWAP")] |
  map(select(.baseCcy==$ticker and ($quote=="" or .quoteCcy==$quote))) |
  unique_by(.instType,.instId) | .[] | . as $row |
  select(any($stocks[0][]; .instId==$row.instId and .instType==$row.instType) | not) |
  [.instType,.instId] | @tsv' -r >"$scratch/candidates.tsv"
index=0
while IFS=$'\t' read -r inst_type inst_id; do
  [[ $inst_id =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid instrument identifier' >"$scratch/candidate.error"; continue; }
  # Filter rows have no state or contract specs. Verify exact metadata in parallel.
  validation="$instrument_check and length == 1 and .[0].instId == \"$inst_id\" and .[0].instType == \"$inst_type\""
  fetch "detail-$index" "$validation" market instruments --instType "$inst_type" --instId "$inst_id" &
  pids+=("$!")
  index=$((index+1))
  # Bound follow-up concurrency for --quote ALL.
  if (( ${#pids[@]} >= 8 )); then wait_queries; fi
done <"$scratch/candidates.tsv"
wait_queries
shopt -s nullglob
details=("$scratch"/detail-*.json)
jq -s 'add // []' "$scratch/stock-matches.json" "${details[@]}" >"$scratch/instruments.json"
errors='[]'
for file in "$scratch"/*.error; do
  name=${file##*/}; name=${name%.error}
  errors=$(jq -cn --argjson errors "$errors" --arg query "$name" --arg message "$(cat "$file")" '$errors + [{query:$query,message:$message}]')
done
jq --arg ticker "$ticker" --arg quote "$quote" --arg product "$product" --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson errors "$errors" '
  {venue:"okx-cex",ticker:$ticker,quoteAsset:(if $quote=="" then null else $quote end),product:$product,queriedAt:$queriedAt,
   sources:["https://www.okx.com/api/v5/aigc/mcp/market-filter","https://www.okx.com/api/v5/public/instruments"],
   markets:[.[] | select(.state=="live") |
     if .instType=="SPOT" and (.baseCcy==$ticker or (.instCategory=="3" and .baseCcy==("X"+$ticker))) then
       {symbol:.instId,baseAsset:.baseCcy,quoteAsset:.quoteCcy,status:.state,product:"spot",representation:(if .instCategory=="3" then "tokenized_stock" else "spot_asset" end),lotSz,minSz,tickSz}
     elif .instType=="SWAP" and .ctType=="linear" and .ctValCcy==$ticker then
       {symbol:.instId,baseAsset:.ctValCcy,quoteAsset:.settleCcy,status:.state,product:"perpetual",representation:"derivative",ctType,ctVal,ctValCcy,lotSz,minSz,tickSz}
     else empty end | select($quote=="" or .quoteAsset==$quote)] | unique_by(.product,.symbol),errors:$errors}' "$scratch/instruments.json"
[[ $errors == '[]' ]]
