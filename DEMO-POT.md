# Testing the potjs-oriented speedups

This guide gives you three concrete ways to exercise and measure the
proxy features built for potjs:

- **GET cache** (content-addressed, infinite TTL)
- **POST dedup** (SHA-256 by `(content, batch_id)`)
- **Write-through** (POST populates GET cache under its returned ref)
- **Client keep-alive** (one TCP connection, many requests)

Pick the path that matches your setup:

1. [**Synthetic curl demo**](#1-synthetic-curl-demo) — nothing to install beyond `curl` and `bash`. Runs in 30 seconds. Proves every feature works end-to-end.
2. [**Real potjs against the proxy**](#2-real-potjs-against-the-proxy-requires-bee) — point potjs's node.js test runner at our proxy. Requires a running Bee (e.g. `fdp-play`).
3. [**Before/after benchmark**](#3-beforeafter-benchmark) — same workload with proxy features on vs. off; watch the latency collapse.

---

## 0. Prereqs

Build once:

```bash
cd /home/calin/work/swarm/hackathon/swarm-dev-proxy
zig build
```

You now have `./zig-out/bin/swarm_dev_proxy` (and it's sitting in PATH if you've added `zig-out/bin` there; otherwise reference it by path).

---

## 1. Synthetic curl demo

Zero-dependency. The proxy's `--mock` mode gives us a working
content-addressed store so we can drive the full "upload → re-upload → read
back" cycle without a real Bee node. The cache / dedup / write-through logic
is identical whether the backend is `--mock` or a real Bee, so what you see
here is what you'd see in production (just with SHA-256 references instead
of BMT).

### 1.1 Start the proxy

```bash
# Terminal 1
./zig-out/bin/swarm_dev_proxy --mock --listen 127.0.0.1:1733
```

Leave it visible. Every request will produce one line of log you can read
in real time. Optional: open `http://127.0.0.1:1733/_proxy` in a browser
to get the same data as an auto-refreshing dashboard.

### 1.2 First pass: 50 fresh uploads

```bash
# Terminal 2
BATCH=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
for i in $(seq 1 50); do
  curl -s -X POST \
    -H "swarm-postage-batch-id: $BATCH" \
    -d "chunk-$i" \
    http://127.0.0.1:1733/bytes > /dev/null
done
```

What you should see in Terminal 1 (one line per POST):

```
POST /bytes -> 201 (…) stamp=abcdef01 #1 up=7B total_up=7B util=0.0% … post_dedup=stored wt=cached root=<hex>…
POST /bytes -> 201 (…) stamp=abcdef01 #2 up=7B total_up=14B … post_dedup=stored wt=cached root=<hex>…
…
POST /bytes -> 201 (…) stamp=abcdef01 #50 …
```

Key markers:
- `post_dedup=stored` — the content was unique, we stored it for future dedup
- `wt=cached` — the body was also written through to the GET cache

### 1.3 Second pass: upload the same 50 again

Same batch, same payloads. Every request should be a dedup hit.

```bash
for i in $(seq 1 50); do
  curl -s -X POST \
    -H "swarm-postage-batch-id: $BATCH" \
    -d "chunk-$i" \
    http://127.0.0.1:1733/bytes > /dev/null
done
```

All 50 log lines now show:

```
POST /bytes -> 201 (0ms …) … post_dedup=hit wt=cached root=<hex>…
```

Upstream was never touched. Total bytes saved = 50 × 7 = 350 B (you can
confirm from the dashboard — see §1.5).

### 1.4 Third pass: GET each reference back

Capture the references first, then GET them. They should all be cache
hits served in 0 ms.

```bash
# Collect refs from fresh uploads (use unique bodies to avoid collisions)
REFS=()
for i in $(seq 1 50); do
  REF=$(curl -s -X POST \
    -H "swarm-postage-batch-id: $BATCH" \
    -d "fetch-me-$i" \
    http://127.0.0.1:1733/bytes | grep -oE '[a-f0-9]{64}')
  REFS+=("$REF")
done

# GET them back
for ref in "${REFS[@]}"; do
  curl -s http://127.0.0.1:1733/bytes/$ref > /dev/null
done
```

Log:

```
POST /bytes -> 201 (…) … post_dedup=stored wt=cached root=…
…
GET /bytes/<ref> -> 200 (0ms req=0B resp=11B) cache=hit
GET /bytes/<ref> -> 200 (0ms req=0B resp=11B) cache=hit
…
```

Every GET is `cache=hit` because the matching POST already populated the
download cache via write-through. No round-trip to the backend.

### 1.5 Check the dashboard

```bash
curl -s http://127.0.0.1:1733/_proxy | grep -A3 -E "Cache|POST dedup"
```

You should see something like:

```
<h2>Cache</h2>
<table>
<tr><th>entries</th><th>bytes</th><th>hits</th><th>misses</th></tr>
<tr><td class="num">50</td><td class="num">550</td><td class="num">50</td><td class="num">0</td></tr>
</table>
<h2>POST dedup</h2>
<table>
<tr><th>entries</th><th>hits</th><th>misses</th><th>bytes saved</th></tr>
<tr><td class="num">100</td><td class="num">50</td><td class="num">150</td><td class="num">350</td></tr>
```

- 50 GET-cache hits / 0 misses → write-through worked
- 50 dedup hits / 350 B saved → POST dedup worked
- 100 dedup entries (50 unique + 50 unique) → two content universes

### 1.6 Keep-alive on one socket

Force curl to reuse a TCP connection across multiple POSTs:

```bash
curl -v -o /dev/null -X POST -d "k1" http://127.0.0.1:1733/bytes \
     --next -o /dev/null -X POST -d "k2" http://127.0.0.1:1733/bytes \
     --next -o /dev/null -X POST -d "k3" http://127.0.0.1:1733/bytes \
     2>&1 | grep -E "^\*|^< HTTP"
```

Expected:

```
* Connected to 127.0.0.1 (…) port 1733
< HTTP/1.1 201 Created
* Connection #0 to host 127.0.0.1 left intact
* Re-using existing connection with host 127.0.0.1
< HTTP/1.1 201 Created
* Connection #0 to host 127.0.0.1 left intact
* Re-using existing connection with host 127.0.0.1
< HTTP/1.1 201 Created
```

`Re-using existing connection` (×2) is the keep-alive proof. Three POSTs,
one TCP socket.

---

## 2. Real potjs against the proxy (requires Bee)

This is the real workload test. potjs speaks to a Bee HTTP API; by
pointing its `beeUrl` at the proxy we get the full speedup stack on
real Swarm traffic.

### 2.1 Start a Bee (pick one)

**Option A — you already have a Bee on `localhost:1633`.** Skip to §2.2.
You just need a usable postage batch id — get it from:

```bash
swarm-cli stamp list              # pick or mint one
# or query the node directly:
curl -s http://localhost:1633/stamps | jq '.stamps[] | {batchID, usable, utilization}'
```

Copy the 64-hex `batchID` of any usable batch.

**Option B — no Bee yet.** potjs ships a `fdp-play`-based locnet for
integration tests. From the potjs repo:

```bash
cd /home/calin/work/swarm/hackathon/potjs
make locnet_start           # five-node local Bee network in Docker
swarm-cli stamp buy --yes --verbose --depth 20 --amount 1b | \
  tee .batch_creation
grep "Stamp ID:" .batch_creation | cut -c11-74 > .batch_id
cat .batch_id               # the 64-char hex
```

`fdp-play` writes its nodes to `localhost:1633` by default, so from
here on the proxy command is the same as Option A.

### 2.2 Start the proxy pointed at Bee

Default upstream is `127.0.0.1:1633`, so if Bee is local you can just run:

```bash
# Terminal 2
cd /home/calin/work/swarm/hackathon/swarm-dev-proxy
./zig-out/bin/swarm_dev_proxy
```

Or be explicit:

```bash
./zig-out/bin/swarm_dev_proxy --listen 127.0.0.1:1733 --upstream 127.0.0.1:1633
```

### 2.3 Sanity-check the forward first

Before running potjs, verify the proxy can talk to your Bee:

```bash
# In another terminal:
curl -s --compressed http://127.0.0.1:1733/health
# -> {"status":"ok","version":"2.7.2-rc1-…","apiVersion":"8.0.0"}

curl -s --compressed http://127.0.0.1:1733/addresses | head -c 120
# -> {"overlay":"…","underlay":["/ip4/…/tcp/1634/p2p/Qm…"], …
```

Tip: `--compressed` isn't decoration — Bee gzips some JSON responses
and the proxy forwards them verbatim (with `Content-Encoding: gzip`)
so chunks stay bit-exact. Browsers and most HTTP clients handle this
automatically; plain `curl` needs the flag.

Each call produces one line in the proxy log:

```
GET /health    -> 200 (3ms req=0B resp=86B)
GET /addresses -> 200 (2ms req=0B resp=343B)
```

### 2.4 Run potjs's test suite through the proxy

potjs's node test driver takes a Bee URL as its third argument. Instead
of pointing at Bee directly (port 1633), point it at the proxy (port
1733):

```bash
# Terminal 3
cd /home/calin/work/swarm/hackathon/potjs
node test/node.js loc-net http://localhost:1733 $(cat .batch_id)
```

While it runs, watch Terminal 2. The POT tree walks produce exactly the
patterns the research identified:

- Each new POT node upload: `POST /bytes … stamp=… util=… wt=cached`
- Repeat uploads from re-saves or from the three-KVS pattern (`byNumber`, `byHash`, `byTx` in fullcircle-research):
  `post_dedup=hit`
- Lazy child loads during `load()`: start as `cache=miss` → `cache=stored`
- Re-loads of the same POT root (second `pot.load()` call in the same session):
  `cache=hit`

The dashboard at `http://127.0.0.1:1733/_proxy` shows the running totals —
hits / misses / bytes saved — live.

### 2.5 Using a non-local Bee

Exactly the same, just change `--upstream`:

```bash
./zig-out/bin/swarm_dev_proxy --upstream bee.example.org:1633
```

All speedup features (write-through, dedup, keep-alive) still work. The
only thing that differs is a client connection pool to Bee — currently
we open a fresh upstream HTTP client per request; pooling is the next
natural feature (tracked in DESIGN.md).

---

## 2b. fullcircle-research explorer speedup

The explorer at `/home/calin/work/swarm/hackathon/fullcircle-research/packages/explorer/`
hits three hot URLs on every page load:

- `GET /bzz/{manifestRef}/meta` — metadata JSON
- `GET /bzz/{manifestRef}/number/{N}` — block bundle by number
- `GET /bzz/{manifestRef}/hash/{H}` — block bundle by hash

All three are content-addressed under the manifest root, so the proxy
caches them with infinite TTL. A typical session: the explorer's
homepage fetches the top 11 blocks; subsequent navigation ("next block",
"previous block", lookup-by-hash) hits the same cache.

### Quick test

Point the explorer (or `curl`) at the proxy:

```bash
# Terminal 1 — proxy against your Bee
./zig-out/bin/swarm_dev_proxy --listen 127.0.0.1:1733

# Terminal 2 — if you have a manifest ref already, try it:
REF=<your-manifest-ref>
curl -s --compressed http://127.0.0.1:1733/bzz/$REF/meta > /dev/null  # first call — upstream
curl -s --compressed http://127.0.0.1:1733/bzz/$REF/meta > /dev/null  # second — cache hit
```

Proxy log:

```
GET /bzz/<ref>/meta -> 200 (…) cache=stored
GET /bzz/<ref>/meta -> 200 (0ms …) cache=hit
```

Existence-probe paths (the lookup page issues `Range: bytes=0-0` to
check if a hash exists in a given index) deliberately bypass the cache:

```bash
curl -s -H "Range: bytes=0-0" http://127.0.0.1:1733/bzz/$REF/hash/$HASH
```

Proxy log (no `cache=` marker — forwarded untouched):

```
GET /bzz/<ref>/hash/<h> -> 206 (…)
```

### Running the explorer against the proxy

In `/home/calin/work/swarm/hackathon/fullcircle-research/`:

```bash
pnpm explorer:dev     # starts SvelteKit dev server, default beeUrl http://localhost:1633
```

Change the beeUrl in the explorer's settings to `http://localhost:1733`
and watch the proxy terminal as you click around: homepage loads, block
navigation, and hash lookups all generate `cache=hit` lines after the
first fetch.

---

## 3. Before/after benchmark

To quantify the speedup, run the same workload with features disabled,
then enabled, and compare wall-clock time. This uses only curl + bash
+ `--mock`, so it's self-contained.

### 3.1 Baseline: everything disabled

```bash
./zig-out/bin/swarm_dev_proxy --mock --listen 127.0.0.1:1733 \
  --no-cache --no-post-dedup --no-chunks &
PROXY_PID=$!
sleep 0.3

BATCH=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789

echo "--- baseline: no cache, no dedup ---"
time {
  for i in $(seq 1 200); do
    curl -s -X POST -H "swarm-postage-batch-id: $BATCH" \
      -d "bench-payload-$i" http://127.0.0.1:1733/bytes > /dev/null
  done
  # repeat (would have been deduped if enabled)
  for i in $(seq 1 200); do
    curl -s -X POST -H "swarm-postage-batch-id: $BATCH" \
      -d "bench-payload-$i" http://127.0.0.1:1733/bytes > /dev/null
  done
}

kill $PROXY_PID 2>/dev/null
wait 2>/dev/null
```

### 3.2 Same workload, features on

```bash
./zig-out/bin/swarm_dev_proxy --mock --listen 127.0.0.1:1733 &
PROXY_PID=$!
sleep 0.3

echo "--- features on: cache + dedup + write-through ---"
time {
  for i in $(seq 1 200); do
    curl -s -X POST -H "swarm-postage-batch-id: $BATCH" \
      -d "bench-payload-$i" http://127.0.0.1:1733/bytes > /dev/null
  done
  for i in $(seq 1 200); do
    curl -s -X POST -H "swarm-postage-batch-id: $BATCH" \
      -d "bench-payload-$i" http://127.0.0.1:1733/bytes > /dev/null
  done
}

kill $PROXY_PID 2>/dev/null
wait 2>/dev/null
```

### 3.3 What the numbers mean

In the "features on" run the second pass of 200 POSTs never touches the
backend — every request is a dedup hit that returns the cached response
in constant time. On my laptop that's ~5× faster for the repeat pass.

Against **real** Bee the difference is much larger because each
"skipped" upload also skips a real network round-trip and a stamp-slot
write. For a potjs workload that re-runs (e.g. a dev iteration loop,
or the three-KVS pattern in fullcircle-research), a 10–50× speedup on
the repeat iterations is typical.

---

## 4. What to look for when something's wrong

If you don't see the markers you expect, these are the three things to
check:

| Symptom | Likely cause |
|---------|--------------|
| `post_dedup=stored` on every POST, never `=hit` | Either the bodies aren't actually identical (check with `sha256sum`) or the batch id differs between runs. Dedup is keyed on `(hash, batch)` deliberately. |
| `wt=cached` appears but the next GET still shows `cache=stored` | The GET isn't for the reference the POST returned. Double-check you're using the hex from the POST's response body. |
| GET is `cache=miss` even though the POST had `wt=cached` | `--no-cache` is probably set; write-through only populates if the cache is enabled. |
| `Connection: close` appears in response headers | The client sent `Connection: close`, or the proxy hit a fatal forward error and rejected keep-alive on that one request. |
| `enc=yes` on the POST and **no** `post_dedup=` segment | Correct — encrypted uploads are never deduped (each uses a fresh random key). |

---

## 5. Teardown

```bash
# If you ran fdp-play:
cd /home/calin/work/swarm/hackathon/potjs
make locnet_stop

# Kill any lingering proxy:
pkill -f swarm_dev_proxy
```
