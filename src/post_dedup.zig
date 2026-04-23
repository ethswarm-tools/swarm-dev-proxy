//! Content-addressed POST deduplication for `POST /bytes` and
//! `POST /chunks`.
//!
//! Rationale: libraries like potjs walk a Proximity Order Trie on
//! every `save()` and POST every serialised node — even when the
//! tree has only slightly changed. Three parallel POT instances
//! (byNumber / byHash / byTx in the fullcircle-research pipeline)
//! routinely produce overlapping node bytes. Deduping identical
//! bodies saves bandwidth and API round-trips, and lets the dapp
//! reuse a reference it already got once.
//!
//! Keying
//!   SHA-256 of the request body, then the key is
//!   "<hex_hash>|<batch_id>". Both halves are needed: the same
//!   chunk uploaded under two different postage batches is two
//!   distinct stamp-funded events on Bee; we must *not* collapse
//!   them or a fresh batch will have phantom uploads we never
//!   actually paid for.
//!
//! Correctness guarantees
//!   - Never cache encrypted uploads (caller checks `swarm-encrypt`
//!     and skips the dedup path). Encryption uses a fresh random
//!     key per upload, so identical plaintext produces different
//!     chunks — deduping would break references.
//!   - Only cache successful 2xx responses.
//!   - Only effective within one proxy process lifetime.

const std = @import("std");

pub const Entry = struct {
    status: u16,
    content_type: ?[]const u8,
    body: []const u8,
};

pub const Stats = struct {
    entries: usize,
    hits: u64,
    misses: u64,
    bytes_saved: u64,
    evictions: u64 = 0,
};

/// Upper bound on entries before we dump the whole cache. Same rationale
/// as `cache.MAX_ENTRIES_DEFAULT`.
pub const MAX_ENTRIES_DEFAULT: usize = 100_000;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Stored) = .empty,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    max_entries: usize = MAX_ENTRIES_DEFAULT,
    /// Cumulative request-body bytes the proxy avoided sending upstream
    /// because of dedup hits.
    bytes_saved: u64 = 0,

    const Stored = struct {
        status: u16,
        content_type: ?[]const u8, // owned or null
        body: []const u8, // owned
        req_body_len: u64, // how many bytes we'd save on each future hit
    };

    pub fn deinit(c: *Cache) void {
        c.mu.lock();
        defer c.mu.unlock();
        var it = c.entries.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            if (e.value_ptr.content_type) |ct| c.gpa.free(ct);
            c.gpa.free(e.value_ptr.body);
        }
        c.entries.deinit(c.gpa);
    }

    /// Compute SHA-256 of `body` and return the 64-char lowercase hex.
    pub fn hashContent(body: []const u8) [64]u8 {
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(body);
        var digest: [32]u8 = undefined;
        sha.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// Build a cache key. `batch_id` may be empty if no stamp header
    /// was present on the upload.
    pub fn keyAlloc(
        gpa: std.mem.Allocator,
        hash_hex: []const u8,
        batch_id: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}|{s}", .{ hash_hex, batch_id });
    }

    pub fn get(c: *Cache, hash_hex: []const u8, batch_id: []const u8) ?Entry {
        c.mu.lock();
        defer c.mu.unlock();
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ hash_hex, batch_id }) catch {
            c.misses += 1;
            return null;
        };
        if (c.entries.get(key)) |s| {
            c.hits += 1;
            c.bytes_saved += s.req_body_len;
            return .{
                .status = s.status,
                .content_type = s.content_type,
                .body = s.body,
            };
        }
        c.misses += 1;
        return null;
    }

    pub fn put(
        c: *Cache,
        hash_hex: []const u8,
        batch_id: []const u8,
        entry: Entry,
        req_body_len: u64,
    ) !void {
        c.mu.lock();
        defer c.mu.unlock();
        const key = try keyAlloc(c.gpa, hash_hex, batch_id);
        errdefer c.gpa.free(key);
        if (c.entries.contains(key)) {
            // Already stored under identical (hash, batch) — caller is
            // observing a dedup hit that happened post-forward.
            c.gpa.free(key);
            return;
        }
        if (c.entries.count() >= c.max_entries) {
            c.clearLocked();
            c.evictions += 1;
        }
        const body_owned = try c.gpa.dupe(u8, entry.body);
        errdefer c.gpa.free(body_owned);
        const ct_owned: ?[]const u8 = if (entry.content_type) |ct| try c.gpa.dupe(u8, ct) else null;
        errdefer if (ct_owned) |x| c.gpa.free(x);
        try c.entries.put(c.gpa, key, .{
            .status = entry.status,
            .content_type = ct_owned,
            .body = body_owned,
            .req_body_len = req_body_len,
        });
    }

    /// Caller must hold c.mu. Frees all live entries; counters persist.
    fn clearLocked(c: *Cache) void {
        var it = c.entries.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            if (e.value_ptr.content_type) |ct| c.gpa.free(ct);
            c.gpa.free(e.value_ptr.body);
        }
        c.entries.clearRetainingCapacity();
    }

    pub fn stats(c: *Cache) Stats {
        c.mu.lock();
        defer c.mu.unlock();
        return .{
            .entries = c.entries.count(),
            .hits = c.hits,
            .misses = c.misses,
            .bytes_saved = c.bytes_saved,
            .evictions = c.evictions,
        };
    }
};

/// Returns true for paths where we should consider deduping the POST
/// body. `POST /bzz` is intentionally excluded: `/bzz` uploads carry
/// directory metadata that can vary between otherwise-identical
/// payloads, and the resulting Mantaray root differs per call.
pub fn isDedupablePath(target: []const u8) bool {
    const end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
    const path = target[0..end];
    return std.mem.eql(u8, path, "/bytes") or std.mem.eql(u8, path, "/chunks");
}

test "hashContent is deterministic and matches SHA-256" {
    const h1 = Cache.hashContent("abc");
    const h2 = Cache.hashContent("abc");
    try std.testing.expectEqualStrings(&h1, &h2);
    // Known SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &h1,
    );
}

test "cache stores and retrieves per (hash, batch)" {
    var c: Cache = .{ .gpa = std.testing.allocator };
    defer c.deinit();

    const hash = Cache.hashContent("chunk-contents");

    // Miss, store, hit.
    try std.testing.expect(c.get(&hash, "batchA") == null);
    try c.put(&hash, "batchA", .{
        .status = 201,
        .content_type = "application/json",
        .body = "{\"reference\":\"xyz\"}",
    }, 14);

    const hit = c.get(&hash, "batchA").?;
    try std.testing.expectEqual(@as(u16, 201), hit.status);
    try std.testing.expectEqualStrings("{\"reference\":\"xyz\"}", hit.body);

    // Same content, different batch — must miss.
    try std.testing.expect(c.get(&hash, "batchB") == null);

    const s = c.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 2), s.misses);
    try std.testing.expectEqual(@as(u64, 14), s.bytes_saved);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "isDedupablePath matches /bytes and /chunks, excludes /bzz and subpaths" {
    try std.testing.expect(isDedupablePath("/bytes"));
    try std.testing.expect(isDedupablePath("/bytes?tag=7"));
    try std.testing.expect(isDedupablePath("/chunks"));
    try std.testing.expect(!isDedupablePath("/bzz"));
    try std.testing.expect(!isDedupablePath("/bzz/index.html"));
    try std.testing.expect(!isDedupablePath("/bytes/abc123")); // GET target
    try std.testing.expect(!isDedupablePath("/"));
}
