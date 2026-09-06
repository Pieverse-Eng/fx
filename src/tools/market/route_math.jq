# Shared arithmetic: prices/reference FX are estimates, never order instructions.
def n: try tonumber catch null;
def pos: n | select(. != null and . > 0 and isfinite);
def nonneg: n | select(. != null and . >= 0 and isfinite);
def usd($rates;$ccy):
  ($ccy|ascii_upcase) as $c |
  if $c=="USD" then 1 else
    ($rates[($c+"USD")]|n) //
    (if $c!="USDT" then (($rates[$c+"USDT"]|n)*($rates.USDTUSD|n)) else null end)
  end | pos;
def depth($levels;$size;$exposure;$rate;$descending):
  [$levels[] | {price:((.[0]|pos)*$rate/$exposure),quantity:((.[1]|pos)*$size*$exposure)}] |
  sort_by(.price) | if $descending then reverse else . end;
def walk_budget($levels;$budget):
  reduce $levels[] as $l ({remaining:$budget,quantity:0,value:0};
    if .remaining>0 then ([.remaining,($l.price*$l.quantity)]|min) as $spend |
      .remaining-= $spend | .quantity+=($spend/$l.price) | .value+=$spend else . end);
def walk_quantity($levels;$quantity):
  reduce $levels[] as $l ({remaining:$quantity,quantity:0,value:0};
    if .remaining>0 then ([.remaining,$l.quantity]|min) as $q |
      .remaining-=$q | .quantity+=$q | .value+=($q*$l.price) else . end);
def round_down($x;$step): if $step>0 then (($x/$step)|floor)*$step else $x end;
def route_identity: {id,venue,symbol,product,quote,quotedAt} + (.routing // {});
def comparison_result($routes;$errors):
  {bestRoute: (if ($routes|length)==0 then null else $routes[0] |
    if .chain!=null then {issuer,chain,symbol,contract}
    else {venue,symbol,product,category,assetId,pairId,dex,marketId,assetClass,settlementAsset}
      | with_entries(select(.value!=null)) end end),
   gaps: ([$errors[] | ([.venue,.chain,.issuer,.symbol,.query] | map(select(.!=null and .!="")) | join(" / ")) as $context |
     (if $context=="" then .message else $context+": "+.message end)] +
     (if ($routes|length)==0 then ["No eligible route with a valid quote"]
      elif ($routes|length)==1 then ["Only one eligible route; comparative minimum not established"] else [] end) | unique)};
def spot($c;$budget):
  # Quote fees reduce spendable funds; base fees reduce received quantity.
  (if $c.feeAsset=="base" then $budget else $budget/(1+$c.fee+$c.extraFee) end) as $bookBudget |
  walk_budget($c.asks;$bookBudget) as $fill |
  if $fill.remaining > $bookBudget*1e-9 then error("Insufficient displayed depth") else
    round_down($fill.quantity;$c.step) as $q | walk_quantity($c.asks;$q) as $f |
    (if $c.feeAsset=="base" then $q*(1-$c.fee-$c.extraFee) else $q end) as $net |
    ($f.value*(if $c.feeAsset=="base" then 1 else 1+$c.fee+$c.extraFee end)) as $total |
    if $q<$c.minQuantity or $f.value<$c.minValue or $net<=0 then error("Below minimum order") else
      ($c|route_identity)+{expectedQuantity:$net,spend:$total,unspent:($budget-$total),
       fees:($f.value*($c.fee+$c.extraFee)),effectivePrice:($total/$net),feeSource:$c.feeSource}
    end
  end;
def perpetual($c;$quantity;$direction):
  # The same exposure is used across candidates; inverse contracts are excluded upstream.
  round_down($quantity;$c.step) as $q |
  if $q<=0 or (($quantity-$q)/$quantity)>1e-8 then error("Lot step prevents matching the common comparison quantity") else
    walk_quantity((if $direction=="short" then $c.bids else $c.asks end);$q) as $f |
    if $f.remaining>$q*1e-9 then error("Insufficient displayed depth")
    elif $q<$c.minQuantity or $f.value<$c.minValue then error("Below minimum order") else
      ($f.value*($c.fee+$c.extraFee)) as $fee |
      ($f.value+(if $direction=="short" then -$fee else $fee end)) as $total |
      ($c|route_identity)+{expectedQuantity:$q,openingValue:$f.value,fees:$fee,effectivePrice:($total/$q),feeSource:$c.feeSource}
    end
  end;

def live_rates($stats;$books;$now):
  [$stats|if type=="array" then .[] else empty end|select(.count>0 and (.closeTime|type)=="number" and ($now-.closeTime|fabs)<300000)|.symbol] as $active |
  [$books|if type=="array" then .[] else empty end|.symbol as $symbol|select(($active|index($symbol))!=null) |
    select((.bidPrice|n)>0 and (.askPrice|n)>0 and (.bidQty|n)>0 and (.askQty|n)>0) |
    (.bidPrice|tonumber) as $bid | (.askPrice|tonumber) as $ask |
    select($ask>=$bid and ($ask-$bid)/$bid<0.01) | {key:.symbol,value:(($bid+$ask)/2)}] | from_entries;
