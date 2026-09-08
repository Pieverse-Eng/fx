#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/src/tools/market/discover-markets.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/cli" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}:$*" in
 curl:*api/v3/ticker/bookTicker*) venue=binance; key=route-rates;;
 curl:*fapi.asterdex.com*/depth*) venue=aster; key=route-book;;
 binance-cli:*depth*|binance-cli:*order-book*) venue=binance; key=route-book;;
 bgc:*'--action orderbook'*) venue=bitget; key=route-bitget;;
 gate-cli:*'market orderbook'*) venue=gate; key=route-gate;;
 kraken:*orderbook*) venue=kraken; key=route-kraken;;
 okx:*'market orderbook'*) venue=okx-cex; key=route-okx;;
 purr:*'hyperliquid l2'*) venue=hyperliquid; key=route-hl;;
 purr:'lighter market --market '*) venue=lighter; key=route-lighter-meta;;
 purr:'lighter order-book-depth '*) venue=lighter; key=route-lighter-book;;
 purr:'hyperliquid candles '*15m*) venue=hyperliquid; key=hl-candles-15m;;
 purr:'hyperliquid candles '*1h*) venue=hyperliquid; key=hl-candles-1h;;
 purr:'hyperliquid candles '*4h*) venue=hyperliquid; key=hl-candles-4h;;
 curl:*recentTrades*api.hyperliquid.xyz/info*) venue=hyperliquid; key=hl-trades;;
 curl:*api/v1/candles*resolution=15m*) venue=lighter; key=lighter-candles-15m;;
 curl:*api/v1/candles*resolution=1h*) venue=lighter; key=lighter-candles-1h;;
 curl:*api/v1/candles*resolution=4h*) venue=lighter; key=lighter-candles-4h;;
 curl:*api/v1/recentTrades*) venue=lighter; key=lighter-trades;;
 curl:*api.xstocks.fi*) venue=issuer; key=route-no-asset;;
 curl:*api.robinhood.com*) venue=issuer; key=route-rh;;
 curl:*getNetworkCoinAll*) venue=issuer; key=route-networks;;
 curl:*binance.com*klines*interval=15m*) venue=binance; key=candles-15m;;
 curl:*binance.com*klines*interval=1h*) venue=binance; key=candles-1h;;
 curl:*binance.com*klines*interval=4h*) venue=binance; key=candles-4h;;
 curl:*binance.com*trades*) venue=binance; key=candle-trades;;
 curl:*fapi.asterdex.com*ticker/24hr*) venue=aster; key=stats-aster;;
 curl:*binance.com*api/v3/ticker/24hr*) venue=binance; key=stats-binance-spot;;
 curl:*binance.com*fapi/v1/ticker/24hr*) venue=binance; key=stats-binance-perp;;
 bgc:*'--action tickers'*) venue=bitget; key=stats-empty;;
 gate-cli:*'market tickers'*) venue=gate; key=stats-empty;;
 kraken:ticker*tokenized_asset*) venue=kraken; key=stats-empty;;
 kraken:ticker*) venue=kraken; key=stats-kraken;;
 okx:*'market tickers'*) venue=okx-cex; key=stats-empty;;
 purr:'hyperliquid markets --kind perp --dex xyz') venue=hyperliquid; key=stats-hl-xyz;;
 purr:'hyperliquid markets --kind perp'*) venue=hyperliquid; key=stats-empty;;
 curl:*orderBookDetails*) venue=lighter; key=stats-lighter;;
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
printf '%s:%s\n' "${0##*/}" "$*" >>"$FIXTURE_DIR/commands"
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
# Representative native catalog records, including inactive predecessors and ADRs.
jq '.[1].universe += [{name:"xyz:SKHX",szDecimals:3}, {name:"xyz:SMSN",szDecimals:3},
 {name:"xyz:SKHY",szDecimals:3}, {name:"xyz:SKHYNIX5L",szDecimals:3}] |
 .[2].universe += [{name:"late:SKHX",szDecimals:3}]' "$fixture_dir/hl-metas.json" >"$fixture_dir/aliases.tmp"
mv "$fixture_dir/aliases.tmp" "$fixture_dir/hl-metas.json"
jq '.order_books += [
 {symbol:"SKHYNIX",market_id:143,market_type:"perp",status:"inactive"},
 {symbol:"SKHYNIXUSD",market_id:161,market_type:"perp",status:"active",supported_size_decimals:3},
 {symbol:"SAMSUNG",market_id:140,market_type:"perp",status:"inactive"},
 {symbol:"SAMSUNGUSD",market_id:162,market_type:"perp",status:"active",supported_size_decimals:3},
 {symbol:"HYUNDAI",market_id:142,market_type:"perp",status:"inactive"},
 {symbol:"HYUNDAIUSD",market_id:160,market_type:"perp",status:"active"},
 {symbol:"SKHY",market_id:216,market_type:"perp",status:"active"},
 {symbol:"SKHYNIXUSD/USDC",market_id:2049,market_type:"spot",status:"active"},
 {symbol:"SKHYNIX5L",market_id:9991,market_type:"perp",status:"active"},
 {symbol:"UNKNOWNUSD",market_id:9992,market_type:"perp",status:"active"},
 {symbol:"TUSD",market_id:9993,market_type:"perp",status:"active"},
 {symbol:"USD1",market_id:9994,market_type:"perp",status:"active"}]' "$fixture_dir/lighter.json" >"$fixture_dir/aliases.tmp"
mv "$fixture_dir/aliases.tmp" "$fixture_dir/lighter.json"
jq '.symbols += (["SKHYNIX","SAMSUNG","SKHY","SKHYNIX5L"]|map({symbol:(.+"USDT"),baseAsset:.,
 quoteAsset:"USDT",marginAsset:"USDT",status:"TRADING",contractType:"PERPETUAL",underlyingSubType:["STOCK"]})) +
 (["1000PEPE","1000000MOG","1MBABYDOGE","1000PEPPER"]|map({symbol:(.+"USDT"),baseAsset:.,
 quoteAsset:"USDT",marginAsset:"USDT",status:"TRADING",contractType:"PERPETUAL"})) +
 [{symbol:"SKHXUSDT",baseAsset:"SKHX",quoteAsset:"USDT",marginAsset:"USDT",status:"PENDING_TRADING",contractType:""}]' "$fixture_dir/aster.json" >"$fixture_dir/aliases.tmp"
mv "$fixture_dir/aliases.tmp" "$fixture_dir/aster.json"
echo '{"code":200,"asks":[{"price":"100","remaining_base_amount":"20"}],"bids":[{"price":"99","remaining_base_amount":"20"}]}' >"$fixture_dir/route-lighter-book.json"
if [[ $# == 1 ]]; then
  echo '[{"symbol":"USDTUSD","bidPrice":"0.9999","askPrice":"1.0001","bidQty":"100","askQty":"100"},{"symbol":"USDCUSD","bidPrice":"0.9989","askPrice":"0.9991","bidQty":"100","askQty":"100"}]' >"$fixture_dir/route-rates.json"
  echo '{"asks":[["100","20"]],"bids":[["99","20"]]}' >"$fixture_dir/route-book.json"
  echo '{"data":{"a":[["100","20"]],"b":[["99","20"]]}}' >"$fixture_dir/route-bitget.json"
  echo '{"asks":[{"p":"100","s":200000}],"bids":[{"p":"99","s":200000}]}' >"$fixture_dir/route-gate.json"
  echo '{"result":"success","orderBook":{"asks":[["100","20"]],"bids":[["99","20"]]}}' >"$fixture_dir/route-kraken.json"
  echo '[{"asks":[["100","2000"]],"bids":[["99","2000"]]}]' >"$fixture_dir/route-okx.json"
  echo '{"levels":[[{"px":"99","sz":"20"}],[{"px":"100","sz":"20"}]]}' >"$fixture_dir/route-hl.json"
  echo '{"taker_fee":"0.0000","supported_size_decimals":3,"min_base_amount":"0.007","min_quote_amount":"10"}' >"$fixture_dir/route-lighter-meta.json"
  echo '{"code":200,"asks":[{"price":"100","remaining_base_amount":"20"}],"bids":[{"price":"99","remaining_base_amount":"20"}]}' >"$fixture_dir/route-lighter-book.json"
  echo '{"error":"asset not found"}' >"$fixture_dir/route-no-asset.json"
  echo '{"assets":[]}' >"$fixture_dir/route-rh.json"
  echo '{"data":[]}' >"$fixture_dir/route-networks.json"
  echo '[]' >"$fixture_dir/stats-empty.json"
  echo '[{"symbol":"SKHYNIXUSDT","quoteVolume":"10"},{"symbol":"SAMSUNGUSDT","quoteVolume":"10"}]' >"$fixture_dir/stats-aster.json"
  jq '[.[1], [.[1].universe[]|{dayNtlVlm:(if .name=="xyz:SKHX" then "2000000" else "1" end)}]]' "$fixture_dir/hl-metas.json" >"$fixture_dir/stats-hl-xyz.json"
  echo '{"order_book_details":[{"market_id":161,"daily_quote_token_volume":"1000000"},{"market_id":162,"daily_quote_token_volume":"1000000"}]}' >"$fixture_dir/stats-lighter.json"
  jq -n --argjson now "$(date +%s%3N)" '[{symbol:"BTCUSDT",quoteVolume:"10",lastPrice:"100"},{symbol:"USDTUSD",count:100,closeTime:$now},{symbol:"USDCUSD",count:100,closeTime:$now}]' >"$fixture_dir/stats-binance-spot.json"
  echo '[{"symbol":"BTCUSDT","quoteVolume":"1000000","lastPrice":"100"},{"symbol":"CRCLUSDT","quoteVolume":"1000000","lastPrice":"100"}]' >"$fixture_dir/stats-binance-perp.json"
  echo '{"USDTZUSD":{"c":["0.99"]},"USDCUSD":{"c":["1.001"]}}' >"$fixture_dir/stats-kraken.json"
  jq '.+{USDTZUSD:{altname:"USDTUSD",wsname:"USDT/USD",base:"USDT",aclass_base:"currency",status:"online"},USDCUSD:{altname:"USDCUSD",wsname:"USDC/USD",base:"USDC",aclass_base:"currency",status:"online"}}' "$fixture_dir/kraken-spot.json" >"$fixture_dir/kraken-spot.tmp"
  mv "$fixture_dir/kraken-spot.tmp" "$fixture_dir/kraken-spot.json"
  now=$(date +%s%3N)
  for tf in 15m 1h 4h; do
    duration=900000; [[ $tf != 1h ]] || duration=3600000; [[ $tf != 4h ]] || duration=14400000
    jq -n --argjson now "$now" --argjson duration "$duration" '[range(60;-1;-1)|[($now/$duration|floor)*$duration-.*$duration,100,103,98,102,12]]' >"$fixture_dir/candles-$tf.json"
    jq 'map({t:.[0],o:.[1],h:.[2],l:.[3],c:.[4],v:.[5]})' "$fixture_dir/candles-$tf.json" >"$fixture_dir/hl-candles-$tf.json"
    jq '{code:200,c:.}' "$fixture_dir/hl-candles-$tf.json" >"$fixture_dir/lighter-candles-$tf.json"
  done
  jq -n --argjson now "$now" '[{price:"102",time:($now-1)}]' >"$fixture_dir/candle-trades.json"
  jq 'map({px:.price,time})' "$fixture_dir/candle-trades.json" >"$fixture_dir/hl-trades.json"
  jq '{trades:map({price,timestamp:.time})}' "$fixture_dir/candle-trades.json" >"$fixture_dir/lighter-trades.json"
  python3 "$repo_root/tests/market-discovery/test_tool_runtime.py" "$1" "$fixture_dir"
  exit
fi
run() { bash "$script" "$@"; }
WAIT_FOR_ALL=1 run BTC CRCL PEPE ETH >"$fixture_dir/result.json"
jq -e '(keys==["errors","results"]) and .errors==[] and (.results|map(.ticker))==["BTC","CRCL","PEPE","ETH"]' "$fixture_dir/result.json" >/dev/null
# Every required catalog was fetched once despite four tickers.
jq -Rsc 'split("\n")[:-1] | map(select(.!="route-lighter-book")) | length==19 and (group_by(.)|all(.[];length==1))' "$fixture_dir/calls" | jq -e . >/dev/null
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
run btc BTC CRCL >"$fixture_dir/result.json"
jq -e '(.results|map(.ticker))==["BTC","CRCL"]' "$fixture_dir/result.json" >/dev/null
[[ $(wc -l <"$fixture_dir/calls") == 19 ]]
# Some venues cannot cover a requested currency; retain the other results.
partial() { run "$@" || [[ $? == 1 ]]; }
# Aliases retain input grouping and native order IDs; no fuzzy issuer matching.
run SKHYNIX SKHX SAMSUNG SMSN HYUNDAI SKHY T USD1 000660 --quote ALL >"$fixture_dir/aliases.json"
jq -e '
 def markets($t): [.results[]|select(.ticker==$t)|.markets[]];
 (markets("SKHYNIX") == (markets("SKHX")|map(select(.symbol!="late:SKHX")))) and
 any(markets("SKHX")[];.symbol=="late:SKHX") and (markets("SAMSUNG") == markets("SMSN")) and
 (markets("SKHYNIX")|length)==3 and (markets("SAMSUNG")|length)==3 and
 any(markets("SKHYNIX")[];.symbol=="xyz:SKHX" and .assetId==110003 and .dex=="xyz") and
 any(markets("SKHYNIX")[];.symbol=="SKHYNIXUSD" and .marketId==161) and
 any(markets("SKHYNIX")[];.symbol=="SKHYNIXUSDT") and
 any(markets("SAMSUNG")[];.symbol=="xyz:SMSN") and
 any(markets("SAMSUNG")[];.symbol=="SAMSUNGUSD" and .marketId==162) and
 (markets("HYUNDAI")|map(.symbol))==["HYUNDAIUSD"] and
 (markets("SKHY")|map(.symbol)|sort)==["SKHY","SKHYUSDT","xyz:SKHY"] and
 markets("T")==[] and markets("000660")==[] and
 (markets("USD1")|map(.symbol))==["USD1"] and .errors==[]' "$fixture_dir/aliases.json" >/dev/null
run SKHYNIX SAMSUNG --product spot | jq -e 'all(.results[];.markets==[])' >/dev/null
partial SKHYNIX --quote USDT | jq -e '(.results[0].markets|map(.symbol))==["SKHYNIXUSDT"]' >/dev/null
run SKHYNIXUSD | jq -e 'any(.results[0].markets[];.marketId==161)' >/dev/null
run PEPE 1000PEPE MOG BABYDOGE | jq -e '
 [.results[]|.ticker as $t|.markets[]|select(.venue=="aster")|[$t,.symbol]] ==
 [["PEPE","1000PEPEUSDT"],["1000PEPE","1000PEPEUSDT"],["MOG","1000000MOGUSDT"],["BABYDOGE","1MBABYDOGEUSDT"]]' >/dev/null
# Known aliases must still respect current availability.
cp "$fixture_dir/hl-metas.json" "$fixture_dir/hl-alias.backup"
cp "$fixture_dir/lighter.json" "$fixture_dir/lighter-alias.backup"
jq '.[1].universe |= map(if .name=="xyz:SKHX" then .isDelisted=true else . end)' "$fixture_dir/hl-metas.json" >"$fixture_dir/aliases.tmp"
mv "$fixture_dir/aliases.tmp" "$fixture_dir/hl-metas.json"
jq '.order_books |= map(if .market_id==161 then .status="inactive" else . end)' "$fixture_dir/lighter.json" >"$fixture_dir/aliases.tmp"
mv "$fixture_dir/aliases.tmp" "$fixture_dir/lighter.json"
run SKHYNIX | jq -e '(.results[0].markets|map(.symbol))==["SKHYNIXUSDT"]' >/dev/null
mv "$fixture_dir/hl-alias.backup" "$fixture_dir/hl-metas.json"
mv "$fixture_dir/lighter-alias.backup" "$fixture_dir/lighter.json"
partial BTC --quote USDC | jq -e '[.results[0].markets[]|select(.venue=="bitget")]|length==2 and any(.[];.symbol=="BTCPERP")' >/dev/null
partial BTC --quote USDT | jq -e '[.results[0].markets[]|select(.venue=="kraken")]|length==1 and .[0].symbol=="XBTUSDT"' >/dev/null
run BTC --quote ALL | jq -e '[.results[0].markets[]|select(.venue=="hyperliquid")]|length==4 and any(.[];.symbol=="late:BTC" and .assetId==120000)' >/dev/null
run BTC --quote ALL | jq -e '[.results[0].markets[]|select(.venue=="okx-cex")]|length==3' >/dev/null
partial ETH --quote USDT | jq -e '[.results[0].markets[]|select(.venue=="lighter")]|length==1 and .[0].symbol=="ETH/USDT"' >/dev/null
run BTC --product spot | jq -e '.errors==[] and all(.results[0].markets[];.product=="spot")' >/dev/null
run BTC --product perpetual | jq -e '.errors==[] and all(.results[0].markets[];.product=="perp")' >/dev/null
run CLOSE BUY SELL DOGE STOP OLD INCH UNKNOWN >"$fixture_dir/result.json"
jq -e 'any(.results[]|select(.ticker=="CLOSE")|.markets[];.restrictions==["Opening restricted"]) and
 any(.results[]|select(.ticker=="BUY")|.markets[];.restrictions==["Buy only"]) and
 any(.results[]|select(.ticker=="SELL")|.markets[];.restrictions==["Sell only"]) and
 any(.results[]|select(.ticker=="DOGE")|.markets[];.symbol=="XDGUSD") and
 all(.results[]|select(.ticker=="STOP" or .ticker=="OLD" or .ticker=="INCH" or .ticker=="UNKNOWN");.markets==[])' "$fixture_dir/result.json" >/dev/null
run 1INCH | jq -e '(.results[0].markets|length)==4' >/dev/null
# Partial failures remain venue-specific, without suppressing healthy venues/products.
touch "$fixture_dir/binance-assets.fail"
if run CRCL >"$fixture_dir/error.json"; then echo 'Expected partial error'; exit 1; fi
jq -e 'any(.errors[];.venue=="binance" and .query=="assets") and any(.results[0].markets[];.venue=="binance" and .product=="perp") and any(.results[0].markets[];.venue=="kraken")' "$fixture_dir/error.json" >/dev/null
rm "$fixture_dir/binance-assets.fail"
if run BTC --quote EUR >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)==2 and ([.errors[].venue]|sort)==["bitget","gate"]' "$fixture_dir/error.json" >/dev/null
cp "$fixture_dir/kraken-tickers.json" "$fixture_dir/kraken-tickers.backup"
echo '{"result":"success","tickers":[]}' >"$fixture_dir/kraken-tickers.json"
if run BTC >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)>0 and ([.results[0].markets[]|select(.venue=="kraken")]|length)==1' "$fixture_dir/error.json" >/dev/null
mv "$fixture_dir/kraken-tickers.backup" "$fixture_dir/kraken-tickers.json"
for key in aster binance-spot bitget-spot gate-spot kraken-spot okx-spot hl-metas lighter; do
  cp "$fixture_dir/$key.json" "$fixture_dir/backup.json"
  echo '{"error":"invalid"}' >"$fixture_dir/$key.json"
  if run BTC CRCL >"$fixture_dir/error.json"; then echo "Expected malformed $key error"; exit 1; fi
  jq -e '(.errors|length)>0 and (.results[0].markets|length)>0' "$fixture_dir/error.json" >/dev/null
  mv "$fixture_dir/backup.json" "$fixture_dir/$key.json"
done
for args in 'BTC --venues binance' '--venues gate,' '--product invalid' '--quote' ''; do
  # Intentional word splitting exercises malformed argument lists.
  if run $args >/dev/null 2>&1; then echo 'Expected input rejection'; exit 1; fi
done
# Only fresh, validated public catalogs are reused between tools in the same workspace.
export FX_MARKET_CACHE_DIR="$fixture_dir/cache"
: >"$fixture_dir/calls"
run BTC CRCL >"$fixture_dir/cache-first.json"
first_calls=$(wc -l <"$fixture_dir/calls")
run BTC CRCL >"$fixture_dir/cache-second.json"
[[ $(wc -l <"$fixture_dir/calls") == "$first_calls" ]]
cmp "$fixture_dir/cache-first.json" "$fixture_dir/cache-second.json"
# An expired entry forces a real read, not stale availability.
for entry in "$FX_MARKET_CACHE_DIR"/*.json; do
  jq '.storedAt=0' "$entry" >"$fixture_dir/expired.json"
  mv "$fixture_dir/expired.json" "$entry"
done
run BTC CRCL >/dev/null
[[ $(wc -l <"$fixture_dir/calls") -gt "$first_calls" ]]
echo 'Unified discovery fixtures passed: all eight workers overlap, one fetch per catalog, multi-ticker results, filters, restrictions, and partial failures.'

# Empty Lighter books are absent assets; failed queries retain coverage errors.
# Keep the persistent cache enabled: book changes must be visible immediately.
partial ETH --quote ALL | jq -e 'any(.results[].markets[];.venue=="lighter")' >/dev/null
cp "$fixture_dir/route-lighter-book.json" "$fixture_dir/book.saved"
echo '{"code":200,"asks":[],"bids":[]}' >"$fixture_dir/route-lighter-book.json"
partial ETH --quote ALL | jq -e 'all(.results[].markets[];.venue!="lighter")' >/dev/null
echo '{"code":500}' >"$fixture_dir/route-lighter-book.json"
partial ETH --quote ALL | jq -e 'any(.errors[];.venue=="lighter") and all(.results[].markets[];.venue!="lighter")' >/dev/null
mv "$fixture_dir/book.saved" "$fixture_dir/route-lighter-book.json"
partial ETH --quote ALL | jq -e 'any(.results[].markets[];.venue=="lighter")' >/dev/null
echo 'Lighter empty-book exclusion and failed-book coverage passed.'
