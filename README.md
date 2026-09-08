```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Run fx

Sign in with Vercel AI Gateway:

```bash
fx login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. Inside fx, run `/provider` (alias `/setup`) to move between Gateway, Codex, and Grok: Enter on a subscription provider switches to it or starts its sign-in, and `vercel` opens further columns for the sign-in method, the API key to use, and the Vercel team. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Model discovery continues when its local version cache is unusable. Use `/logout codex` or `/logout grok` to remove that subscription session. Logging out of the active subscription switches to an already-connected provider, preferring Gateway and then the other subscription. If none is usable, fx stays signed out. Logging out of an inactive subscription keeps the active provider unchanged. Active subscription logout is unavailable while work is active or queued; choosing the provider again from `/provider` starts sign-in.

If a saved credential cannot be checked, `/login`, `/provider`, and `/setup` still open and identify the unavailable source. You can type the provider name immediately after Enter; credential checks preserve your input and keep choices unavailable until checking finishes. Provider and team preparation also keeps typing and cancellation responsive while its catalog loads. Ctrl+C cancels preparation without changing the current provider. A prompt submitted during preparation waits for the selected provider; if preparation fails, the prompt stays pending for explicit recovery. While responses are active or queued, these commands immediately explain that provider switching is unavailable. Other credentials remain usable. Fix the saved credential and reopen `/provider` to retry. Storage or connection failures do not start another sign-in, and browser authorization reports success only after the new credential is saved.

If credential storage fails when you submit a prompt, fx keeps the prompt and the selected account. Repair the saved credential, then press Enter to retry. A sign-in that cannot save its credential reports a storage failure. Resumed sessions restore their provider's credential and model catalog before the first prompt.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

Codex and Grok discover current stable client versions from upstream release metadata without requiring either CLI to be installed. fx caches release metadata for one minute. Opening `/model` or requesting ACP model options refreshes an expired subscription catalog. If a release lookup temporarily fails, fx uses the last successfully fetched version.
Embedded Pieverse runtimes can select the tenant-scoped OpenAI-compatible route without persisting credentials:

```bash
FX_PROVIDER=pieverse \
FX_MODEL=pieverse/auto/paid \
FX_PIEVERSE_API_KEY=sk-pv-... \
FX_PIEVERSE_BASE_URL=https://ai.pieverse.io/v1 \
fx ask "research this market"
```

`FX_MODEL` is used as-is, so an embedding platform can pass the parent agent's current model when it starts fx. `FX_PIEVERSE_API_KEY` authorizes only the Pieverse provider and is never accepted by the Vercel, Codex, or Grok routes. `FX_PIEVERSE_BASE_URL` is optional and defaults to `https://ai.pieverse.io/v1`.

To use an AI Gateway API key instead:

```bash
fx setup
```

Embedding hosts that inject provider authentication at the network boundary can set `FX_AUTH_MODE=host-managed`. In this mode, fx does not read, refresh, or write local model-provider credentials and does not add authentication-owned headers to Gateway, Codex, or Grok requests. The host must authenticate those forwarded requests.

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. While fx is working, you can submit a multiline update with Enter; it steers the active turn at its next safe model boundary. When no tool is running, your message appears in the transcript immediately. Updates waiting for a running tool show their first two lines with a dotted rail and an ellipsis when more text is hidden. Press Escape to interrupt the active work and apply the update as soon as the turn settles.

Use `/resume` to choose a saved conversation. The picker shares its catalog across workspace views and reuses unchanged session summaries between launches. The first catalog build, or recovery from missing cache data, scans saved sessions automatically. Changed sessions are checked again, and closing the picker stops obsolete loading work.

Tool calls are expanded by default. Enable `Collapse tool calls` in `/settings`, or set `"collapse_tool_calls": true` in `~/.fx/settings.json`, to show one summary per tool-call group in the main transcript. Individual calls remain available in the full transcript with Ctrl+O. Follow-up activity for captured shell commands shows the original command, such as `Observed zig build`, while tool results keep the same execution handle.

When a tool targets a directory with additional project instructions, fx shows `Reading project instructions before continuing:` before the agent decides whether to retry. This refresh does not add a failure or “command not run” count to the tool summary.

While fx is working, Ctrl+C clears a nonempty composer without interrupting the turn. Press Ctrl+C again with an empty composer to cancel the active work.

Ctrl+L clears the inline display while keeping the conversation available in Ctrl+O. It preserves your draft and conversation context; `/clear` starts a fresh conversation instead.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fx session resume last
fx session resume --id <id>
```

`fx -c` also resumes the latest session for the current workspace. It skips unrelated current-format conversation histories during selection and attempts safe recovery of the selected session after an interrupted migration. A busy or unrecoverable selected session produces an error rather than opening an older conversation.

Repeated continuation reuses validated summaries of unchanged older sessions instead of replaying their histories during selection. The first scan, or a scan after those session files change, can take longer. Opening the resume picker preserves these cached summaries.

Older sessions that saved Vercel connection settings can be opened through `-r`, `/resume`, `-c`, or an exact ID. Migration preserves their model settings and keeps unfinished responses as interrupted history, without replaying old requests or restoring saved credential references.

If a saved conversation is damaged, run `fx session recover <id>` to copy its validated prefix into a new session. Recovery preserves checkpoint boundaries and referenced result files, leaves the original unchanged, and prints the new session ID. Records after the damaged boundary are not included, and recovery does not rerun commands. Healthy conversations can be resumed without recovery.

Interactive terminal tabs show `fx v<version> | <folder>` using the running binary's version and current workspace folder name, for example `fx v0.0.7 | fx`. Renaming a session or switching models leaves the title unchanged. Resuming from another folder uses that folder's name. Exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

fx automatically summarizes a long session into a fresh context window when the active model request reaches 80% of its usable input capacity, then continues the same turn. Run `/compact` to create the same durable handoff immediately and wait for your next prompt. Manual compaction refreshes the selected login when needed; Ctrl+C cancels preparation. If authentication fails, the chat stays open and unchanged so you can reconnect and retry `/compact`.

Compaction handoffs remain internal context for the model. Resuming a session and opening its full transcript show the conversation and tool activity, not internal summaries or operation ledgers.

Saved conversations preserve original assistant replies and compatible provider continuation data. Display formatting does not rewrite saved text, and hook-driven continuation keeps earlier replies separate from the final response.

In saved sessions, oversized `read_tool_result` responses keep a complete terminal-safe backing copy even when the inline response is clipped. Compaction and later retrieval preserve that copy without masking the explicitly requested text again.

Resuming an older session upgrades its saved permissions and skips empty legacy file-change entries while keeping the conversation and tool results. Cancelled tools remain recorded as failures and do not prevent later compaction. If the model returns an empty compaction summary, fx retries the summary once without repeating tools. Cancellation or another failed summary leaves the previous context intact.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

With `--json`, `output` contains accumulated assistant Markdown across the request. Recovery replaces failed preview text rather than joining separate responses. If recovery pauses before a replacement is accepted, `output` keeps the latest preview. `final_output` contains only a completed final assistant response and is `""` for interrupted, failed, background, or otherwise absent final responses.

For JSON tool results, the model returns `{"result_refs":["call_id", "another_call_id"]}` instead of repeating payloads. In `--json` mode, fx retains original JSON objects/arrays from executed calls in this request, before model-context truncation. Each retained result is prefixed in model-visible text with `FX result reference: {"result_ref":"<exact call ID>"}`; the model copies that value instead of guessing IDs from provider metadata or call order. FX resolves these IDs into the existing `final_output` string: one unchanged result, or a JSON array of unchanged results in the requested order, without the reference annotations. `output` retains the model's reference envelope. Errors and gaps inside selected results are preserved. Unknown, duplicate, or invalid references fail with a nonzero exit code and empty `final_output`. References are not persisted or resolved across requests. Capture is bounded to 256 results and 8 MiB including call IDs; exceeding either limit fails reference resolution explicitly. Ordinary responses and text/terminal output retain their existing behavior.

JSON results also include `usage.input_tokens` and `usage.output_tokens`, even with `--no-save`. These are the sums of token counts reported by main-agent completions in the turn, not the latest prompt size or session totals. A field is `null` when no completion reported that count; when only some completions report it, the sum includes only those known counts. JSON errors retain usage already observed. These fields do not include nested tool/provider usage, request counts, or dollar spend.

Foreground terminal commands run with an explicit finite deadline. fx uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

Invalid Shell requests return the specific argument problems before any command runs. When the intended repair is unambiguous, the error includes a `retry_with` request for the agent to submit through normal validation and permissions. Repeated equivalent corrections stop the tool loop.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow review of the exact pending action for concrete security danger. Prepared file mutations and static tools are reviewed without task text; reviewed commands, dynamic tools, and delegated actions also receive bounded trusted root-request context. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

Use `fx ask --full-access` or `/permissions full-access` to disable fx permission checks for trusted environments. The former `--yolo` flag and `/permissions yolo` command remain supported. `FX_PERMISSION_MODE` and profile `permission_mode` accept `full-access`; saved settings and JSON output retain `yolo` for compatibility.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

In the interactive shell, bare `/mcp` opens an inline browser for servers, tools, resources, and prompts without adding anything to the transcript. Resource and prompt content enters the composer only after an explicit Insert action. Direct `/mcp SUBCOMMAND` forms remain available.

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Run `fx mcp add NAME COMMAND [ARGS...]` for a local server or `fx mcp add --transport http NAME URL` for Streamable HTTP without opening the interactive shell; the equivalent `/mcp add` forms remain available inside fx. A workspace may also provide Claude-compatible `.mcp.json` with a top-level `mcpServers` object. Pending project servers stay disconnected on every surface until they are approved with `/mcp trust approve <server>` or `fx mcp trust approve <server>`. Interactive fx presents the trust prompt after startup. `fx ask` reports skipped pending servers on stderr, and ACP leaves them unavailable. Repository files cannot persist approval or expose environment-expanded values before approval. `/mcp trust reject <server>` rejects one and `/mcp trust reset` clears the workspace choices. Profile entries win same-name collisions. Profile `~/.fx/mcp.json` accepts `mcpServers` as an alias for `mcp`, while writes always use `mcp` and ambiguous server-like keys produce a visible warning. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report invalid or suspicious trusted MCP profiles without starting their servers.

The `subagent` tool has two operations: `run` delegates one temporary task, and `message` creates or continues a named persistent agent. Each call waits for the child's result. A first message creates the named child immediately; optional instructions set or replace that child's system overlay while preserving fx's trusted base prompt. Child sessions remain private to their saved parent session. Each call appears in the main chat with its agent name or one-off status and a short task preview; full requests and replies remain in the tool details.

Failed calls include the captured failure reason and any partial result, including HTTP failures before an answer or after earlier tool calls. Earlier tool effects are not rolled back or automatically retried. Existing child records remain readable, but records saved by this version cannot be reopened by older binaries that only support child registry schema 1.

Run `fx mcp` to see the available commands. Use `fx mcp list`, `fx mcp path`, and `fx mcp remove NAME` for noninteractive profile management. `fx mcp trust approve|reject NAME`, `fx mcp trust approve-all`, and `fx mcp trust reset` manage workspace-scoped project trust. `fx mcp auth NAME` and `fx mcp logout NAME` run the existing remote credential lifecycle without opening the TUI or contacting the Gateway.

MCP servers have a 30-second startup timeout by default; set `startup_timeout_ms` on a server when its cold start needs a different bound. For direct `docker run` stdio entries, fx uses a private container ID file to remove the owned container after shutdown or startup failure. A configuration that already supplies `--cidfile` keeps ownership of its own cleanup policy.

Native MCP connections use the standard `initialize` handshake by default,
negotiating the supported 2025 and 2024 protocol versions. Servers that require
the newer `2026-07-28` discovery lifecycle can opt in with
`FX_MCP_PROTOCOL_VERSION=2026-07-28` in their configured `environment` map.
The SDK's host-owned client controls its own protocol negotiation.

MCP servers connect independently. In headless asks, a request for one server starts
that server without starting unrelated optional servers. Capability search loads
matching tool definitions automatically; explicit `mcp_select_tool` remains
available. The server validates its tool arguments. Image results reach supported
models as images and remain available in saved sessions; text-only models receive
an explicit notice.

Skills are advertised in a stable catalog sized to the selected model's context window. The default budget is approximately 2% of context, or 8,000 characters when the context size is unknown, with up to 1,024 characters per description. Explicit byte overrides take precedence. When space is limited, fx shortens descriptions before omitting skill identities; `capability_search` can find skills outside that catalog.

This fork registers `discover_markets` directly in the agent's tool context. For example, `{"tickers":["IREN","APLD","HUT"]}` searches all eight supported venues concurrently, reusing catalogs across tickers. Every call checks all eight venues. Optional `product` (`spot`, `perp`, or `all`) and `quote` filters narrow the products and currencies. Aster defaults to all quotes; Binance, Bitget, Gate, and OKX default to USDT; Hyperliquid and Lighter default to USDC; Kraken defaults to USD. Use `quote: "ALL"` to search all supported quotes.

The research workflow instructs the agent to verify asset identity and supported-market identifiers using available read-only market or issuer information before ticker-based research. Names, listing codes, and symbols are identification clues; discovery matches venue base tickers and verified venue-scoped aliases, but does not resolve company names or listing codes. An empty result does not establish asset unavailability. Unresolved identifiers must be clarified before their candles or route comparisons are requested. Related resolved legs stay together where supported, unresolved legs remain explicit, and the response retains relevant unchanged JSON results from earlier calls.

Discovery, candles, and route comparisons share a bounded perpetual alias table: `SKHYNIX`/`SKHX` and `SAMSUNG`/`SMSN` map to XYZ's `xyz:SKHX`/`xyz:SMSN`, Lighter's `SKHYNIXUSD`/`SAMSUNGUSD`, and Aster's `SKHYNIX`/`SAMSUNG` bases; `HYUNDAI` also matches Lighter's `HYUNDAIUSD`. XYZ identities are documented in its [Korean asset specifications](https://docs.trade.xyz/asset-directory/korea); native symbols were checked against the [Lighter catalog](https://mainnet.zklighter.elliot.ai/api/v1/orderBooks?filter=all) and [Aster catalog](https://fapi.asterdex.com/fapi/v3/exchangeInfo). Add mappings only after verifying the same underlying exposure and units, scoped to the actual venue and product. These aliases do not include the `SKHY` ADR, leveraged funds, arbitrary builders, or arbitrary `USD` suffixes. Current catalog status and currency filters still apply. Aster also recognizes `1000`, `1000000`, and `1M` quantity prefixes, preserving the native contract symbol and normalizing candles to the requested underlying unit.

The tool returns only `results` grouped by ticker and `errors` for unresolved coverage. Markets retain exact venue-native symbols, spot/perp types, required order-routing identifiers, and material restrictions. Partial venue failures preserve successful findings. Sizing specifications, query scope, timestamps, and debug metadata are omitted. It uses public market commands only and does not place orders. The query script is embedded in the binary; no market-discovery skill or workspace script installation is needed. The native host must provide Bash 4+, jq, GNU timeout, curl, and the selected venue CLIs. Tests live in `tests/market-discovery/`.

`search_tokens` searches Bitget Wallet's public token catalog for onchain memecoins and long-tail tokens; stocks, stock-linked tokens, and major cryptocurrencies are out of scope. `{"query":"cashcat"}` searches without a chain filter and returns only the provider's first match. Optional `chain` accepts a provider chain code (for example `bnb`, `sol`, or `robinhood`); optional `limit` accepts 1–20. Omit `limit` by default and set it only when additional candidates are needed. Results preserve provider order and return `name`, `symbol`, `chain`, `contract`, `twitter`, `website`, and `telegram` inside `results`. Social links are supplied by the provider; missing, empty, or non-string links become `null`. A successful empty search returns `{"results":[]}`; transport and provider failures are tool errors. Search ranking is not an identity verification. This read-only tool requires curl, no wallet credentials or skill installation.

`get_market_candles` accepts only `{"tickers":["IREN","APLD"]}`. It selects a reference market across the same eight venues using public 24-hour turnover converted to USD (OKX perpetual turnover is estimated from base volume and current price). It fetches 15m, 1h, and 4h candles plus the latest actual trade in parallel, keeping every timeframe on the same market and falling back if candle retrieval fails. Each timeframe returns up to 50 closed candles and a separate current candle, with ISO 8601 UTC timestamps (including milliseconds) and prices/volumes normalized to the underlying unit. Unknown volume units remain null. The response contains `columns`, per-ticker `results` (quote currency, retrieval time, latest trade, timeframes), and `errors`; source markets stay in internal logs. Missing or stale data is reported rather than manufactured.

The two tools reuse validated public discovery catalogs for 60 seconds in `.fx/market-cache/v1`. Volume statistics, conversion quotes, latest trades, and candles are refreshed per call. Selection attempts are recorded as `candle-source-<TICKER>.jsonl` in that directory. Failure to write these optional diagnostics warns on stderr without discarding market data. Actual candle-worker failures retain stderr in the command log and include `exitCode` in the per-ticker error. This is a reference-data selection, not an execution-cost ranking or a trading recommendation.


Explicit `$skill-name` mentions load the selected instructions before the model starts work. The `skill` tool accepts an advertised `location` and an optional relative `resource`, returning the complete document or a visible failure. Omitting `resource` or passing an empty string reads `SKILL.md`. File and tool-result limits still apply, and an explicit `skill_chunk_bytes` limit blocks a complete read that would exceed it. Existing named, offset-based calls remain supported.

In the interactive shell, explicitly requested skills show a named load summary before the assistant replies. Full failure details are available in Ctrl+O. These automatic loads are not counted as tool calls; a loaded status confirms prepared instructions, not that the model followed them.

`compare_trade_routes` compares public taker entry quotes for one base ticker. Spot buys use `{"ticker":"CRCL","product":"spot","amount":"1000"}`; perpetuals also require `"direction":"long"` or `"short"`. Optional `currency` is USD, USDT (default), or USDC and controls budget/comparison units, not market filtering. Venue comparisons default to USDT pairs, USDC on Hyperliquid/Lighter, and USD on Kraken. Optional `quote` overrides all venue quote filters (for example `"quote":"USDC"`); `"quote":"ALL"` explicitly enables all quotes. Onchain routes retain their supported payment assets. Spot amount is the total budget including trading fees and estimated external gas; perp amount is position notional, not margin. Perps use a common underlying quantity rounded to venue lot steps internally.

The backend reuses discovery catalogs, fetches independent books concurrently (bounded to 12 active workers), checks base-size units and live quote conversions, walks depth and applies public/default-tier fees. Aster uses its [published taker schedule](https://docs.asterdex.com/trading/perpetuals/fees-and-specs/fees): 0.04% for ordinary USDT perps, 0.005% for ordinary USD1 perps, and 0.009% for identified stock, ETF and commodity RWA perps, including USD1 RWA. Unsupported fee categories and pre-launch markets are excluded. Hyperliquid and Lighter include Pieverse's documented 0.05% execution fee. Rankings exclude fee promotions, account discounts, funding, transfer costs and the cost of converting funds into each route's payment currency. Funds are assumed already present at each venue/chain. USDC-collateral HIP-3 fees use the market's deployer fee scale and growth mode under the [official fee formula](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/hip-3-deployer-actions). Missing scale/growth state, unverified collateral fee alignment, and inverse contracts are excluded explicitly. Lighter markets with successful but empty two-sided order books are omitted from discovery; failed book queries remain coverage errors. Quotes are estimates, not executable orders or guarantees of a globally lowest cost.

Stock spot buys additionally discover issuer deployments on BNB (bStocks/xStocks), Solana (xStocks), and Robinhood Chain. Crypto spot and perps never request stock swap quotes. Bitget Wallet public quotes cover BNB/Robinhood; Solana uses the existing platform DFlow broker capability (`FX_PLATFORM_DFLOW_QUOTE_URL`, `FX_PLATFORM_QUOTE_TOKEN`). Gas is reserved inside the budget and the reduced input is quoted again. Solana raw xStocks amounts use the issuer multiplier; EVM balances already represent adjusted token units. Non-unit bStocks/Robinhood multipliers are excluded until their exposure semantics are supported. Provider-forbidden quotes, missing gas/fees, insufficient depth and failed coverage are summarized in `gaps`. No wallet access, approvals, transactions or account mutations occur.

The response contains `bestRoute`, `rankedRoutes`, and `gaps`. `bestRoute` retains the overall winner: `venue`, exact `symbol`, `product`, and required routing identifiers, or `issuer`, `chain`, `symbol`, and `contract` for an onchain route. `rankedRoutes` contains the cheapest eligible route per venue or onchain provider/chain, in cost order, with the same identifiers plus `costRank` and the onchain `provider` when applicable. Lower ranks are cheaper; equal effective prices share a rank, including for shorts. Ranks are ordinal, not cost amounts or savings. The caller can select among its configured venues and identify strictly cheaper alternatives from the same comparison; fx does not inspect account configuration. Numeric costs, quantities, sources, and timestamps remain internal. With no eligible routes, `bestRoute` is null and `rankedRoutes` is empty. `gaps` contains concise comparison exclusions and flags when only one eligible route exists, which does not establish a comparative minimum. Refresh quotes and validate account-specific fees, order limits and readiness before execution.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
