//! Append-only on-disk persistence for the in-memory caches.
//!
//! Both `cache.Cache` (GET) and `post_dedup.Cache` (POST) hold
//! immutable, content-addressed entries — perfect candidates for
//! survival across proxy restarts. The dev iterate-loop ("re-run
//! my era:upload") then finds the same content already cached on
//! disk and skips both the upstream round-trip and the stamp slot.
//!
//! File layout: a single `.cache` file per logical store. Each entry
//! is appended as a self-describing record:
//!
//!   [ "SDPC" : 4 bytes magic ]
//!   [ status : u16 LE ]
//!   [ ct_len : u8     ]   (0 => no content-type)
//!   [ key_len : u16 LE ]
//!   [ body_len : u32 LE ]
//!   [ aux : u64 LE    ]   (free-form; e.g. POST dedup uses it for
//!                          req_body_len so `bytes_saved` survives
//!                          restarts; download cache passes 0)
//!   [ key bytes        ]
//!   [ content_type bytes ]
//!   [ body bytes       ]
//!
//! On overflow (`truncate`), the file is reset to size 0 and we start
//! fresh. Recovery on startup is a single linear scan; corrupted
//! tails (mid-write crashes) are detected when the next magic
//! mismatches and we stop reading from there. Earlier entries
//! survive.
//!
//! Thread-safety: writes serialize through the caller's mutex (the
//! cache's existing one). Reads only happen at startup before any
//! writer touches the cache, so no separate locking needed for
//! `iter`.

const std = @import("std");

const MAGIC: [4]u8 = .{ 'S', 'D', 'P', 'C' };
const HEADER_LEN: usize = 4 + 2 + 1 + 2 + 4 + 8; // magic + status + ct_len + key_len + body_len + aux = 21

pub const Persist = struct {
    file: std.fs.File,
    /// Read+append handle. Position semantics: we always seek to end
    /// before writing, so concurrent loaders/writers don't fight over
    /// position. Caller's mutex serialises writes.
    mu: std.Thread.Mutex = .{},

    pub fn open(path: []const u8) !Persist {
        // Ensure parent directory exists.
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        const f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer f.close();
        try f.seekFromEnd(0);
        return .{ .file = f };
    }

    pub fn close(p: *Persist) void {
        p.file.close();
    }

    pub fn append(
        p: *Persist,
        key: []const u8,
        status: u16,
        content_type: ?[]const u8,
        body: []const u8,
        aux: u64,
    ) !void {
        if (key.len > std.math.maxInt(u16)) return error.KeyTooLong;
        if (body.len > std.math.maxInt(u32)) return error.BodyTooLong;
        const ct_len: u8 = if (content_type) |ct| blk: {
            if (ct.len > std.math.maxInt(u8)) return error.ContentTypeTooLong;
            break :blk @intCast(ct.len);
        } else 0;

        var header: [HEADER_LEN]u8 = undefined;
        @memcpy(header[0..4], &MAGIC);
        std.mem.writeInt(u16, header[4..6], status, .little);
        header[6] = ct_len;
        std.mem.writeInt(u16, header[7..9], @intCast(key.len), .little);
        std.mem.writeInt(u32, header[9..13], @intCast(body.len), .little);
        std.mem.writeInt(u64, header[13..21], aux, .little);

        // One pwritev-equivalent: we pwriteAll at end. The mutex
        // discipline ensures no interleaving with other appends.
        p.mu.lock();
        defer p.mu.unlock();

        try p.file.seekFromEnd(0);
        var buf: [4096]u8 = undefined;
        var fw = p.file.writerStreaming(&buf);
        try fw.interface.writeAll(&header);
        try fw.interface.writeAll(key);
        if (content_type) |ct| try fw.interface.writeAll(ct);
        try fw.interface.writeAll(body);
        try fw.interface.flush();
    }

    pub fn truncate(p: *Persist) !void {
        p.mu.lock();
        defer p.mu.unlock();
        try p.file.setEndPos(0);
        try p.file.seekTo(0);
    }

    /// One-shot iterator over every record currently on disk. Returned
    /// slices are owned by the caller (allocated via `gpa`). On a
    /// truncated/corrupt tail we stop iterating without erroring —
    /// the caller gets every entry that successfully decoded.
    pub const Iter = struct {
        gpa: std.mem.Allocator,
        file: std.fs.File,
        offset: u64 = 0,
        end: u64,

        pub const Record = struct {
            key: []u8,
            status: u16,
            content_type: ?[]u8,
            body: []u8,
            aux: u64,

            pub fn deinit(r: Record, gpa: std.mem.Allocator) void {
                gpa.free(r.key);
                if (r.content_type) |ct| gpa.free(ct);
                gpa.free(r.body);
            }
        };

        pub fn next(it: *Iter) !?Record {
            if (it.offset >= it.end) return null;
            // Need at least HEADER_LEN bytes left.
            if (it.end - it.offset < HEADER_LEN) return null;

            var header: [HEADER_LEN]u8 = undefined;
            try it.file.seekTo(it.offset);
            const n = try it.file.read(&header);
            if (n != HEADER_LEN) return null;
            if (!std.mem.eql(u8, header[0..4], &MAGIC)) return null;

            const status = std.mem.readInt(u16, header[4..6], .little);
            const ct_len: usize = header[6];
            const key_len = std.mem.readInt(u16, header[7..9], .little);
            const body_len = std.mem.readInt(u32, header[9..13], .little);
            const aux = std.mem.readInt(u64, header[13..21], .little);

            const total: u64 = HEADER_LEN + key_len + ct_len + body_len;
            if (it.offset + total > it.end) return null; // truncated tail

            const key = try it.gpa.alloc(u8, key_len);
            errdefer it.gpa.free(key);
            if (try it.file.read(key) != key_len) return null;

            const ct: ?[]u8 = if (ct_len > 0) blk: {
                const buf = try it.gpa.alloc(u8, ct_len);
                if (try it.file.read(buf) != ct_len) {
                    it.gpa.free(buf);
                    return null;
                }
                break :blk buf;
            } else null;
            errdefer if (ct) |x| it.gpa.free(x);

            const body = try it.gpa.alloc(u8, body_len);
            errdefer it.gpa.free(body);
            if (try it.file.read(body) != body_len) return null;

            it.offset += total;
            return .{
                .key = key,
                .status = status,
                .content_type = ct,
                .body = body,
                .aux = aux,
            };
        }
    };

    pub fn iter(p: *Persist, gpa: std.mem.Allocator) !Iter {
        const end = try p.file.getEndPos();
        try p.file.seekTo(0);
        return .{ .gpa = gpa, .file = p.file, .offset = 0, .end = end };
    }
};

test "append + iterate round-trip" {
    const gpa = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/swarm-dev-proxy-persist-{x}.cache", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};

    var p = try Persist.open(path);
    defer p.close();

    try p.append("/bytes/abc", 200, "application/octet-stream", "hello world", 11);
    try p.append("/bytes/def", 200, null, "no-ct content", 0);

    var it = try p.iter(gpa);
    var seen: usize = 0;
    while (try it.next()) |rec| {
        defer rec.deinit(gpa);
        seen += 1;
        if (std.mem.eql(u8, rec.key, "/bytes/abc")) {
            try std.testing.expectEqual(@as(u16, 200), rec.status);
            try std.testing.expectEqualStrings("application/octet-stream", rec.content_type.?);
            try std.testing.expectEqualStrings("hello world", rec.body);
            try std.testing.expectEqual(@as(u64, 11), rec.aux);
        } else if (std.mem.eql(u8, rec.key, "/bytes/def")) {
            try std.testing.expectEqual(@as(u16, 200), rec.status);
            try std.testing.expect(rec.content_type == null);
            try std.testing.expectEqualStrings("no-ct content", rec.body);
            try std.testing.expectEqual(@as(u64, 0), rec.aux);
        } else return error.UnexpectedKey;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "truncate empties the file" {
    const gpa = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/swarm-dev-proxy-persist-{x}.cache", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};

    var p = try Persist.open(path);
    defer p.close();

    try p.append("k", 200, null, "data", 0);
    try p.truncate();
    try p.append("k2", 201, null, "second", 0);

    var it = try p.iter(gpa);
    var keys: [10][]const u8 = undefined;
    var n: usize = 0;
    while (try it.next()) |rec| {
        defer rec.deinit(gpa);
        keys[n] = "" ++ "";
        try std.testing.expectEqualStrings("k2", rec.key);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "iterator stops cleanly on a truncated tail" {
    const gpa = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/swarm-dev-proxy-persist-{x}.cache", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};

    var p = try Persist.open(path);
    try p.append("good", 200, null, "alpha", 0);
    try p.append("good2", 200, null, "beta", 0);
    p.close();

    // Simulate a crash mid-write by appending bogus tail bytes.
    {
        const f = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll("not-a-record");
    }

    var p2 = try Persist.open(path);
    defer p2.close();
    var it = try p2.iter(gpa);
    var n: usize = 0;
    while (try it.next()) |rec| {
        defer rec.deinit(gpa);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n); // both legit records survived
}
