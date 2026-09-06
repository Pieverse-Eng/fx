#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
export FIXTURE_DIR="$fixture_dir"
cat >"$fixture_dir/okx" <<'EOF'
#!/usr/bin/env bash
set -eu
action=$2; shift 2
kind=''; base=''; quote=''; id=''
while (( $# )); do
  case "$1" in
    --instType) kind=$2; shift 2 ;;
    --baseCcy) base=$2; shift 2 ;;
    --quoteCcy) quote=$2; shift 2 ;;
    --instId) id=$2; shift 2 ;;
    --json) shift ;;
    *) shift 2 ;;
  esac
done
case "$action" in
  filter)
    if [[ ${TRUNCATE_FILTER:-0} == 1 ]]; then
      echo '[{"rows":[],"total":101}]'; exit 0
    fi
    jq --arg kind "$kind" --arg base "$base" --arg quote "$quote" '
      [.[] | select(.instType==$kind and (.baseCcy==$base or .ctValCcy==$base)) |
        {instId,instType,baseCcy:(if .instType=="SWAP" then .ctValCcy else .baseCcy end),quoteCcy:(if .instType=="SWAP" then .settleCcy else .quoteCcy end)} |
        select($quote=="" or .quoteCcy==$quote)] | [{rows:.,total:length}]' "$FIXTURE_DIR/instruments.json" ;;
  instruments-by-category)
    if [[ ${FAIL_STOCKS:-0} == 1 ]]; then echo '{"code":"500","msg":"failure"}';
    else jq '[.[]|select(.instCategory=="3" and .instType=="SPOT")]' "$FIXTURE_DIR/instruments.json"; fi ;;
  instruments) jq --arg id "$id" '[.[]|select(.instId==$id)]' "$FIXTURE_DIR/instruments.json" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fixture_dir/okx"
export PATH="$fixture_dir:$PATH"
jq -n '[
 {instId:"BTC-USDT",baseCcy:"BTC",quoteCcy:"USDT",instType:"SPOT",state:"live"},
 {instId:"BTC-USDC",baseCcy:"BTC",quoteCcy:"USDC",instType:"SPOT",state:"live"},
 {instId:"BTC-EUR",baseCcy:"BTC",quoteCcy:"EUR",instType:"SPOT",state:"suspend"},
 {instId:"XBTC-USDT",baseCcy:"XBTC",quoteCcy:"USDT",instType:"SPOT",instCategory:"1",state:"live"},
 {instId:"XCRCL-USDT",baseCcy:"XCRCL",quoteCcy:"USDT",instType:"SPOT",instCategory:"3",state:"live"},
 {instId:"BTC-USDT-SWAP",baseCcy:"",quoteCcy:"",settleCcy:"USDT",ctValCcy:"BTC",ctType:"linear",instType:"SWAP",state:"live"},
 {instId:"CRCL-USDT-SWAP",baseCcy:"",quoteCcy:"",settleCcy:"USDT",ctValCcy:"CRCL",ctType:"linear",instType:"SWAP",state:"live"}
]' >"$fixture_dir/instruments.json"
bash "$script_dir/okx-markets.sh" btc | jq -e '.quoteAsset=="USDT" and (.markets|length)==2 and all(.markets[];.baseAsset=="BTC")' >/dev/null
bash "$script_dir/okx-markets.sh" BTC --quote usdc --product spot | jq -e '(.markets|length)==1 and .markets[0].symbol=="BTC-USDC"' >/dev/null
bash "$script_dir/okx-markets.sh" BTC --quote ALL | jq -e '.quoteAsset==null and (.markets|length)==3' >/dev/null
bash "$script_dir/okx-markets.sh" CRCL | jq -e '(.markets|length)==2 and any(.markets[];.symbol=="XCRCL-USDT" and .representation=="tokenized_stock") and any(.markets[];.symbol=="CRCL-USDT-SWAP")' >/dev/null
bash "$script_dir/okx-markets.sh" XCRCL --product spot | jq -e '(.markets|length)==1' >/dev/null
bash "$script_dir/okx-markets.sh" UNKNOWN | jq -e '.markets==[] and .errors==[]' >/dev/null
if FAIL_STOCKS=1 bash "$script_dir/okx-markets.sh" CRCL >"$fixture_dir/partial.json"; then
  echo 'Expected nonzero status for failed stock catalog' >&2; exit 1
fi
jq -e '(.errors|length)==1 and .errors[0].query=="stocks" and (.markets|length)==1 and .markets[0].symbol=="CRCL-USDT-SWAP"' "$fixture_dir/partial.json" >/dev/null
if TRUNCATE_FILTER=1 bash "$script_dir/okx-markets.sh" BTC --product perpetual >"$fixture_dir/truncated.json"; then
  echo 'Expected nonzero status for incomplete filter results' >&2; exit 1
fi
jq -e '.markets==[] and (.errors|length)==1 and .errors[0].query=="swap"' "$fixture_dir/truncated.json" >/dev/null
echo 'OKX discovery fixtures passed: default, override, all quotes, category-restricted alias, deduplication, live state, no match, partial failure, incomplete filter.'
