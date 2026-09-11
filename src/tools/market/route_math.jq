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
# Compensated sums keep deep fills from accumulating enough error to lose a lot.
def add_fill($quantity;$value):
  ($quantity-.quantityCorrection) as $q | (.quantity+$q) as $qt |
  .quantityCorrection=(($qt-.quantity)-$q) | .quantity=$qt |
  ($value-.valueCorrection) as $v | (.value+$v) as $vt |
  .valueCorrection=(($vt-.value)-$v) | .value=$vt;
def walk_budget($levels;$budget):
  reduce $levels[] as $l ({remaining:$budget,quantity:0,value:0,quantityCorrection:0,valueCorrection:0};
    if .remaining>0 then ([.remaining,($l.price*$l.quantity)]|min) as $spend |
      add_fill($spend/$l.price;$spend) | .remaining=([$budget-.value,0]|max) else . end)
  | del(.quantityCorrection,.valueCorrection);
def walk_quantity($levels;$quantity):
  reduce $levels[] as $l ({remaining:$quantity,quantity:0,value:0,quantityCorrection:0,valueCorrection:0};
    if .remaining>0 then ([.remaining,$l.quantity]|min) as $q |
      add_fill($q;$q*$l.price) | .remaining=([$quantity-.quantity,0]|max) else . end)
  | del(.quantityCorrection,.valueCorrection);
def round_down($x;$step):
  if $step>0 then
    ($x/$step) as $lots |
    # Division can put an exact lot count just below its integer (0.043/0.001).
    # Snap only within binary64 rounding error, not a fixed quantity epsilon.
    (4*2.220446049250313e-16*($lots|fabs)) as $tolerance |
    if $tolerance>=0.5 then error("Lot count exceeds safe floating-point precision") else
      ($lots|round) as $nearest |
      (if (($lots-$nearest)|fabs)<=$tolerance then $nearest else ($lots|floor) end)*$step
    end
  else $x end;
def route_identity: {id,venue,symbol,product,quote,quotedAt} + (.routing // {});
def comparison_route_identity:
  if .chain!=null then {issuer,chain,symbol,contract}
  else {venue,symbol,product,category,assetId,pairId,dex,marketId,assetClass,settlementAsset} + (if .contractType=="inverse" then {contractType} else {} end)
    | with_entries(select(.value!=null)) end;
def ranked_routes($routes):
  # The caller already sorts by effective entry price, descending for shorts.
  # Retain the cheapest route per venue or onchain provider/chain. Equal
  # effective prices share a rank so callers do not recommend a tied route
  # as a cheaper alternative. Configuration policy belongs to the caller.
  reduce $routes[] as $route ({seen:[],price:null,rank:0,routes:[]};
    ([$route.venue,$route.product,$route.chain,$route.provider]|tojson) as $key |
    if .price!=$route.effectivePrice then .rank+=1 | .price=$route.effectivePrice else . end |
    if (.seen|index($key))!=null then . else
      .seen+=[$key] |
      .routes+=[($route|comparison_route_identity) + {costRank:.rank} +
        (if $route.chain!=null and $route.provider!=null then {provider:$route.provider} +
          ($route|{route,coverage,effectivePrice,gas,quoteType,feeEstimateSource,feeNote}|with_entries(select(.value!=null))) else {} end)]
    end) | .routes;
def comparison_result($routes;$errors):
  {bestRoute: (if ($routes|length)==0 then null else $routes[0]|comparison_route_identity end),
   rankedRoutes: ranked_routes($routes),
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
       fees:($f.value*($c.fee+$c.extraFee)),estimatedFillPrice:($f.value/$q),
       depthSlippageBps:((($f.value/$q)/$c.asks[0].price-1)*10000),
       spreadCostBps:(($c.asks[0].price-$c.bids[0].price)/($c.asks[0].price+$c.bids[0].price)*10000),effectivePrice:($total/$net),feeSource:$c.feeSource}
    end
  end;
def perpetual($c;$quantity;$direction):
  # Simulate a linear contract in underlying quantity.
  round_down($quantity;$c.step) as $q |
  if $q<=0 or (($quantity-$q)/$quantity)>1e-8 then error("Lot step prevents matching the requested quantity") else
    walk_quantity((if $direction=="short" then $c.bids else $c.asks end);$q) as $f |
    if $f.remaining>$q*1e-9 then error("Insufficient displayed depth")
    elif $q<$c.minQuantity or $f.value<$c.minValue then error("Below minimum order") else
      ($f.value*($c.fee+$c.extraFee)) as $fee |
      ($f.value+(if $direction=="short" then -$fee else $fee end)) as $total |
      ($c|route_identity)+{expectedQuantity:$q,openingValue:$f.value,fees:$fee,
        estimatedFillPrice:($f.value/$q),
        depthSlippageBps:(if $direction=="short" then (1-($f.value/$q)/$c.bids[0].price)*10000 else (($f.value/$q)/$c.asks[0].price-1)*10000 end),
        spreadCostBps:(($c.asks[0].price-$c.bids[0].price)/($c.asks[0].price+$c.bids[0].price)*10000),effectivePrice:($total/$q),feeSource:$c.feeSource}
    end
  end;

# Inverse orders are rounded in fixed quote-value contracts. Each fill level
# contributes contracts * quote value / price in base; entry price is harmonic.
def inverse_notional($c;$amount;$direction):
  round_down($amount/$c.contractValue;$c.contractStep) as $contracts |
  ($contracts*$c.contractValue) as $notional |
  if $contracts<=0 then error("Below minimum order") else
    walk_budget((if $direction=="short" then $c.bids else $c.asks end);$notional) as $f |
    if $f.remaining>$notional*1e-9 then error("Insufficient displayed depth") else
      ($notional/$f.quantity) as $price | ($c.fee+$c.extraFee) as $fee |
      ($c|route_identity)+{contracts:$contracts,expectedQuantity:$f.quantity,openingValue:$notional,
        fees:($notional*$fee),settlementFee:($f.quantity*$fee),settlementAsset:$c.settlementAsset,
        estimatedFillPrice:$price,effectivePrice:($price*(if $direction=="short" then 1-$fee else 1+$fee end)),
        depthSlippageBps:(if $direction=="short" then (1-$price/$c.bids[0].price)*10000 else ($price/$c.asks[0].price-1)*10000 end),
        spreadCostBps:(($c.asks[0].price-$c.bids[0].price)/($c.asks[0].price+$c.bids[0].price)*10000),feeSource:$c.feeSource}
    end
  end;
def perpetual_notional($c;$amount;$direction):
  if $c.inverse==true then inverse_notional($c;$amount;$direction) else
  (($c.asks[0].price+$c.bids[0].price)/2) as $mid |
  perpetual($c;round_down($amount/$mid;$c.step);$direction) end;

def live_rates($stats;$books;$now):
  [$stats|if type=="array" then .[] else empty end|select(.count>0 and (.closeTime|type)=="number" and ($now-.closeTime|fabs)<300000)|.symbol] as $active |
  [$books|if type=="array" then .[] else empty end|.symbol as $symbol|select(($active|index($symbol))!=null) |
    select((.bidPrice|n)>0 and (.askPrice|n)>0 and (.bidQty|n)>0 and (.askQty|n)>0) |
    (.bidPrice|tonumber) as $bid | (.askPrice|tonumber) as $ask |
    select($ask>=$bid and ($ask-$bid)/$bid<0.01) | {key:.symbol,value:(($bid+$ask)/2)}] | from_entries;
