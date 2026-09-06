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
# Exercise naming patterns across assets and products, not a PEPE-only mapping.
jq '.symbols += (["PEPE","SHIB","1000SATS","1000CAT","1000CHEEMS","1MBABYDOGE","1INCH","0G"] | map({symbol:(.+"USDT"),baseAsset:.,quoteAsset:"USDT",status:"TRADING",isSpotTradingAllowed:true}))' "$fixture_dir/spot.json" >"$fixture_dir/next.json"
mv "$fixture_dir/next.json" "$fixture_dir/spot.json"
jq '.symbols += (["1000PEPE","1000SHIB","1000000MOG","1000000BOB","1MBABYDOGE","1000SATS","1000CAT","1000CHEEMS","1INCH","0G","1000PEPPER"] | map({symbol:(.+"USDT"),baseAsset:.,quoteAsset:"USDT",status:"TRADING",contractType:"PERPETUAL"})) + [
  {symbol:"1000PEPEUSDC",baseAsset:"1000PEPE",quoteAsset:"USDC",status:"TRADING",contractType:"PERPETUAL"},
  {symbol:"1000000PEPEUSDT",baseAsset:"1000000PEPE",quoteAsset:"USDT",status:"SETTLING",contractType:"PERPETUAL"},
  {symbol:"1MPEPEUSDT_261225",baseAsset:"1MPEPE",quoteAsset:"USDT",status:"TRADING",contractType:"CURRENT_QUARTER"}
]' "$fixture_dir/futures.json" >"$fixture_dir/next.json"
mv "$fixture_dir/next.json" "$fixture_dir/futures.json"
for pair in PEPE:1000PEPE SHIB:1000SHIB MOG:1000000MOG BOB:1000000BOB BABYDOGE:1MBABYDOGE SATS:1000SATS CAT:1000CAT CHEEMS:1000CHEEMS 1000PEPE:1000PEPE 1INCH:1INCH 0G:0G; do
  input=${pair%%:*}; expected=${pair#*:}
  bash "$script_dir/binance-markets.sh" "$input" --product perpetual | jq -e --arg base "$expected" '(.markets|length)==1 and .markets[0].baseAsset==$base and .markets[0].symbol==($base+"USDT") and .errors==[]' >/dev/null
done
for pair in SATS:1000SATS CAT:1000CAT CHEEMS:1000CHEEMS BABYDOGE:1MBABYDOGE; do
  input=${pair%%:*}; expected=${pair#*:}
  bash "$script_dir/binance-markets.sh" "$input" --product spot | jq -e --arg base "$expected" '(.markets|length)==1 and .markets[0].baseAsset==$base and .markets[0].product=="spot"' >/dev/null
done
bash "$script_dir/binance-markets.sh" PEPE | jq -e '(.markets|length)==2 and any(.markets[];.baseAsset=="PEPE" and .product=="spot") and any(.markets[];.baseAsset=="1000PEPE" and .product=="perpetual")' >/dev/null
bash "$script_dir/binance-markets.sh" PEPE --quote USDC | jq -e '(.markets|length)==1 and .markets[0].symbol=="1000PEPEUSDC"' >/dev/null
bash "$script_dir/binance-markets.sh" PEPE --quote ALL | jq -e '(.markets|length)==3' >/dev/null
for input in INCH G UNKNOWN; do
  bash "$script_dir/binance-markets.sh" "$input" | jq -e '.markets==[] and .errors==[]' >/dev/null
done
echo '{"success":false,"data":[]}' >"$fixture_dir/assets.json"
if bash "$script_dir/binance-markets.sh" CRCL >"$fixture_dir/partial.json"; then
  echo 'Expected nonzero status for failed asset catalog' >&2; exit 1
fi
jq -e '(.errors|length)==1 and .errors[0].catalog=="assets" and (.markets|length)==1 and .markets[0].symbol=="CRCLUSDT"' "$fixture_dir/partial.json" >/dev/null
echo 'Binance discovery fixtures passed: quote/product filters, bStocks, denomination prefixes, exact numeric tickers, no match, partial failure.'
