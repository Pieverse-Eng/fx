# Keep exchange-native units. A percentage, ratio and cash funding payment are
# different quantities; unknown interval/units must not become zero or 8 hours.
def observation($value;$unit;$source):
  {value:($value|n),unit:$unit,source:$source} |
  .status=(if .value==null then "unknown" else "available" end);
# Kraken analytics supplies paired timestamp and OHLC arrays. Use the latest
# published relative-rate close, never cash funding divided by today's mark.
def kraken_relative_funding($f;$now):
  ((try (
    ($now|fromdateiso8601|.*1000) as $clock |
    $f.result as $r |
    if $f.errors!=[] or ($r.timestamp|type)!="array" or
      ($r.data.relativeRate|type)!="array" or
      ($r.timestamp|length)!=($r.data.relativeRate|length) then null else
      [$r.timestamp|to_entries[]|{time:(.value|n),ohlc:$r.data.relativeRate[.key]}] |
      sort_by(.time) | last |
      select(.time!=null and .time<=$clock and .time>=$clock-7200000) |
      select((.ohlc|type)=="array" and (.ohlc|length)==4) |
      {value:(.ohlc[3]|n),sourceTime:.time}
    end
  ) catch null)//null) as $v |
  observation($v.value;"ratio";"/api/charts/v1/analytics/{symbol}/funding relativeRate close") +
    {intervalHours:1,kind:"current",sourceTime:$v.sourceTime};
def native_book($m;$raw):
  ($raw|if type=="array" then . elif .result=="success" then . else rows end) as $b |
  if $m.venue=="hyperliquid" then {asks:[$b.levels[1][]|[.px,.sz]],bids:[$b.levels[0][]|[.px,.sz]]}
  elif $m.venue=="orderly" then {asks:[$b.asks[]|[.price,.quantity]],bids:[$b.bids[]|[.price,.quantity]]}
  elif $m.venue=="lighter" then {asks:[$b.asks[]|[.price,.remaining_base_amount]],bids:[$b.bids[]|[.price,.remaining_base_amount]]}
  elif $m.venue=="gate" and $m.product!="spot" then {asks:[$b.asks[]|[.p,.s]],bids:[$b.bids[]|[.p,.s]]}
  elif $m.venue=="kraken" and $m.product=="spot" then $b|to_entries[0].value
  elif $m.venue=="kraken" then $b.orderBook
  elif $m.venue=="okx-cex" then $b[0]
  elif $m.venue=="bitget" then {asks:$b.a,bids:$b.b}
  else $b end;
def book_summary($book):
  ($book.bids[0].price//null) as $bid | ($book.asks[0].price//null) as $ask |
  {status:(if $bid==null and $ask==null then "empty" elif $bid==null or $ask==null then "one_sided" elif $bid>$ask then "crossed" else "available" end),
   bestBid:$bid,bestAsk:$ask,
   spreadBps:(if $bid!=null and $ask!=null then ($ask-$bid)/(($ask+$bid)/2)*10000 else null end),
   bidDepth1Pct:([$book.bids[]|select(.price >= $bid*0.99)|.price*.quantity]|add//0),
   askDepth1Pct:([$book.asks[]|select(.price <= $ask*1.01)|.price*.quantity]|add//0),
   bidLevels:($book.bids|length),askLevels:($book.asks|length),
   bidBandComplete:(($book.bids|length)==0 or $book.bids[-1].price < $bid*0.99),
   askBandComplete:(($book.asks|length)==0 or $book.asks[-1].price > $ask*1.01),
   coverage:"returned_levels_only; depth amounts are in quoteCurrency"};
def snapshot($m;$raw;$f;$o;$meta;$size;$unsupported;$now):
  (if $m.venue=="okx-cex" and ($f|type)!="array" then []
   elif $m.venue=="bitget" and ($f.data|type)!="array" then {} else $f end) as $f |
  (if $m.venue=="okx-cex" and ($o|type)!="array" then [] else $o end) as $o |
  (quote_ccy($m)) as $quote |
  kraken_inverse($m) as $inverse |
  ((try (if $unsupported or $size==null or $size<=0 then error("Unknown contract units") else
    native_book($m;$raw) | if (.asks|type)!="array" or (.bids|type)!="array" or
      (all((.asks+.bids)[]; (.[0]|n)!=null and (.[0]|n)>0 and (.[1]|n)!=null and (.[1]|n)>=0)|not)
      then error("Malformed book") else . end |
    (if $inverse then {asks:[.asks[]|[.[0],((.[1]|n)/(.[0]|n))]],bids:[.bids[]|[.[0],((.[1]|n)/(.[0]|n))]]} else . end) |
    {asks:depth(.asks;$size;1;1;false),bids:depth(.bids;$size;1;1;true)} end) catch null)//null) as $book |
  (if $m.venue=="hyperliquid" then
     (try ([$meta[0].universe|to_entries[]|select(.value.name==$m.symbol)|.key][0]) catch null) as $i |
     if $i==null then {} else $meta[1][$i] end
   elif $m.venue=="kraken" then ([$meta.tickers[]?|select(.symbol==$m.symbol)][0]//{})
   elif $m.venue=="bitget" then (try $meta.data[0] catch null)//{}
   elif $m.venue=="okx-cex" then (try $meta[0] catch null)//{}
   elif $m.venue=="lighter" then ([$o.order_book_details[]?|select(.market_id==$m.marketId)][0]//{})
   else $meta end) as $ctx |
  (if $m.product=="spot" then {status:"not_applicable"}
   elif $m.venue=="orderly" then observation($ctx.est_funding_rate;"ratio";"/v1/public/futures") +
     {kind:"estimated",lastSettledRate:($ctx.last_funding_rate|n),intervalHours:($m.funding_period|n),nextSettlementTime:($ctx.next_funding_time|n)}
   elif $m.venue=="bitget" then ($f.data[0]//{}) as $v |
     observation($v.fundingRate;"ratio";"current-fund-rate") + {intervalHours:($v.fundingRateInterval|n),nextSettlementTime:($v.nextUpdate|n)}
   elif $m.venue=="gate" then observation($ctx.funding_rate;"ratio";"contracts") +
     {intervalHours:(if ($ctx.funding_interval|n)!=null then ($ctx.funding_interval|n)/3600 else null end),nextSettlementTime:(if ($ctx.funding_next_apply|n)!=null then ($ctx.funding_next_apply|n)*1000 else null end)}
   elif $m.venue=="hyperliquid" then observation($ctx.funding;"ratio";"metaAndAssetCtxs") + {intervalHours:1}
   elif $m.venue=="lighter" then ([$f.funding_rates[]?|select(.exchange=="lighter" and .market_id==$m.marketId)][0]//{}) as $v |
     # The comparison endpoint reports an eight-hour ratio; settlement is hourly.
     observation((if ($v.rate|n)!=null then ($v.rate|n)/8 else null end);"ratio";"funding-rates") +
       {intervalHours:1,settlementIntervalHours:1,kind:"estimated"}
   elif $m.venue=="kraken" and (($m.symbol|ascii_downcase|startswith("pf_")) or $inverse) then kraken_relative_funding($f;$now)
   elif $m.venue=="kraken" then observation($ctx.fundingRate;"provider_native";"tickers") +
     {prediction:($ctx.fundingRatePrediction|n),intervalHours:null,reason:"Cash funding rate depends on contract specification; not a percentage"}
   elif $m.venue=="okx-cex" then ($f[0]//{}) as $v |
     observation($v.fundingRate;"ratio";"funding-rate") + {intervalHours:(if ($v.fundingTime|n)!=null and ($v.nextFundingTime|n)!=null then (($v.nextFundingTime|n)-($v.fundingTime|n))/3600000 else null end),nextSettlementTime:($v.fundingTime|n)}
   else observation($f.lastFundingRate;"ratio";"premiumIndex") + {intervalHours:((try ([$meta[]|select(.symbol==$m.symbol)|.fundingIntervalHours][0]|n) catch null) // (if $m.venue=="binance" and ($meta|type)=="array" then 8 else null end)),nextSettlementTime:($f.nextFundingTime|n)} end) as $funding |
  (if $m.product=="spot" then {status:"not_applicable"}
   elif $m.venue=="orderly" then observation($ctx.open_interest;"base";"/v1/public/futures")
   elif $m.venue=="bitget" then observation($o.data.openInterestList[0].size;"base";"open-interest")
   elif $m.venue=="gate" then observation($ctx.position_size;"contracts";"contracts") + {contractMultiplier:$size}
   elif $m.venue=="hyperliquid" then observation($ctx.openInterest;"base";"metaAndAssetCtxs")
   elif $m.venue=="lighter" then observation($ctx.open_interest;"base";"orderBookDetails") + {basis:"single_sided"}
   elif $m.venue=="kraken" then observation($ctx.openInterest;(if $unsupported or $inverse then "contracts" else "base" end);"tickers") +
     (if $inverse then {contractMultiplier:$size,quoteValue:(if ($ctx.openInterest|n)!=null then ($ctx.openInterest|n)*$size else null end),quoteCurrency:$quote} else {} end)
   elif $m.venue=="okx-cex" then observation($o[0].oi;"contracts";"open-interest") + {baseAmount:($o[0].oiCcy|n),usdValue:($o[0].oiUsd|n)}
   else observation($o.openInterest;"base";"openInterest") end) as $oi |
  ($m|comparison_route_identity) + (if $inverse then {contractType:"inverse",settlementAsset:$m.baseAsset,contractValue:$size,contractValueCurrency:$quote} else {} end) + {observedAt:$now,marketStatus:($m.status//"unknown"),quoteCurrency:$quote,
    nativeBaseAsset:$m.baseAsset,underlying:$m.ticker,exposureMultiplier:exposure($m),
    product:(if $m.product=="perpetual" then "perp" else $m.product end),
    funding:($funding + (if $funding.unit=="ratio" then {positiveRatePays:"long_to_short"} else {} end)),openInterest:$oi,
    markPrice:(try (if $m.venue=="aster" or $m.venue=="binance" then $f.markPrice
      elif $m.venue=="bitget" then $ctx.markPrice
      elif $m.venue=="okx-cex" then $ctx.markPx
      elif $m.venue=="hyperliquid" then $ctx.markPx
      elif $m.venue=="kraken" then $ctx.markPrice else $ctx.mark_price end|n) catch null),
    book:(if $book==null then {status:"unknown",reason:"Book query failed or contract units are unverified"} else book_summary($book) + {
      sourceTime:(try (if ($raw|type)=="array" then $raw[0].ts else $raw.ts // $raw.time // $raw.data.ts // null end) catch null)
    } end),
    gaps:([if $funding.status=="unknown" then "Funding unavailable" else empty end,
           if $oi.status=="unknown" then "Open interest unavailable" else empty end,
           if $book==null then "Depth unavailable" else empty end]),nativeBook:$book} |
  (if $m.venue=="orderly" then . + {indexPrice:($ctx.index_price|n),volume24h:observation($ctx["24h_amount"];$quote;"/v1/public/futures")} else . end) |
  if .openInterest.status=="available" and .markPrice!=null then
    (if .openInterest.unit=="base" then .openInterest.value
     elif $inverse then .openInterest.quoteValue/.markPrice
     elif .openInterest.unit=="contracts" and $unsupported==false and .openInterest.contractMultiplier!=null then .openInterest.value*.openInterest.contractMultiplier
     else null end) as $base |
    if $base!=null then .openInterest += {baseAmount:$base,quoteValue:($base*.markPrice),quoteCurrency:$quote} else . end
  else . end;

# Size-specific displayed liquidity does not depend on fee or account eligibility.
# This continuous-quantity estimate is separate from lot-rounded entry routing.
def displayed_fill($s;$input;$rates):
  (if $input.amount==null then null else
    try (
      (if $s.quoteCurrency==($input.currency//"USDT") then 1
       else usd($rates;($input.currency//"USDT"))/usd($rates;$s.quoteCurrency) end) as $fx |
      ($s.nativeBook) as $b |
      if $s.book.status!="available" then error("A valid two-sided book is required") else
        (($input.amount|n)*$fx) as $budget |
        (($b.asks[0].price+$b.bids[0].price)/2) as $mid |
        (if $input.product=="spot" or $s.contractType=="inverse" then walk_budget((if $input.direction=="short" then $b.bids else $b.asks end);$budget)
         else walk_quantity((if $input.direction=="short" then $b.bids else $b.asks end);$budget/$mid) end) as $fill |
        (if $input.direction=="short" then $b.bids[0].price else $b.asks[0].price end) as $best |
        {status:"available",basis:"displayed_book_before_fees_and_order_constraints",direction:($input.direction//"buy"),
         requestedNotional:($input.amount|n),referenceCurrency:($input.currency//"USDT"),quoteCurrency:$s.quoteCurrency,
         quantityUnit:"native_base",filledQuantity:$fill.quantity,
         fullyFillable:($fill.remaining <= (if $input.product=="spot" or $s.contractType=="inverse" then $budget else $budget/$mid end)*1e-9),
         averageFillPrice:(if $fill.quantity>0 then $fill.value/$fill.quantity else null end),
         depthSlippageBps:(if $fill.quantity<=0 then null elif $input.direction=="short" then (1-$fill.value/$fill.quantity/$best)*10000 else ($fill.value/$fill.quantity/$best-1)*10000 end)}
      end
    ) catch {status:"unknown",reason:.}
  end)//{status:"unknown",reason:"Quote currency conversion unavailable"};
