//! swarm-dev-proxy library: transparent forward proxy for the Bee HTTP API
//! with a structured request log. This is P0 of the design — correctness
//! first, Swarm-awareness bolts onto forwardRequest later.

const std = @import("std");
const http = std.http;
const net = std.net;
const Io = std.Io;

pub const stamps = @import("stamps.zig");
pub const feeds = @import("feeds.zig");
pub const cache = @import("cache.zig");
pub const chunks = @import("chunks.zig");
pub const mock = @import("mock.zig");
pub const ui = @import("ui.zig");
pub const replay = @import("replay.zig");
pub const manifest = @import("manifest.zig");
pub const post_dedup = @import("post_dedup.zig");

pub const Config = struct {
    listen_addr: []const u8 = "127.0.0.1",
    listen_port: u16 = 1733,
    upstream_host: []const u8 = "127.0.0.1",
    upstream_port: u16 = 1633,
    cache_enabled: bool = true,
    /// Whether to side-fetch and decode the root chunk on POST /bytes /
    /// POST /bzz responses. Adds one extra upstream round-trip per
    /// upload; disable if that latency gets in the way.
    chunk_inspection_enabled: bool = true,
    /// When true, serve every request from an in-process mock backend
    /// instead of forwarding to `upstream_host:upstream_port`. Hashes
    /// are SHA-256 (not Swarm BMT), so content stored here won't
    /// resolve against a real Bee node.
    mock_enabled: bool = false,
    /// When true, dedupe `POST /bytes` and `POST /chunks` by SHA-256
    /// of the body + postage batch id. Second uploads of the same
    /// content under the same batch short-circuit to the cached
    /// response without touching the backend.
    post_dedup_enabled: bool = true,
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    tracker: stamps.Tracker,
    feed_tracker: feeds.Tracker,
    download_cache: cache.Cache,
    mock_backend: mock.Backend,
    post_dedup_cache: post_dedup.Cache,
    /// Long-lived HTTP client for every upstream call. Its internal
    /// `ConnectionPool` keeps TCP connections to Bee alive across
    /// requests, which is the upstream mirror of the HTTP keep-alive
    /// we give dapp clients. For a potjs bulk save (~8000 POST /bytes
    /// calls) this collapses ~8000 TCP handshakes to a handful.
    upstream_client: http.Client,
    /// Optional replay log; owned by `main`/caller, set via
    /// `setReplayWriter` after `init`. A null pointer means "no log".
    replay_writer: ?*replay.Writer = null,
    /// Lifetime counters for encryption/ACT observation. Surfaced on
    /// the /_proxy dashboard. Bumped atomically so single-log reads
    /// during concurrent dispatch are consistent.
    enc_count: std.atomic.Value(u64) = .init(0),
    act_count: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, cfg: Config) Proxy {
        return .{
            .gpa = gpa,
            .cfg = cfg,
            .tracker = .{ .gpa = gpa },
            .feed_tracker = .{ .gpa = gpa },
            .download_cache = .{ .gpa = gpa },
            .mock_backend = .{ .gpa = gpa },
            .post_dedup_cache = .{ .gpa = gpa },
            .upstream_client = .{ .allocator = gpa },
        };
    }

    pub fn deinit(self: *Proxy) void {
        self.tracker.deinit();
        self.feed_tracker.deinit();
        self.download_cache.deinit();
        self.mock_backend.deinit();
        self.post_dedup_cache.deinit();
        self.upstream_client.deinit();
    }

    pub fn run(self: *Proxy) !void {
        const address = try net.Address.parseIp(self.cfg.listen_addr, self.cfg.listen_port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        var banner_buf: [256]u8 = undefined;
        var banner_writer = std.fs.File.stderr().writerStreaming(&banner_buf);
        const banner = &banner_writer.interface;
        try banner.print(
            "swarm-dev-proxy listening on http://{s}:{d} -> http://{s}:{d}\n",
            .{
                self.cfg.listen_addr,  self.cfg.listen_port,
                self.cfg.upstream_host, self.cfg.upstream_port,
            },
        );
        try banner.flush();

        while (true) {
            const conn = server.accept() catch |err| {
                logErr("accept", err);
                continue;
            };
            // Detached thread per connection — real concurrency so
            // clients with parallel workers (bee-js's manifestUploader
            // fires 32-concurrent) don't serialize at the accept loop.
            // Everything the thread touches is protected:
            //   * shared http.Client -> thread-safe ConnectionPool
            //   * all trackers + caches -> their own mutexes
            //   * enc/act counters -> atomics
            //   * request-scoped state (req_body, resp_headers, ...)
            //     is stack-local to each thread.
            const t = std.Thread.spawn(.{}, connectionEntry, .{ self, conn }) catch |err| {
                logErr("spawn", err);
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    /// Entry for detached per-connection worker threads.
    fn connectionEntry(self: *Proxy, conn: net.Server.Connection) void {
        self.handleConnection(conn) catch |err| {
            logErr("connection", err);
        };
    }

    /// Accepts a single connection (already established), serves it, returns.
    /// Extracted so tests can drive the proxy without binding a real socket
    /// forever.
    pub fn handleConnection(self: *Proxy, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var read_buf: [32 * 1024]u8 = undefined;
        var write_buf: [8 * 1024]u8 = undefined;
        var net_reader = conn.stream.reader(&read_buf);
        var net_writer = conn.stream.writer(&write_buf);

        var server = http.Server.init(net_reader.interface(), &net_writer.interface);

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return err,
            };
            self.forwardRequest(&request) catch |err| {
                // Richer diagnostic than plain `logErr` — include the
                // method and target so the user can correlate the 502
                // to the exact request. Avoids "why did my client see
                // a 502?" mysteries.
                var buf: [512]u8 = undefined;
                var w = std.fs.File.stderr().writerStreaming(&buf);
                w.interface.print("forward error: {s} {s} -> {s}\n", .{
                    @tagName(request.head.method),
                    request.head.target,
                    @errorName(err),
                }) catch {};
                w.interface.flush() catch {};
                // Best-effort 502; close the connection after a fatal
                // forward error — the transport state is suspect.
                request.respond("bad gateway\n", .{
                    .status = .bad_gateway,
                    .keep_alive = false,
                }) catch {};
                return;
            };
        }
    }

    fn forwardRequest(self: *Proxy, request: *http.Server.Request) !void {
        const started = std.time.milliTimestamp();
        const method = request.head.method;

        // request.head.target points into the request read buffer and is
        // invalidated once we start reading the body.
        const target_owned = try self.gpa.dupe(u8, request.head.target);
        defer self.gpa.free(target_owned);

        const parsed_path: ?feeds.PathKind = feeds.parsePath(target_owned);

        // Dashboard intercept. `/_proxy` never reaches a backend; it
        // renders a snapshot of the proxy's own state. Guard on a
        // prefix so future sub-pages can live under `/_proxy/...`.
        if (method == .GET and std.mem.startsWith(u8, pathOnly(target_owned), "/_proxy")) {
            try self.serveDashboard(request);
            const elapsed_ms = std.time.milliTimestamp() - started;
            logRequest(.{
                .method = method,
                .target = target_owned,
                .status = .ok,
                .elapsed_ms = elapsed_ms,
                .req_bytes = 0,
                .resp_bytes = 0,
            });
            return;
        }

        // Range requests bypass the cache entirely. We currently only
        // store full bodies; synthesising a 206 from a cached 200 is a
        // later feature. The explorer uses `Range: bytes=0-0` as a
        // cheap existence probe on /bzz paths — always forwarding is
        // both correct and plenty fast.
        const has_range = blk_range: {
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "range")) break :blk_range true;
            }
            break :blk_range false;
        };

        // Cache lookup (immutable content-addressed GETs only).
        const cache_key: ?[]const u8 = blk: {
            if (!self.cfg.cache_enabled) break :blk null;
            if (method != .GET) break :blk null;
            if (has_range) break :blk null;
            break :blk cache.keyForGet(target_owned);
        };
        if (cache_key) |key| {
            if (self.download_cache.get(key)) |entry| {
                const extras: []const http.Header = if (entry.content_type) |ct|
                    &.{.{ .name = "content-type", .value = ct }}
                else
                    &.{};
                try request.respond(entry.body, .{
                    .status = @enumFromInt(entry.status),
                    .extra_headers = extras,
                    .keep_alive = request.head.keep_alive,
                });
                const elapsed_ms = std.time.milliTimestamp() - started;
                logRequest(.{
                    .method = method,
                    .target = target_owned,
                    .status = @enumFromInt(entry.status),
                    .elapsed_ms = elapsed_ms,
                    .req_bytes = 0,
                    .resp_bytes = entry.body.len,
                    .cache_result = .hit,
                });
                return;
            }
        }

        // Snapshot forwarded headers before invalidation (skip hop-by-hop).
        // Capture swarm-postage-batch-id while we're at it so stamp tracking
        // doesn't need a second pass.
        var fwd_headers: std.ArrayList(http.Header) = .empty;
        defer {
            for (fwd_headers.items) |h| {
                self.gpa.free(h.name);
                self.gpa.free(h.value);
            }
            fwd_headers.deinit(self.gpa);
        }
        var batch_id_owned: ?[]u8 = null;
        defer if (batch_id_owned) |b| self.gpa.free(b);
        {
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "swarm-postage-batch-id") and batch_id_owned == null) {
                    batch_id_owned = try self.gpa.dupe(u8, h.value);
                }
                if (isHopByHop(h.name)) continue;
                try fwd_headers.append(self.gpa, .{
                    .name = try self.gpa.dupe(u8, h.name),
                    .value = try self.gpa.dupe(u8, h.value),
                });
            }
        }

        // Collect the request body (simple, non-streaming for P0).
        var req_body: Io.Writer.Allocating = .init(self.gpa);
        defer req_body.deinit();

        if (method.requestHasBody()) {
            var body_buf: [16 * 1024]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_buf);
            _ = body_reader.streamRemaining(&req_body.writer) catch |err| switch (err) {
                error.ReadFailed, error.WriteFailed => return err,
            };
        }
        const req_body_bytes = req_body.written();

        // Response-side buffers (populated by mock or upstream below).
        var resp_status: http.Status = undefined;

        var resp_headers: std.ArrayList(http.Header) = .empty;
        defer {
            for (resp_headers.items) |h| {
                self.gpa.free(h.name);
                self.gpa.free(h.value);
            }
            resp_headers.deinit(self.gpa);
        }

        var resp_body: Io.Writer.Allocating = .init(self.gpa);
        defer resp_body.deinit();

        // POST dedup check (before dispatching to the backend). If the
        // same payload under the same batch has been successfully
        // uploaded already this process, short-circuit to the cached
        // response. Never dedupes encrypted uploads — `swarm-encrypt`
        // generates a fresh random key per call.
        var post_dedup_key_hex: ?[64]u8 = null;
        var post_dedup_result: PostDedupResult = .none;
        const request_enc = sniffEnc(fwd_headers.items);
        if (self.cfg.post_dedup_enabled and method == .POST and
            post_dedup.isDedupablePath(target_owned) and !request_enc.encrypted)
        {
            post_dedup_key_hex = post_dedup.Cache.hashContent(req_body_bytes);
            const batch_key: []const u8 = if (batch_id_owned) |b| b else "";
            if (self.post_dedup_cache.get(post_dedup_key_hex.?[0..], batch_key)) |cached| {
                resp_status = @enumFromInt(cached.status);
                if (cached.content_type) |ct| try appendHeader(self.gpa, &resp_headers, "content-type", ct);
                try resp_body.writer.writeAll(cached.body);
                post_dedup_result = .hit;
            }
        }

        if (post_dedup_result == .hit) {
            // Response buffers already populated from the cache; skip
            // the backend entirely.
        } else if (self.cfg.mock_enabled) {
            const mr = try self.mock_backend.handle(self.gpa, method, target_owned, req_body_bytes);
            defer self.gpa.free(mr.body);
            resp_status = mr.status;
            if (mr.content_type) |ct| try appendHeader(self.gpa, &resp_headers, "content-type", ct);
            if (mr.feed_index_hex) |idx| try appendHeader(self.gpa, &resp_headers, "swarm-feed-index", idx);
            if (mr.feed_next_hex) |nxt| try appendHeader(self.gpa, &resp_headers, "swarm-feed-index-next", nxt);
            try resp_body.writer.writeAll(mr.body);
        } else {
            // Forward to upstream Bee node via the shared, pooled
            // client. `keep_alive = true` lets the client's internal
            // ConnectionPool reuse the TCP connection for the next
            // upstream call.
            //
            // Retry discipline: pooled connections can go stale (Bee
            // closes an idle TCP conn, server-side GC, etc.). A stale
            // pooled connection then fails the next request instantly
            // with BrokenPipe/ConnectionResetByPeer/ReadFailed — if we
            // bail on that, one bad socket wedges every subsequent
            // request. Fix: on any transport-class error, drop the
            // whole pool (deinit+reinit), then retry once with a fresh
            // dial. Real 4xx/5xx responses from Bee are not treated as
            // transport errors and always pass through.
            const url = try std.fmt.allocPrint(self.gpa, "http://{s}:{d}{s}", .{
                self.cfg.upstream_host, self.cfg.upstream_port, target_owned,
            });
            defer self.gpa.free(url);

            const uri = try std.Uri.parse(url);

            var attempt: u8 = 0;
            while (true) : (attempt += 1) {
                if (attempt > 0) {
                    // Drop anything we partially populated on the failed
                    // attempt so the retry starts from clean state.
                    for (resp_headers.items) |h| {
                        self.gpa.free(h.name);
                        self.gpa.free(h.value);
                    }
                    resp_headers.clearRetainingCapacity();
                    resp_body.writer.end = 0;
                }

                self.sendUpstreamOnce(
                    method,
                    uri,
                    fwd_headers.items,
                    req_body_bytes,
                    &resp_status,
                    &resp_headers,
                    &resp_body,
                ) catch |err| {
                    // Transport-class errors mean the specific pooled
                    // connection was stale; sendUpstreamOnce has already
                    // marked it `closing` via errdefer. Retry once and
                    // the pool will hand us a fresh connection instead.
                    if (attempt < 1 and isUpstreamTransportError(err)) {
                        logPoolReset(err);
                        continue;
                    }
                    return err;
                };
                break;
            }
        }
        const resp_body_bytes = resp_body.written();

        // POST dedup: store on successful miss. Key includes batch id
        // so a fresh batch doesn't inherit a prior batch's stamps.
        if (post_dedup_key_hex) |hash| if (post_dedup_result == .none) {
            const status_int = @intFromEnum(resp_status);
            if (status_int >= 200 and status_int < 300) {
                const batch_key: []const u8 = if (batch_id_owned) |b| b else "";
                const ct = findHeader(resp_headers.items, "content-type");
                self.post_dedup_cache.put(hash[0..], batch_key, .{
                    .status = status_int,
                    .content_type = ct,
                    .body = resp_body_bytes,
                }, req_body_bytes.len) catch {};
                post_dedup_result = .stored;
            } else {
                post_dedup_result = .miss;
            }
        };

        // Write-through: after a successful `POST /bytes` (or /chunks),
        // parse the returned reference and populate the download cache
        // so a subsequent `GET /bytes/<ref>` is free. Works for mock,
        // upstream, and POST-dedup-hit paths — all three populate the
        // same `resp_body_bytes` we read here.
        var write_through_ref: ?[]u8 = null;
        defer if (write_through_ref) |r| self.gpa.free(r);
        if (self.cfg.cache_enabled and method == .POST and
            post_dedup.isDedupablePath(target_owned) and
            !request_enc.encrypted)
        {
            const status_int = @intFromEnum(resp_status);
            if (status_int >= 200 and status_int < 300) {
                if (chunks.parsePostReference(self.gpa, resp_body_bytes)) |parsed| {
                    defer parsed.deinit();
                    // Derive the path prefix from the original target.
                    const prefix = if (std.mem.startsWith(u8, pathOnly(target_owned), "/chunks"))
                        "/chunks/"
                    else
                        "/bytes/";
                    const cache_path = std.fmt.allocPrint(self.gpa, "{s}{s}", .{
                        prefix, parsed.value.reference,
                    }) catch null;
                    if (cache_path) |p| {
                        self.download_cache.put(
                            p,
                            200,
                            "application/octet-stream",
                            req_body_bytes,
                        ) catch {};
                        write_through_ref = p; // retained for the log
                    }
                } else |_| {}
            }
        }

        try request.respond(resp_body_bytes, .{
            .status = resp_status,
            .extra_headers = resp_headers.items,
            .keep_alive = request.head.keep_alive,
        });

        const elapsed_ms = std.time.milliTimestamp() - started;

        var stamp_stats: ?stamps.BatchStats = null;
        var warn_level: stamps.WarnLevel = .none;
        if (batch_id_owned) |bid| {
            const outcome = try self.tracker.record(bid, req_body_bytes.len, resp_body_bytes.len);
            if (outcome.first_record) {
                self.fetchAndStoreCapacity(bid) catch {
                    self.tracker.markCapacityFailed(bid) catch {};
                };
            }
            warn_level = self.tracker.checkAndMarkWarn(bid);
            stamp_stats = self.tracker.snapshot(bid);
        }

        var feed_stats: ?feeds.FeedStats = null;
        var soc_stats: ?feeds.SocStats = null;
        if (parsed_path) |pk| switch (pk) {
            .feed => |id| {
                if (method == .GET or method == .HEAD) {
                    const idx = findHeader(resp_headers.items, "swarm-feed-index");
                    const next = findHeader(resp_headers.items, "swarm-feed-index-next");
                    feed_stats = try self.feed_tracker.recordFeedRead(
                        id.owner, id.key, idx, next, null,
                    );
                } else if (method == .POST or method == .PUT) {
                    feed_stats = try self.feed_tracker.recordFeedWrite(id.owner, id.key);
                }
            },
            .soc => |id| {
                if (method == .POST or method == .PUT) {
                    soc_stats = try self.feed_tracker.recordSocWrite(
                        id.owner, id.key, req_body_bytes.len,
                    );
                }
            },
        };

        var cache_result: CacheResult = .none;
        if (cache_key) |key| {
            if (resp_status == .ok) {
                const ct = findHeader(resp_headers.items, "content-type");
                self.download_cache.put(key, @intFromEnum(resp_status), ct, resp_body_bytes) catch {};
                cache_result = .stored;
            } else {
                cache_result = .miss;
            }
        }

        // Root-chunk inspection: on successful POST /bytes or /bzz,
        // side-fetch the root chunk to surface tree shape in the log.
        // For /bzz we additionally probe the same bytes for Mantaray
        // manifest shape (version, fork count).
        var chunk_info: ?chunks.Inspection = null;
        var manifest_info: ?manifest.Inspection = null;
        var root_ref_owned: ?[]u8 = null;
        defer if (root_ref_owned) |r| self.gpa.free(r);

        const enc = mergeEnc(sniffEnc(fwd_headers.items), sniffEnc(resp_headers.items));
        if (enc.encrypted) _ = self.enc_count.fetchAdd(1, .monotonic);
        if (enc.act) _ = self.act_count.fetchAdd(1, .monotonic);

        if (self.cfg.chunk_inspection_enabled and resp_status == .created and method == .POST and isUploadPath(target_owned)) {
            if (chunks.parsePostReference(self.gpa, resp_body_bytes)) |parsed| {
                defer parsed.deinit();
                root_ref_owned = self.gpa.dupe(u8, parsed.value.reference) catch null;
                if (root_ref_owned) |ref| {
                    chunk_info = self.inspectChunk(ref) catch null;
                    if (isBzzPath(target_owned)) {
                        manifest_info = self.inspectManifest(ref) catch null;
                    }
                }
            } else |_| {}
        }

        logRequest(.{
            .method = method,
            .target = target_owned,
            .status = resp_status,
            .elapsed_ms = elapsed_ms,
            .req_bytes = req_body_bytes.len,
            .resp_bytes = resp_body_bytes.len,
            .batch_id = batch_id_owned,
            .stamp_stats = stamp_stats,
            .warn_level = warn_level,
            .feed_stats = feed_stats,
            .soc_stats = soc_stats,
            .cache_result = cache_result,
            .root_reference = root_ref_owned,
            .chunk_info = chunk_info,
            .enc = enc,
            .manifest_info = manifest_info,
            .post_dedup_result = post_dedup_result,
            .write_through = write_through_ref != null,
        });

        if (self.replay_writer) |rw| {
            rw.record(.{
                .ts_ms = std.time.milliTimestamp(),
                .method = @tagName(method),
                .target = target_owned,
                .req_headers = fwd_headers.items,
                .req_body = req_body_bytes,
                .resp_status = @intFromEnum(resp_status),
                .resp_headers = resp_headers.items,
                .resp_body = resp_body_bytes,
            }) catch {};
        }
    }

    /// One attempt at the upstream round-trip: open request, write body,
    /// read response headers + body. Output parameters are populated on
    /// success; on error, whatever partial state got written is the
    /// caller's problem to reset.
    ///
    /// Thread-safety: on any error we mark this specific connection
    /// `.closing = true` before `deinit` releases it back to the pool.
    /// That tells the pool to drop this connection rather than hand it
    /// out to the next caller. Per-connection safety replaces the
    /// earlier global `deinit(client) + reinit` approach, which was
    /// racy once the accept loop became multi-threaded.
    fn sendUpstreamOnce(
        self: *Proxy,
        method: http.Method,
        uri: std.Uri,
        extra_headers: []const http.Header,
        req_body_bytes: []const u8,
        out_status: *http.Status,
        out_headers: *std.ArrayList(http.Header),
        out_body: *Io.Writer.Allocating,
    ) !void {
        var upstream_req = try self.upstream_client.request(method, uri, .{
            .extra_headers = extra_headers,
            .keep_alive = true,
        });
        defer upstream_req.deinit();
        errdefer if (upstream_req.connection) |c| {
            c.closing = true;
        };

        if (method.requestHasBody()) {
            upstream_req.transfer_encoding = .{ .content_length = req_body_bytes.len };
            var body_writer = try upstream_req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(req_body_bytes);
            try body_writer.end();
            const conn = upstream_req.connection orelse return error.UpstreamConnectionGone;
            try conn.flush();
        } else {
            try upstream_req.sendBodiless();
        }

        var redirect_buf: [4096]u8 = undefined;
        var response = try upstream_req.receiveHead(&redirect_buf);

        out_status.* = response.head.status;

        var rit = response.head.iterateHeaders();
        while (rit.next()) |h| {
            if (isHopByHop(h.name)) continue;
            try out_headers.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, h.name),
                .value = try self.gpa.dupe(u8, h.value),
            });
        }

        if (method.responseHasBody()) {
            var xfer_buf: [16 * 1024]u8 = undefined;
            const body_reader = response.reader(&xfer_buf);
            _ = body_reader.streamRemaining(&out_body.writer) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
                error.WriteFailed => return err,
            };
        }
    }

    fn serveDashboard(self: *Proxy, request: *http.Server.Request) !void {
        const batches = try self.tracker.list(self.gpa);
        defer self.gpa.free(batches);
        const feed_list = try self.feed_tracker.listFeeds(self.gpa);
        defer self.gpa.free(feed_list);
        const soc_list = try self.feed_tracker.listSocs(self.gpa);
        defer self.gpa.free(soc_list);

        var html: std.Io.Writer.Allocating = .init(self.gpa);
        defer html.deinit();
        try ui.renderDashboard(&html.writer, .{
            .batches = batches,
            .feed_list = feed_list,
            .soc_list = soc_list,
            .cache_stats = self.download_cache.stats(),
            .post_dedup_stats = self.post_dedup_cache.stats(),
            .upstream_host = self.cfg.upstream_host,
            .upstream_port = self.cfg.upstream_port,
            .mock_enabled = self.cfg.mock_enabled,
            .enc_count = self.enc_count.load(.monotonic),
            .act_count = self.act_count.load(.monotonic),
        });

        try request.respond(html.written(), .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            .keep_alive = request.head.keep_alive,
        });
    }

    /// Fetch the chunk bytes at `ref` from whichever backend is active
    /// (mock or upstream) and decode the root chunk. Returns error on
    /// fetch failure; logRequest tolerates null gracefully.
    fn inspectChunk(self: *Proxy, ref: []const u8) !chunks.Inspection {
        const raw = try self.fetchChunkBytes(ref);
        defer self.gpa.free(raw);
        return chunks.inspectChunkBytes(raw);
    }

    /// Side-fetch `GET /chunks/{ref}` through whichever backend is
    /// active and return the raw wire bytes (`span || content`).
    /// Caller owns the returned slice and must free with `self.gpa`.
    fn fetchChunkBytes(self: *Proxy, ref: []const u8) ![]u8 {
        if (self.cfg.mock_enabled) {
            var target_buf: [256]u8 = undefined;
            const target = try std.fmt.bufPrint(&target_buf, "/chunks/{s}", .{ref});
            const mr = try self.mock_backend.handle(self.gpa, .GET, target, "");
            if (mr.status != .ok) {
                self.gpa.free(mr.body);
                return error.ChunkFetchFailed;
            }
            return mr.body;
        }
        const url = try std.fmt.allocPrint(self.gpa, "http://{s}:{d}/chunks/{s}", .{
            self.cfg.upstream_host, self.cfg.upstream_port, ref,
        });
        defer self.gpa.free(url);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(self.gpa, &body);
        defer body = body_writer.toArrayList();

        const result = try self.upstream_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = true,
        });
        if (result.status != .ok) return error.ChunkFetchFailed;
        return self.gpa.dupe(u8, body_writer.written());
    }

    /// Side-fetch the root chunk and inspect it as a Mantaray manifest
    /// node. Cheap (one extra round-trip per bzz upload). Silent
    /// failure on anything that isn't a well-formed Mantaray node.
    fn inspectManifest(self: *Proxy, ref: []const u8) !manifest.Inspection {
        const raw = try self.fetchChunkBytes(ref);
        defer self.gpa.free(raw);
        return manifest.inspectChunkBytes(raw);
    }

    fn isUploadPath(target: []const u8) bool {
        const path_end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
        const path = target[0..path_end];
        return std.mem.eql(u8, path, "/bytes") or
            std.mem.eql(u8, path, "/bzz") or
            std.mem.startsWith(u8, path, "/bzz/");
    }

    fn isBzzPath(target: []const u8) bool {
        const path_end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
        const path = target[0..path_end];
        return std.mem.eql(u8, path, "/bzz") or std.mem.startsWith(u8, path, "/bzz/");
    }

    /// One-shot side-fetch of `GET /stamps/{id}` against whichever
    /// backend is active (mock or upstream), used to populate capacity
    /// and TTL for a newly-seen batch.
    fn fetchAndStoreCapacity(self: *Proxy, batch_id: []const u8) !void {
        if (self.cfg.mock_enabled) {
            var target_buf: [256]u8 = undefined;
            const target = try std.fmt.bufPrint(&target_buf, "/stamps/{s}", .{batch_id});
            const mr = try self.mock_backend.handle(self.gpa, .GET, target, "");
            defer self.gpa.free(mr.body);
            if (mr.status != .ok) return error.StampNotFound;
            const parsed = try parseStampJson(self.gpa, mr.body);
            defer parsed.deinit();
            const s = parsed.value;
            try self.tracker.setCapacity(batch_id, s.depth, s.bucketDepth, s.utilization, s.batchTTL);
            return;
        }
        const parsed = try fetchStampCapacity(
            self.gpa,
            &self.upstream_client,
            self.cfg.upstream_host,
            self.cfg.upstream_port,
            batch_id,
        );
        defer parsed.deinit();
        const s = parsed.value;
        try self.tracker.setCapacity(
            batch_id,
            s.depth,
            s.bucketDepth,
            s.utilization,
            s.batchTTL,
        );
    }
};

const BeeStampResponse = struct {
    depth: u32,
    bucketDepth: u32,
    utilization: u64,
    batchTTL: i64,
};

pub fn parseStampJson(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(BeeStampResponse) {
    return std.json.parseFromSlice(BeeStampResponse, gpa, body, .{
        .ignore_unknown_fields = true,
    });
}

fn fetchStampCapacity(
    gpa: std.mem.Allocator,
    client: *http.Client,
    upstream_host: []const u8,
    upstream_port: u16,
    batch_id: []const u8,
) !std.json.Parsed(BeeStampResponse) {
    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/stamps/{s}", .{
        upstream_host, upstream_port, batch_id,
    });
    defer gpa.free(url);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body);
    defer body = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = true,
    });
    if (result.status != .ok) return error.StampNotFound;

    return parseStampJson(gpa, body_writer.written());
}

// Hop-by-hop headers per RFC 7230 §6.1 plus a few proxy-managed ones. We
// also drop accept-encoding so upstream returns raw bytes (needed for
// bit-exact chunk passthrough).
const hop_by_hop = [_][]const u8{
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
    "accept-encoding",
};

fn isHopByHop(name: []const u8) bool {
    for (hop_by_hop) |h| {
        if (std.ascii.eqlIgnoreCase(name, h)) return true;
    }
    return false;
}

fn pathOnly(target: []const u8) []const u8 {
    const end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
    return target[0..end];
}

/// Returns true for errors that suggest a stale pooled TCP connection —
/// i.e. the kind where dropping the whole upstream pool and re-dialing
/// is the right recovery. Real 4xx/5xx responses from Bee are not
/// errors here: they come back as http.Status values on successful
/// round-trips, so they don't enter this path at all.
fn isUpstreamTransportError(err: anyerror) bool {
    return switch (err) {
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.EndOfStream,
        error.ReadFailed,
        error.WriteFailed,
        error.UnexpectedReadFailure,
        error.UnexpectedWriteFailure,
        error.HttpConnectionClosing,
        error.HttpHeadersOversize,
        error.HttpRequestTruncated,
        => true,
        else => false,
    };
}

fn logPoolReset(err: anyerror) void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print(
        "stale upstream conn after {s}; dropped + retrying with fresh dial\n",
        .{@errorName(err)},
    ) catch return;
    w.interface.flush() catch return;
}

/// Encryption + Access Control Trie markers surfaced by Bee on both
/// requests and responses. We just observe — no crypto here.
pub const EncInfo = struct {
    /// True if either side asserted `swarm-encrypt: true` or the
    /// response carried an encrypted (128-char) reference indicator.
    encrypted: bool = false,
    /// True if any ACT header is present.
    act: bool = false,
    /// Publisher public key (hex). Lifetime matches the caller's
    /// header storage; dupe if you need to outlive it.
    act_publisher: ?[]const u8 = null,
    /// History address (hex) identifying the ACT history chunk.
    act_history: ?[]const u8 = null,

    pub fn any(e: EncInfo) bool {
        return e.encrypted or e.act;
    }
};

fn sniffEnc(headers: []const http.Header) EncInfo {
    var info: EncInfo = .{};
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "swarm-encrypt")) {
            if (std.ascii.eqlIgnoreCase(h.value, "true") or std.mem.eql(u8, h.value, "1"))
                info.encrypted = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "swarm-act")) {
            if (std.ascii.eqlIgnoreCase(h.value, "true") or std.mem.eql(u8, h.value, "1"))
                info.act = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "swarm-act-publisher")) {
            info.act = true;
            info.act_publisher = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "swarm-act-history-address")) {
            info.act = true;
            info.act_history = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "swarm-act-timestamp")) {
            info.act = true;
        }
    }
    return info;
}

fn mergeEnc(a: EncInfo, b: EncInfo) EncInfo {
    return .{
        .encrypted = a.encrypted or b.encrypted,
        .act = a.act or b.act,
        .act_publisher = a.act_publisher orelse b.act_publisher,
        .act_history = a.act_history orelse b.act_history,
    };
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn appendHeader(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(http.Header),
    name: []const u8,
    value: []const u8,
) !void {
    try list.append(gpa, .{
        .name = try gpa.dupe(u8, name),
        .value = try gpa.dupe(u8, value),
    });
}

pub const CacheResult = enum { none, hit, miss, stored };
pub const PostDedupResult = enum { none, hit, miss, stored };

const LogEvent = struct {
    method: http.Method,
    target: []const u8,
    status: http.Status,
    elapsed_ms: i64,
    req_bytes: usize,
    resp_bytes: usize,
    batch_id: ?[]const u8 = null,
    stamp_stats: ?stamps.BatchStats = null,
    warn_level: stamps.WarnLevel = .none,
    feed_stats: ?feeds.FeedStats = null,
    soc_stats: ?feeds.SocStats = null,
    cache_result: CacheResult = .none,
    root_reference: ?[]const u8 = null,
    chunk_info: ?chunks.Inspection = null,
    enc: EncInfo = .{},
    manifest_info: ?manifest.Inspection = null,
    post_dedup_result: PostDedupResult = .none,
    write_through: bool = false,
};

fn logRequest(ev: LogEvent) void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    const out = &w.interface;
    out.print("{s} {s} -> {d} ({d}ms req={d}B resp={d}B)", .{
        @tagName(ev.method),
        ev.target,
        @intFromEnum(ev.status),
        ev.elapsed_ms,
        ev.req_bytes,
        ev.resp_bytes,
    }) catch return;
    if (ev.batch_id) |bid| if (ev.stamp_stats) |s| {
        const short = bid[0..@min(bid.len, 8)];
        out.print(" stamp={s} #{d} up={d}B total_up={d}B", .{
            short, s.uploads, ev.req_bytes, s.bytes_up,
        }) catch {};
        if (s.utilizationPct()) |pct| {
            out.print(" util={d:.1}%", .{pct}) catch {};
            if (s.batch_ttl_seconds) |ttl| out.print(" ttl={s}", .{formatTtl(ttl)}) catch {};
        } else if (s.capacity_fetch_failed) {
            out.writeAll(" util=? (capacity fetch failed)") catch {};
        }
    };
    if (ev.feed_stats) |f| {
        out.print(" feed={s}/{s} reads={d} writes={d}", .{
            shortHex(f.owner), shortHex(f.topic), f.reads, f.writes,
        }) catch {};
        if (f.last_index_hex) |idx| out.print(" idx={s}", .{idx}) catch {};
        if (f.next_index_hex) |nxt| out.print(" next={s}", .{nxt}) catch {};
    }
    if (ev.soc_stats) |s| {
        out.print(" soc={s}/{s} writes={d} up={d}B total_up={d}B", .{
            shortHex(s.owner), shortHex(s.id), s.writes, ev.req_bytes, s.bytes_up,
        }) catch {};
    }
    switch (ev.cache_result) {
        .none => {},
        .hit => out.writeAll(" cache=hit") catch {},
        .miss => out.writeAll(" cache=miss") catch {},
        .stored => out.writeAll(" cache=stored") catch {},
    }
    switch (ev.post_dedup_result) {
        .none => {},
        .hit => out.writeAll(" post_dedup=hit") catch {},
        .miss => out.writeAll(" post_dedup=miss") catch {},
        .stored => out.writeAll(" post_dedup=stored") catch {},
    }
    if (ev.write_through) out.writeAll(" wt=cached") catch {};
    if (ev.root_reference) |ref| {
        out.print(" root={s}", .{shortHex(ref)}) catch {};
        if (ev.chunk_info) |ci| {
            if (ci.is_leaf) {
                out.print(" span={d}B leaf", .{ci.span}) catch {};
            } else {
                out.print(" span={d}B children={d} leaves≈{d} depth≈{d}", .{
                    ci.span, ci.root_children, ci.leaves_estimated, ci.depth_estimated,
                }) catch {};
            }
        }
    }
    if (ev.enc.encrypted) out.writeAll(" enc=yes") catch {};
    if (ev.enc.act) {
        out.writeAll(" act=yes") catch {};
        if (ev.enc.act_publisher) |p| out.print(" pub={s}", .{shortHex(p)}) catch {};
    }
    if (ev.manifest_info) |*m| if (m.is_manifest) {
        out.writeAll(" manifest=yes") catch {};
        if (m.version()) |v| out.print(" ver={s}", .{v}) catch {};
        if (m.fork_count) |n| out.print(" forks={d}", .{n}) catch {};
    };
    out.writeAll("\n") catch return;
    if (ev.warn_level != .none) {
        if (ev.batch_id) |bid| {
            const short = bid[0..@min(bid.len, 8)];
            const threshold: u8 = switch (ev.warn_level) {
                .w80 => 80,
                .w95 => 95,
                .none => unreachable,
            };
            out.print("!! stamp {s} crossed {d}% utilization — buy/dilute before it fills !!\n", .{
                short, threshold,
            }) catch {};
        }
    }
    out.flush() catch return;
}

fn shortHex(s: []const u8) []const u8 {
    return s[0..@min(s.len, 8)];
}

/// Format a TTL in seconds as a compact human-readable string.
/// Returned slice points into a thread-local static buffer — only valid
/// until the next call on the same thread. Fine for single-shot logging.
fn formatTtl(seconds: i64) []const u8 {
    const S = struct {
        threadlocal var buf: [32]u8 = undefined;
    };
    if (seconds <= 0) return "expired";
    const s: u64 = @intCast(seconds);
    const d = s / 86_400;
    const h = (s % 86_400) / 3_600;
    const m = (s % 3_600) / 60;
    const written = std.fmt.bufPrint(&S.buf, "{d}d{d}h{d}m", .{ d, h, m }) catch "?";
    return written;
}

fn logErr(where: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    const out = &w.interface;
    out.print("{s} error: {s}\n", .{ where, @errorName(err) }) catch return;
    out.flush() catch return;
}

test "sniffEnc detects swarm-encrypt and ACT headers" {
    const h1 = [_]http.Header{.{ .name = "swarm-encrypt", .value = "true" }};
    try std.testing.expect(sniffEnc(&h1).encrypted);
    try std.testing.expect(!sniffEnc(&h1).act);

    const h2 = [_]http.Header{
        .{ .name = "swarm-act", .value = "true" },
        .{ .name = "swarm-act-publisher", .value = "abc12345publisher" },
    };
    const info = sniffEnc(&h2);
    try std.testing.expect(info.act);
    try std.testing.expectEqualStrings("abc12345publisher", info.act_publisher.?);

    // Case-insensitive on header name.
    const h3 = [_]http.Header{.{ .name = "Swarm-Encrypt", .value = "1" }};
    try std.testing.expect(sniffEnc(&h3).encrypted);

    // Timestamp alone marks ACT without publisher.
    const h4 = [_]http.Header{.{ .name = "swarm-act-timestamp", .value = "1234567890" }};
    const only_ts = sniffEnc(&h4);
    try std.testing.expect(only_ts.act);
    try std.testing.expect(only_ts.act_publisher == null);

    // Unrelated headers yield empty info.
    const h5 = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    try std.testing.expect(!sniffEnc(&h5).any());
}

test "hop-by-hop matching is case-insensitive" {
    try std.testing.expect(isHopByHop("Connection"));
    try std.testing.expect(isHopByHop("CONTENT-LENGTH"));
    try std.testing.expect(isHopByHop("host"));
    try std.testing.expect(!isHopByHop("Content-Type"));
    try std.testing.expect(!isHopByHop("Swarm-Postage-Batch-Id"));
}

test "default config is sane" {
    const cfg: Config = .{};
    try std.testing.expectEqual(@as(u16, 1733), cfg.listen_port);
    try std.testing.expectEqual(@as(u16, 1633), cfg.upstream_port);
    try std.testing.expect(cfg.listen_port != cfg.upstream_port);
}

// Integration: spin up the proxy AND a tiny mock upstream in-process,
// send a real request through, assert the round-trip.
test "round-trip GET via proxy to local upstream" {
    const gpa = std.testing.allocator;

    // Upstream listener on an ephemeral port.
    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    // Proxy listener on an ephemeral port.
    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    // Upstream thread: serves one canned response.
    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond("hello from upstream", .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "x-upstream", .value = "yes" }},
                .keep_alive = false,
            });
        }
    }.serve, .{&upstream});

    // Proxy thread: serves one connection.
    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    // Client hits the proxy.
    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/whatever", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    try std.testing.expectEqual(http.Status.ok, result.status);
    try std.testing.expectEqualStrings("hello from upstream", body_writer.written());
}

test "parseStampJson tolerates extra Bee fields" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "batchID": "abc",
        \\  "utilization": 7,
        \\  "usable": true,
        \\  "label": "",
        \\  "depth": 20,
        \\  "amount": "1000000000000",
        \\  "bucketDepth": 16,
        \\  "blockNumber": 28850373,
        \\  "immutableFlag": true,
        \\  "exists": true,
        \\  "batchTTL": 414720,
        \\  "expired": false
        \\}
    ;
    const parsed = try parseStampJson(gpa, body);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 20), parsed.value.depth);
    try std.testing.expectEqual(@as(u32, 16), parsed.value.bucketDepth);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.utilization);
    try std.testing.expectEqual(@as(i64, 414720), parsed.value.batchTTL);
}

// Helper: upstream that serves two sequential requests — the forwarded
// upload plus the /stamps/{id} side-fetch — with a configurable
// utilization for the stamp response.
const StampServeConfig = struct {
    expected_batch: []const u8,
    depth: u32 = 20,
    bucket_depth: u32 = 16,
    utilization: u64 = 7,
    batch_ttl: i64 = 414720,
};

fn serveUploadAndStamps(srv: *net.Server, cfg: StampServeConfig) !void {
    // Connection 1: the forwarded upload.
    {
        const conn = try srv.accept();
        defer conn.stream.close();
        var rb: [4096]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var r = conn.stream.reader(&rb);
        var w = conn.stream.writer(&wb);
        var s = http.Server.init(r.interface(), &w.interface);
        var req = try s.receiveHead();

        var saw_batch = false;
        var hit = req.iterateHeaders();
        while (hit.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "swarm-postage-batch-id")) {
                try std.testing.expectEqualStrings(cfg.expected_batch, h.value);
                saw_batch = true;
            }
        }
        try std.testing.expect(saw_batch);

        try req.respond("{\"reference\":\"deadbeef\"}", .{
            .status = .created,
            .keep_alive = false,
        });
    }

    // Connection 2: the /stamps/{id} side-fetch.
    {
        const conn = try srv.accept();
        defer conn.stream.close();
        var rb: [4096]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var r = conn.stream.reader(&rb);
        var w = conn.stream.writer(&wb);
        var s = http.Server.init(r.interface(), &w.interface);
        var req = try s.receiveHead();

        // Validate the path looks like /stamps/<id>.
        try std.testing.expect(std.mem.startsWith(u8, req.head.target, "/stamps/"));

        var body_buf: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf,
            "{{\"batchID\":\"{s}\",\"depth\":{d},\"bucketDepth\":{d}," ++
            "\"utilization\":{d},\"batchTTL\":{d},\"usable\":true," ++
            "\"exists\":true}}",
            .{ cfg.expected_batch, cfg.depth, cfg.bucket_depth, cfg.utilization, cfg.batch_ttl },
        );
        try req.respond(body, .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .keep_alive = false,
        });
    }
}

test "POST with swarm-postage-batch-id is tracked and capacity side-fetched" {
    const gpa = std.testing.allocator;
    const batch_id = "abcdef01deadbeefcafebabe0123456789abcdef0123456789abcdef01234567";
    const payload = "some upload bytes";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, serveUploadAndStamps, .{
        &upstream,
        StampServeConfig{
            .expected_batch = batch_id,
            .utilization = 7, // 7/16 = 43.75% — below any threshold
        },
    });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{.{ .name = "swarm-postage-batch-id", .value = batch_id }},
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    try std.testing.expectEqual(http.Status.created, result.status);

    const snap = proxy.tracker.snapshot(batch_id) orelse return error.StampNotTracked;
    try std.testing.expectEqual(@as(u64, 1), snap.uploads);
    try std.testing.expectEqual(@as(u64, payload.len), snap.bytes_up);
    try std.testing.expectEqual(@as(?u32, 20), snap.depth);
    try std.testing.expectEqual(@as(?u32, 16), snap.bucket_depth);
    try std.testing.expectEqual(@as(?u64, 7), snap.bee_utilization);
    try std.testing.expectApproxEqAbs(@as(f64, 43.75), snap.utilizationPct().?, 0.01);
    try std.testing.expect(!snap.warned_80);
    try std.testing.expect(!snap.warned_95);
}

test "upload on a highly-utilized batch crosses w80 threshold" {
    const gpa = std.testing.allocator;
    const batch_id = "ffffeeee" ++ ("0" ** 56);
    const payload = "x";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, serveUploadAndStamps, .{
        &upstream,
        StampServeConfig{
            .expected_batch = batch_id,
            .utilization = 13, // 13/16 = 81.25% — crosses w80
        },
    });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{.{ .name = "swarm-postage-batch-id", .value = batch_id }},
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    const snap = proxy.tracker.snapshot(batch_id) orelse return error.StampNotTracked;
    try std.testing.expect(snap.warned_80);
    try std.testing.expect(!snap.warned_95);
}

test "GET /feeds/{owner}/{topic} captures index from response headers" {
    const gpa = std.testing.allocator;
    const owner = "aabbccddeeff00112233445566778899aabbccdd";
    const topic = "1122334455667788991122334455667788112233";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond("{\"reference\":\"deadbeef\"}", .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "swarm-feed-index", .value = "2a" },
                    .{ .name = "swarm-feed-index-next", .value = "2b" },
                    .{ .name = "content-type", .value = "application/json" },
                },
                .keep_alive = false,
            });
        }
    }.serve, .{&upstream});

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/feeds/{s}/{s}?type=sequence", .{
        proxy_port, owner, topic,
    });
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    try std.testing.expectEqual(http.Status.ok, result.status);

    const snap = (try proxy.feed_tracker.snapshotFeed(owner, topic)) orelse
        return error.FeedNotTracked;
    try std.testing.expectEqual(@as(u64, 1), snap.reads);
    try std.testing.expectEqual(@as(u64, 0), snap.writes);
    try std.testing.expectEqualStrings("2a", snap.last_index_hex.?);
    try std.testing.expectEqualStrings("2b", snap.next_index_hex.?);
}

test "POST /soc/{owner}/{id} counts bytes uploaded" {
    const gpa = std.testing.allocator;
    const owner = "deadbeef" ++ ("0" ** 32);
    const id = "cafebabe" ++ ("f" ** 32);
    const payload = "single owner chunk payload";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond("{\"reference\":\"abc123\"}", .{
                .status = .created,
                .keep_alive = false,
            });
        }
    }.serve, .{&upstream});

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/soc/{s}/{s}?sig=aa", .{
        proxy_port, owner, id,
    });
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    const snap = (try proxy.feed_tracker.snapshotSoc(owner, id)) orelse
        return error.SocNotTracked;
    try std.testing.expectEqual(@as(u64, 1), snap.writes);
    try std.testing.expectEqual(@as(u64, payload.len), snap.bytes_up);
}

test "second GET /bytes/{ref} is served from cache without hitting upstream" {
    const gpa = std.testing.allocator;
    const reference = "abc123";
    const payload = "the cached payload";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    // Upstream serves exactly 1 request — the second client request must
    // be served from cache, or this test hangs waiting for accept().
    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, body: []const u8) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/octet-stream" },
                },
                .keep_alive = false,
            });
        }
    }.serve, .{ &upstream, payload });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();

    // Proxy thread: serve exactly 2 connections.
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes/{s}", .{
        proxy_port, reference,
    });
    defer gpa.free(url);

    // First request: miss → stored.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.ok, result.status);
        try std.testing.expectEqualStrings(payload, body_writer.written());
    }

    // Second request: hit. Upstream is not accepting any more connections,
    // so any attempt to reach it would hang → a passing test proves we
    // never tried.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.ok, result.status);
        try std.testing.expectEqualStrings(payload, body_writer.written());
    }

    upstream_thread.join();
    proxy_thread.join();

    const s = proxy.download_cache.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "POST /bytes triggers root-chunk inspection: leaf tree" {
    const gpa = std.testing.allocator;
    const reference = "abcdef0123456789";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    // Upstream serves 2 requests: the forwarded POST /bytes, then the
    // chunk-inspection side-fetch GET /chunks/<ref>.
    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, ref: []const u8) !void {
            // 1. POST /bytes → 201 with {"reference":...}
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                var body_buf: [256]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buf, "{{\"reference\":\"{s}\"}}", .{ref});
                try req.respond(body, .{
                    .status = .created,
                    .keep_alive = false,
                });
            }
            // 2. GET /chunks/<ref> → leaf chunk (span=100, 100 bytes content)
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                try std.testing.expect(std.mem.startsWith(u8, req.head.target, "/chunks/"));

                var chunk_bytes: [8 + 100]u8 = undefined;
                std.mem.writeInt(u64, chunk_bytes[0..8], 100, .little);
                @memset(chunk_bytes[8..], 'A');
                try req.respond(&chunk_bytes, .{
                    .status = .ok,
                    .keep_alive = false,
                });
            }
        }
    }.serve, .{ &upstream, reference });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        // leave chunk_inspection_enabled = true (default)
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "hello",
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    try std.testing.expectEqual(http.Status.created, result.status);
    // The client received the original JSON response unchanged.
    try std.testing.expect(std.mem.indexOf(u8, body_writer.written(), reference) != null);
}

test "mock mode serves POST+GET round-trip without any upstream" {
    const gpa = std.testing.allocator;

    // Crucially, no upstream listener is started. If the proxy ever tries
    // to forward a request, the test will fail.
    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .mock_enabled = true,
    });
    defer proxy.deinit();

    // Proxy thread: serve 2 connections (one POST, one GET).
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    const post_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(post_url);

    // POST /bytes — mock hashes the payload and returns a reference.
    var reference_hex_owned: []u8 = undefined;
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();

        const result = try client.fetch(.{
            .location = .{ .url = post_url },
            .method = .POST,
            .payload = "the mock payload",
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.created, result.status);

        const parsed = try chunks.parsePostReference(gpa, body_writer.written());
        defer parsed.deinit();
        reference_hex_owned = try gpa.dupe(u8, parsed.value.reference);
    }
    defer gpa.free(reference_hex_owned);

    // GET /bytes/{ref} — retrieves what we just stored.
    {
        const get_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes/{s}", .{
            proxy_port, reference_hex_owned,
        });
        defer gpa.free(get_url);

        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();

        const result = try client.fetch(.{
            .location = .{ .url = get_url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.ok, result.status);
        try std.testing.expectEqualStrings("the mock payload", body_writer.written());
    }

    proxy_thread.join();
}

test "POST /bytes triggers root-chunk inspection: intermediate tree" {
    const gpa = std.testing.allocator;
    const reference = "deeeadbeef";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, ref: []const u8) !void {
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                var body_buf: [256]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buf, "{{\"reference\":\"{s}\"}}", .{ref});
                try req.respond(body, .{
                    .status = .created,
                    .keep_alive = false,
                });
            }
            {
                // Intermediate root: span=8192 (2 leaves), content=2*32 bytes.
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();

                var chunk_bytes: [8 + 64]u8 = undefined;
                std.mem.writeInt(u64, chunk_bytes[0..8], 8192, .little);
                @memset(chunk_bytes[8..], 0xAB);
                try req.respond(&chunk_bytes, .{
                    .status = .ok,
                    .keep_alive = false,
                });
            }
        }
    }.serve, .{ &upstream, reference });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "x",
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();
}

test "replay log captures one ndjson line per forwarded request" {
    const gpa = std.testing.allocator;

    // Temp file — unique per run.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/swarm-dev-proxy-replay-{x}.ndjson", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};

    // No upstream — mock handles it.
    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .mock_enabled = true,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();

    var rw = try replay.Writer.init(gpa, path);
    defer rw.deinit();
    proxy.replay_writer = &rw;

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{proxy_port});
    defer gpa.free(url);

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    proxy_thread.join();

    const contents = try std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024);
    defer gpa.free(contents);
    const trimmed = std.mem.trimRight(u8, contents, "\n");
    try std.testing.expect(trimmed.len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("GET", obj.get("method").?.string);
    try std.testing.expectEqualStrings("/health", obj.get("target").?.string);
    try std.testing.expectEqual(@as(i64, 200), obj.get("resp_status").?.integer);
    // base64("ok\n") = b2sK
    try std.testing.expectEqualStrings("b2sK", obj.get("resp_body_b64").?.string);
}

test "GET /_proxy renders an HTML dashboard with live tracker state" {
    const gpa = std.testing.allocator;

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .mock_enabled = true,
    });
    defer proxy.deinit();

    // Seed tracker state directly so the dashboard has something to
    // display without running a full upload round-trip.
    _ = try proxy.tracker.record("batchDASH0000000", 42, 0);
    try proxy.tracker.setCapacity("batchDASH0000000", 20, 16, 2, 86_400);
    _ = try proxy.feed_tracker.recordFeedRead("ownerdash", "topicdash", "07", "08", null);
    _ = try proxy.feed_tracker.recordSocWrite("sownerdash", "sociddash", 256);

    // Serve one request (the dashboard GET).
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/_proxy", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    proxy_thread.join();

    try std.testing.expectEqual(http.Status.ok, result.status);
    const html = body_writer.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>swarm-dev-proxy</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "batchDASH0000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ownerdas") != null); // 8-char prefix
    try std.testing.expect(std.mem.indexOf(u8, html, "sownerda") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pill-mock") != null);
}

test "encryption/ACT headers bump per-proxy counters" {
    const gpa = std.testing.allocator;

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .mock_enabled = true,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "encrypted-upload",
        .extra_headers = &.{
            .{ .name = "swarm-encrypt", .value = "true" },
            .{ .name = "swarm-act", .value = "true" },
            .{ .name = "swarm-act-publisher", .value = "deadbeefpublisher" },
        },
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    proxy_thread.join();

    try std.testing.expectEqual(@as(u64, 1), proxy.enc_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), proxy.act_count.load(.monotonic));
}

test "second POST /bytes with identical body is deduped (upstream sees one connection)" {
    const gpa = std.testing.allocator;
    const payload = "identical-chunk-content";

    // Upstream accepts exactly ONE POST. If dedup fails the second
    // client POST will try to forward and this test hangs.
    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond("{\"reference\":\"deadbeef\"}", .{
                .status = .created,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .keep_alive = false,
            });
        }
    }.serve, .{&upstream});

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
    defer gpa.free(url);

    // First POST — upstream serves it, proxy stores the response.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.created, r.status);
        try std.testing.expect(std.mem.indexOf(u8, body_writer.written(), "deadbeef") != null);
    }

    // Second POST — identical body. Upstream isn't accepting any more
    // connections. A passing test is the proof that dedup short-circuited.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.created, r.status);
        try std.testing.expectEqualStrings("{\"reference\":\"deadbeef\"}", body_writer.written());
    }

    upstream_thread.join();
    proxy_thread.join();

    const s = proxy.post_dedup_cache.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(u64, payload.len), s.bytes_saved);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "POST /bzz side-fetches root chunk and reports Mantaray info" {
    const gpa = std.testing.allocator;

    // Build a synthetic Mantaray root chunk: 0x5a key, "mantaray:1.0",
    // ref_size=32, bitmap with 3 set bits.
    const MIN_NODE_BYTES = 128;
    var node: [MIN_NODE_BYTES]u8 = undefined;
    @memset(&node, 0);
    const key_byte: u8 = 0x5a;
    @memset(node[0..32], key_byte);
    const version_str = "mantaray:1.0";
    var plain: [MIN_NODE_BYTES - 32]u8 = undefined;
    @memset(&plain, 0);
    @memcpy(plain[0..version_str.len], version_str);
    plain[31] = 32; // ref_size
    // 3 forks in the bitmap.
    plain[64] = 0b0000_0111;
    for (plain, 0..) |b, i| node[32 + i] = b ^ key_byte;

    var framed: [8 + MIN_NODE_BYTES]u8 = undefined;
    std.mem.writeInt(u64, framed[0..8], node.len, .little);
    @memcpy(framed[8..], &node);

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    // Upstream serves: 1) the forwarded POST /bzz, 2) GET /chunks/<ref>
    // from chunk inspection. Manifest inspection reuses the SAME chunk
    // fetch call — no third connection needed.
    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, framed_chunk: []const u8) !void {
            // 1: POST /bzz
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                try req.respond("{\"reference\":\"aabbccdd\"}", .{
                    .status = .created,
                    .keep_alive = false,
                });
            }
            // 2: GET /chunks/aabbccdd — chunk inspection fetches this.
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                try req.respond(framed_chunk, .{
                    .status = .ok,
                    .keep_alive = false,
                });
            }
            // 3: GET /chunks/aabbccdd — manifest inspection fetches
            // the same chunk again. (Both inspections use the same
            // helper but each does its own round-trip.)
            {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                try req.respond(framed_chunk, .{
                    .status = .ok,
                    .keep_alive = false,
                });
            }
        }
    }.serve, .{ &upstream, &framed });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
    });
    defer proxy.deinit();
    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            const conn = try srv.accept();
            try p.handleConnection(conn);
        }
    }.serve, .{ &proxy, &proxy_listener });

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bzz", .{proxy_port});
    defer gpa.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
    defer body_buf = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "ignored by mock",
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });

    upstream_thread.join();
    proxy_thread.join();

    // The dapp's original response body is unchanged.
    try std.testing.expectEqual(http.Status.created, result.status);
    try std.testing.expect(std.mem.indexOf(u8, body_writer.written(), "aabbccdd") != null);
}

test "write-through: GET /bytes/{ref} after a POST /bytes skips upstream" {
    const gpa = std.testing.allocator;
    const payload = "write-through-content";
    const reference = "cafe1234deadbeef";

    // Upstream accepts exactly ONE connection — the POST. If the GET
    // doesn't hit the download cache populated by the POST, this test
    // hangs on accept().
    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, ref: []const u8) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            var body_buf: [128]u8 = undefined;
            const body = try std.fmt.bufPrint(&body_buf, "{{\"reference\":\"{s}\"}}", .{ref});
            try req.respond(body, .{
                .status = .created,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .keep_alive = false,
            });
        }
    }.serve, .{ &upstream, reference });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
        .chunk_inspection_enabled = false,
    });
    defer proxy.deinit();

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    // 1. POST /bytes — upstream serves, proxy records the content
    //    against the returned reference in the download cache.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes", .{proxy_port});
        defer gpa.free(url);
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.created, r.status);
    }

    // 2. GET /bytes/<ref> — must come from the download cache. Upstream
    //    is no longer accepting, so any leak to the backend hangs.
    {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bytes/{s}", .{
            proxy_port, reference,
        });
        defer gpa.free(url);
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.ok, r.status);
        try std.testing.expectEqualStrings(payload, body_writer.written());
    }

    upstream_thread.join();
    proxy_thread.join();

    const s = proxy.download_cache.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits); // the GET
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "GET /bzz/{ref}/meta is cached — second request skips upstream" {
    const gpa = std.testing.allocator;
    const body = "{\"blocks\":1000}";

    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, payload: []const u8) !void {
            const conn = try srv.accept();
            defer conn.stream.close();
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.stream.reader(&rb);
            var w = conn.stream.writer(&wb);
            var s = http.Server.init(r.interface(), &w.interface);
            var req = try s.receiveHead();
            try req.respond(payload, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .keep_alive = false,
            });
        }
    }.serve, .{ &upstream, body });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
    });
    defer proxy.deinit();

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bzz/abc1234567890/meta", .{proxy_port});
    defer gpa.free(url);

    for (0..2) |_| {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        const r = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
        try std.testing.expectEqual(http.Status.ok, r.status);
        try std.testing.expectEqualStrings(body, body_writer.written());
    }

    upstream_thread.join();
    proxy_thread.join();

    const s = proxy.download_cache.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "/bzz/ GET with Range header bypasses cache" {
    const gpa = std.testing.allocator;
    const body = "short body";

    // Upstream must accept BOTH connections — Range probes do not cache.
    const upstream_addr = try net.Address.parseIp("127.0.0.1", 0);
    var upstream = try upstream_addr.listen(.{ .reuse_address = true });
    defer upstream.deinit();
    const upstream_port = upstream.listen_address.getPort();

    const proxy_addr = try net.Address.parseIp("127.0.0.1", 0);
    var proxy_listener = try proxy_addr.listen(.{ .reuse_address = true });
    defer proxy_listener.deinit();
    const proxy_port = proxy_listener.listen_address.getPort();

    const upstream_thread = try std.Thread.spawn(.{}, struct {
        fn serve(srv: *net.Server, payload: []const u8) !void {
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                const conn = try srv.accept();
                defer conn.stream.close();
                var rb: [4096]u8 = undefined;
                var wb: [4096]u8 = undefined;
                var r = conn.stream.reader(&rb);
                var w = conn.stream.writer(&wb);
                var s = http.Server.init(r.interface(), &w.interface);
                var req = try s.receiveHead();
                try req.respond(payload, .{
                    .status = .ok,
                    .keep_alive = false,
                });
            }
        }
    }.serve, .{ &upstream, body });

    var proxy = Proxy.init(gpa, .{
        .listen_addr = "127.0.0.1",
        .listen_port = proxy_port,
        .upstream_host = "127.0.0.1",
        .upstream_port = upstream_port,
    });
    defer proxy.deinit();

    const proxy_thread = try std.Thread.spawn(.{}, struct {
        fn serve(p: *Proxy, srv: *net.Server) !void {
            var n: usize = 0;
            while (n < 2) : (n += 1) {
                const conn = try srv.accept();
                try p.handleConnection(conn);
            }
        }
    }.serve, .{ &proxy, &proxy_listener });

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/bzz/probe/hash/0xdead", .{proxy_port});
    defer gpa.free(url);

    for (0..2) |_| {
        var client: http.Client = .{ .allocator = gpa };
        defer client.deinit();
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(gpa);
        var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body_buf);
        defer body_buf = body_writer.toArrayList();
        _ = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{.{ .name = "range", .value = "bytes=0-0" }},
            .response_writer = &body_writer.writer,
            .keep_alive = false,
        });
    }

    upstream_thread.join();
    proxy_thread.join();

    const s = proxy.download_cache.stats();
    try std.testing.expectEqual(@as(u64, 0), s.hits);
    try std.testing.expectEqual(@as(u64, 0), s.misses);
    try std.testing.expectEqual(@as(usize, 0), s.entries);
}

