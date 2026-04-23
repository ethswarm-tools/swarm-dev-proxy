//! Per-batch stamp-usage tracking.
//!
//! Observation-only: we never mutate stamp state. We see a
//! `swarm-postage-batch-id` header on a forwarded request, and we keep a
//! running tally (count, bytes up, bytes down, first/last seen). This is
//! enough for the P0 "that upload used N of your batch" log line; capacity
//! and TTL are P1 once we start side-fetching `GET /stamps/{id}` from the
//! upstream node.

const std = @import("std");

pub const BatchStats = struct {
    uploads: u64 = 0,
    bytes_up: u64 = 0,
    bytes_down: u64 = 0,
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,

    /// Capacity-side fields; populated by a one-shot side-fetch of
    /// `GET /stamps/{id}` against the upstream Bee node after the first
    /// time a batch is seen. `null` means the side-fetch hasn't run (or
    /// failed — check `capacity_fetch_failed`).
    depth: ?u32 = null,
    bucket_depth: ?u32 = null,
    bee_utilization: ?u64 = null,
    batch_ttl_seconds: ?i64 = null,
    capacity_fetch_failed: bool = false,

    warned_80: bool = false,
    warned_95: bool = false,

    /// Fullest-bucket fill ratio as a percentage (0..100), computed from
    /// Bee's `utilization` relative to per-bucket capacity. Returns null
    /// if capacity hasn't been fetched yet.
    pub fn utilizationPct(s: BatchStats) ?f64 {
        const d = s.depth orelse return null;
        const bd = s.bucket_depth orelse return null;
        const util = s.bee_utilization orelse return null;
        if (d < bd) return null;
        const per_bucket: u64 = @as(u64, 1) << @intCast(d - bd);
        if (per_bucket == 0) return null;
        const u_f: f64 = @floatFromInt(util);
        const pb_f: f64 = @floatFromInt(per_bucket);
        return (u_f / pb_f) * 100.0;
    }
};

pub const RecordOutcome = struct {
    stats: BatchStats,
    first_record: bool,
};

pub const WarnLevel = enum { none, w80, w95 };

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    batches: std.StringHashMapUnmanaged(BatchStats) = .empty,

    pub fn deinit(t: *Tracker) void {
        t.mu.lock();
        defer t.mu.unlock();
        var it = t.batches.iterator();
        while (it.next()) |entry| {
            t.gpa.free(entry.key_ptr.*);
        }
        t.batches.deinit(t.gpa);
    }

    /// Record one forwarded upload against `batch_id`. Returns the snapshot
    /// of the batch's stats *after* this update plus a `first_record`
    /// flag — callers use that to trigger a one-shot capacity side-fetch.
    ///
    /// `batch_id` is duped on first insertion — callers may pass a slice
    /// that points into a transient buffer.
    pub fn record(
        t: *Tracker,
        batch_id: []const u8,
        bytes_up: u64,
        bytes_down: u64,
    ) !RecordOutcome {
        t.mu.lock();
        defer t.mu.unlock();

        const now = std.time.milliTimestamp();

        const gop = try t.batches.getOrPut(t.gpa, batch_id);
        const first_record = !gop.found_existing;
        if (first_record) {
            gop.key_ptr.* = try t.gpa.dupe(u8, batch_id);
            gop.value_ptr.* = .{ .first_seen_ms = now };
        }
        const s = gop.value_ptr;
        s.uploads += 1;
        s.bytes_up += bytes_up;
        s.bytes_down += bytes_down;
        s.last_seen_ms = now;
        return .{ .stats = s.*, .first_record = first_record };
    }

    /// Populate the capacity-side fields after a successful side-fetch of
    /// `GET /stamps/{id}`. Idempotent — last write wins.
    pub fn setCapacity(
        t: *Tracker,
        batch_id: []const u8,
        depth: u32,
        bucket_depth: u32,
        bee_utilization: u64,
        batch_ttl_seconds: i64,
    ) !void {
        t.mu.lock();
        defer t.mu.unlock();
        const gop = try t.batches.getOrPut(t.gpa, batch_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try t.gpa.dupe(u8, batch_id);
            gop.value_ptr.* = .{ .first_seen_ms = std.time.milliTimestamp() };
        }
        const s = gop.value_ptr;
        s.depth = depth;
        s.bucket_depth = bucket_depth;
        s.bee_utilization = bee_utilization;
        s.batch_ttl_seconds = batch_ttl_seconds;
        s.capacity_fetch_failed = false;
    }

    /// Mark the capacity side-fetch as having failed so we don't keep
    /// retrying on every subsequent upload for this batch.
    pub fn markCapacityFailed(t: *Tracker, batch_id: []const u8) !void {
        t.mu.lock();
        defer t.mu.unlock();
        const gop = try t.batches.getOrPut(t.gpa, batch_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try t.gpa.dupe(u8, batch_id);
            gop.value_ptr.* = .{ .first_seen_ms = std.time.milliTimestamp() };
        }
        gop.value_ptr.capacity_fetch_failed = true;
    }

    /// Check whether the current fullest-bucket utilization crosses an
    /// 80 % or 95 % threshold that hasn't been warned about yet. Marks
    /// the threshold as warned so repeated calls only fire once.
    pub fn checkAndMarkWarn(t: *Tracker, batch_id: []const u8) WarnLevel {
        t.mu.lock();
        defer t.mu.unlock();
        const s = t.batches.getPtr(batch_id) orelse return .none;
        const pct = s.utilizationPct() orelse return .none;
        if (pct >= 95.0 and !s.warned_95) {
            s.warned_95 = true;
            s.warned_80 = true;
            return .w95;
        }
        if (pct >= 80.0 and !s.warned_80) {
            s.warned_80 = true;
            return .w80;
        }
        return .none;
    }

    pub fn snapshot(t: *Tracker, batch_id: []const u8) ?BatchStats {
        t.mu.lock();
        defer t.mu.unlock();
        const s = t.batches.getPtr(batch_id) orelse return null;
        return s.*;
    }

    pub fn count(t: *Tracker) usize {
        t.mu.lock();
        defer t.mu.unlock();
        return t.batches.count();
    }

    pub const ListEntry = struct { batch_id: []const u8, stats: BatchStats };

    /// Copy of every tracked batch. Returned slice is caller-owned and
    /// must be freed via `gpa.free`; the `batch_id` strings are still
    /// owned by the tracker (stable as long as the tracker is).
    pub fn list(t: *Tracker, gpa: std.mem.Allocator) ![]ListEntry {
        t.mu.lock();
        defer t.mu.unlock();
        const out = try gpa.alloc(ListEntry, t.batches.count());
        var i: usize = 0;
        var it = t.batches.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = .{ .batch_id = e.key_ptr.*, .stats = e.value_ptr.* };
        }
        return out;
    }
};

test "tracker counts uploads and bytes per batch" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    const r1 = try t.record("batchA", 100, 10);
    try std.testing.expect(r1.first_record);

    const r2 = try t.record("batchA", 250, 20);
    try std.testing.expect(!r2.first_record);

    const r3 = try t.record("batchB", 5, 5);
    try std.testing.expect(r3.first_record);
    try std.testing.expectEqual(@as(u64, 1), r3.stats.uploads);

    try std.testing.expectEqual(@as(usize, 2), t.count());

    const a = t.snapshot("batchA").?;
    try std.testing.expectEqual(@as(u64, 2), a.uploads);
    try std.testing.expectEqual(@as(u64, 350), a.bytes_up);
    try std.testing.expectEqual(@as(u64, 30), a.bytes_down);
    try std.testing.expect(a.last_seen_ms >= a.first_seen_ms);

    try std.testing.expect(t.snapshot("never-seen") == null);
}

test "tracker dupes batch_id keys" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    var transient: [8]u8 = .{ 'b', 'a', 't', 'c', 'h', 'X', 0, 0 };
    _ = try t.record(transient[0..6], 42, 0);

    // Mutate the caller's buffer — tracker must have its own copy.
    transient[0] = 'Z';

    const s = t.snapshot("batchX").?;
    try std.testing.expectEqual(@as(u64, 42), s.bytes_up);
}

test "utilization percentage from depth, bucket_depth, utilization" {
    // depth=20, bucket_depth=16 -> 2^(20-16)=16 chunks per bucket.
    // utilization=8 -> fill = 8/16 = 50%.
    const s: BatchStats = .{
        .depth = 20,
        .bucket_depth = 16,
        .bee_utilization = 8,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), s.utilizationPct().?, 0.0001);
}

test "utilization is null without capacity fetch" {
    const s: BatchStats = .{};
    try std.testing.expect(s.utilizationPct() == null);
}

test "threshold crossing fires once per level" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    _ = try t.record("b", 1, 0);
    // 12/16 = 75% — below threshold.
    try t.setCapacity("b", 20, 16, 12, 3600);
    try std.testing.expectEqual(WarnLevel.none, t.checkAndMarkWarn("b"));

    // 13/16 = 81.25% — crosses 80%.
    try t.setCapacity("b", 20, 16, 13, 3600);
    try std.testing.expectEqual(WarnLevel.w80, t.checkAndMarkWarn("b"));
    // Same level should not fire again.
    try std.testing.expectEqual(WarnLevel.none, t.checkAndMarkWarn("b"));

    // 16/16 = 100% — crosses 95%.
    try t.setCapacity("b", 20, 16, 16, 3600);
    try std.testing.expectEqual(WarnLevel.w95, t.checkAndMarkWarn("b"));
    try std.testing.expectEqual(WarnLevel.none, t.checkAndMarkWarn("b"));
}

test "threshold crossing skips 80 when first observation is already above 95" {
    var t: Tracker = .{ .gpa = std.testing.allocator };
    defer t.deinit();

    _ = try t.record("b", 1, 0);
    // First capacity observation already at 100% — jump straight to w95,
    // and implicitly mark w80 as warned (suppresses a redundant warning).
    try t.setCapacity("b", 20, 16, 16, 3600);
    try std.testing.expectEqual(WarnLevel.w95, t.checkAndMarkWarn("b"));
    try std.testing.expectEqual(WarnLevel.none, t.checkAndMarkWarn("b"));
}
