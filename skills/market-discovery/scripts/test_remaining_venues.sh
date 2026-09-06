#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/cli" <<'MOCK'
#!/usr/bin/env bash
case "${0##*/}:$*" in
 bgc:*SPOT*) key=bitget-spot;;
 bgc:*USDT-FUTURES*) key=bitget-usdt;;
 bgc:*USDC-FUTURES*) key=bitget-usdc;;
 gate-cli:*'market pairs'*) key=gate-spot;;
 gate-cli:*'market contracts --settle usdt'*) key=gate-perp;;
 gate-cli:*'currency --currency CRCLG'*) key=gate-stock;;
 kraken:*tokenized_asset*) key=kraken-stocks;;
 kraken:pairs*) key=kraken-spot;;
 kraken:*instruments*) key=kraken-perp;;
 kraken:*tickers*) key=kraken-tickers;;
 *) echo "Unexpected query: $*" >&2; exit 2;;
esac
printf '%s\n' "$key" >>"$FIXTURE_DIR/calls"
[[ ! -f $FIXTURE_DIR/$key.fail ]] || exit 1
cat "$FIXTURE_DIR/$key.json"
MOCK
chmod +x "$fixture_dir/cli"
for cli in bgc gate-cli kraken; do ln -s cli "$fixture_dir/$cli"; done
export PATH="$fixture_dir:$PATH"
jq -n '{data:(["BTC","PEPE","1INCH"]|map({symbol:(.+"USDT"),baseCoin:.,quoteCoin:"USDT",category:"SPOT",status:"online"}))+[
 {symbol:"BTCUSDC",baseCoin:"BTC",quoteCoin:"USDC",category:"SPOT",status:"online"},
 {symbol:"RCRCLUSDT",baseCoin:"rCRCL",quoteCoin:"USDT",category:"SPOT",status:"online",symbolType:"stock"},
 {symbol:"RPEPEUSDT",baseCoin:"rPEPE",quoteCoin:"USDT",category:"SPOT",status:"online",symbolType:"crypto"},
 {symbol:"OLDUSDT",baseCoin:"OLD",quoteCoin:"USDT",category:"SPOT",status:"offline"}]}' >"$fixture_dir/bitget-spot.json"
jq -n '{data:(["BTC","CRCL","1000PEPE","1INCH"]|map({symbol:(.+"USDT"),baseCoin:.,quoteCoin:"USDT",category:"USDT-FUTURES",status:"online",type:"perpetual"}))+[
 {symbol:"BTCUSDT_261225",baseCoin:"BTC",quoteCoin:"USDT",category:"USDT-FUTURES",status:"online",type:"delivery"},
 {symbol:"CLOSEUSDT",baseCoin:"CLOSE",quoteCoin:"USDT",category:"USDT-FUTURES",status:"limit_open",type:"perpetual"}]}' >"$fixture_dir/bitget-usdt.json"
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
run() { bash "$script_dir/$1-markets.sh" "${@:2}"; }
run bitget btc | jq -e '.quoteAsset=="USDT" and (.markets|length)==2' >/dev/null
[[ $(wc -l <"$fixture_dir/calls") -eq 2 ]]
run bitget BTC --quote USDC | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="BTCPERP")' >/dev/null
run bitget BTC --quote ALL | jq -e '(.markets|length)==4' >/dev/null
run bitget CRCL | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="RCRCLUSDT" and .baseAsset=="rCRCL")' >/dev/null
run bitget PEPE | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="1000PEPEUSDT")' >/dev/null
run bitget CLOSE | jq -e '.markets[0].restrictions==["Opening restricted"]' >/dev/null
run gate CRCL | jq -e '(.markets|length)==5 and all(.markets[];.symbol!="CRCL3L_USDT")' >/dev/null
run gate CRCL3L | jq -e '.markets[0].representation=="leveraged_token"' >/dev/null
run gate BTC --quote ALL | jq -e '(.markets|length)==3' >/dev/null
run gate BTC --quote USDC --product spot | jq -e '(.markets|length)==1 and .markets[0].symbol=="BTC_USDC"' >/dev/null
run gate BUY | jq -e '.markets[0].restrictions==["Buy only"]' >/dev/null
run gate SELL | jq -e '.markets[0].restrictions==["Sell only"]' >/dev/null
run gate PEPE | jq -e '.markets==[]' >/dev/null
run kraken BTC | jq -e '(.markets|length)==3 and any(.markets[];.symbol=="XBTUSD") and any(.markets[];.symbol=="PI_XBTUSD" and .status=="post_only")' >/dev/null
run kraken CRCL | jq -e '(.markets|length)==1 and .markets[0].symbol=="CRCLxUSD" and .markets[0].restrictions==["Resting limit orders only"]' >/dev/null
run kraken CRCLX --product spot | jq -e '.markets[0].symbol=="CRCLxUSD"' >/dev/null
run kraken DOGE | jq -e '.markets[0].symbol=="XDGUSD" and .markets[0].restrictions==["Limit orders only"]' >/dev/null
run kraken BTC --quote USDT | jq -e '(.markets|length)==1 and .markets[0].symbol=="XBTUSDT"' >/dev/null
run kraken BTC --quote ALL | jq -e '(.markets|length)==4' >/dev/null
run kraken STOP | jq -e '.markets==[] and .errors==[]' >/dev/null
for venue in bitget gate kraken; do
  for ticker in OLD INCH UNKNOWN; do run "$venue" "$ticker" | jq -e '.markets==[] and .errors==[]' >/dev/null; done
  run "$venue" BTC --product spot | jq -e 'all(.markets[];.product=="spot")' >/dev/null
  run "$venue" BTC --product perpetual | jq -e 'all(.markets[];.product=="perpetual")' >/dev/null
  if run "$venue" BTC --product invalid >/dev/null 2>&1; then echo 'Expected invalid product rejection'; exit 1; fi
done
for venue in bitget gate; do
  if run "$venue" BTC --quote EUR >"$fixture_dir/error.json"; then echo 'Expected unsupported perpetual scope'; exit 1; fi
  jq -e '.errors|length>0' "$fixture_dir/error.json" >/dev/null
done
# Preserve unaffected catalogs on failure instead of returning false absence.
for pair in bitget:bitget-usdt gate:gate-perp kraken:kraken-perp; do
  venue=${pair%%:*}; key=${pair#*:}; touch "$fixture_dir/$key.fail"
  if run "$venue" BTC >"$fixture_dir/error.json"; then echo 'Expected query failure'; exit 1; fi
  jq -e '(.errors|length)==1 and any(.markets[];.product=="spot")' "$fixture_dir/error.json" >/dev/null
  rm "$fixture_dir/$key.fail"
done
echo '{"code":"40000","data":[]}' >"$fixture_dir/bitget-spot.json"
if run bitget BTC >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)==1 and (.markets|length)==1' "$fixture_dir/error.json" >/dev/null
echo '{"error":"upstream"}' >"$fixture_dir/gate-spot.json"
if run gate BTC >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)==1 and (.markets|length)==1' "$fixture_dir/error.json" >/dev/null
echo '{"result":"success","tickers":[]}' >"$fixture_dir/kraken-tickers.json"
if run kraken BTC >"$fixture_dir/error.json"; then exit 1; fi
jq -e '(.errors|length)==1 and .errors[0].query=="status" and (.markets|length)==1' "$fixture_dir/error.json" >/dev/null
echo 'Bitget, Gate, Kraken fixtures passed: catalogs, currencies, products, naming, restrictions, exclusions, and partial errors.'
