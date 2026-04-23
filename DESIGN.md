# Swarm Dev Proxy — Design

## Audience

Dapp developers building on Swarm. Secondary: hackathon teams (Swarm Mail,
FullCircle, Collab app, Freedom Mobile, BDF Protocol) who all upload and read
chunks and would benefit from visibility into what their code is actually
doing.

## Shape of the tool

```
 dapp ──HTTP──▶ swarm-dev-proxy (:1733) ──HTTP──▶ bee node (:1633)
                      │
                      ├──▶ terminal log (chunk trees, stamp usage, feeds)
                      ├──▶ local cache (dedupe GETs)
                      └──▶ mock backend (no bee node required)
```

The proxy is a forward HTTP proxy with Bee-specific awareness. Every request
and response is parsed for Bee semantics — Swarm references, postage batch
IDs, feed topics, SOC headers — and those are surfaced to the developer in
real time.

## Feature ranking

Ordered by a combination of impact-to-dapp-dev and feasibility inside a
hackathon window.

### P0 — ships first

1. **Transparent forward proxy.** ✅ shipped. Listens on `:1733`, forwards
   to `:1633` (configurable), bit-exact passthrough of request/response
   bodies.
2. **Structured request log.** ✅ shipped. One stderr line per request:
   `METHOD target -> status (Nms req=XB resp=YB)`.
3. **Stamp consumption tracking.** ✅ shipped. Per-batch running tally
   (uploads, bytes up/down, first/last seen) via `swarm-postage-batch-id`
   header observation. On first sight of a batch, one-shot side-fetch of
   `GET /stamps/{id}` against upstream populates depth, bucket_depth,
   Bee's `utilization`, and `batchTTL`. Log line appends
   `stamp=<id8> #N up=XB total_up=YB util=F.F% ttl=XdYhZm`, and a
   separate `!! stamp <id8> crossed 80% (or 95%) utilization !!` line
   fires once per threshold when the fullest-bucket fill crosses.
   Side-fetch failure is cached (`capacity_fetch_failed`) so we don't
   retry per-upload.

### P1 — the differentiators

4. **Chunk-level upload inspection.** ✅ shipped. On a successful
   `POST /bytes` or `POST /bzz`, the reference is parsed from the JSON
   response body and a one-shot `GET /chunks/{ref}` side-fetches the
   root chunk. The 8-byte little-endian span prefix tells us whether the
   root is a leaf (`span=NB leaf`) or an intermediate chunk
   (`span=NB children=C leaves≈L depth≈D`). Does not walk the full tree —
   that would be N+1 fetches per upload. Opt out with `--no-chunks`.
5. **Feed + SOC inspection.** ✅ shipped. Path-based detection of
   `/feeds/{owner}/{topic}` and `/soc/{owner}/{id}` (query-string and
   nested-segment handling included). Per-(owner,topic) and
   per-(owner,id) tallies of reads / writes / bytes. For feeds we surface
   `swarm-feed-index` and `swarm-feed-index-next` from the upstream
   response, so the log line shows `feed=<o8>/<t8> reads=R writes=W
   idx=2a next=2b`. SOC writes append `soc=<o8>/<i8> writes=W up=XB
   total_up=YB`. Still todo: signature validation, payload diff between
   feed updates, SOC address derivation (keccak256 over id+owner) — all
   pushed to P2.
6. **Local download cache.** ✅ shipped. Keyed on the path (with query
   stripped) for `GET /bytes/{ref}` and `GET /chunks/{ref}`. Infinite
   TTL since the content is hash-addressed. On hit, responds from cache
   without touching upstream and logs `cache=hit`. On miss, stores the
   200-OK response. Stats (`hits`/`misses`/`entries`/`bytes`) live on
   the cache. `--no-cache` disables. No eviction yet; restart if memory
   pressure becomes an issue.
7. **Minimal mock mode (`--mock`).** ✅ shipped. In-process backend:
   - `POST /bytes` → SHA-256(content), stores bytes in memory, returns
     `{"reference":"<64 hex>"}`. Content is capped at 4 KiB so the
     single-chunk invariant holds.
   - `GET /bytes/{ref}` and `GET /chunks/{ref}` serve the stored content
     (chunk form adds an 8-byte LE span prefix).
   - `GET /stamps/{id}` returns a canned response (depth 20, bucket
     depth 16, utilisation 0, TTL 7 days) so stamp tracking has
     something to display.
   - `GET /feeds/{owner}/{topic}` returns a stub with
     `swarm-feed-index: 00` / `swarm-feed-index-next: 01` headers.
   - `POST /soc/...` and `POST /feeds/...` get deterministic fake
     references.
   - `GET /health` → 200.
   - Anything else: 501.

   Mock mode rewires both the stamp capacity side-fetch and the root
   chunk side-fetch to go through the mock too, so the proxy's full
   tracker/log behaviour stays identical to upstream-backed mode. Mock
   references use SHA-256 (not Swarm BMT/keccak), so content stored in
   mock mode does not resolve against a real Bee node.

### P2 — if time permits

8. **Spec-accurate mock.** Expand the mock to feeds, SOCs, stamps, and
   `/bzz` manifests with plausible responses.
9. **Manifest / Mantaray decoding.** ✅ scoped version shipped. On a
   successful `POST /bzz` the root chunk is side-fetched via the
   shared `fetchChunkBytes` helper (mock- or upstream-aware) and
   passed through `manifest.inspectChunkBytes`. That routine
   deobfuscates the fixed-size header portion of the Mantaray node
   (XOR-cycled against the first 32 bytes of the chunk) and checks
   for the `mantaray` magic. If present we report the version string
   (e.g. `mantaray:1.0`) and the popcount of the 32-byte fork bitmap
   at offset 96. Rendered in the log as
   `manifest=yes ver=<str> forks=<N>`.

   **Not shipped** (still on the P2 list): full path→reference
   resolution. That requires parsing the variable-length fork list
   with prefix-length encoding, following fork refs recursively, and
   mapping file paths to the terminal entries. ~300–500 LOC more and
   needs verification against real Bee-produced manifests.
10. **Replay log.** ✅ write-side shipped. `--replay-log FILE` appends
    one ndjson record per request to `FILE`. Each record has the
    timestamp, method, target, request/response headers, and bodies
    (base64-encoded so binary chunks survive). Thread-safe via a mutex
    around the append. Still to do: a `--replay FILE` driver that
    consumes the log and plays each request against a different
    upstream — valuable for bug repro but not shipped this round.
11. **Web UI.** ✅ shipped. `GET /_proxy` returns a zero-JS HTML
    dashboard that auto-refreshes every 2 s via
    `<meta http-equiv="refresh">`. Four sections: cache stats, postage
    batches (with utilisation % coloured on threshold cross), feeds
    (index / next), single-owner chunks. Path is prefix-matched
    (`/_proxy/...`) so sub-pages can be added later without another
    route registration. Does not depend on the terminal log.
12. **BMT verify flag.** Locally recompute the BMT hash of returned
    chunks and cross-check against the reference. Requires implementing
    BMT — separate rabbit hole.
13. **Encryption / ACT metadata.** ✅ shipped. `sniffEnc` scans request
    and response headers for `swarm-encrypt`, `swarm-act`,
    `swarm-act-publisher`, `swarm-act-history-address`,
    `swarm-act-timestamp`. Detected info appears in the log line as
    `enc=yes act=yes pub=<hex8>` where applicable. Two atomic
    lifetime counters (encrypted requests, ACT requests) are exposed
    on the `/_proxy` dashboard under an "Encryption & ACT" section.
    Observation-only — no crypto happens in the proxy.

### P2 additions driven by potjs research

17. **`/bzz/` cache + Range bypass.** ✅ shipped. Research on
    fullcircle-research showed the explorer hits `/bzz/{ref}/meta` on
    every page load and `/bzz/{ref}/number/N`, `/bzz/{ref}/hash/H`
    for every block-bundle fetch. Within a given manifest root the
    `(ref, subpath)` tuple is content-addressed and immutable, so the
    cache now matches any `/bzz/{ref}[/subpath]` path with the full
    path as the key. Requests carrying a `Range` header bypass the
    cache entirely — the explorer uses `Range: bytes=0-0` as a cheap
    existence probe, and we can't synthesise 206 Partial Content from
    a cached 200 (yet).

15. **Write-through GET cache.** ✅ shipped. After any successful
    `POST /bytes` (or `/chunks`) — including POST-dedup hits — the
    request body is inserted into the download cache keyed by
    `/bytes/{ref}` (or `/chunks/{ref}`). Future `GET` for that
    reference is a cache hit instead of a round-trip. Encrypted
    uploads skip this path (same reasoning as POST dedup). Log line
    appends `wt=cached` when the cache was populated. Motivated by
    potjs: upload then lazy-read child nodes is the dominant pattern
    during re-runs of the same pipeline.

18. **Upstream connection pooling.** ✅ shipped. `Proxy` now owns a
    long-lived `std.http.Client`; every upstream call (the forward
    path plus side-fetches for chunk inspection, manifest inspection,
    stamp capacity) uses it with `.keep_alive = true`. Its internal
    `ConnectionPool` reuses the TCP connection to Bee across
    requests. For a potjs bulk save (~8000 POSTs) this collapses
    ~8000 TCP handshakes to one. Verified on a real Bee with `ss`:
    20 requests through the proxy produce exactly **one** upstream
    TCP connection.

21. **Upstream retry-with-pool-reset on transport errors.** ✅ shipped.
    Under a sustained workload (fullcircle-research's 47k-chunk
    manifest save), the remote Bee occasionally closes a pooled
    connection — keep-alive timeout, server-side GC, packet loss. The
    stale pooled connection then fails the next request instantly
    with `BrokenPipe` / `ConnectionResetByPeer` / `EndOfStream` /
    `HttpConnectionClosing` — and without recovery logic, one bad
    socket wedges the whole proxy: every subsequent request gets the
    same dead connection and 502s in ~1.6 ms without ever dialing.
    Fix: on any transport-class error, drop the entire upstream pool
    (`deinit` + reinit the shared `http.Client`), then retry the
    request once with a fresh dial. Real 4xx/5xx responses from Bee
    pass through unchanged — only connection-level errors trigger
    the reset. Logged as `upstream pool reset after <error>; retrying
    with fresh dial` so you can tell from stderr that recovery fired.
    Verified live: 20 requests at steady ~46 ms, 65-second idle, next
    request triggers `HttpConnectionClosing` → pool reset → clean 200
    at 113 ms, subsequent requests back to ~46 ms.

20. **CLI accepts `http://HOST:PORT` for `--upstream`.** Previously
    `parseHostPort` split on the last `:` and treated `http://65…:3000`
    as host `"http://65…"`, port `3000`. Every upstream call then
    tried to connect to hostname `"http"` and bounced with
    `InvalidPort` / `ConnectionRefused` → the client saw 502. The
    parser now strips `http://` (rejects `https://` explicitly
    because we don't do TLS upstream yet) and drops any trailing
    path/query. Verified live by running fullcircle-research's
    `era:upload` against a remote Bee at `http://65.109.80.9:3000` —
    300+ POST /bytes round-trips, all clean.

19. **Richer 502 diagnostic.** Minor but consequential: when
    `forwardRequest` errors, the proxy now prints
    `forward error: POST /bytes -> ConnectionRefused` (method +
    target + error name) instead of just `forward error: <name>`.
    Makes "why did my client see 502?" trivially diagnosable from
    the stderr log.

16. **Client keep-alive.** ✅ shipped. All four `request.respond`
    sites now pass `.keep_alive = request.head.keep_alive` so a
    HTTP/1.1 client's connection is kept open by default. The
    existing accept loop already handles multiple requests per
    connection, so this lets clients like potjs reuse one TCP
    connection across thousands of chunk POSTs instead of doing
    per-request TCP+HTTP handshakes. The 502 bad-gateway error path
    deliberately closes the connection — transport state is suspect.

14. **POST dedup.** ✅ shipped. `POST /bytes` and `POST /chunks`
    bodies are SHA-256'd and keyed under
    `(content_hash, postage_batch_id)`. Identical-content uploads
    under the same batch short-circuit to the cached `{reference}`
    response without touching the backend. Encrypted uploads
    (`swarm-encrypt: true`) are always forwarded — each one uses a
    fresh random key, so dedup would be incorrect. Only 2xx
    responses are cached. Log line appends `post_dedup=stored` or
    `post_dedup=hit`. Dashboard exposes entries, hits, misses,
    bytes saved. `--no-post-dedup` opts out. Motivated by potjs /
    Proximity Order Trie: `save()` walks the tree post-order and
    POSTs each serialised node, and three parallel KVSs
    (byNumber / byHash / byTx in fullcircle-research) share many
    nodes across them.

### Explicitly out of scope

- Production features: stamp auto-buy, bzz.link subdomain routing, auth,
  rate limiting. That is what `swarm-gateway` is for.
- Deep protocol-level work: implementing pullsync, the hive protocol, or
  the BMT hash from scratch. The proxy is a middleman, not a node.

## Key technical decisions to make early

- **HTTP library.** `std.http` in Zig 0.15 is usable; decide whether to
  use it directly or wrap it for ergonomics. Start with `std.http`.
- **Bee API surface we care about.** Upload (`/bytes`, `/bzz`, `/chunks`),
  download (same paths reversed), feeds (`/feeds/...`), stamps
  (`/stamps`), SOCs (`/soc`). Everything else is a pass-through.
- **Chunk-tree walking.** To visualize an upload, we need to fetch the
  root chunk and decode its span/children. This is P1 work, not P0 —
  the proxy must ship and forward traffic correctly first. BMT hash
  verification stays a P2 "verify" flag.
- **State store.** In-memory for P0. A tiny embedded KV (e.g. a single
  append-only file) for the cache and batch state if we need persistence.

## Open questions

- Should the proxy intercept `swarm-cli` / `bee-js` behavior or just
  observe? Start with observation only. Interception (e.g. auto-stamp)
  drifts toward being a `gateway-proxy` clone.
- Do we need TLS termination? The target deployment is `localhost`, so
  no, at least for the hackathon.
- How do we validate chunk trees without re-implementing BMT? For P0,
  trust the node. For P2, implement BMT and cross-check.
