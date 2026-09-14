# Embedded ahead of discover-markets.sh; uses its resolved catalogs and identifiers.
# All reads below are public. Source selection and conversion evidence stay in the host log.
market_read() (
  local target=$1; shift
  local child
  timeout --kill-after=2s 25s "$@" >"$target.raw" 2>"$target.stderr" & child=$!
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 130' INT TERM
  if wait "$child" && jq -e 'type=="array" or type=="object"' "$target.raw" >/dev/null 2>&1; then
    mv "$target.raw" "$target"
  else
    echo null >"$target"
  fi
)
market_launch() { market_read "$@" & pids+=("$!"); }

# Numeric and unit normalization is shared by the adapters, never left to the model.
candle_jq='
def num: try tonumber catch null;
def positive: num | if .!=null and .>0 and isfinite then . else null end;
def iso_ms: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601 * 1000;
def rows: if type=="array" then . elif .data!=null then .data elif .result!=null then .result else . end;
def exposure($m):
  ($m.baseAsset // ""|ascii_upcase) as $base | ($m.ticker|ascii_upcase) as $t |
  if $base==$t then 1
  elif $m.venue=="hyperliquid" and $base==("K"+$t) then 1000
  elif $base==("1000"+$t) then 1000
  elif $base==("1000000"+$t) or $base==("1M"+$t) then 1000000
  else 1 end;
def quote_ccy($m): $m.quoteAsset // $m.collateralAsset // $m.settlementAsset;
def currency: ascii_upcase | if .=="XBT" then "BTC" elif .=="XDG" then "DOGE" else . end;
def kraken_inverse($m): $m.venue=="kraken" and $m.product!="spot" and
  ($m.symbol|ascii_upcase|startswith("PI_")) and $m.contractType=="futures_inverse" and
  $m.quoteAsset=="USD" and ($m.contractSize|positive)!=null and
  ($m.sizeDecimals|num)==0;
# Direct USD and reversed USD pairs take priority over a USDT bridge.
def reference_rates($pairs;$kr;$bn;$catalog;$now):
  ($kr|rows) as $k |
  reduce ($pairs[]|select(.status=="online")|. as $p|
    (.wsname|split("/")|map(currency)) as $ccys |
    ($k[$p.key] // $k[$p.altname] // $k[($p.wsname|gsub("/";""))]) as $v |
    select(($v.a[0]|positive)!=null and ($v.b[0]|positive)!=null and ($v.v[1]|positive)!=null and
      ($v.a[0]|num)>=($v.b[0]|num) and ($v.a[0]|num)/($v.b[0]|num)<1.01) |
    ((($v.a[0]|num)+($v.b[0]|num))/2) as $mid |
    if $ccys[1]=="USD" then {ccy:$ccys[0],rate:$mid}
    elif $ccys[0]=="USD" then {ccy:$ccys[1],rate:(1/$mid)} else empty end) as $p
    ({USD:1}; .[$p.ccy]=$p.rate) |
  . as $direct |
  ([$bn[]?|select((.count|positive)!=null and (.lastPrice|positive)!=null and
    (.closeTime|num)!=null and (($now-(.closeTime|num))|fabs)<300000)]|INDEX(.symbol)) as $stats |
  reduce ($catalog.symbols[]?|select(.status=="TRADING")|
    . as $p | $stats[$p.symbol] as $v | select($v!=null and $direct.USDT!=null) |
    if .quoteAsset=="USDT" then {ccy:(.baseAsset|currency),rate:(($v.lastPrice|num)*$direct.USDT)}
    elif .baseAsset=="USDT" then {ccy:(.quoteAsset|currency),rate:($direct.USDT/($v.lastPrice|num))} else empty end) as $p
    ($direct; if .[$p.ccy]==null then .[$p.ccy]=$p.rate else . end) |
  . as $anchors |
  # One cross through an independently priced base, without recursively deriving rates.
  [ $pairs[]|select(.status=="online")|. as $p|
    (.wsname|split("/")|map(currency)) as $ccys |
    select((["BTC","ETH"]|index($ccys[0]))!=null and $anchors[$ccys[1]]==null and ($anchors[$ccys[0]]|positive)!=null) |
    ($k[$p.key] // $k[$p.altname] // $k[($p.wsname|gsub("/";""))]) as $v |
    select(($v.a[0]|positive)!=null and ($v.b[0]|positive)!=null and ($v.v[1]|positive)!=null and
      ($v.a[0]|num)>=($v.b[0]|num) and ($v.a[0]|num)/($v.b[0]|num)<1.01) |
    {ccy:$ccys[1],rate:($anchors[$ccys[0]]/((($v.a[0]|num)+($v.b[0]|num))/2)),volume:(($v.v[1]|num)*$anchors[$ccys[0]])}
  ] | sort_by(-.volume) |
  reduce .[] as $p ($anchors; if .[$p.ccy]==null then .[$p.ccy]=$p.rate else . end);
# Venue-native tokens must not borrow the price of a same-name asset elsewhere.
def venue_reference_rates($rates;$gate_pairs;$gate_tickers;$hl):
  (if ($gate_pairs|type)=="array" then $gate_pairs else [] end) as $gate_pairs |
  (if ($gate_tickers|type)=="array" then $gate_tickers else [] end) as $gate_tickers |
  (if ($hl|type)=="array" and ($hl|length)==2 and ($hl[0]|type)=="object" and ($hl[1]|type)=="array" then $hl else [{},[]] end) as $hl |
  ([$gate_tickers[]?|{key:.currency_pair,value:.}]|from_entries) as $gate |
  (reduce ($gate_pairs[]?|select(.trade_status=="tradable")|
    select(.quote as $q | (["USD","USDT","USDC"]|index($q))!=null) |
    . as $p | $gate[$p.id] as $v |
    select(($rates[$p.quote]|positive)!=null and ($v.lowest_ask|positive)!=null and
      ($v.highest_bid|positive)!=null and ($v.quote_volume|positive)!=null and
      ($v.lowest_ask|num)>=($v.highest_bid|num) and ($v.lowest_ask|num)/($v.highest_bid|num)<1.01) |
    {ccy:$p.base,rate:(((($v.lowest_ask|num)+($v.highest_bid|num))/2)*$rates[$p.quote])}) as $p
    ({}; if .[$p.ccy]==null then .[$p.ccy]=$p.rate else . end)) as $gate_rates |
  (reduce ($hl[0].universe[]? | . as $pair |
    ([$hl[0].tokens[]?|select(.index==$pair.tokens[0])][0]) as $base |
    ([$hl[0].tokens[]?|select(.index==$pair.tokens[1])][0]) as $quote |
    select($quote.name=="USDC" and $quote.index==0 and ($rates.USDC|positive)!=null and
      ([$hl[0].tokens[]?|select(.name==$base.name)]|length)==1) |
    ([$hl[1][]?|select(.coin==$pair.name)]|if length==1 then .[0] else null end) as $ctx |
    select(($ctx.midPx|positive)!=null and ($ctx.dayNtlVlm|positive)!=null) |
    {ccy:$base.name,rate:(($ctx.midPx|num)*$rates.USDC)}) as $p
    ({}; if .[$p.ccy]==null then .[$p.ccy]=$p.rate else . end)) as $hl_rates |
  $rates + {venues:{gate:$gate_rates,hyperliquid:$hl_rates}};
def reference_rate($rates;$m): (quote_ccy($m)|currency) as $ccy |
  $rates.venues[$m.venue][$ccy] // $rates[$ccy] // null;

def findrow($data;$key;$symbol): first($data|rows|.[]?|select(.[$key]==$symbol)) // null;
'

