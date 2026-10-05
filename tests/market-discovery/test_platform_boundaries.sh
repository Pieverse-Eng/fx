#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/platform"
source "$root/src/tools/market/platform-catalog.sh"
fact() { jq -n --arg product "$1" --arg id "$2" '{id:$id,venue:"binance",environment:"mainnet",product:$product,nativeSymbol:"BTCUSDT",base:"BTC",quote:"USDT",status:"active",exposureMultiplier:1,aliases:["BTC"],binding:{nativeId:"BTCUSDT",instrumentId:("binance:"+$product+":BTCUSDT")},baseRepresentation:{id:"native-btc",verification:"verified",listed:true,unitsPerToken:1,chain:null,contract:null,issuer:null,evidence:{},symbol:"BTC",aliases:["BTC"],asset:{id:"crypto:BTC",category:"crypto",symbol:"BTC",aliases:["BTC"]}}}'; }
fact spot a | jq -s . >"$scratch/platform/facts.json"
ticker=BTC; quote=USDT; product=all; fn=binance; venue=binance
match_binance() { echo '{"markets":[{"symbol":"BTCUSDT","product":"spot"},{"symbol":"BTCUSDT","product":"perpetual"}],"errors":[]}'; }
platform_match >"$scratch/product.json"
jq -e '.markets|length==1 and .[0].product=="spot"' "$scratch/product.json" >/dev/null
# Restricted native listings remain discoverable; live restrictions govern opening routes.
jq 'map(.status="halted")' "$scratch/platform/facts.json" >"$scratch/restricted.json"; mv "$scratch/restricted.json" "$scratch/platform/facts.json"
match_binance() { echo '{"markets":[{"symbol":"BTCUSDT","product":"spot","restrictions":["Buy only"]}],"errors":[]}'; }
platform_match >"$scratch/restricted-match.json"
jq -e '.markets|length==1 and .[0].restrictions==["Buy only"]' "$scratch/restricted-match.json" >/dev/null
# Unverified listings are discoverable, but not route-comparison candidates.
jq '.[0].baseRepresentation.verification="unverified"' "$scratch/platform/facts.json" >"$scratch/u.json"; mv "$scratch/u.json" "$scratch/platform/facts.json"
FX_MARKET_MODE=routes
platform_match >"$scratch/unverified.json"
jq -e '.markets==[] and (.errors|length)>0' "$scratch/unverified.json" >/dev/null
unset FX_MARKET_MODE
fact perp a | jq -s 'map(.venue="hyperliquid" | .nativeSymbol="BTC" | .quote="USDC" | .binding.assetId=0)' >"$scratch/platform/facts.json"
venue=hyperliquid; fn=hyperliquid; product=perpetual; quote=USDC
match_hyperliquid() { echo '{"markets":[],"errors":[{"symbol":"BTC","message":"Exact instrument or collateral metadata is unavailable"}]}'; }
platform_match >"$scratch/collateral.json"
jq -e '.markets==[] and .errors[0].message=="Exact instrument or collateral metadata is unavailable"' "$scratch/collateral.json" >/dev/null
# A shared issuer failure must survive coverage rebuilding.
echo '[]' >"$scratch/deployments.json"; echo '[]' >"$scratch/errors.json"; : >"$scratch/coverage.jsonl"
platform_catalog_read() { return 1; }
platform_authorize_issuer xstocks "$scratch/deployments.json" "$scratch/errors.json" "$scratch/facts.json" BTC
jq -se '.[0].issuer=="xstocks"' "$scratch/coverage.jsonl" >/dev/null
echo 'Platform product, comparison identity and coverage boundaries passed.'
