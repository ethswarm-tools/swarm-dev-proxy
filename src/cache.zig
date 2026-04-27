//! Content-addressed response cache.
//!
//! Keyed by Swarm reference ("bytes:<ref>" or "chunks:<ref>"), which is a
//! hash of the content — so entries are immutable and can be kept
//! indefinitely. Thread-safe. Caller owns nothing returned; the tracker
//! clones on put and loans slices on get (valid until the entry is
//! evicted, which for now is never).

const std = @import("std");
const disk_persist = @import("disk_persist.zig");

pub const Entry = struct {
    status: u16,
    content_type: ?[]const u8,
    body: []const u8,
};

/// Upper bound on entries before we dump the whole cache. Simple
/// "clear-on-overflow" keeps the data structure tiny while still
/// providing an effective bound on RSS during long-running workloads.
/// Not LRU, but good enough for hot-path dedup; lost entries just
/// cost a cache miss (backend call) next time.
pub const MAX_ENTRIES_DEFAULT: usize = 100_000;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Stored) = .empty,
    total_bytes: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    max_entries: usize = MAX_ENTRIES_DEFAULT,
    /// Optional on-disk persistence; if set, every successful `put`
    /// also appends a record and overflow truncates the file. The
    /// pointer's owned by the Proxy; we never deinit it here.
    persist: ?*disk_persist.Persist = null,

    const Stored = struct {
        status: u16,
        content_type: ?[]const u8, // owned or null
        body: []const u8, // owned
    };

    /// Restore previously-persisted entries from disk. Call once
    /// after init() and before serving requests. Each successful
    /// record becomes a live entry. Called outside the mutex
    /// because no other thread is touching the cache yet.
    pub fn loadFromDisk(c: *Cache) !void {
        const persist = c.persist orelse return;
        var it = try persist.iter(c.gpa);
        while (try it.next()) |rec| {
            // Ownership move: rec.* slices are owned by us; insert
            // them directly into the hashmap.
            errdefer {
                c.gpa.free(rec.key);
                if (rec.content_type) |x| c.gpa.free(x);
                c.gpa.free(rec.body);
            }
            const gop = try c.entries.getOrPut(c.gpa, rec.key);
            if (gop.found_existing) {
                // Two records for the same key (shouldn't happen for
                // immutable content addressing, but be defensive on
                // an old/replayed file). Free the new one.
                c.gpa.free(rec.key);
                if (rec.content_type) |x| c.gpa.free(x);
                c.gpa.free(rec.body);
                continue;
            }
            gop.key_ptr.* = rec.key;
            gop.value_ptr.* = .{
                .status = rec.status,
                .content_type = rec.content_type,
                .body = rec.body,
            };
            c.total_bytes += rec.body.len;
        }
    }

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

    /// Look up a cached entry. Returns a snapshot — the returned slices
    /// are owned by the cache. Since we never evict, they outlive the
    /// caller's use for now. Bumps `hits`/`misses` for summary lines.
    pub fn get(c: *Cache, key: []const u8) ?Entry {
        c.mu.lock();
        defer c.mu.unlock();
        if (c.entries.get(key)) |s| {
            c.hits += 1;
            return .{
                .status = s.status,
                .content_type = s.content_type,
                .body = s.body,
            };
        }
        c.misses += 1;
        return null;
    }

    /// Store a response. Clones key, content_type, and body. Silently
    /// does nothing if an entry already exists (immutable by hash).
    pub fn put(
        c: *Cache,
        key: []const u8,
        status: u16,
        content_type: ?[]const u8,
        body: []const u8,
    ) !void {
        c.mu.lock();
        defer c.mu.unlock();
        if (c.entries.contains(key)) return;

        if (c.entries.count() >= c.max_entries) {
            c.clearLocked();
            c.evictions += 1;
            if (c.persist) |p| p.truncate() catch {};
        }

        const key_owned = try c.gpa.dupe(u8, key);
        errdefer c.gpa.free(key_owned);
        const body_owned = try c.gpa.dupe(u8, body);
        errdefer c.gpa.free(body_owned);
        const ct_owned: ?[]const u8 = if (content_type) |ct| try c.gpa.dupe(u8, ct) else null;
        errdefer if (ct_owned) |x| c.gpa.free(x);

        try c.entries.put(c.gpa, key_owned, .{
            .status = status,
            .content_type = ct_owned,
            .body = body_owned,
        });
        c.total_bytes += body.len;

        // Best-effort disk persistence. If the disk is full or the
        // append fails for any reason, we keep the in-memory entry —
        // a transient disk error shouldn't lose the live cache.
        if (c.persist) |p| {
            p.append(key, status, content_type, body, 0) catch {};
        }
    }

    /// Caller must hold c.mu. Free every stored entry + key and reset
    /// counters associated with live storage (`total_bytes`). `hits`,
    /// `misses`, and `evictions` are lifetime totals and persist.
    fn clearLocked(c: *Cache) void {
        var it = c.entries.iterator();
        while (it.next()) |e| {
            c.gpa.free(e.key_ptr.*);
            if (e.value_ptr.content_type) |ct| c.gpa.free(ct);
            c.gpa.free(e.value_ptr.body);
        }
        c.entries.clearRetainingCapacity();
        c.total_bytes = 0;
    }

    pub const Stats = struct {
        entries: usize,
        bytes: u64,
        hits: u64,
        misses: u64,
        evictions: u64 = 0,
    };

    pub fn stats(c: *Cache) Stats {
        c.mu.lock();
        defer c.mu.unlock();
        return .{
            .entries = c.entries.count(),
            .bytes = c.total_bytes,
            .hits = c.hits,
            .misses = c.misses,
            .evictions = c.evictions,
        };
    }
};

/// Return a cache key for a cacheable GET path. Returns null for
/// anything else. Query strings are stripped.
///
/// Cacheable prefixes:
///   `/bytes/<ref>`  — raw content by reference; no subpaths allowed
///   `/chunks/<ref>` — single chunk by reference; no subpaths allowed
///   `/bzz/<ref>`, `/bzz/<ref>/<path>` — manifest-resolved resource.
///       Subpaths ARE allowed here because the Mantaray under `<ref>`
///       deterministically maps each path to a fixed content ref —
///       the tuple (ref, path) is content-addressed.
pub fn keyForGet(target: []const u8) ?[]const u8 {
    const path_end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
    const path = target[0..path_end];

    // /bytes/ and /chunks/ — strict "exactly one hex ref" form.
    for ([_][]const u8{ "/bytes/", "/chunks/" }) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) {
            const ref = path[prefix.len..];
            if (std.mem.indexOfScalar(u8, ref, '/') != null) return null;
            if (ref.len == 0) return null;
            return path;
        }
    }

    // /bzz/ — allow any subpath. The full path is the key.
    if (std.mem.startsWith(u8, path, "/bzz/")) {
        const rest = path["/bzz/".len..];
        const first_slash = std.mem.indexOfScalar(u8, rest, '/');
        const ref = if (first_slash) |i| rest[0..i] else rest;
        if (ref.len == 0) return null;
        return path;
    }

    return null;
}

test "keyForGet matches /bytes/<ref>" {
    const key = keyForGet("/bytes/abcd1234").?;
    try std.testing.expectEqualStrings("/bytes/abcd1234", key);
}

test "keyForGet matches /chunks/<ref>" {
    const key = keyForGet("/chunks/deadbeef").?;
    try std.testing.expectEqualStrings("/chunks/deadbeef", key);
}

test "keyForGet strips query" {
    const key = keyForGet("/bytes/abcd1234?foo=bar").?;
    try std.testing.expectEqualStrings("/bytes/abcd1234", key);
}

test "keyForGet rejects deeper paths on /bytes and /chunks" {
    try std.testing.expect(keyForGet("/bytes/abc/index.html") == null);
    try std.testing.expect(keyForGet("/chunks/abc/sub") == null);
    try std.testing.expect(keyForGet("/bytes/") == null);
    try std.testing.expect(keyForGet("/") == null);
}

test "keyForGet matches /bzz/ root and subpaths" {
    {
        const k = keyForGet("/bzz/abcd").?;
        try std.testing.expectEqualStrings("/bzz/abcd", k);
    }
    {
        const k = keyForGet("/bzz/abcd/meta").?;
        try std.testing.expectEqualStrings("/bzz/abcd/meta", k);
    }
    {
        const k = keyForGet("/bzz/abcd/number/1000").?;
        try std.testing.expectEqualStrings("/bzz/abcd/number/1000", k);
    }
    // Query stripped, deep subpath preserved.
    {
        const k = keyForGet("/bzz/abcd/hash/0xdead?download=1").?;
        try std.testing.expectEqualStrings("/bzz/abcd/hash/0xdead", k);
    }
    // Empty ref rejected.
    try std.testing.expect(keyForGet("/bzz/") == null);
    try std.testing.expect(keyForGet("/bzz//meta") == null);
}

test "cache put and get round-trip" {
    var c: Cache = .{ .gpa = std.testing.allocator };
    defer c.deinit();

    try std.testing.expect(c.get("/bytes/abc") == null);
    try c.put("/bytes/abc", 200, "application/octet-stream", "payload-here");
    const hit = c.get("/bytes/abc").?;
    try std.testing.expectEqual(@as(u16, 200), hit.status);
    try std.testing.expectEqualStrings("application/octet-stream", hit.content_type.?);
    try std.testing.expectEqualStrings("payload-here", hit.body);

    const s = c.stats();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
    try std.testing.expectEqual(@as(u64, "payload-here".len), s.bytes);
}

test "cache is idempotent on duplicate puts" {
    var c: Cache = .{ .gpa = std.testing.allocator };
    defer c.deinit();

    try c.put("/bytes/abc", 200, null, "first");
    try c.put("/bytes/abc", 200, null, "second-ignored");
    const hit = c.get("/bytes/abc").?;
    try std.testing.expectEqualStrings("first", hit.body);
}
