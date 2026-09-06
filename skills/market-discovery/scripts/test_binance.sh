#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/binance-cli" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  spot) cat "$FIXTURE_DIR/spot.json" ;;
  futures-usds) cat "$FIXTURE_DIR/futures.json" ;;
  request) cat "$FIXTURE_DIR/assets.json" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fixture_dir/binance-cli"
export PATH="$fixture_dir:$PATH"
jq -n '{symbols:[
  {symbol:"BTCUSDT",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",isSpotTradingAllowed:true},
  {symbol:"BTCUSDC",baseAsset:"BTC",quoteAsset:"USDC",status:"TRADING",isSpotTradingAllowed:true},
  {symbol:"BTCJPY",baseAsset:"BTC",quoteAsset:"JPY",status:"HALT",isSpotTradingAllowed:true},
  {symbol:"CRCLBUSDT",baseAsset:"CRCLB",quoteAsset:"USDT",status:"TRADING",isSpotTradingAllowed:true}
]}' >"$fixture_dir/spot.json"
jq -n '{symbols:[
  {symbol:"BTCUSDT",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",contractType:"PERPETUAL"},
  {symbol:"BTCUSDC",baseAsset:"BTC",quoteAsset:"USDC",status:"TRADING",contractType:"PERPETUAL"},
  {symbol:"BTCUSDT_261225",baseAsset:"BTC",quoteAsset:"USDT",status:"TRADING",contractType:"CURRENT_QUARTER"},
  {symbol:"CRCLUSDT",baseAsset:"CRCL",quoteAsset:"USDT",status:"TRADING",contractType:"TRADIFI_PERPETUAL"}
]}' >"$fixture_dir/futures.json"
jq -n '{success:true,data:[{assetCode:"CRCLB",uq:"CRCL",tags:["bStocks"],trading:true,delisted:false,test:0}]}' >"$fixture_dir/assets.json"
bash "$script_dir/binance-markets.sh" btc | jq -e '.quoteAsset=="USDT" and (.markets|length)==2 and all(.markets[];.symbol=="BTCUSDT")' >/dev/null
bash "$script_dir/binance-markets.sh" BTC --quote usdc --product spot | jq -e '(.markets|length)==1 and .markets[0].symbol=="BTCUSDC" and .markets[0].product=="spot"' >/dev/null
bash "$script_dir/binance-markets.sh" BTC --quote ALL | jq -e '.quoteAsset==null and (.markets|length)==4' >/dev/null
bash "$script_dir/binance-markets.sh" CRCL | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="CRCLBUSDT" and .representation=="tokenized_stock") and any(.markets[];.symbol=="CRCLUSDT" and .product=="perpetual")' >/dev/null
bash "$script_dir/binance-markets.sh" UNKNOWN | jq -e '.markets==[] and .errors==[]' >/dev/null
echo '{"success":false,"data":[]}' >"$fixture_dir/assets.json"
if bash "$script_dir/binance-markets.sh" CRCL >"$fixture_dir/partial.json"; then
  echo 'Expected nonzero status for failed asset catalog' >&2; exit 1
fi
jq -e '(.errors|length)==1 and .errors[0].catalog=="assets" and (.markets|length)==1 and .markets[0].symbol=="CRCLUSDT"' "$fixture_dir/partial.json" >/dev/null
echo 'Binance discovery fixtures passed: default, override, all quotes, bStocks, no match, partial failure.'
