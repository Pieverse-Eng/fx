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
  elif ($m.venue=="lighter" or $m.venue=="bitget") and $base==("1000"+$t) then 1000
  elif $m.venue=="bitget" and ($base==("1000000"+$t) or $base==("1M"+$t)) then 1000000
  else 1 end;
def quote_ccy($m): $m.quoteAsset // $m.collateralAsset // $m.settlementAsset;
def findrow($data;$key;$symbol): first($data|rows|.[]?|select(.[$key]==$symbol)) // null;
'

load_volume() {
  local m=$1
  jq -n --argjson m "$m" --slurpfile stats "$scratch_root/stats/${venue}.json" "$candle_jq"'
    $stats[0] as $s |
    if $m.venue=="aster" or $m.venue=="binance" then
      findrow($s[$m.product];"symbol";$m.symbol) | {volume:(.quoteVolume|num)}
    elif $m.venue=="bitget" then
      findrow($s[$m.category];"symbol";$m.symbol) | {volume:((.platformTurnover24h // .turnover24h)|num)}
    elif $m.venue=="gate" then
      findrow($s[$m.product];(if $m.product=="spot" then "currency_pair" else "contract" end);$m.symbol) |
      {volume:((.quote_volume // .volume_24h_quote)|num)}
    elif $m.venue=="kraken" then
      if $m.product=="spot" then
        ($s[if $m.assetClass=="tokenized_asset" then "stocks" else "spot" end]|rows) as $data |
        ($data[$m.symbol] // $data[($m.wsname|gsub("/";""))] //
          first($s.pairs[]|select(.altname==$m.symbol)|.key as $key|$data[$key])) as $row |
        {volume:(($row.v[1]|num)*($row.p[1]|num))}
      else first($s.perpetual.tickers[]?|select((.symbol|ascii_upcase)==($m.symbol|ascii_upcase))) | {volume:(.volumeQuote|num)} end
    elif $m.venue=="okx-cex" then
      findrow($s[$m.product];"instId";$m.symbol) |
      {volume:(if $m.product=="spot" then (.volCcy24h|num) else (.volCcy24h|num)*(.last|num) end),
       estimated:($m.product!="spot")}
    elif $m.venue=="lighter" then
      first((($s.order_book_details // [])+($s.spot_order_book_details // []))[]|select(.market_id==$m.marketId)) |
      {volume:(.daily_quote_token_volume|num)}
    elif $m.venue=="hyperliquid" then
      if $m.product=="spot" then
        ($s.spot) as $pair | first($pair[0].universe|to_entries[]|select(.value.name==$m.pairId)|.key) as $i |
        {volume:($pair[1][$i].dayNtlVlm|num)}
      else
        $s[$m.dex][0].universe | to_entries | map(select(.value.name==$m.symbol)) | .[0].key as $i |
        {volume:($s[$m.dex][1][$i].dayNtlVlm|num)}
      end
    else {volume:null} end' 2>/dev/null || echo '{"volume":null}'
}

fetch_volumes() {
  local candidates=$1 name dex
  mkdir "$scratch_root/stats"
  pids=()
  market_launch "$scratch_root/stats/aster-perpetual.json" curl -fsS --max-time 20 'https://fapi.asterdex.com/fapi/v1/ticker/24hr'
  market_launch "$scratch_root/stats/binance-spot.json" curl -fsS --max-time 20 'https://api.binance.com/api/v3/ticker/24hr'
  market_launch "$scratch_root/stats/binance-perpetual.json" curl -fsS --max-time 20 'https://fapi.binance.com/fapi/v1/ticker/24hr'
  for name in SPOT USDT-FUTURES USDC-FUTURES; do market_launch "$scratch_root/stats/bitget-$name.json" bgc market --action tickers --category "$name"; done
  market_launch "$scratch_root/stats/gate-spot.json" gate-cli cex spot market tickers --format json
  market_launch "$scratch_root/stats/gate-perpetual.json" gate-cli cex futures market tickers --settle usdt --format json
  local spot_pairs stock_pairs
  spot_pairs=$(jq -nr --slurpfile c "$candidates" --slurpfile pairs "$scratch_root/kraken/pairs-original.json" "$candle_jq"'
    [$c[0][]|quote_ccy(.)]|unique as $quotes |
    ([$pairs[0][]|(.wsname|split("/")) as $pair|select($pair[1]=="USD" and ($quotes|index($pair[0]))!=null)|.altname] +
     [$c[0][]|select(.venue=="kraken" and .product=="spot" and .assetClass!="tokenized_asset")|.symbol])|unique|join(",")')
  stock_pairs=$(jq -r '[.[]|select(.venue=="kraken" and .product=="spot" and .assetClass=="tokenized_asset")|.symbol]|unique|join(",")' "$candidates")
  if [[ -n $spot_pairs ]]; then market_launch "$scratch_root/stats/kraken-spot.json" kraken ticker "$spot_pairs" -o json
  else echo '{}' >"$scratch_root/stats/kraken-spot.json"; fi
  if [[ -n $stock_pairs ]]; then market_launch "$scratch_root/stats/kraken-stocks.json" kraken ticker "$stock_pairs" --asset-class tokenized_asset -o json
  else echo '{}' >"$scratch_root/stats/kraken-stocks.json"; fi
  market_launch "$scratch_root/stats/kraken-perpetual.json" kraken futures tickers -o json
  market_launch "$scratch_root/stats/okx-cex-spot.json" okx market tickers SPOT --site global --json
  market_launch "$scratch_root/stats/okx-cex-perpetual.json" okx market tickers SWAP --site global --json
  market_launch "$scratch_root/stats/lighter.json" curl -fsS --max-time 20 'https://mainnet.zklighter.elliot.ai/api/v1/orderBookDetails'
  market_launch "$scratch_root/stats/hyperliquid-spot.json" purr hyperliquid markets --kind spot
  while IFS= read -r dex; do
    # DEX names also become local filenames; reject path separators.
    [[ $dex =~ ^[A-Za-z0-9_-]+$ ]] || continue
    market_launch "$scratch_root/stats/hyperliquid-$dex.json" purr hyperliquid markets --kind perp --dex "$dex"
  done < <(jq -r '[.[]|select(.venue=="hyperliquid" and .product=="perpetual")|.dex]|unique[]' "$candidates")
  wait_queries
  for venue in aster binance bitget gate kraken okx-cex hyperliquid; do
    for name in "$scratch_root/stats/$venue-"*.json; do
      [[ -f $name ]] || continue
      jq -c --arg key "${name##*/$venue-}" '{key:($key|sub(".json$";"")),value:.}' "$name" >>"$scratch_root/stats/$venue.parts"
    done
    jq -s 'from_entries' "$scratch_root/stats/$venue.parts" >"$scratch_root/stats/$venue.json"
  done
  # Preserve original Kraken response keys for matching and live currency conversion.
  jq '[to_entries[]|.key as $key|.value+{key:$key}]' "$scratch_root/kraken/pairs-original.json" >"$scratch_root/stats/kraken-pairs.json" 2>/dev/null || echo '[]' >"$scratch_root/stats/kraken-pairs.json"
  # Cached catalog hits also retain raw data; use the original API key from wsname if unavailable.
  jq --slurpfile pairs "$scratch_root/stats/kraken-pairs.json" '.+{pairs:$pairs[0]}' "$scratch_root/stats/kraken.json" >"$scratch_root/stats/kraken.tmp"
  mv "$scratch_root/stats/kraken.tmp" "$scratch_root/stats/kraken.json"
}

fetch_candle() {
  local m=$1 tf=$2 file=$3 now=$4 seconds interval symbol product kind
  symbol=$(jq -r '.symbol' <<<"$m"); product=$(jq -r '.product' <<<"$m")
  seconds=900; [[ $tf != 1h ]] || seconds=3600; [[ $tf != 4h ]] || seconds=14400
  interval=$tf; [[ $tf != 1h ]] || interval=1H; [[ $tf != 4h ]] || interval=4H
  local start=$((now/1000-seconds*200))
  case $(jq -r '.venue' <<<"$m") in
    aster) market_read "$file" curl -fsS --max-time 20 --get 'https://fapi.asterdex.com/fapi/v1/klines' --data-urlencode "symbol=$symbol" --data-urlencode "interval=$tf" --data-urlencode 'limit=51' ;;
    binance)
      if [[ $product == spot ]]; then kind=spot; else kind=perp; fi
      local url='https://api.binance.com/api/v3/klines'; [[ $kind != perp ]] || url='https://fapi.binance.com/fapi/v1/klines'
      market_read "$file" curl -fsS --max-time 20 --get "$url" --data-urlencode "symbol=$symbol" --data-urlencode "interval=$tf" --data-urlencode 'limit=51' ;;
    bitget) market_read "$file" bgc market --action candles --category "$(jq -r '.category' <<<"$m")" --symbol "$symbol" --interval "$interval" --limit 51 ;;
    gate)
      if [[ $product == spot ]]; then
        market_read "$file" gate-cli cex spot market candlesticks --pair "$symbol" --interval "$tf" --limit 51 --format json
      else market_read "$file" gate-cli cex futures market candlesticks --contract "$symbol" --settle usdt --interval "$tf" --limit 51 --format json; fi ;;
    kraken)
      if [[ $product == spot ]]; then
        local opts=(); [[ $(jq -r '.assetClass' <<<"$m") != tokenized_asset ]] || opts=(--asset-class tokenized_asset)
        market_read "$file" kraken ohlc "$symbol" --interval "$((seconds/60))" "${opts[@]}" -o json
      else market_read "$file" curl -fsS --max-time 20 "https://futures.kraken.com/api/charts/v1/trade/$symbol/$tf?count=51"; fi ;;
    hyperliquid)
      [[ $product != spot ]] || symbol=$(jq -r '.pairId' <<<"$m")
      market_read "$file" purr hyperliquid candles --coin "$symbol" --interval "$tf" --start-time "$((start*1000))" --end-time "$now" ;;
    lighter) market_read "$file" curl -fsS --max-time 20 --get 'https://mainnet.zklighter.elliot.ai/api/v1/candles' --data-urlencode "market_id=$(jq -r '.marketId' <<<"$m")" --data-urlencode "resolution=$tf" --data-urlencode "start_timestamp=$start" --data-urlencode "end_timestamp=$((now/1000))" --data-urlencode 'count_back=51' ;;
    okx-cex) market_read "$file" okx market candles "$symbol" --bar "$interval" --limit 51 --site global --json ;;
  esac
}

fetch_last_trade() {
  local m=$1 file=$2 symbol product venue
  symbol=$(jq -r '.symbol' <<<"$m"); product=$(jq -r '.product' <<<"$m"); venue=$(jq -r '.venue' <<<"$m")
  case $venue in
    aster) market_read "$file" curl -fsS --max-time 20 --get 'https://fapi.asterdex.com/fapi/v1/trades' --data-urlencode "symbol=$symbol" --data-urlencode 'limit=1' ;;
    binance)
      local url='https://api.binance.com/api/v3/trades'; [[ $product == spot ]] || url='https://fapi.binance.com/fapi/v1/trades'
      market_read "$file" curl -fsS --max-time 20 --get "$url" --data-urlencode "symbol=$symbol" --data-urlencode 'limit=1' ;;
    bitget) market_read "$file" bgc market --action recentFills --category "$(jq -r '.category' <<<"$m")" --symbol "$symbol" --limit 1 ;;
    gate)
      local url='https://api.gateio.ws/api/v4/spot/trades' key=currency_pair
      [[ $product == spot ]] || { url='https://api.gateio.ws/api/v4/futures/usdt/trades'; key=contract; }
      market_read "$file" curl -fsS --max-time 20 --get "$url" --data-urlencode "$key=$symbol" --data-urlencode 'limit=1' ;;
    kraken)
      if [[ $product == spot ]]; then
        local opts=(); [[ $(jq -r '.assetClass' <<<"$m") != tokenized_asset ]] || opts=(--data-urlencode asset_class=tokenized_asset)
        market_read "$file" curl -fsS --max-time 20 --get 'https://api.kraken.com/0/public/Trades' --data-urlencode "pair=$symbol" --data-urlencode count=1 "${opts[@]}"
      else market_read "$file" kraken futures ticker "$symbol" -o json; fi ;;
    hyperliquid)
      [[ $product != spot ]] || symbol=$(jq -r '.pairId' <<<"$m")
      market_read "$file" curl -fsS --max-time 20 -H 'Content-Type: application/json' -d "$(jq -cn --arg coin "$symbol" '{type:"recentTrades",coin:$coin}')" 'https://api.hyperliquid.xyz/info' ;;
    lighter) market_read "$file" curl -fsS --max-time 20 --get 'https://mainnet.zklighter.elliot.ai/api/v1/recentTrades' --data-urlencode "market_id=$(jq -r '.marketId' <<<"$m")" --data-urlencode limit=1 ;;
    okx-cex) market_read "$file" okx market trades "$symbol" --limit 1 --site global --json ;;
  esac
}

normalize_candles() {
  local m=$1 tf=$2 file=$3 now=$4 duration=900000
  [[ $tf != 1h ]] || duration=3600000; [[ $tf != 4h ]] || duration=14400000
  jq --argjson m "$m" --argjson now "$now" --argjson duration "$duration" "$candle_jq"'
    def entry($row;$confirmed): {row:$row,confirmed:$confirmed};
    if .==null then error("query failed") else . end |
    (if $m.venue=="aster" or $m.venue=="binance" then
       if type!="array" then error("invalid kline response") else map(entry([.[0],.[1],.[2],.[3],.[4],.[5]];null)) end
     elif $m.venue=="bitget" then .data | map(entry(.[0:6];null))
     elif $m.venue=="okx-cex" then rows | map(entry([.[0],.[1],.[2],.[3],.[4],(if $m.product=="spot" then .[5] else .[6] end)];(.[8]=="1")))
     elif $m.venue=="gate" then
       if $m.product=="spot" then map(entry([(.[0]|num)*1000,.[5],.[3],.[4],.[2],.[6]];(if .[7]!=null then (.[7]=="true" or .[7]==true) else null end)))
       else map(entry([(.t|num)*1000,.o,.h,.l,.c,(if ($m.contractSize|positive)!=null then (.v|num)*($m.contractSize|num) else null end)];null)) end
     elif $m.venue=="kraken" then
       if $m.product=="spot" then rows | [to_entries[]|select(.key!="last")|.value[]|entry([(.[0]|num)*1000,.[1],.[2],.[3],.[4],.[6]];null)]
       else .candles | map(entry([.time,.open,.high,.low,.close,(if ($m.symbol|startswith("PF_")) then .volume else null end)];null)) end
     elif $m.venue=="hyperliquid" then map(entry([.t,.o,.h,.l,.c,.v];null))
     elif $m.venue=="lighter" then if .code!=200 then error("invalid candles") else .c | map(entry([.t,.o,.h,.l,.c,.v];null)) end
     else error("unsupported venue") end) |
    if type!="array" or length==0 then error("no candles returned") else . end |
    map(.row |= map(if .==null then null else num end)) |
    if any(.[]; (.row|length)!=6 or any(.row[0:5][];.==null or (isfinite|not) or .<=0) or
       (.row[2]<([.row[1],.row[3],.row[4]]|max)) or (.row[3]>([.row[1],.row[2],.row[4]]|min)) or
       (.row[5]!=null and ((.row[5]|isfinite|not) or .row[5]<0))) then error("invalid OHLCV values") else . end |
    map(select(.row[0]<=$now)) | sort_by(.row[0]) | unique_by(.row[0]) |
    map(.row |= [.[0],(.[1]/exposure($m)),(.[2]/exposure($m)),(.[3]/exposure($m)),(.[4]/exposure($m)),(if .[5]==null then null else .[5]*exposure($m) end)]) |
    {closed:([.[]|select(.row[0]+$duration<=$now and .confirmed!=false)|.row]|.[-50:]),
     current:([.[]|select(.row[0]<=$now and .row[0]+$duration>$now and .confirmed!=true)|.row]|last // null)} |
    if (.closed|length)==0 then error("no closed candles") else . end' "$file"
}

normalize_trade() {
  local m=$1 file=$2 now=$3
  jq --argjson m "$m" --argjson now "$now" "$candle_jq"'
    (if $m.venue=="aster" or $m.venue=="binance" then map({price,time})
     elif $m.venue=="bitget" then .data|map({price,time:.ts})
     elif $m.venue=="gate" then map({price,time:(if .create_time_ms then (.create_time_ms|num) else (.create_time|num)*1000 end)})
     elif $m.venue=="kraken" then
       if $m.product=="spot" then .result|[to_entries[]|select(.key!="last")|.value[]|{price:.[0],time:((.[2]|num)*1000|floor)}]
       else [.ticker|{price:.last,time:(.lastTime|iso_ms)}] end
     elif $m.venue=="hyperliquid" then map({price:.px,time})
     elif $m.venue=="lighter" then .trades|map({price,time:.timestamp})
     elif $m.venue=="okx-cex" then rows|map({price:.px,time:.ts})
     else [] end) |
    map({price:((.price|num)/exposure($m)),time:(.time|num)}) |
    map(select(.price!=null and .price>0 and (.price|isfinite) and .time!=null and .time>0 and .time<=$now)) |
    max_by(.time) // null' "$file" 2>/dev/null || echo null
}

candle_asset() (
  local ticker=$1 rank_file=$2 dir="$scratch_root/candles-$1" m attempt=0 best_count=-1 best_dir='' count tf now
  mkdir "$dir"
  pids=()
  trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; exit 130' INT TERM
  while IFS= read -r m; do
    attempt=$((attempt+1)); local trial="$dir/$attempt"; mkdir "$trial"
    now=$(date +%s%3N)
    pids=()
    for tf in 15m 1h 4h; do fetch_candle "$m" "$tf" "$trial/$tf.raw.json" "$now" & pids+=("$!"); done
    fetch_last_trade "$m" "$trial/trade.json" & pids+=("$!")
    wait_queries
    now=$(date +%s%3N)
    : >"$trial/errors.jsonl"; count=0
    for tf in 15m 1h 4h; do
      if normalize_candles "$m" "$tf" "$trial/$tf.raw.json" "$now" >"$trial/$tf.json" 2>"$trial/$tf.error"; then count=$((count+1))
      else
        echo null >"$trial/$tf.json"
        jq -cn --arg ticker "$ticker" --arg timeframe "$tf" '{ticker:$ticker,timeframe:$timeframe,message:"Candle data unavailable or invalid"}' >>"$trial/errors.jsonl"
      fi
    done
    normalize_trade "$m" "$trial/trade.json" "$now" >"$trial/last.json"
    if [[ $(cat "$trial/last.json") == null ]]; then
      jq -cn --arg ticker "$ticker" '{ticker:$ticker,query:"lastTrade",message:"Latest trade price and timestamp unavailable"}' >>"$trial/errors.jsonl"
    elif jq -e --argjson now "$now" '$now-.time>86400000' "$trial/last.json" >/dev/null; then
      jq -cn --arg ticker "$ticker" '{ticker:$ticker,query:"lastTrade",message:"Latest available trade is more than 24 hours old"}' >>"$trial/errors.jsonl"
    fi
    jq -n --arg ticker "$ticker" --argjson now "$now" --argjson m "$m" \
      --slurpfile m15 "$trial/15m.json" --slurpfile h1 "$trial/1h.json" --slurpfile h4 "$trial/4h.json" --slurpfile last "$trial/last.json" --slurpfile errors "$trial/errors.jsonl" "$candle_jq"'
      {result:{ticker:$ticker,quote:quote_ccy($m),asOf:$now,lastTrade:$last[0],timeframes:{"15m":$m15[0],"1h":$h1[0],"4h":$h4[0]}},errors:$errors}' >"$trial/result.json"
    jq -cn --argjson m "$m" --argjson now "$now" --argjson count "$count" '{ticker:$m.ticker,venue:$m.venue,symbol:$m.symbol,product:$m.product,quote:($m.quoteAsset // $m.collateralAsset // $m.settlementAsset),volumeUSD:$m.volumeUSD,volumeEstimated:($m.volumeEstimated // false),exposureMultiplier:($m.exposureMultiplier // 1),time:$now,usableTimeframes:$count}' >>"$dir/sources.jsonl"
    if (( count>best_count )); then best_count=$count; best_dir=$trial; fi
    (( count<3 )) || break
  done < <(jq -c --arg ticker "$ticker" '[.[]|select(.ticker==$ticker)]|sort_by([(-.volumeUSD),.venue,.product,.symbol])[]' "$rank_file")
  if [[ -n $best_dir ]]; then cp "$best_dir/result.json" "$dir/result.json"
  else
    jq -n --arg ticker "$ticker" --argjson now "$(date +%s%3N)" '{result:{ticker:$ticker,quote:null,asOf:$now,lastTrade:null,timeframes:{"15m":null,"1h":null,"4h":null}},errors:[{ticker:$ticker,query:"candles",message:"No reference market with usable candles and comparable volume"}]}' >"$dir/result.json"
  fi
  if [[ -n $cache_dir && -f $dir/sources.jsonl ]]; then cp "$dir/sources.jsonl" "$cache_dir/candle-source-$ticker.jsonl"; fi
)

run_candles() {
  local candidates="$scratch_root/candidates.json" m rate volume ticker venue
  jq -s '[.[]|.venue as $venue|.results[]|.ticker as $ticker|.markets[]|.+{venue:$venue,ticker:$ticker}]' "$@" >"$candidates"
  jq -s '[.[]|.venue as $venue|.errors[]|.+{venue:$venue,query:("discovery:"+.query)}]' "$@" >"$scratch_root/candle-errors.json"
  fetch_volumes "$candidates"
  # Rates are observed public prices, never hardcoded stablecoin parity.
  jq -n --slurpfile pairs "$scratch_root/stats/kraken-pairs.json" --slurpfile kr "$scratch_root/stats/kraken-spot.json" --slurpfile bn "$scratch_root/stats/binance-spot.json" "$candle_jq"'
    ($kr[0]|rows) as $k |
    reduce ($pairs[0][]|select((.wsname|split("/")[1])=="USD")) as $p ({USD:1};
      ($k[$p.key].c[0]|positive) as $rate | if $rate then .[($p.wsname|split("/")[0])]= $rate else . end) |
    . as $direct |
    reduce ($bn[0][]?|select(.symbol|endswith("USDT"))) as $p ($direct;
      if $direct.USDT!=null and ($p.lastPrice|positive)!=null then .[($p.symbol|rtrimstr("USDT"))]=($p.lastPrice|num)*$direct.USDT else . end)
  ' >"$scratch_root/rates.json" 2>/dev/null || echo '{"USD":1}' >"$scratch_root/rates.json"
  : >"$scratch_root/ranked.jsonl"; : >"$scratch_root/rank-errors.jsonl"
  while IFS= read -r m; do
    venue=$(jq -r '.venue' <<<"$m"); ticker=$(jq -r '.ticker' <<<"$m")
    volume=$(load_volume "$m")
    [[ -n $volume ]] || volume='{"volume":null}'
    rate=$(jq -r --argjson m "$m" "$candle_jq"' .[quote_ccy($m)] // null' "$scratch_root/rates.json")
    if jq -ne --argjson v "$volume" --argjson rate "$rate" '($v.volume|type)=="number" and $v.volume>=0 and ($v.volume|isfinite) and ($rate|type)=="number" and $rate>0' >/dev/null; then
      jq -cn --argjson m "$m" --argjson v "$volume" --argjson rate "$rate" "$candle_jq"'$m+{volumeUSD:($v.volume*$rate),volumeEstimated:($v.estimated // false),exposureMultiplier:exposure($m)}' >>"$scratch_root/ranked.jsonl"
    else
      jq -cn --arg ticker "$ticker" --arg venue "$venue" '{ticker:$ticker,venue:$venue,query:"volume",message:"Some markets excluded: 24h volume or quote conversion unavailable"}' >>"$scratch_root/rank-errors.jsonl"
    fi
  done < <(jq -c '.[]' "$candidates")
  jq -s '.' "$scratch_root/ranked.jsonl" >"$scratch_root/ranked.json"
  workers=()
  for ticker in "${tickers[@]}"; do candle_asset "$ticker" "$scratch_root/ranked.json" & workers+=("$!"); done
  local index
  for index in "${!workers[@]}"; do
    ticker=${tickers[$index]}
    if ! wait "${workers[$index]}"; then
      jq -n --arg ticker "$ticker" '{result:{ticker:$ticker,quote:null,asOf:null,lastTrade:null,timeframes:{"15m":null,"1h":null,"4h":null}},errors:[{ticker:$ticker,query:"candles",message:"Candle worker failed"}]}' >"$scratch_root/candles-$ticker/result.json"
    fi
  done
  workers=()
  local files=(); for ticker in "${tickers[@]}"; do files+=("$scratch_root/candles-$ticker/result.json"); done
  jq -sc --slurpfile discovery "$scratch_root/candle-errors.json" --slurpfile rank "$scratch_root/rank-errors.jsonl" '
    {columns:["openTime","open","high","low","close","volume"],results:map(.result),errors:([.[].errors[]]+$discovery[0]+($rank|unique_by(.ticker,.venue)))}' "${files[@]}"
}
