#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/purr" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'lighter markets --market-type all' ]] || exit 2
echo query >>"$FIXTURE_DIR/calls"
[[ ! -f $FIXTURE_DIR/fail ]] || exit 1
cat "$FIXTURE_DIR/catalog.json"
EOF
chmod +x "$fixture_dir/purr"
export PATH="$fixture_dir:$PATH"
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
]}' >"$fixture_dir/catalog.json"
bash "$script_dir/lighter-markets.sh" eth | jq -e '.currencyFilter=="USDC" and (.markets|length)==2 and any(.markets[];.symbol=="ETH" and .marketId==0 and .settlementAsset=="USDC" and .quoteAsset==null and .sizeDecimals==4 and .minBaseAmount=="0.0050") and any(.markets[];.symbol=="ETH/USDC" and .marketId==2048 and .settlementAsset==null)' >/dev/null
[[ $(wc -l <"$fixture_dir/calls") -eq 1 ]]
bash "$script_dir/lighter-markets.sh" ETH --product spot | jq -e '(.markets|length)==1 and .markets[0].symbol=="ETH/USDC"' >/dev/null
bash "$script_dir/lighter-markets.sh" ETH --product perpetual | jq -e '(.markets|length)==1 and .markets[0].symbol=="ETH"' >/dev/null
bash "$script_dir/lighter-markets.sh" ETH --quote usdt | jq -e '(.markets|length)==1 and .markets[0].symbol=="ETH/USDT"' >/dev/null
bash "$script_dir/lighter-markets.sh" ETH --quote ALL | jq -e '.currencyFilter==null and (.markets|length)==3' >/dev/null
for pair in PEPE:1000PEPE SHIB:1000SHIB 1000PEPE:1000PEPE 1INCH:1INCH; do
  input=${pair%%:*}; expected=${pair#*:}
  bash "$script_dir/lighter-markets.sh" "$input" | jq -e --arg symbol "$expected" '(.markets|length)==1 and .markets[0].symbol==$symbol' >/dev/null
done
for ticker in OLD INCH UNKNOWN; do
  bash "$script_dir/lighter-markets.sh" "$ticker" | jq -e '.markets==[] and .errors==[]' >/dev/null
done
for invalid in '{"code":500,"order_books":[]}' '{"code":200}' '{"code":200,"order_books":[{"symbol":"ETH"}]}' 'not json'; do
  printf '%s\n' "$invalid" >"$fixture_dir/catalog.json"
  if bash "$script_dir/lighter-markets.sh" ETH >"$fixture_dir/error.json"; then echo 'Expected catalog error' >&2; exit 1; fi
  jq -e '.markets==[] and (.errors|length)==1' "$fixture_dir/error.json" >/dev/null
done
touch "$fixture_dir/fail"
if bash "$script_dir/lighter-markets.sh" ETH >"$fixture_dir/error.json"; then echo 'Expected query failure' >&2; exit 1; fi
jq -e '.markets==[] and (.errors|length)==1' "$fixture_dir/error.json" >/dev/null
echo 'Lighter fixtures passed: single catalog, products, currencies, exact symbols, prefixes, inactive markets, and failed coverage.'
