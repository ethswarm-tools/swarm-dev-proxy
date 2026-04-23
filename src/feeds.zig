//! Feed and Single-Owner-Chunk (SOC) observation.
//!
//! Both are keyed by human-readable identifiers (owner+topic for feeds,
//! owner+id for SOCs) extracted from the request path. We count
//! reads/writes and — for feeds — track the last and next index
//! surfaced in Bee's `swarm-feed-index` / `swarm-feed-index-next`
//! response headers.
//!
//! Mirrors the shape of `stamps.Tracker`: thread-safe, last-write-wins
//! on strings, caller passes transient slices and the tracker owns the
//! copies.

const std = @import("std");

pub const FeedStats = struct {
    /// Hex string, duped into tracker-owned memory.
    owner: []const u8,
    /// Hex string, duped into tracker-owned memory.
    topic: []const u8,
    reads: u64 = 0,
    writes: u64 = 0,
    last_index_hex: ?[]const u8 = null,
    next_index_hex: ?[]const u8 = null,
    last_reference: ?[]const u8 = null,
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
};

pub const SocStats = struct {
    owner: []const u8,
    id: []const u8,
    writes: u64 = 0,
    reads: u64 = 0,
    bytes_up: u64 = 0,
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
};

/// Parsed feed or SOC identity extracted from the request path.
pub const PathKind = union(enum) {
    feed: Identity,
    soc: Identity,

    pub const Identity = struct {
        owner: []const u8,
        /// For feeds this is the topic; for SOCs this is the identifier.
        key: []const u8,
    };
};

/// Returns a PathKind if `target` is a recognised feed/SOC path.
/// `target` typically comes from `request.head.target` (pre-query).
/// Slices point into the original `target`; caller owns lifetime.
pub fn parsePath(target: []const u8) ?PathKind {
    const path_end = std.mem.indexOfAnyPos(u8, target, 0, "?#") orelse target.len;
    const path = target[0..path_end];

    inline for ([_]struct { prefix: []const u8, mk: fn (PathKind.Identity) PathKind }{
        .{ .prefix = "/feeds/", .mk = mkFeed },
        .{ .prefix = "/soc/", .mk = mkSoc },
    }) |spec| {
        if (std.mem.startsWith(u8, path, spec.prefix)) {
            const rest = path[spec.prefix.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            const owner = rest[0..slash];
            const key_part = rest[slash + 1 ..];
            // Disallow deeper nesting (e.g. /feeds/a/b/c) — not a feed path.
            if (std.mem.indexOfScalar(u8, key_part, '/') != null) return null;
            if (owner.len == 0 or key_part.len == 0) return null;
            return spec.mk(.{ .owner = owner, .key = key_part });
        }
    }
    return null;
}

fn mkFeed(id: PathKind.Identity) PathKind {
    return .{ .feed = id };
}

fn mkSoc(id: PathKind.Identity) PathKind {
    return .{ .soc = id };
}

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    /// Keyed by "<owner>/<topic>".
    feeds: std.StringHashMapUnmanaged(FeedStats) = .empty,
    /// Keyed by "<owner>/<id>".
    socs: std.StringHashMapUnmanaged(SocStats) = .empty,

    pub fn deinit(t: *Tracker) void {
        t.mu.lock();
        defer t.mu.unlock();
        var fit = t.feeds.iterator();
        while (fit.next()) |e| {
            t.gpa.free(e.key_ptr.*);
            freeFeedStats(t.gpa, e.value_ptr);
        }
        t.feeds.deinit(t.gpa);
        var sit = t.socs.iterator();
        while (sit.next()) |e| {
            t.gpa.free(e.key_ptr.*);
            freeSocStats(t.gpa, e.value_ptr);
        }
        t.socs.deinit(t.gpa);
    }

    pub fn recordFeedRead(
        t: *Tracker,
        owner: []const u8,
        topic: []const u8,
        index_hex: ?[]const u8,
        next_index_hex: ?[]const u8,
        reference_hex: ?[]const u8,
    ) !FeedStats {
        t.mu.lock();
        defer t.mu.unlock();
        const s = try t.ensureFeed(owner, topic);
        s.reads += 1;
        s.last_seen_ms = std.time.milliTimestamp();
        try replaceOpt(t.gpa, &s.last_index_hex, index_hex);
        try replaceOpt(t.gpa, &s.next_index_hex, next_index_hex);
        try replaceOpt(t.gpa, &s.last_reference, reference_hex);
        return s.*;
    }

    pub fn recordFeedWrite(
        t: *Tracker,
        owner: []const u8,
        topic: []const u8,
    ) !FeedStats {
        t.mu.lock();
        defer t.mu.unlock();
        const s = try t.ensureFeed(owner, topic);
        s.writes += 1;
        s.last_seen_ms = std.time.milliTimestamp();
        return s.*;
    }

    pub fn recordSocWrite(
        t: *Tracker,
        owner: []const u8,
        id: []const u8,
        bytes_up: u64,
    ) !SocStats {
        t.mu.lock();
        defer t.mu.unlock();
        const s = try t.ensureSoc(owner, id);
        s.writes += 1;
        s.bytes_up += bytes_up;
        s.last_seen_ms = std.time.milliTimestamp();
        return s.*;
    }

    pub fn snapshotFeed(t: *Tracker, owner: []const u8, topic: []const u8) !?FeedStats {
        t.mu.lock();
        defer t.mu.unlock();
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ owner, topic });
        const s = t.feeds.getPtr(key) orelse return null;
        return s.*;
    }

    pub fn snapshotSoc(t: *Tracker, owner: []const u8, id: []const u8) !?SocStats {
        t.mu.lock();
        defer t.mu.unlock();
        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ owner, id });
        const s = t.socs.getPtr(key) orelse return null;
        return s.*;
    }

    pub fn feedCount(t: *Tracker) usize {
        t.mu.lock();
        defer t.mu.unlock();
        return t.feeds.count();
    }

    pub fn socCount(t: *Tracker) usize {
        t.mu.lock();
        defer t.mu.unlock();
        return t.socs.count();
    }

    /// Caller owns returned slice and must `gpa.free` it. The embedded
    /// strings live on the tracker and stay valid as long as it does.
    pub fn listFeeds(t: *Tracker, gpa: std.mem.Allocator) ![]FeedStats {
        t.mu.lock();
        defer t.mu.unlock();
        const out = try gpa.alloc(FeedStats, t.feeds.count());
        var i: usize = 0;
        var it = t.feeds.iterator();
        while (it.next()) |e| : (i += 1) out[i] = e.value_ptr.*;
        return out;
    }

    pub fn listSocs(t: *Tracker, gpa: std.mem.Allocator) ![]SocStats {
        t.mu.lock();
        defer t.mu.unlock();
        const out = try gpa.alloc(SocStats, t.socs.count());
        var i: usize = 0;
        var it = t.socs.iterator();
        while (it.next()) |e| : (i += 1) out[i] = e.value_ptr.*;
        return out;
    }

    // --- internals ---

    fn ensureFeed(t: *Tracker, owner: []const u8, topic: []const u8) !*FeedStats {
        const key = try std.fmt.allocPrint(t.gpa, "{s}/{s}", .{ owner, topic });
        errdefer t.gpa.free(key);
        const gop = try t.feeds.getOrPut(t.gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .owner = try t.gpa.dupe(u8, owner),
                .topic = try t.gpa.dupe(u8, topic),
                .first_seen_ms = std.time.milliTimestamp(),
            };
        } else {
            // Key already owned by map; free the one we just made.
            t.gpa.free(key);
        }
        return gop.value_ptr;
    }

    fn ensureSoc(t: *Tracker, owner: []const u8, id: []const u8) !*SocStats {
        const key = try std.fmt.allocPrint(t.gpa, "{s}/{s}", .{ owner, id });
        errdefer t.gpa.free(key);
        const gop = try t.socs.getOrPut(t.gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .owner = try t.gpa.dupe(u8, owner),
                .id = try t.gpa.dupe(u8, id),
                .first_seen_ms = std.time.milliTimestamp(),
            };
        } else {
            t.gpa.free(key);
        }
        return gop.value_ptr;
    }
};

fn replaceOpt(gpa: std.mem.Allocator, field: *?[]const u8, new_value: ?[]const u8) !void {
    const nv = new_value orelse return;
    if (field.*) |old| gpa.free(old);
    field.* = try gpa.dupe(u8, nv);
}

fn freeFeedStats(gpa: std.mem.Allocator, s: *FeedStats) void {
    gpa.free(s.owner);
    gpa.free(s.topic);
    if (s.last_index_hex) |x| gpa.free(x);
    if (s.next_index_hex) |x| gpa.free(x);
    if (s.last_reference) |x| gpa.free(x);
}

fn freeSocStats(gpa: std.mem.Allocator, s: *SocStats) void {
    gpa.free(s.owner);
    gpa.free(s.id);
}

test "parsePath extracts feed owner+topic" {
    const got = parsePath("/feeds/abcd1234/topic5678").?;
    try std.testing.expectEqualStrings("abcd1234", got.feed.owner);
    try std.testing.expectEqualStrings("topic5678", got.feed.key);
}

test "parsePath strips query string" {
    const got = parsePath("/feeds/abcd/topic?type=sequence").?;
    try std.testing.expectEqualStrings("abcd", got.feed.owner);
    try std.testing.expectEqualStrings("topic", got.feed.key);
}

test "parsePath recognises SOC paths" {
    const got = parsePath("/soc/owner123/id456").?;
    try std.testing.expectEqualStrings("owner123", got.soc.owner);
    try std.testing.expectEqualStrings("id456", got.soc.key);
}

test "parsePath rejects deeper nesting and empty segments" {
    try std.testing.expect(parsePath("/feeds/a/b/c") == null);
    try std.testing.expect(parsePath("/feeds/a/") == null);
    try std.testing.expect(parsePath("/feeds//topic") == null);
    try std.testing.expect(parsePath("/bytes/abc") == null);
    try std.testing.expect(parsePath("/") == null);
}

test "tracker counts feed reads and retains index" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    _ = try t.recordFeedRead("owner1", "topicA", "2a", "2b", "deadbeef");
    _ = try t.recordFeedRead("owner1", "topicA", "2b", "2c", "cafebabe");
    _ = try t.recordFeedRead("owner1", "topicB", "00", "01", null);

    try std.testing.expectEqual(@as(usize, 2), t.feedCount());

    const a = (try t.snapshotFeed("owner1", "topicA")).?;
    try std.testing.expectEqual(@as(u64, 2), a.reads);
    try std.testing.expectEqualStrings("2b", a.last_index_hex.?);
    try std.testing.expectEqualStrings("2c", a.next_index_hex.?);
    try std.testing.expectEqualStrings("cafebabe", a.last_reference.?);
}

test "tracker counts SOC writes and bytes" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    _ = try t.recordSocWrite("ownerZ", "idZ", 4096);
    _ = try t.recordSocWrite("ownerZ", "idZ", 100);

    const s = (try t.snapshotSoc("ownerZ", "idZ")).?;
    try std.testing.expectEqual(@as(u64, 2), s.writes);
    try std.testing.expectEqual(@as(u64, 4196), s.bytes_up);
    try std.testing.expectEqual(@as(usize, 1), t.socCount());
}
