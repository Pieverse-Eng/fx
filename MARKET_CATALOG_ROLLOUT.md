# Pieverse shared market catalog rollout

PR 43 changes the directory authority for `discover_markets`, `get_market_candles`
and `compare_trade_routes`. It does not change account/order permissions, prices,
fees or live native rules. FX remains a public fork of `vercel-labs/fx`.

## Merge and artifact delivery

1. Require the four platform aggregates from **Full CI at the exact commit**,
   including the native suite, registered-tool fixtures and each platform's four
   E2E shards. Merge alone does not install a binary anywhere.
2. Use **Prepare Release** to produce a reviewed version/changelog PR. Keep the
   fork version/tag under Pieverse ownership; do not publish the inherited
   `0.0.9` automatically merely because its tag is absent.
3. Release on a fork requires an explicit workflow dispatch. First run
   `validate_only=true`; then, after signing/release environments and artifacts
   are accepted, dispatch `publish_fork=true`. Publishing goes to this fork's
   GitHub Releases. Its workflow cannot write the upstream CDN or latest pointer.
   The ancillary dev-release and CDN-backfill workflows are upstream-only too;
   a fork main merge does not activate those publication channels.
4. Operators install the matching `fx-<platform>.tar.gz` from the exact
   `Pieverse-Eng/fx` release, verify its attached `.sha256`, and pin that release
   and checksum in the consuming image/configuration. Identify the actual FX
   consumer before updating it: the platform repository currently has no FX
   binary installation in its Dockerfiles. Do not assume an Agent image already
   contains this fork.
5. Verify the installed binary's version and drive all three registered tools
   on that actual runtime. `fx.sh/setup.sh` and `fx upgrade` still use the upstream
   `releases.fx.sh` channel. They do not deliver this fork; operators must use the
   pinned fork artifact for subsequent updates too. A managed fork updater/CDN
   is a separate delivery change, not implied by this PR.

## Directory activation

Publish and verify the platform directory first. Check complete venue and issuer
pages, matching revisions/totals, BTC/UBTC, wrapped ETH, same-name different assets,
stock issuer/contracts and units. Then configure:

```sh
FX_MARKET_CATALOG_URL=https://<public-market-data-origin>/v1/market-catalog
```

Restart the owning process/container through its existing rollout mechanism so
it receives the environment. Discovery retains unverified native listings, but
route comparison requires one common verified economic asset ID. Live metadata
must agree on native product and binding. Source failures remain explicit gaps;
they never authorize candidates from another independently discovered list.

Acceptance uses fixture/public read-only data and no real orders. Test issuer
failure and directory failure in addition to the happy path. Unset the variable
only as the documented short-term rollback; it restores legacy directory reads
without changing account or trading protocols.
