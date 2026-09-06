#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/purr" <<'EOF'
#!/usr/bin/env bash
set -eu
shift
action=$1; shift
query=''; kind=''; dex=default
while (( $# )); do
 case "$1" in --query) query=$2;; --kind) kind=$2;; --dex) dex=$2;; *) exit 2;; esac
 shift 2
done
if [[ $action == search ]]; then
 if [[ ${CAPPED:-0} == 1 ]]; then
   jq -n '{matches:[range(10)|{kind:"perp",symbol:"BTC",dex:"default",assetId:0}]}'
 else
   jq --arg query "$query" '{matches:[.[]|select(.symbol|ascii_upcase|contains($query))]}' "$FIXTURE_DIR/search.json"
 fi
elif [[ $kind == spot ]]; then
 cat "$FIXTURE_DIR/spot.json"
elif [[ ${FAIL_META:-0} == 1 ]]; then
 exit 1
else
 cat "$FIXTURE_DIR/meta-$dex.json"
fi
EOF
cat >"$fixture_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ ${FAIL_FALLBACK:-0} == 1 ]]; then exit 1; fi
case "$*" in
 *perpDexs*) cat "$FIXTURE_DIR/dexes.json";;
 *allPerpMetas*) cat "$FIXTURE_DIR/all-metas.json";;
 *) exit 2;;
esac
EOF
chmod +x "$fixture_dir/purr" "$fixture_dir/curl"
export PATH="$fixture_dir:$PATH"
jq -n '[{tokens:[
 {index:0,name:"USDC",szDecimals:8},{index:1,name:"USDH",szDecimals:8},
 {index:2,name:"UBTC",fullName:"Unit Bitcoin",szDecimals:5},
 {index:3,name:"CRCLX",fullName:"Wrapped Circle xStock",szDecimals:2},
 {index:4,name:"BTCD",fullName:"BTC dominance",szDecimals:2}
 ],universe:[{index:142,name:"@142",tokens:[2,0]}, {index:234,name:"@234",tokens:[2,1]},
 {index:714,name:"@714",tokens:[3,0]}, {index:999,name:"@999",tokens:[4,0]}]},[]]' >"$fixture_dir/spot.json"
jq -n '[{kind:"perp",symbol:"BTC",dex:"default",assetId:0},
 {kind:"perp",symbol:"xyz:BTC",dex:"xyz",assetId:110000},
 {kind:"perp",symbol:"xyz:CRCL",dex:"xyz",assetId:110001},
 {kind:"perp",symbol:"xyz:BTCD",dex:"xyz",assetId:110002},
 {kind:"perp",symbol:"kPEPE",dex:"default",assetId:1}]' >"$fixture_dir/search.json"
jq -n '[{collateralToken:0,universe:[{name:"BTC",szDecimals:5,maxLeverage:40},{name:"kPEPE",szDecimals:0}]},[]]' >"$fixture_dir/meta-default.json"
jq -n '[{collateralToken:0,universe:[{name:"xyz:BTC",szDecimals:5,isDelisted:true},{name:"xyz:CRCL",szDecimals:3,onlyIsolated:true,marginMode:"noCross"},{name:"xyz:BTCD",szDecimals:1}]},[]]' >"$fixture_dir/meta-xyz.json"
jq -n '[null,{name:"xyz"},{name:"late"}]' >"$fixture_dir/dexes.json"
jq -s '[.[0][0],.[1][0],{collateralToken:1,universe:[{name:"late:BTC",szDecimals:5}]}]' "$fixture_dir/meta-default.json" "$fixture_dir/meta-xyz.json" >"$fixture_dir/all-metas.json"
bash "$script_dir/hyperliquid-markets.sh" btc | jq -e '.currencyFilter=="USDC" and (.markets|length)==2 and any(.markets[];.symbol=="BTC" and .collateralAsset=="USDC" and .quoteAsset==null) and any(.markets[];.symbol=="UBTC/USDC" and .pairId=="@142")' >/dev/null
bash "$script_dir/hyperliquid-markets.sh" BTC --quote USDH --product spot | jq -e '(.markets|length)==1 and .markets[0].pairId=="@234"' >/dev/null
bash "$script_dir/hyperliquid-markets.sh" BTC --quote ALL | jq -e '(.markets|length)==3' >/dev/null
bash "$script_dir/hyperliquid-markets.sh" CRCL | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="xyz:CRCL" and .onlyIsolated==true) and any(.markets[];.symbol=="CRCLX/USDC")' >/dev/null
bash "$script_dir/hyperliquid-markets.sh" PEPE --product perpetual | jq -e '(.markets|length)==1 and .markets[0].symbol=="kPEPE"' >/dev/null
bash "$script_dir/hyperliquid-markets.sh" UNKNOWN | jq -e '.markets==[] and .errors==[]' >/dev/null
CAPPED=1 bash "$script_dir/hyperliquid-markets.sh" BTC --quote ALL | jq -e '(.markets|length)==4 and any(.markets[];.symbol=="late:BTC" and .assetId==120000 and .collateralAsset=="USDH") and .errors==[]' >/dev/null
if FAIL_META=1 bash "$script_dir/hyperliquid-markets.sh" BTC >"$fixture_dir/partial.json"; then exit 1; fi
jq -e '(.errors|length)>0 and (.markets|length)==1 and .markets[0].product=="spot"' "$fixture_dir/partial.json" >/dev/null
if CAPPED=1 FAIL_FALLBACK=1 bash "$script_dir/hyperliquid-markets.sh" BTC >"$fixture_dir/fallback-error.json"; then exit 1; fi
jq -e '(.errors|length)>0 and (.markets|length)==1' "$fixture_dir/fallback-error.json" >/dev/null
jq '.[0].collateralToken=99999' "$fixture_dir/meta-default.json" >"$fixture_dir/next.json"
mv "$fixture_dir/next.json" "$fixture_dir/meta-default.json"
if bash "$script_dir/hyperliquid-markets.sh" BTC >"$fixture_dir/collateral-error.json"; then exit 1; fi
jq -e '(.errors|length)>0 and all(.markets[];.product=="spot")' "$fixture_dir/collateral-error.json" >/dev/null
jq '.[0].universe += [{index:888,name:"@888",tokens:[2,0]}]' "$fixture_dir/spot.json" >"$fixture_dir/next.json"
mv "$fixture_dir/next.json" "$fixture_dir/spot.json"
bash "$script_dir/hyperliquid-markets.sh" BTC --product spot | jq -e '(.markets|length)==2 and ([.markets[].pairId]|sort)==["@142","@888"]' >/dev/null
echo 'Hyperliquid fixtures passed: currency roles, products, Unit/xStock/k aliases, inactive and substring exclusions, capped-search recovery, query failures, missing collateral, distinct pair IDs.'
