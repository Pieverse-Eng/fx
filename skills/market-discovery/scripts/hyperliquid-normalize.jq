# Keep actual market identifiers and currency roles separate.
def base_matches($name):
  ($name|ascii_upcase) as $base | $base==$ticker or $base==("K"+$ticker);
def spot_matches($token):
  ($token.name|ascii_upcase) as $base |
  $base==$ticker or
  ($base==("U"+$ticker) and (($token.fullName // "")|startswith("Unit "))) or
  ($base==($ticker+"X") and (($token.fullName // "")|ascii_downcase|contains("xstock")));
($spot[0][0].tokens // []) as $tokens |
[$spot[0][0].universe[]? | . as $pair |
  [$tokens[]|select(.index==$pair.tokens[0])] as $base |
  [$tokens[]|select(.index==$pair.tokens[1])] as $quote |
  {pair:$pair,base:$base[0],quote:$quote[0]}] as $pairs |
[$perps[0][] |
  select(.asset==null or base_matches(.asset.name|split(":")|last)) |
  . as $row | [$tokens[]|select(.index==$row.collateralToken)] as $collateral |
  . + {collateral:$collateral[0]}] as $perpRows |
{venue:"hyperliquid",ticker:$ticker,currencyFilter:(if $currency=="" then null else $currency end),product:$product,
 queriedAt:$queriedAt,sources:["https://api.hyperliquid.xyz/info"],
 markets:([
   if $product!="perpetual" then $pairs[] |
     select(.base!=null and .quote!=null and spot_matches(.base)) |
     select($currency=="" or (.quote.name|ascii_upcase)==$currency) |
     {symbol:(.base.name+"/"+.quote.name),pairId:.pair.name,assetId:(10000+.pair.index),product:"spot",
      baseAsset:.base.name,baseFullName:(.base.fullName // null),quoteAsset:.quote.name,collateralAsset:null,
      szDecimals:.base.szDecimals,status:"listed"}
   else empty end
 ] + [
   $perpRows[] | select(.asset!=null and .asset.isDelisted!=true and .collateral!=null and (.assetId|type)=="number") |
   select($currency=="" or (.collateral.name|ascii_upcase)==$currency) |
   {symbol:.asset.name,dex,assetId,product:"perpetual",baseAsset:(.asset.name|split(":")|last),
    quoteAsset:null,collateralAsset:.collateral.name,szDecimals:.asset.szDecimals,maxLeverage:.asset.maxLeverage,
    onlyIsolated:(.asset.onlyIsolated // false),marginMode:(.asset.marginMode // null),status:"active"}
 ] | unique_by(.product,.assetId)),
 errors:($errors + [
   if $product!="perpetual" then $pairs[]|select(.base==null or .quote==null)|{query:"spot",message:"Unresolved pair token metadata",symbol:.pair.name} else empty end
 ] + [
   $perpRows[] | select(.asset==null or (.asset.isDelisted!=true and (.collateral==null or (.assetId|type)!="number"))) |
   {query:"perpetual",symbol:(.symbol // .asset.name),dex,message:"Exact instrument or collateral metadata is unavailable"}
 ])}
