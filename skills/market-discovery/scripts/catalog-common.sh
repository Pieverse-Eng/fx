#!/usr/bin/env bash
# Shared shell plumbing for the Bitget, Gate, and Kraken catalog helpers.
# Caller sets venue, default_quote, and cli before sourcing with its arguments.
set -euo pipefail
usage() { echo "Usage: $venue-markets.sh TICKER [--quote CURRENCY|ALL (default $default_quote)] [--product spot|perpetual|all]" >&2; exit 2; }
[[ $# -gt 0 ]] || usage
ticker=${1^^}; shift
quote=$default_quote; product=all
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
for dependency in "$cli" jq timeout; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 2; }
done
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
fetch() {
  local name=$1 validation=$2 extraction=$3 source=$4; shift 4
  printf '%s\n' "$source" >"$scratch/$name.source"
  if ! timeout --kill-after=2s 25s "$@" >"$scratch/$name.raw" 2>"$scratch/$name.stderr"; then
    echo 'Public catalog query failed or timed out; coverage unresolved' >"$scratch/$name.error"
  elif ! jq -e "$validation" "$scratch/$name.raw" >/dev/null 2>&1; then
    echo 'API error or malformed public catalog; coverage unresolved' >"$scratch/$name.error"
  fi
  if [[ -f $scratch/$name.error ]]; then echo '[]' >"$scratch/$name.json"
  else jq "$extraction" "$scratch/$name.raw" >"$scratch/$name.json"; fi
}
wait_queries() { for pid in "${pids[@]}"; do wait "$pid"; done; pids=(); }
finish() {
  local errors='[]' sources='[]' file name
  shopt -s nullglob
  for file in "$scratch"/*.error; do
    name=${file##*/}; name=${name%.error}
    errors=$(jq -cn --argjson errors "$errors" --arg query "$name" --arg message "$(cat "$file")" '$errors+[{query:$query,message:$message}]')
  done
  for file in "$scratch"/*.source; do
    sources=$(jq -cn --argjson sources "$sources" --arg source "$(cat "$file")" '$sources+[$source]')
  done
  jq -n --arg venue "$venue" --arg ticker "$ticker" --arg quote "$quote" --arg product "$product" \
    --arg queriedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson sources "$sources" --argjson errors "$errors" \
    --slurpfile markets "$scratch/markets.json" \
    '{venue:$venue,ticker:$ticker,quoteAsset:(if $quote=="" then null else $quote end),product:$product,queriedAt:$queriedAt,sources:$sources,markets:$markets[0],errors:$errors}'
  [[ $errors == '[]' ]]
}
