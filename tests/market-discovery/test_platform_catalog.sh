#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export FIXTURE_DIR=$fixture
cat > "$fixture/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target=''; url=''
while (( $# )); do
 case "$1" in -o) target=$2;shift 2;; https://*) url=$1;shift;; *) shift;;esac
done
page=first; [[ $url != *cursor=* ]] || page=second
[[ ! -f $FIXTURE_DIR/fail ]] || { printf 503; exit; }
cp "$FIXTURE_DIR/$page.json" "$target"
printf 200
MOCK
chmod +x "$fixture/curl"
export PATH="$fixture:$PATH" FX_MARKET_CATALOG_URL=https://catalog.invalid/v1/market-catalog
jq -n '{schemaVersion:1,revision:"v1",total:2,nextCursor:"page-2",items:[{id:"a",venue:"hyperliquid",product:"spot",nativeSymbol:"@142",base:"UBTC",quote:"USDC",aliases:["UBTC","BTC"],binding:{assetId:10142},baseRepresentation:{verification:"verified",asset:{aliases:["BTC"]}}}]}' > "$fixture/first.json"
jq -n '{schemaVersion:1,revision:"v1",total:2,nextCursor:null,items:[{id:"b",venue:"hyperliquid",product:"perp",nativeSymbol:"BTC",base:"BTC",quote:"USDC",aliases:["BTC"],binding:{assetId:0},baseRepresentation:{verification:"verified",asset:{aliases:["BTC"]}}}]}' > "$fixture/second.json"
source "$root/src/tools/market/platform-catalog.sh"
scratch="$fixture/work";mkdir "$scratch"
platform_catalog_read venues hyperliquid "$scratch/facts.json"
jq -e 'length==2' "$scratch/facts.json" >/dev/null
# Formatting uses current native observations, not another economic alias resolver.
match_hyperliquid() { jq -n '{markets:[{symbol:"UBTC/USDC",assetId:10142,product:"spot"},{symbol:"OTHER/USDC",assetId:10555,product:"spot"}]}'; }
ticker=BTC;quote=USDC;product=spot;fn=hyperliquid;venue=hyperliquid
mkdir "$scratch/platform"
cp "$scratch/facts.json" "$scratch/platform/facts.json"
platform_match > "$fixture/result.json"
jq -e '.markets|length==1 and .[0].assetId==10142' "$fixture/result.json" >/dev/null
jq '.revision="v2"' "$fixture/second.json" > "$fixture/new.json";mv "$fixture/new.json" "$fixture/second.json"
if platform_catalog_read venues hyperliquid "$scratch/broken.json";then echo 'Mixed revisions accepted' >&2;exit 1;fi
[[ ! -f $scratch/broken.json ]]
touch "$fixture/fail"
if platform_catalog_read venues hyperliquid "$scratch/failed.json";then echo 'Failed catalog accepted' >&2;exit 1;fi
[[ ! -f $scratch/failed.json ]]
echo 'Platform catalog pagination, exact native selection and failure preservation passed.'
