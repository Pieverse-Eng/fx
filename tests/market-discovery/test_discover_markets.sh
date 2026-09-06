#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/skills/market-discovery/scripts/discover-markets.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/cli" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}:$*" in
 curl:*fapi.asterdex.com*) venue=aster; key=aster;;
 binance-cli:spot*) venue=binance; key=binance-spot;;
 binance-cli:futures-usds*) venue=binance; key=binance-futures;;
 binance-cli:request*) venue=binance; key=binance-assets;;
 bgc:*SPOT*) venue=bitget; key=bitget-spot;;
 bgc:*USDT-FUTURES*) venue=bitget; key=bitget-usdt;;
 bgc:*USDC-FUTURES*) venue=bitget; key=bitget-usdc;;
 gate-cli:*'market pairs'*) venue=gate; key=gate-spot;;
 gate-cli:*'market contracts --settle usdt'*) venue=gate; key=gate-perp;;
 gate-cli:*'currency --currency CRCLG'*) venue=gate; key=gate-stock;;
 kraken:*tokenized_asset*) venue=kraken; key=kraken-stocks;;
 kraken:pairs*) venue=kraken; key=kraken-spot;;
 kraken:*instruments*) venue=kraken; key=kraken-perp;;
 kraken:*tickers*) venue=kraken; key=kraken-tickers;;
 okx:*'market instruments --instType SPOT'*) venue=okx-cex; key=okx-spot;;
 okx:*'market instruments --instType SWAP'*) venue=okx-cex; key=okx-swap;;
 purr:'hyperliquid markets --kind spot') venue=hyperliquid; key=hl-spot;;
 curl:*perpDexs*) venue=hyperliquid; key=hl-dexes;;
 curl:*allPerpMetas*) venue=hyperliquid; key=hl-metas;;
 purr:'lighter markets --market-type all') venue=lighter; key=lighter;;
 *) echo "Unexpected public query: $*" >&2; exit 2;;
esac
printf '%s\n' "$key" >>"$FIXTURE_DIR/calls"
if [[ ${WAIT_FOR_ALL:-0} == 1 ]]; then
  touch "$FIXTURE_DIR/started-$venue"
  # All eight workers must have entered their first public query before any returns.
  # A sequential implementation fails deterministically rather than by a timing assertion.
  for ((attempt=0; attempt<300; attempt++)); do
    files=("$FIXTURE_DIR"/started-*)
    (( ${#files[@]} == 8 )) && break
    sleep 0.01
  done
  (( ${#files[@]} == 8 )) || exit 1
fi
[[ ! -f $FIXTURE_DIR/$key.fail ]] || exit 1
cat "$FIXTURE_DIR/$key.json"
MOCK
chmod +x "$fixture_dir/cli"
for cli in curl binance-cli bgc gate-cli kraken purr okx; do ln -s cli "$fixture_dir/$cli"; done
export PATH="$fixture_dir:$PATH"
jq -n '{data:((["BTC","PEPE","1INCH"]|map({symbol:(.+"USDT"),baseCoin:.,quoteCoin:"USDT",category:"SPOT",status:"online"}))+[
 {symbol:"BTCUSDC",baseCoin:"BTC",quoteCoin:"USDC",category:"SPOT",status:"online"},
 {symbol:"RCRCLUSDT",baseCoin:"rCRCL",quoteCoin:"USDT",category:"SPOT",status:"online",symbolType:"stock"},
 {symbol:"RPEPEUSDT",baseCoin:"rPEPE",quoteCoin:"USDT",category:"SPOT",status:"online",symbolType:"crypto"},
 {symbol:"OLDUSDT",baseCoin:"OLD",quoteCoin:"USDT",category:"SPOT",status:"offline"}])}' >"$fixture_dir/bitget-spot.json"
jq -n '{data:((["BTC","CRCL","1000PEPE","1INCH"]|map({symbol:(.+"USDT"),baseCoin:.,quoteCoin:"USDT",category:"USDT-FUTURES",status:"online",type:"perpetual"}))+[
 {symbol:"BTCUSDT_261225",baseCoin:"BTC",quoteCoin:"USDT",category:"USDT-FUTURES",status:"online",type:"delivery"},
 {symbol:"CLOSEUSDT",baseCoin:"CLOSE",quoteCoin:"USDT",category:"USDT-FUTURES",status:"limit_open",type:"perpetual"}])}' >"$fixture_dir/bitget-usdt.json"
echo '{"data":[{"symbol":"BTCPERP","baseCoin":"BTC","quoteCoin":"USDC","category":"USDC-FUTURES","status":"online","type":"perpetual"}]}' >"$fixture_dir/bitget-usdc.json"
jq -n '[{id:"BTC_USDT",base:"BTC",quote:"USDT",trade_status:"tradable"},
 {id:"BTC_USDC",base:"BTC",quote:"USDC",trade_status:"tradable"},
 {id:"CRCLG_USDT",base:"CRCLG",base_name:"Circle",quote:"USDT",trade_status:"tradable"},
 {id:"CRCLX_USDT",base:"CRCLX",base_name:"Circle xStock",quote:"USDT",trade_status:"tradable"},
 {id:"CRCLON_USDT",base:"CRCLON",base_name:"Circle Ondo Tokenized",quote:"USDT",trade_status:"tradable"},
 {id:"CRCL3L_USDT",base:"CRCL3L",base_name:"CRCL3xLong",quote:"USDT",trade_status:"tradable"},
 {id:"PEPEX_USDT",base:"PEPEX",base_name:"Unrelated coin",quote:"USDT",trade_status:"tradable"},
 {id:"BUY_USDT",base:"BUY",quote:"USDT",trade_status:"buyable"},
 {id:"SELL_USDT",base:"SELL",quote:"USDT",trade_status:"sellable"},
 {id:"OLD_USDT",base:"OLD",quote:"USDT",trade_status:"untradable"}]' >"$fixture_dir/gate-spot.json"
jq -n '[{name:"BTC_USDT",type:"direct",status:"trading",quanto_multiplier:"0.0001"},
 {name:"CRCL_USDT",type:"direct",status:"trading",contract_type:"stocks"},
 {name:"CRCLX_USDT",type:"direct",status:"trading",contract_type:"stocks"},
 {name:"PEPEX_USDT",type:"direct",status:"trading",contract_type:"crypto"},
 {name:"OLD_USDT",type:"direct",status:"trading",in_delisting:true}]' >"$fixture_dir/gate-perp.json"
echo '{"currency":"CRCLG","category":["stocks","gstocks"]}' >"$fixture_dir/gate-stock.json"
jq -n '{XXBTZUSD:{altname:"XBTUSD",wsname:"XBT/USD",base:"XXBT",aclass_base:"currency",status:"online"},
 XBTUSDT:{altname:"XBTUSDT",wsname:"XBT/USDT",base:"XXBT",aclass_base:"currency",status:"online"},
 XDGUSD:{altname:"XDGUSD",wsname:"XDG/USD",base:"XXDG",aclass_base:"currency",status:"limit_only"},
 ONE:{altname:"1INCHUSD",wsname:"1INCH/USD",base:"1INCH",aclass_base:"currency",status:"online"},
 OLD:{altname:"OLDUSD",wsname:"OLD/USD",base:"OLD",aclass_base:"currency",status:"cancel_only"}}' >"$fixture_dir/kraken-spot.json"
jq -n '{CRCLSPVUSD:{altname:"CRCLxUSD",wsname:"CRCLx/USD",base:"CRCLx",aclass_base:"tokenized_asset",status:"post_only"},
 CRCLxUSD:{altname:"CRCLxUSD",wsname:"CRCLx/USD",base:"CRCLx",aclass_base:"tokenized_asset",status:"post_only"}}' >"$fixture_dir/kraken-stocks.json"
jq -n '{result:"success",instruments:[
 {symbol:"PF_XBTUSD",base:"BTC",quote:"USD",tradeable:true,isExpired:false,postOnly:false,type:"flexible_futures"},
 {symbol:"PI_XBTUSD",base:"XBT",quote:"USD",tradeable:true,isExpired:false,postOnly:true,type:"futures_inverse"},
 {symbol:"FF_XBTUSD_261225",base:"BTC",quote:"USD",tradeable:true,isExpired:false},
 {symbol:"PF_OLDUSD",base:"OLD",quote:"USD",tradeable:true,isExpired:true},
 {symbol:"PF_STOPUSD",base:"STOP",quote:"USD",tradeable:true,isExpired:false}]}' >"$fixture_dir/kraken-perp.json"
jq -n '{result:"success",tickers:[{symbol:"pf_xbtusd",tag:"perpetual",suspended:false},
 {symbol:"pi_xbtusd",tag:"perpetual",suspended:false},
 {symbol:"pf_oldusd",tag:"perpetual",suspended:false},
 {symbol:"pf_stopusd",tag:"perpetual",suspended:true}]}' >"$fixture_dir/kraken-tickers.json"
jq -n '{symbols:[
  {symbol:"BTCUSDT",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",isSpotTradingAllowed:true},
  {symbol:"BTCUSDC",baseAsset:"BTC",quoteAsset:"USDC",status:"TRADING",isSpotTradingAllowed:true},
  {symbol:"BTCJPY",baseAsset:"BTC",quoteAsset:"JPY",status:"HALT",isSpotTradingAllowed:true},
  {symbol:"CRCLBUSDT",baseAsset:"CRCLB",quoteAsset:"USDT",status:"TRADING",isSpotTradingAllowed:true}
]}' >"$fixture_dir/binance-spot.json"
jq -n '{symbols:[
  {symbol:"BTCUSDT",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",contractType:"PERPETUAL"},
  {symbol:"BTCUSDC",baseAsset:"BTC",quoteAsset:"USDC",status:"TRADING",contractType:"PERPETUAL"},
  {symbol:"BTCUSDT_261225",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",contractType:"CURRENT_QUARTER"},
  {symbol:"CRCLUSDT",baseAsset:"CRCL",quoteAsset:"USDT",status:"TRADING",contractType:"TRADIFI_PERPETUAL"}
]}' >"$fixture_dir/binance-futures.json"
jq -n '{success:true,data:[{assetCode:"CRCLB",uq:"CRCL",tags:["bStocks"],trading:true,delisted:false,test:0}]}' >"$fixture_dir/binance-assets.json"
jq -n '[
 {instId:"BTC-USDT",baseCcy:"BTC",quoteCcy:"USDT",instType:"SPOT",state:"live"},
 {instId:"BTC-USDC",baseCcy:"BTC",quoteCcy:"USDC",instType:"SPOT",state:"live"},
 {instId:"BTC-EUR",baseCcy:"BTC",quoteCcy:"EUR",instType:"SPOT",state:"suspend"},
 {instId:"XBTC-USDT",baseCcy:"XBTC",quoteCcy:"USDT",instType:"SPOT",instCategory:"1",state:"live"},
 {instId:"XCRCL-USDT",baseCcy:"XCRCL",quoteCcy:"USDT",instType:"SPOT",instCategory:"3",state:"live"},
 {instId:"BTC-USDT-SWAP",baseCcy:"",quoteCcy:"",settleCcy:"USDT",ctValCcy:"BTC",ctType:"linear",instType:"SWAP",state:"live"},
 {instId:"CRCL-USDT-SWAP",baseCcy:"",quoteCcy:"",settleCcy:"USDT",ctValCcy:"CRCL",ctType:"linear",instType:"SWAP",state:"live"}
]' >"$fixture_dir/instruments.json"
jq '[.[]|select(.instType=="SPOT")]' "$fixture_dir/instruments.json" >"$fixture_dir/okx-spot.json"
jq '[.[]|select(.instType=="SWAP")]' "$fixture_dir/instruments.json" >"$fixture_dir/okx-swap.json"
jq -n '{code:200,order_books:[
 {symbol:"ETH",market_id:0,market_type:"perp",status:"active",quote_asset_id:0,supported_size_decimals:4,supported_price_decimals:2,min_base_amount:"0.0050",min_quote_amount:"10.000000"},
 {symbol:"ETH/USDC",market_id:2048,market_type:"spot",status:"active"},
 {symbol:"ETH/USDT",market_id:9999,market_type:"spot",status:"active"},
 {symbol:"ETH/USDC",market_id:9998,market_type:"spot",status:"inactive"},
 {symbol:"1000PEPE",market_id:4,market_type:"perp",status:"active",multiplier:"1.000000000000000000"},
 {symbol:"1000PEPPER",market_id:99,market_type:"perp",status:"active"},
 {symbol:"1000SHIB",market_id:5,market_type:"perp",status:"active"},
 {symbol:"1INCH",market_id:6,market_type:"perp",status:"active"},
 {symbol:"OLD",market_id:7,market_type:"perp",status:"inactive"}
]}' >"$fixture_dir/lighter.json"
jq -n '[{tokens:[
 {index:0,name:"USDC",szDecimals:8},{index:1,name:"USDH",szDecimals:8},
 {index:2,name:"UBTC",fullName:"Unit Bitcoin",szDecimals:5},
 {index:3,name:"CRCLX",fullName:"Wrapped Circle xStock",szDecimals:2},
 {index:4,name:"BTCD",fullName:"BTC dominance",szDecimals:2}
 ],universe:[{index:142,name:"@142",tokens:[2,0]}, {index:234,name:"@234",tokens:[2,1]},
 {index:714,name:"@714",tokens:[3,0]}, {index:999,name:"@999",tokens:[4,0]}]},[]]' >"$fixture_dir/hl-spot.json"
jq -n '[{kind:"perp",symbol:"BTC",dex:"default",assetId:0},
 {kind:"perp",symbol:"xyz:BTC",dex:"xyz",assetId:110000},
 {kind:"perp",symbol:"xyz:CRCL",dex:"xyz",assetId:110001},
 {kind:"perp",symbol:"xyz:BTCD",dex:"xyz",assetId:110002},
 {kind:"perp",symbol:"kPEPE",dex:"default",assetId:1}]' >"$fixture_dir/search.json"
jq -n '[{collateralToken:0,universe:[{name:"BTC",szDecimals:5,maxLeverage:40},{name:"kPEPE",szDecimals:0}]},[]]' >"$fixture_dir/meta-default.json"
jq -n '[{collateralToken:0,universe:[{name:"xyz:BTC",szDecimals:5,isDelisted:true},{name:"xyz:CRCL",szDecimals:3,onlyIsolated:true,marginMode:"noCross"},{name:"xyz:BTCD",szDecimals:1}]},[]]' >"$fixture_dir/meta-xyz.json"
jq -n '[null,{name:"xyz"},{name:"late"}]' >"$fixture_dir/hl-dexes.json"
jq -s '[.[0][0],.[1][0],{collateralToken:1,universe:[{name:"late:BTC",szDecimals:5}]}]' "$fixture_dir/meta-default.json" "$fixture_dir/meta-xyz.json" >"$fixture_dir/hl-metas.json"

jq -n '{symbols:[
 {symbol:"BTCUSDT",baseAsset:"BTC",quoteAsset:"USDT",marginAsset:"USDT",status:"TRADING",contractType:"PERPETUAL"},
 {symbol:"CRCLUSDT",baseAsset:"CRCL",quoteAsset:"USDT",marginAsset:"USDT",status:"TRADING",contractType:"PERPETUAL",underlyingSubType:["STOCK"]},
 {symbol:"OLDUSDT",baseAsset:"OLD",quoteAsset:"USDT",marginAsset:"USDT",status:"PENDING_TRADING",contractType:""},
 {symbol:"BTCUSDC",baseAsset:"BTC",quoteAsset:"USDC",marginAsset:"USDC",status:"TRADING",contractType:"PERPETUAL"}
]}' >"$fixture_dir/aster.json"
run() { bash "$script" "$@"; }
WAIT_FOR_ALL=1 run BTC CRCL PEPE ETH >"$fixture_dir/result.json"
jq -e '(keys==["errors","results"]) and .errors==[] and (.results|map(.ticker))==["BTC","CRCL","PEPE","ETH"]' "$fixture_dir/result.json" >/dev/null
# Every required catalog was fetched once despite four tickers.
jq -Rsc 'split("\n")[:-1] | length==19 and (group_by(.)|all(.[];length==1))' "$fixture_dir/calls" | jq -e . >/dev/null
jq -e '[.results[]|select(.ticker=="CRCL")|.markets[]] as $m |
 any($m[];.venue=="aster" and .symbol=="CRCLUSDT") and
 any($m[];.venue=="binance" and .symbol=="CRCLBUSDT" and .product=="spot") and
 any($m[];.venue=="bitget" and .symbol=="RCRCLUSDT" and .category=="SPOT") and
 ([$m[]|select(.venue=="gate")]|length)==5 and
 any($m[];.venue=="kraken" and .symbol=="CRCLxUSD" and .assetClass=="tokenized_asset" and .restrictions==["Resting limit orders only"]) and
 any($m[];.venue=="okx-cex" and .symbol=="XCRCL-USDT") and
 any($m[];.venue=="hyperliquid" and .symbol=="xyz:CRCL" and .assetId==110001 and .dex=="xyz" and .restrictions==["isolated_only"])' "$fixture_dir/result.json" >/dev/null
# Keep the order selectors needed by each CLI; do not leak sizing metadata.
jq -e '
 all(.results[].markets[]; (.product=="spot" or .product=="perp") and
   ((keys-["venue","symbol","product","category","settlementAsset","assetId","dex","assetClass","marketId","restrictions"]|length)==0)) and
 any(.results[].markets[];.venue=="gate" and .product=="perp" and .settlementAsset=="USDT") and
 all(.results[].markets[]|select(.venue=="lighter");(.marketId|type)=="number") and
 any(.results[].markets[];.venue=="hyperliquid" and .product=="spot" and .assetId==10142) and
 keys==["errors","results"]
' "$fixture_dir/result.json" >/dev/null
jq -e 'any(.results[]|select(.ticker=="PEPE")|.markets[];.venue=="lighter" and .symbol=="1000PEPE") and any(.results[]|select(.ticker=="PEPE")|.markets[];.venue=="hyperliquid" and .symbol=="kPEPE")' "$fixture_dir/result.json" >/dev/null
# Dedup inputs, validate filters, and keep currency overrides literal.
: >"$fixture_dir/calls"
run btc BTC CRCL --venues bitget,bitget >"$fixture_dir/result.json"
jq -e 'all(.results[].markets[];.venue=="bitget") and (.results|map(.ticker))==["BTC","CRCL"]' "$fixture_dir/result.json" >/dev/null
[[ $(wc -l <"$fixture_dir/calls") == 2 ]]
run BTC --venues bitget --quote USDC | jq -e '(.results[0].markets|length)==2 and any(.results[0].markets[];.symbol=="BTCPERP")' >/dev/null
run BTC --venues kraken --quote USDT | jq -e '(.results[0].markets|length)==1 and .results[0].markets[0].symbol=="XBTUSDT"' >/dev/null
run BTC --venues hyperliquid --quote ALL | jq -e '(.results[0].markets|length)==4 and any(.results[0].markets[];.symbol=="late:BTC" and .assetId==120000)' >/dev/null
run BTC --venues okx --quote ALL | jq -e '(.results[0].markets|length)==3' >/dev/null
run ETH --venues lighter --quote USDT | jq -e '(.results[0].markets|length)==1 and .results[0].markets[0].symbol=="ETH/USDT"' >/dev/null
run BTC --product spot | jq -e '.errors==[] and all(.results[0].markets[];.product=="spot")' >/dev/null
run BTC --product perpetual | jq -e '.errors==[] and all(.results[0].markets[];.product=="perp")' >/dev/null
run CLOSE BUY SELL DOGE STOP OLD INCH UNKNOWN --venues bitget,gate,kraken >"$fixture_dir/result.json"
jq -e 'any(.results[]|select(.ticker=="CLOSE")|.markets[];.restrictions==["Opening restricted"]) and
 any(.results[]|select(.ticker=="BUY")|.markets[];.restrictions==["Buy only"]) and
 any(.results[]|select(.ticker=="SELL")|.markets[];.restrictions==["Sell only"]) and
 any(.results[]|select(.ticker=="DOGE")|.markets[];.symbol=="XDGUSD") and
 all(.results[]|select(.ticker=="STOP" or .ticker=="OLD" or .ticker=="INCH" or .ticker=="UNKNOWN");.markets==[])' "$fixture_dir/result.json" >/dev/null
run 1INCH --venues bitget,kraken,lighter | jq -e '(.results[0].markets|length)==4' >/dev/null
# Partial failures remain venue-specific, without suppressing healthy venues/products.
touch "$fixture_dir/binance-assets.fail"
if run CRCL >"$fixture_dir/error.json"; then echo 'Expected partial error'; exit 1; fi
jq -e 'any(.errors[];.venue=="binance" and .query=="assets") and any(.results[0].markets[];.venue=="binance" and .product=="perp") and any(.results[0].markets[];.venue=="kraken")' "$fixture_dir/error.json" >/dev/null
rm "$fixture_dir/binance-assets.fail"
if run BTC --venues gate,bitget --quote EUR >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)==2 and ([.errors[].venue]|sort)==["bitget","gate"]' "$fixture_dir/error.json" >/dev/null
cp "$fixture_dir/kraken-tickers.json" "$fixture_dir/kraken-tickers.backup"
echo '{"result":"success","tickers":[]}' >"$fixture_dir/kraken-tickers.json"
if run BTC --venues kraken >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)>0 and (.results[0].markets|length)==1' "$fixture_dir/error.json" >/dev/null
mv "$fixture_dir/kraken-tickers.backup" "$fixture_dir/kraken-tickers.json"
for key in aster binance-spot bitget-spot gate-spot kraken-spot okx-spot hl-metas lighter; do
  cp "$fixture_dir/$key.json" "$fixture_dir/backup.json"
  echo '{"error":"invalid"}' >"$fixture_dir/$key.json"
  if run BTC CRCL >"$fixture_dir/error.json"; then echo "Expected malformed $key error"; exit 1; fi
  jq -e '(.errors|length)>0 and (.results[0].markets|length)>0' "$fixture_dir/error.json" >/dev/null
  mv "$fixture_dir/backup.json" "$fixture_dir/$key.json"
done
for args in '--venues unknown' '--venues gate,' '--product invalid' '--quote' ''; do
  # Intentional word splitting exercises malformed argument lists.
  if run $args >/dev/null 2>&1; then echo 'Expected input rejection'; exit 1; fi
done
echo 'Unified discovery fixtures passed: all eight workers overlap, one fetch per catalog, multi-ticker results, filters, restrictions, and partial failures.'
