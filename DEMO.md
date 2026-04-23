# swarm-dev-proxy — demo guide

Step-by-step walkthrough of every feature currently shipped. Each
section has a copy-pasteable command and the exact log line the proxy
prints on its stderr. Every output here was captured from a real run
of the binary built from this tree.

The proxy runs in two modes:

- **`--mock`** — serves everything in-process. No Bee node required.
  Best for hackathon demos, CI, and walkthroughs without network setup.
- **upstream mode** (default) — forwards to a running Bee node at
  `127.0.0.1:1633`. Use this to demo against real Swarm content.

Unless noted, every example below uses `--mock` so you can follow along
with nothing but this repo.

---

## 0. Prerequisites

- Zig 0.15.2 (`zig version`)
- `curl`
- (optional) a Bee node at `:1633` for upstream-mode demos

## 1. Build

```bash
zig build
```

Produces `./zig-out/bin/swarm_dev_proxy`.

## 2. Start the proxy in mock mode

Two-terminal setup — proxy in one, curl in the other.

```bash
# terminal 1
./zig-out/bin/swarm_dev_proxy --mock
```

Banner:

```
swarm-dev-proxy listening on http://127.0.0.1:1733 -> http://127.0.0.1:1633
```

(Upstream is still listed even in `--mock`; it's inert, kept so the
banner format is the same in both modes.)

Every request to `:1733` will now print a one-line log entry on this
terminal. Keep it visible.

---

## 3. Transparent forward proxy + structured log

Baseline: every request is visible, every response has method / target
/ status / latency / body sizes.

```bash
# terminal 2
curl -s http://127.0.0.1:1733/health
```

Client:

```
ok
```

Proxy log:

```
GET /health -> 200 (0ms req=0B resp=3B)
```

Log fields, left to right:

- HTTP method and request target
- upstream (or mock) status code
- round-trip latency in ms
- request body size in bytes
- response body size in bytes

---

## 4. Content-addressed store (POST + GET round-trip)

Mock mode hashes your payload with SHA-256 and stores it keyed by the
hex digest.

```bash
curl -s -X POST -d "hello from curl" http://127.0.0.1:1733/bytes
```

Client:

```
{"reference":"6cb0d45896690f951545be0e87a1caa6c1252e1d08292d2ea682d390473fe9e7"}
```

Proxy log:

```
POST /bytes -> 201 (0ms req=15B resp=80B) root=6cb0d458 span=15B leaf
```

The `root=…` / `span=…B leaf` part is chunk inspection kicking in —
see section 7.

Retrieve the content by reference:

```bash
REF=6cb0d45896690f951545be0e87a1caa6c1252e1d08292d2ea682d390473fe9e7
curl -s http://127.0.0.1:1733/bytes/$REF
```

Client:

```
hello from curl
```

Proxy log:

```
GET /bytes/6cb0d458... -> 200 (0ms req=0B resp=15B) cache=stored
```

The `cache=stored` tail means the response just went into the download
cache — see next section.

---

## 5. Local download cache

Hit the same reference a second time:

```bash
curl -s http://127.0.0.1:1733/bytes/$REF
```

Proxy log:

```
GET /bytes/6cb0d458... -> 200 (0ms req=0B resp=15B) cache=hit
```

Served entirely in-process — `cache=hit`. Against a real Bee node the
latency drop between miss and hit is typically 20–100 ms → <1 ms.

Keys are the request path with query string stripped, so
`/bytes/{ref}?download=true` and `/bytes/{ref}` share a cache entry.

Cache is only consulted for `GET /bytes/{ref}` and `GET /chunks/{ref}`
(content-addressed → immutable → safe to cache forever).

A non-200 response is not stored, but the miss is still visible:

```bash
curl -s http://127.0.0.1:1733/bytes/$(printf '0%.0s' {1..64})
```

Proxy log:

```
GET /bytes/000...000 -> 404 (0ms req=0B resp=16B) cache=miss
```

Disable the cache entirely with `--no-cache`.

---

## 6. Stamp consumption tracking

Upload against a named postage batch. The proxy observes the
`swarm-postage-batch-id` header, maintains a per-batch tally, and
side-fetches `GET /stamps/{id}` on first sight of a batch to learn
capacity + TTL.

```bash
BATCH=abcdef01deadbeefcafebabe0123456789abcdef0123456789abcdef01234567
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "stamped" http://127.0.0.1:1733/bytes
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "again"   http://127.0.0.1:1733/bytes
```

Proxy log:

```
POST /bytes -> 201 (1ms req=7B resp=80B) stamp=abcdef01 #1 up=7B  total_up=7B  util=0.0% ttl=7d0h0m root=ca2fe806 span=7B leaf
POST /bytes -> 201 (0ms req=5B resp=80B) stamp=abcdef01 #2 up=5B  total_up=12B util=0.0% ttl=7d0h0m root=b4c9e140 span=5B leaf
```

Fields on the stamp section:

- `stamp=<8-hex prefix>` — batch identity
- `#N` — number of uploads we've seen for this batch
- `up=X total_up=Y` — this upload's body size and the cumulative
  request-body total
- `util=F.F%` — fullest-bucket utilization from Bee's `utilization`
  field (computed as `utilization / 2^(depth - bucketDepth) * 100`)
- `ttl=XdYhZm` — remaining TTL from Bee's `batchTTL`

Mock mode returns a canned stamp shape (depth 20, bucket depth 16,
utilization 0, TTL 7 days), so you'll always see `util=0.0%` in
`--mock`. Against real Bee this tracks the live value.

### 6.1 Threshold warnings

When a batch crosses 80 % or 95 % utilization (real Bee only, since
mock returns 0), a warning line fires **once**:

```
POST /bytes -> 201 (1ms req=1B resp=24B) stamp=ffffeeee #1 up=1B total_up=1B util=81.3% ttl=4d19h12m
!! stamp ffffeeee crossed 80% utilization — buy/dilute before it fills !!
```

Subsequent uploads on the same batch stay quiet — we don't spam. 95 %
fires separately the first time the fullest bucket passes that line.

---

## 7. Root-chunk inspection

Already visible in sections 4 and 6: after every successful
`POST /bytes` or `POST /bzz`, the proxy parses the `reference` out of
Bee's JSON response, side-fetches `GET /chunks/{ref}`, and decodes the
8-byte little-endian span prefix.

**Leaf tree** (span ≤ 4 KiB → one chunk):

```
POST /bytes -> 201 ... root=6cb0d458 span=15B leaf
```

**Intermediate tree** (from the integration test fixture with an 8 KiB
span and two child references):

```
POST /bytes -> 201 ... root=deeeadbe span=8192B children=2 leaves≈2 depth≈1
```

Fields on the chunk section:

- `root=<8-hex prefix>` — reference returned by the upload
- `span=NB` — total bytes of the subtree (from the chunk's span prefix)
- `leaf` — if the root chunk *is* the content; no children
- `children=C` — number of 32-byte child refs at the root level
- `leaves≈L` — estimated leaf count (`ceil(span / 4096)`)
- `depth≈D` — estimated tree depth (`ceil(log₁₂₈(leaves))`)

Disable with `--no-chunks` — one fewer round-trip per upload.

---

## 8. Feed inspection

GET on a feed endpoint produces per-(owner, topic) tallies plus the
current / next index pulled from Bee's `swarm-feed-index` and
`swarm-feed-index-next` response headers.

```bash
OWNER=aabbccddeeff00112233445566778899aabbccdd
TOPIC=1122334455667788991122334455667788112233
curl -s "http://127.0.0.1:1733/feeds/$OWNER/$TOPIC?type=sequence"
```

Client:

```
{"reference":"deadbeef"}
```

Proxy log:

```
GET /feeds/aabb.../1122...?type=sequence -> 200 (1ms req=0B resp=24B) feed=aabbccdd/11223344 reads=1 writes=0 idx=00 next=01
```

Fields:

- `feed=<owner8>/<topic8>` — short identity
- `reads=R writes=W` — running per-feed counters
- `idx=<hex>` — current index (from `swarm-feed-index`)
- `next=<hex>` — next-write index (from `swarm-feed-index-next`)

Mock mode always returns `idx=00 next=01`; against real Bee this is
the actual feed state. Hit the same feed a second time → `reads=2`.

---

## 9. SOC inspection

Analogous to feeds, keyed by (owner, id):

```bash
curl -s -X POST -d "soc-payload" "http://127.0.0.1:1733/soc/deadbeef/cafebabe?sig=aa"
```

Proxy log:

```
POST /soc/deadbeef/cafebabe?sig=aa -> 201 (0ms req=11B resp=80B) soc=deadbeef/cafebabe writes=1 up=11B total_up=11B
```

Fields:

- `soc=<owner8>/<id8>` — short identity
- `writes=N` — running per-SOC counter
- `up=X total_up=Y` — this request's body size and cumulative total

---

## 10. Browser dashboard at `/_proxy`

Every tracker above also renders as HTML. Open `http://127.0.0.1:1733/_proxy`
in a browser once the proxy is running:

```bash
# Terminal 2 — open in browser, OR dump the HTML to stdout:
curl -s http://127.0.0.1:1733/_proxy
```

The page auto-refreshes every 2 seconds (`<meta http-equiv="refresh">`),
so during a live demo you can leave it open while firing curls from
another terminal — each row updates without touching the browser. Four
sections:

- **Cache** — entries, bytes cached, cumulative hits / misses.
- **Postage batches** — batch prefix, upload count, total bytes,
  utilisation %, TTL, and the warning-flag column.
- **Feeds** — owner / topic prefixes, reads / writes, current and next
  indexes.
- **Single-owner chunks** — owner / id prefixes, writes, bytes
  uploaded.

Paths under `/_proxy/...` are reserved for future sub-pages; the
default path matches on the `/_proxy` prefix.

Proxy log:

```
GET /_proxy -> 200 (0ms req=0B resp=0B)
```

(Logged size is 0 because the dashboard branch is outside the normal
request-body accounting — worth tightening if you care about accurate
byte counts for the dashboard itself.)

---

## 10f. Write-through + keep-alive (potjs speedups)

Two small features that add up to a real speedup for potjs's write-
then-lazy-read workload.

**Write-through cache.** Every successful `POST /bytes` (or `/chunks`)
feeds its body into the GET cache under the returned reference. The
very next `GET /bytes/<ref>` is then served in-process.

```bash
REF=$(curl -s -X POST -d "some chunk content" http://127.0.0.1:1733/bytes | grep -oE '[a-f0-9]{64}')
curl -s http://127.0.0.1:1733/bytes/$REF
```

Proxy log:

```
POST /bytes -> 201 (…) post_dedup=stored wt=cached root=2c826997 span=18B leaf
GET /bytes/2c826997e4… -> 200 (0ms req=0B resp=18B) cache=hit
```

The `wt=cached` marker on the POST line means "I also populated the
download cache"; the `cache=hit` on the GET shows upstream was never
touched. Encrypted uploads skip this path — each encryption uses a
fresh random key, so the ref→content mapping isn't stable.

**Client keep-alive.** All responses now honour the HTTP/1.1
connection-persistence default. potjs's bulk-insert pattern (~8000
puts per three concurrent POT `save()` calls) can reuse one TCP
connection per worker instead of paying TCP+HTTP handshake per chunk.

Quick curl verification:

```bash
curl -v -o /dev/null -X POST -d "a" http://127.0.0.1:1733/bytes \
     --next -o /dev/null -X POST -d "b" http://127.0.0.1:1733/bytes 2>&1 \
     | grep -E "^\*|^< HTTP|^< Connection"
```

Expected:

```
* Connected to 127.0.0.1
< HTTP/1.1 201 Created
* Connection #0 to host 127.0.0.1 left intact
* Re-using existing connection with host 127.0.0.1
< HTTP/1.1 201 Created
* Connection #0 to host 127.0.0.1 left intact
```

`Re-using existing connection` is the proof. Fatal forward errors
still close the connection, because the transport state isn't
trustworthy after an interrupted forward.

---

## 10e. POST dedup (potjs-friendly)

Libraries like potjs walk a Proximity Order Trie on every `save()`
and POST every serialised node, even when most of the tree hasn't
changed. Three parallel KVSs (byNumber / byHash / byTx in
fullcircle-research) often share overlapping node bytes. The proxy
hashes every `POST /bytes` and `POST /chunks` body with SHA-256 and
keys under `(content_hash, postage_batch_id)`. Second uploads of the
same content under the same batch short-circuit to the cached
response without touching the backend.

Three behaviours to know:

**Same content + same batch → hit, upstream not touched**

```bash
BATCH=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "same-content" http://127.0.0.1:1733/bytes
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "same-content" http://127.0.0.1:1733/bytes
```

Proxy log:

```
POST /bytes -> 201 … post_dedup=stored root=cae1b3fa span=12B leaf
POST /bytes -> 201 … post_dedup=hit    root=cae1b3fa span=12B leaf
```

**Same content + different batch → miss, stored fresh**

```bash
BATCH2=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
curl -s -X POST -H "swarm-postage-batch-id: $BATCH2" -d "same-content" http://127.0.0.1:1733/bytes
```

Proxy log:

```
POST /bytes -> 201 … post_dedup=stored root=cae1b3fa …
```

A fresh postage batch is a distinct stamp-funded universe; we must not
skip a legitimately-stamp-funded upload.

**Encrypted uploads are never deduped**

```bash
curl -s -X POST -H "swarm-encrypt: true" -d "same-content" http://127.0.0.1:1733/bytes
curl -s -X POST -H "swarm-encrypt: true" -d "same-content" http://127.0.0.1:1733/bytes
```

Proxy log (note no `post_dedup=` segment):

```
POST /bytes -> 201 … enc=yes
POST /bytes -> 201 … enc=yes
```

Each encrypted upload uses a fresh random key, so identical plaintext
produces distinct chunks — deduping would break correctness.

**Dashboard** at `GET /_proxy` has a "POST dedup" section with
entries / hits / misses / bytes saved. Disable with `--no-post-dedup`.

---

## 10d. Mantaray manifest probe

`POST /bzz` uploads produce a Mantaray root chunk rather than a plain
BMT data tree. When the proxy sees a 201 response on a `/bzz` path it
side-fetches the root chunk, deobfuscates the fixed-size header, and
— if the `mantaray` magic is present — reports the version string
and the number of forks at the root.

Against real Bee, a website upload will log something like:

```
POST /bzz -> 201 (…) root=<hex8> span=<N>B children=<C> leaves≈<L> depth≈<D> manifest=yes ver=mantaray:1.0 forks=7
```

`children` is from the BMT chunk-tree inspection (how many 32-byte
refs the root chunk carries at that binary level). `forks` is from
the Mantaray decode (how many HTTP-level first-bytes branch out). For
a typical small website they should match.

Full path → reference resolution (which would let the proxy tell you
"this upload contains `index.html` at chunk X and `assets/logo.png`
at chunk Y") is a P2 stretch goal and not implemented yet.

---

## 10c. Encryption & ACT observation

Bee supports encrypted uploads (`swarm-encrypt: true`) and Access
Control Tries for gated access (`swarm-act`, `swarm-act-publisher`,
`swarm-act-history-address`). The proxy watches for any of these on
requests and responses and surfaces them in two places.

In the terminal log:

```bash
curl -s -X POST -H "swarm-encrypt: true" -d "secret" http://127.0.0.1:1733/bytes
curl -s -X POST -H "swarm-act-publisher: abc12345def67890" -d "act-content" http://127.0.0.1:1733/bytes
```

Proxy log:

```
POST /bytes -> 201 (1ms req=6B  resp=80B) root=2bb80d53 span=6B  leaf enc=yes
POST /bytes -> 201 (1ms req=11B resp=80B) root=1e2d1595 span=11B leaf act=yes pub=abc12345
```

And on the dashboard (`GET /_proxy`) under **Encryption & ACT**:

```
encrypted requests  |  ACT requests
         1          |       1
```

The counters are lifetime totals per proxy process. No crypto happens
in the proxy — it just observes and reports.

---

## 10b. Replay log

Append every request/response to an ndjson file. Each line is one
event with base64-encoded bodies, safe for binary chunks.

```bash
./zig-out/bin/swarm_dev_proxy --mock --replay-log /tmp/replay.ndjson
```

In another terminal:

```bash
curl -s http://127.0.0.1:1733/health > /dev/null
curl -s -X POST -d "abc" http://127.0.0.1:1733/bytes > /dev/null
```

The log now has:

```
{"ts_ms":1776899523294,"method":"GET","target":"/health","req_headers":[…],"req_body_b64":"","resp_status":200,"resp_headers":[["content-type","text/plain"]],"resp_body_b64":"b2sK"}
{"ts_ms":1776899523299,"method":"POST","target":"/bytes","req_headers":[…],"req_body_b64":"YWJj","resp_status":201,"resp_headers":[["content-type","application/json"]],"resp_body_b64":"eyJyZWZl…"}
```

(`b2sK` = `ok\n`, `YWJj` = `abc` — quick sanity check.)

`jq` works out of the box:

```bash
jq -r '[.method, .target, .resp_status] | @tsv' /tmp/replay.ndjson
```

Use cases:
- share a bug-reproducing interaction as a single file
- feed the log through a future `--replay` driver to repeat a bug against a different node
- grep for status codes, decode bodies with `base64 -d`, diff two runs.

---

## 11. CLI flags

```bash
./zig-out/bin/swarm_dev_proxy --help
```

```
swarm-dev-proxy — forward HTTP proxy for the Bee API

Usage: swarm-dev-proxy [options]

Options:
  --listen HOST:PORT     address to listen on (default 127.0.0.1:1733)
  --upstream HOST:PORT   upstream Bee node (default 127.0.0.1:1633)
  --no-cache             disable GET /bytes and /chunks response cache
  --no-chunks            skip root-chunk side-fetch on POST /bytes and /bzz
  --no-post-dedup        disable content-hash dedup of POST /bytes and /chunks
  --mock                 serve from in-process mock (no upstream required)
  --replay-log FILE      append every request/response to FILE as ndjson
  --help, -h             show this message
```

Useful combinations:

```bash
# Hackathon demo — no Bee needed:
./zig-out/bin/swarm_dev_proxy --mock

# Bind to all interfaces, point at a remote Bee:
./zig-out/bin/swarm_dev_proxy --listen 0.0.0.0:1733 --upstream 10.0.0.5:1633

# Pure passthrough, no bells and whistles:
./zig-out/bin/swarm_dev_proxy --no-cache --no-chunks

# Redirect logs to a file for later analysis:
./zig-out/bin/swarm_dev_proxy --mock 2>/tmp/proxy.log
```

---

## 12. Against a real Bee node

Everything above also works against a live Bee. Drop the `--mock`:

```bash
./zig-out/bin/swarm_dev_proxy --upstream 127.0.0.1:1633
```

Then point `swarm-cli`, `bee-js`, your dapp, or raw `curl` at `:1733`.
The proxy observes every call and keeps the logs rolling. Stamp
utilization, feed indexes, and chunk tree shapes will reflect real
data from the node.

Note: references produced in mock mode use SHA-256, not Swarm's
BMT/keccak hash. Content stored via mock cannot be retrieved from a
real Bee node and vice versa — mock mode is explicitly a parallel
universe for testing.

---

## 13. Running the test suite

Every feature above has at least one integration test that spins up a
mock upstream + the proxy in-process, sends a real HTTP request, and
asserts the round-trip:

```bash
zig build test
```

45 tests total, covering:

- the core round-trip
- per-batch stamp tallies and capacity side-fetch
- 80 % utilization threshold crossing
- feed reads capturing `swarm-feed-index` headers
- SOC writes counting bytes
- second `GET /bytes/{ref}` served from cache without touching upstream
- root-chunk inspection, leaf + intermediate trees
- full mock-mode POST+GET round-trip with no upstream running at all
- `GET /_proxy` renders a dashboard containing seeded tracker state
- `--replay-log` writes one valid ndjson line per forwarded request
- `swarm-encrypt` / `swarm-act-*` headers bump the per-proxy counters
- `POST /bzz` responses trigger a mock-aware Mantaray side-fetch and
  report version + fork count
- Second `POST /bytes` with identical body + batch is deduped (upstream
  only accepts the first connection — test hangs if dedup breaks)
- `GET /bytes/{ref}` after a `POST /bytes` hits the download cache
  populated by write-through (upstream is closed before the GET)

Output includes each integration test's proxy log line — a decent
sanity check that the log format hasn't drifted.

---

## 14. Full scripted demo

For a live walkthrough you can paste this directly:

```bash
# Terminal 1
./zig-out/bin/swarm_dev_proxy --mock

# Terminal 2
P=http://127.0.0.1:1733

curl -s $P/health; echo
REF=$(curl -s -X POST -d "hello from curl" $P/bytes | grep -oE '[a-f0-9]{64}')
echo "reference=$REF"
curl -s $P/bytes/$REF; echo
curl -s $P/bytes/$REF; echo        # second GET — watch for cache=hit

BATCH=abcdef01deadbeefcafebabe0123456789abcdef0123456789abcdef01234567
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "stamped" $P/bytes; echo
curl -s -X POST -H "swarm-postage-batch-id: $BATCH" -d "again"   $P/bytes; echo

OWNER=aabbccddeeff00112233445566778899aabbccdd
TOPIC=1122334455667788991122334455667788112233
curl -s "$P/feeds/$OWNER/$TOPIC?type=sequence"; echo

curl -s -X POST -d "soc-payload" "$P/soc/deadbeef/cafebabe?sig=aa"; echo
```

Everything you've learned from the sections above shows up in Terminal
1 as the commands fire.
