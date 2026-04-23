# Swarm Dev Proxy

A local HTTP proxy that sits between a dapp (or `bee-js` / `swarm-cli` / `curl`)
and a running Bee node, giving developers the kind of visibility they take for
granted on HTTP APIs but that is currently missing on Swarm.

Single static Zig binary. No runtime dependencies. Run it alongside your dev
server and point your app at it instead of `http://localhost:1633`.

## What it is not

It is not:

- [`gateway-proxy`](https://github.com/ethersphere/gateway-proxy) — a production
  reverse proxy that sits in front of a Bee node for public gateways (stamp
  auto-buy, bzz.link subdomain routing, auth).
- [`swarm-gateway`](https://github.com/ethersphere/swarm-gateway) — the newer
  production gateway with moderation and allow/deny lists.
- [`gateway-ui`](https://github.com/ethersphere/gateway-ui) — the React
  upload/download UI for a public gateway.

Those are built for end users browsing Swarm. The Dev Proxy is for developers
building dapps against Swarm — closer in spirit to Chrome DevTools than to
nginx.

## What it does

The target feature set (see [DESIGN.md](./DESIGN.md) for the ranked plan):

- **Transparent forward proxy + structured request log** (P0) — every call
  logged with method, path, status, latency, body size, Swarm reference.
- **Stamp consumption tracking** (P0) — "that upload used 47 of your 1024
  batch slots"; per-batch running totals, TTL countdown, warn at 80 / 95 %.
- **Chunk-level upload inspection** (P1) — for every upload, show the chunk
  tree: root hash, span, chunk count, depth.
- **Feed + SOC state inspection** (P1) — current index, topic, owner, next
  expected update, diff between writes. SOCs get the same treatment.
- **Local cache layer** (P1) — dedupe identical downloads during iterative
  development so you stop hammering the node (or the network).
- **Mock mode** (P1 minimal, P2 full) — serve plausible responses without a
  running Bee node, so test suites can run in CI.
- **Manifest/Mantaray decoding, BMT verify, encryption/ACT metadata,
  replay log, web UI** (P2) — nice-to-haves, stretch goals.

## Quickstart

```bash
zig build run          # starts the proxy on :1733 → forwards to :1633
zig build test         # run the test suite
```

Point your dapp at `http://localhost:1733` and keep the terminal visible.

For a copy-pasteable walkthrough of every feature with verified output,
see [DEMO.md](./DEMO.md). For the potjs-oriented speedup story
(write-through / POST dedup / keep-alive, plus before-after benchmarks
and a real-Bee integration path), see [DEMO-POT.md](./DEMO-POT.md).

## Status

P0 shipped. Working today:

- Transparent forward proxy (`POST`/`GET`/… all round-trip through to the
  upstream Bee node, bit-exact bodies).
- Structured per-request log line on stderr.
- Per-batch stamp tallies (uploads, bytes up/down) — appended to the log
  line whenever a `swarm-postage-batch-id` header is seen.
- Capacity + TTL side-fetch on first sight of a batch (one shot against
  `GET /stamps/{id}`), surfacing `util=F.F%` and `ttl=XdYhZm` on every
  subsequent upload line.
- 80 % / 95 % threshold warnings — fire once per level, based on Bee's
  `utilization` (fullest-bucket fill).
- Feed observation: per-(owner,topic) tallies of reads / writes, with
  `swarm-feed-index` and `swarm-feed-index-next` surfaced on every read.
- SOC observation: per-(owner,id) tallies of writes and bytes uploaded.
- Content-addressed download cache for `GET /bytes/{ref}` and
  `GET /chunks/{ref}` — infinite TTL, disable with `--no-cache`.
- Root-chunk inspection on `POST /bytes` / `POST /bzz`: decodes the
  8-byte span prefix to show tree shape (leaf vs intermediate, children,
  leaf estimate, depth estimate). Disable with `--no-chunks`.
- `--mock` mode: in-process backend for CI / tests. Deterministic
  SHA-256 references; covers `/bytes`, `/chunks`, `/stamps`, `/feeds`,
  `/soc`, `/health`. No upstream needed.
- Browser dashboard at `GET /_proxy` — zero-JS HTML, auto-refreshes
  every 2 s, shows cache stats / batches / feeds / SOCs as they arrive.
- Replay log via `--replay-log FILE` — every request/response appended
  as ndjson with base64-encoded bodies; `tail -f`-able and `jq`-safe.
- Encryption / ACT observation — `swarm-encrypt`, `swarm-act-*` headers
  produce `enc=yes act=yes pub=<hex8>` in the log; lifetime counters
  appear on the dashboard.
- Mantaray manifest probe — on `POST /bzz`, the root chunk is
  side-fetched, deobfuscated, and reported as
  `manifest=yes ver=mantaray:1.0 forks=N`.
- POST dedup — `POST /bytes` / `POST /chunks` bodies are SHA-256'd and
  keyed by `(hash, batch_id)`; identical uploads short-circuit to the
  cached reference (`post_dedup=hit`). Built for potjs-style workloads
  where POT `save()` re-uploads unchanged nodes. `--no-post-dedup` to
  disable. Encrypted uploads are always forwarded.
- Write-through cache — successful POSTs populate the GET cache under
  their returned reference. A subsequent `GET /bytes/{ref}` is served
  in-process (`wt=cached` on the upload line, `cache=hit` on the GET).
- Client keep-alive — HTTP/1.1 connections are kept open so clients
  like potjs can reuse one TCP connection across thousands of chunk
  POSTs.
- `/bzz/` path caching — the explorer-style URLs
  `/bzz/{ref}/meta`, `/bzz/{ref}/number/{n}`, `/bzz/{ref}/hash/{h}`
  are all content-addressed under their manifest root; full paths are
  cached forever. `Range`-header probes bypass (used for existence
  checks on the explorer lookup page).
- Upstream connection pool — one long-lived `std.http.Client` keeps TCP
  connections to Bee alive across all forwarded requests. Measured
  live: 20 proxy→Bee requests produce exactly one TCP connection.
- Pool recovery — stale pooled connections (Bee closed idle conn,
  network hiccup) no longer wedge the proxy. On any transport-class
  error the whole pool is reset and the request retries once with a
  fresh dial; real 4xx/5xx from Bee pass through untouched.

Example output:
```
POST /bytes -> 201 (1ms req=17B resp=24B) stamp=abcdef01 #1 up=17B total_up=17B util=43.8% ttl=4d19h12m
POST /bytes -> 201 (0ms req=1B resp=24B)  stamp=ffffeeee #1 up=1B total_up=1B util=81.3% ttl=4d19h12m
!! stamp ffffeeee crossed 80% utilization — buy/dilute before it fills !!
GET  /feeds/aabb.../1122... -> 200 feed=aabbccdd/11223344 reads=1 writes=0 idx=2a next=2b
POST /soc/dead.../cafe...   -> 201 soc=deadbeef/cafebabe writes=1 up=26B total_up=26B
GET  /bytes/abc123          -> 200 cache=stored
GET  /bytes/abc123          -> 200 cache=hit
POST /bytes                 -> 201 root=abcdef01 span=100B leaf
POST /bytes                 -> 201 root=deeeadbe span=8192B children=2 leaves≈2 depth≈1
```

All P0 + P1 items are now shipped. Remaining P2 candidates (manifest
decoding, replay log, web UI, BMT verify, encryption/ACT metadata) live
in [DESIGN.md](./DESIGN.md).

## Why Zig

- Single static binary, trivially distributable to other hackathon teams and
  to node operators.
- Zero-allocation hot paths for chunk inspection and BMT verification.
- Comptime generics make the mock/real transport split clean.
- Compiles to WASM — the same inspection engine can later power a browser
  devtools panel.
