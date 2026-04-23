//! Minimal in-process mock backend — enough to unblock dapp test suites
//! that don't have a running Bee node.
//!
//! Scope:
//!   - `POST /bytes` stores content, returns a deterministic SHA-256
//!     reference. Content is capped at 4 KiB (one chunk) so the
//!     content-addressed single-chunk invariant holds.
//!   - `GET /bytes/{ref}` returns stored content, or 404.
//!   - `GET /chunks/{ref}` returns the chunk form (8-byte LE span
//!     prefix + content), or 404.
//!   - `GET /stamps/{id}` returns a canned capacity/TTL so stamp
//!     tracking in the proxy has something to display.
//!   - `GET /health` → 200 "ok".
//!   - `POST /soc/{owner}/{id}`, `POST /feeds/{owner}/{topic}`, and
//!     `GET /feeds/{owner}/{topic}` get stub responses with plausible
//!     headers so the proxy's feed/SOC tracking has data to track.
//!
//! Mock hashes use SHA-256, NOT Swarm BMT/keccak. Content uploaded to a
//! mock backend will not resolve against a real Bee node and vice
//! versa — mock mode is explicitly a parallel universe for tests.

const std = @import("std");
const http = std.http;

pub const MAX_CONTENT_BYTES: usize = 4096;

pub const Response = struct {
    status: http.Status,
    body: []u8, // owned by caller-supplied allocator; caller frees
    content_type: ?[]const u8 = null, // static string, no free needed
    feed_index_hex: ?[]const u8 = null, // static string
    feed_next_hex: ?[]const u8 = null, // static string
};

pub const Backend = struct {
    gpa: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    /// ref_hex (64 chars) → owned content
    store: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(b: *Backend) void {
        b.mu.lock();
        defer b.mu.unlock();
        var it = b.store.iterator();
        while (it.next()) |e| {
            b.gpa.free(e.key_ptr.*);
            b.gpa.free(e.value_ptr.*);
        }
        b.store.deinit(b.gpa);
    }

    /// Route one request. Returns an owned `Response`; caller is
    /// responsible for freeing `.body` via `resp_gpa`.
    pub fn handle(
        b: *Backend,
        resp_gpa: std.mem.Allocator,
        method: http.Method,
        target: []const u8,
        body: []const u8,
    ) !Response {
        const path_end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
        const path = target[0..path_end];

        // Health.
        if (method == .GET and std.mem.eql(u8, path, "/health")) {
            return .{
                .status = .ok,
                .body = try resp_gpa.dupe(u8, "ok\n"),
                .content_type = "text/plain",
            };
        }

        // Store.
        if (method == .POST and std.mem.eql(u8, path, "/bytes")) {
            return b.postBytes(resp_gpa, body);
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/bytes/")) {
            const ref = path["/bytes/".len..];
            if (std.mem.indexOfScalar(u8, ref, '/') != null) return notImplemented(resp_gpa);
            return b.getBytes(resp_gpa, ref);
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/chunks/")) {
            const ref = path["/chunks/".len..];
            if (std.mem.indexOfScalar(u8, ref, '/') != null) return notImplemented(resp_gpa);
            return b.getChunks(resp_gpa, ref);
        }

        // Stamp stub.
        if (method == .GET and std.mem.startsWith(u8, path, "/stamps/")) {
            return b.stampStub(resp_gpa);
        }

        // SOC stub.
        if ((method == .POST or method == .PUT) and std.mem.startsWith(u8, path, "/soc/")) {
            // Derive a deterministic fake reference from the remainder of
            // the path. Real Bee would compute keccak256(id || owner).
            return b.socStub(resp_gpa, path["/soc/".len..]);
        }

        // Feed stubs.
        if (std.mem.startsWith(u8, path, "/feeds/")) {
            if (method == .POST or method == .PUT) {
                return b.feedCreateStub(resp_gpa, path["/feeds/".len..]);
            }
            if (method == .GET or method == .HEAD) {
                return b.feedReadStub(resp_gpa, path["/feeds/".len..]);
            }
        }

        return notImplemented(resp_gpa);
    }

    // --- handlers ---

    fn postBytes(b: *Backend, resp_gpa: std.mem.Allocator, body: []const u8) !Response {
        if (body.len > MAX_CONTENT_BYTES) {
            return .{
                .status = .payload_too_large,
                .body = try std.fmt.allocPrint(
                    resp_gpa,
                    "mock backend only accepts payloads up to {d} bytes\n",
                    .{MAX_CONTENT_BYTES},
                ),
                .content_type = "text/plain",
            };
        }

        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(body);
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        const ref_hex: [64]u8 = std.fmt.bytesToHex(digest, .lower);

        b.mu.lock();
        defer b.mu.unlock();

        const gop = try b.store.getOrPut(b.gpa, &ref_hex);
        if (!gop.found_existing) {
            gop.key_ptr.* = try b.gpa.dupe(u8, &ref_hex);
            gop.value_ptr.* = try b.gpa.dupe(u8, body);
        }

        return .{
            .status = .created,
            .body = try std.fmt.allocPrint(resp_gpa, "{{\"reference\":\"{s}\"}}", .{&ref_hex}),
            .content_type = "application/json",
        };
    }

    fn getBytes(b: *Backend, resp_gpa: std.mem.Allocator, ref: []const u8) !Response {
        b.mu.lock();
        defer b.mu.unlock();
        const content = b.store.get(ref) orelse return notFound(resp_gpa, "bytes not found\n");
        return .{
            .status = .ok,
            .body = try resp_gpa.dupe(u8, content),
            .content_type = "application/octet-stream",
        };
    }

    fn getChunks(b: *Backend, resp_gpa: std.mem.Allocator, ref: []const u8) !Response {
        b.mu.lock();
        defer b.mu.unlock();
        const content = b.store.get(ref) orelse return notFound(resp_gpa, "chunk not found\n");
        // Chunk wire format: 8-byte LE span prefix + content.
        const out = try resp_gpa.alloc(u8, 8 + content.len);
        std.mem.writeInt(u64, out[0..8], content.len, .little);
        @memcpy(out[8..], content);
        return .{
            .status = .ok,
            .body = out,
            .content_type = "application/octet-stream",
        };
    }

    fn stampStub(_: *Backend, resp_gpa: std.mem.Allocator) !Response {
        // 20-depth, 16-bucket, ~utilization 0 — well below any warning
        // threshold. TTL one week.
        const body =
            \\{"batchID":"mock","depth":20,"bucketDepth":16,"utilization":0,
            \\"batchTTL":604800,"usable":true,"exists":true}
        ;
        return .{
            .status = .ok,
            .body = try resp_gpa.dupe(u8, body),
            .content_type = "application/json",
        };
    }

    fn socStub(b: *Backend, resp_gpa: std.mem.Allocator, tail: []const u8) !Response {
        _ = b;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(tail);
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        const ref_hex: [64]u8 = std.fmt.bytesToHex(digest, .lower);
        return .{
            .status = .created,
            .body = try std.fmt.allocPrint(resp_gpa, "{{\"reference\":\"{s}\"}}", .{&ref_hex}),
            .content_type = "application/json",
        };
    }

    fn feedCreateStub(b: *Backend, resp_gpa: std.mem.Allocator, tail: []const u8) !Response {
        _ = b;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update("feed-manifest:");
        sha.update(tail);
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        const ref_hex: [64]u8 = std.fmt.bytesToHex(digest, .lower);
        return .{
            .status = .created,
            .body = try std.fmt.allocPrint(resp_gpa, "{{\"reference\":\"{s}\"}}", .{&ref_hex}),
            .content_type = "application/json",
        };
    }

    fn feedReadStub(b: *Backend, resp_gpa: std.mem.Allocator, tail: []const u8) !Response {
        _ = b;
        _ = tail;
        return .{
            .status = .ok,
            .body = try resp_gpa.dupe(u8, "{\"reference\":\"deadbeef\"}"),
            .content_type = "application/json",
            .feed_index_hex = "00",
            .feed_next_hex = "01",
        };
    }
};

fn notFound(resp_gpa: std.mem.Allocator, msg: []const u8) !Response {
    return .{
        .status = .not_found,
        .body = try resp_gpa.dupe(u8, msg),
        .content_type = "text/plain",
    };
}

fn notImplemented(resp_gpa: std.mem.Allocator) !Response {
    return .{
        .status = .not_implemented,
        .body = try resp_gpa.dupe(u8, "mock backend doesn't implement this endpoint\n"),
        .content_type = "text/plain",
    };
}

test "POST /bytes then GET /bytes/<ref> round-trips content" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const post = try b.handle(gpa, .POST, "/bytes", "hello world");
    defer gpa.free(post.body);
    try std.testing.expectEqual(http.Status.created, post.status);

    // Pull reference out of JSON.
    const start = std.mem.indexOf(u8, post.body, "\"").? + 1;
    const ref_start = std.mem.indexOfPos(u8, post.body, start, ":\"").? + 2;
    const ref_end = std.mem.indexOfPos(u8, post.body, ref_start, "\"").?;
    const ref = post.body[ref_start..ref_end];
    try std.testing.expectEqual(@as(usize, 64), ref.len);

    const get_target = try std.fmt.allocPrint(gpa, "/bytes/{s}", .{ref});
    defer gpa.free(get_target);

    const get = try b.handle(gpa, .GET, get_target, "");
    defer gpa.free(get.body);
    try std.testing.expectEqual(http.Status.ok, get.status);
    try std.testing.expectEqualStrings("hello world", get.body);
}

test "GET /chunks/<ref> returns span + content" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const post = try b.handle(gpa, .POST, "/bytes", "abc");
    defer gpa.free(post.body);

    const ref_start = std.mem.indexOf(u8, post.body, ":\"").? + 2;
    const ref_end = std.mem.indexOfPos(u8, post.body, ref_start, "\"").?;
    const ref = post.body[ref_start..ref_end];

    const get_target = try std.fmt.allocPrint(gpa, "/chunks/{s}", .{ref});
    defer gpa.free(get_target);

    const get = try b.handle(gpa, .GET, get_target, "");
    defer gpa.free(get.body);
    try std.testing.expectEqual(http.Status.ok, get.status);
    try std.testing.expectEqual(@as(usize, 8 + 3), get.body.len);
    const span = std.mem.readInt(u64, get.body[0..8], .little);
    try std.testing.expectEqual(@as(u64, 3), span);
    try std.testing.expectEqualStrings("abc", get.body[8..]);
}

test "missing reference returns 404" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const r = try b.handle(gpa, .GET, "/bytes/deadbeef", "");
    defer gpa.free(r.body);
    try std.testing.expectEqual(http.Status.not_found, r.status);
}

test "oversized upload is rejected" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const big = try gpa.alloc(u8, MAX_CONTENT_BYTES + 1);
    defer gpa.free(big);
    @memset(big, 'X');

    const r = try b.handle(gpa, .POST, "/bytes", big);
    defer gpa.free(r.body);
    try std.testing.expectEqual(http.Status.payload_too_large, r.status);
}

test "same content produces same reference (deterministic hash)" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const r1 = try b.handle(gpa, .POST, "/bytes", "identical");
    defer gpa.free(r1.body);
    const r2 = try b.handle(gpa, .POST, "/bytes", "identical");
    defer gpa.free(r2.body);
    try std.testing.expectEqualStrings(r1.body, r2.body);
}

test "stamp stub survives shape expected by tracker" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .gpa = gpa };
    defer b.deinit();

    const r = try b.handle(gpa, .GET, "/stamps/whatever", "");
    defer gpa.free(r.body);
    try std.testing.expectEqual(http.Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"depth\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"batchTTL\":604800") != null);
}
