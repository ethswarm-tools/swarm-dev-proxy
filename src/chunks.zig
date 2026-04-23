//! Root-chunk inspection.
//!
//! After `POST /bytes` (or `/bzz`) completes with a 201, Bee returns
//! `{"reference":"<hex>"}` — the root chunk of the content-addressed
//! BMT tree for the uploaded data. A one-shot side-fetch of
//! `GET /chunks/{reference}` gives us the chunk bytes, and the 8-byte
//! little-endian span prefix tells us how much data the subtree covers.
//!
//! We don't walk the whole tree — that would be N+1 fetches for every
//! upload. Just parse the root and report span, top-level fan-out, and
//! an estimate of total leaves.

const std = @import("std");
const http = std.http;
const Io = std.Io;

const CHUNK_PAYLOAD_MAX: u64 = 4096;
const REFERENCE_SIZE: u64 = 32; // 32-byte Swarm hashes in intermediate chunks
// A Swarm reference may be 32-byte (unencrypted) or 64-byte (encrypted).
// We default to 32-byte since dev proxies mostly see unencrypted flows;
// encrypted content would just report a different fan-out estimate.

pub const Inspection = struct {
    span: u64,
    /// `true` if the root chunk fits the entire payload — no children.
    is_leaf: bool,
    /// Number of direct children of the root (0 for a leaf chunk).
    root_children: u32,
    /// Estimate of total leaf chunks across the whole subtree.
    leaves_estimated: u64,
    /// Depth of the tree root above the leaves (0 for a leaf root).
    depth_estimated: u32,
};

pub const BeeBytesPostResponse = struct {
    reference: []const u8,
};

pub fn parsePostReference(
    gpa: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(BeeBytesPostResponse) {
    return std.json.parseFromSlice(BeeBytesPostResponse, gpa, body, .{
        .ignore_unknown_fields = true,
    });
}

/// Parse the raw bytes of a Swarm chunk (as returned by Bee's
/// `/chunks/{ref}` endpoint): 8-byte little-endian span prefix followed
/// by up to 4096 bytes of content. Derives fan-out and depth estimates.
pub fn inspectChunkBytes(chunk_bytes: []const u8) !Inspection {
    if (chunk_bytes.len < 8) return error.ChunkTooShort;
    const span = std.mem.readInt(u64, chunk_bytes[0..8], .little);
    const content = chunk_bytes[8..];

    if (span <= CHUNK_PAYLOAD_MAX) {
        return .{
            .span = span,
            .is_leaf = true,
            .root_children = 0,
            .leaves_estimated = 1,
            .depth_estimated = 0,
        };
    }

    // Intermediate root: content is concatenated child references.
    const children: u32 = @intCast(content.len / REFERENCE_SIZE);
    const leaves_estimated = (span + CHUNK_PAYLOAD_MAX - 1) / CHUNK_PAYLOAD_MAX;
    // Each level fans out by up to CHUNK_PAYLOAD_MAX/REFERENCE_SIZE = 128.
    // depth = ceil(log_128(leaves)).
    var depth: u32 = 0;
    var levels_capacity: u64 = 1;
    const fan_out: u64 = CHUNK_PAYLOAD_MAX / REFERENCE_SIZE;
    while (levels_capacity < leaves_estimated) {
        levels_capacity *= fan_out;
        depth += 1;
    }
    return .{
        .span = span,
        .is_leaf = false,
        .root_children = children,
        .leaves_estimated = leaves_estimated,
        .depth_estimated = depth,
    };
}

/// Side-fetch the chunk bytes at `reference_hex` from `upstream_host:port`
/// and run `inspectChunkBytes` on them. Caller owns no allocations.
pub fn inspectReference(
    gpa: std.mem.Allocator,
    upstream_host: []const u8,
    upstream_port: u16,
    reference_hex: []const u8,
) !Inspection {
    const url = try std.fmt.allocPrint(gpa, "http://{s}:{d}/chunks/{s}", .{
        upstream_host, upstream_port, reference_hex,
    });
    defer gpa.free(url);

    var client: http.Client = .{ .allocator = gpa };
    defer client.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var body_writer: Io.Writer.Allocating = .fromArrayList(gpa, &body);
    defer body = body_writer.toArrayList();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .keep_alive = false,
    });
    if (result.status != .ok) return error.ChunkFetchFailed;

    return inspectChunkBytes(body_writer.written());
}

test "leaf chunk: span<=4096, depth 0, one leaf" {
    var bytes: [8 + 100]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], 100, .little);
    @memset(bytes[8..], 'A');
    const insp = try inspectChunkBytes(&bytes);
    try std.testing.expectEqual(@as(u64, 100), insp.span);
    try std.testing.expect(insp.is_leaf);
    try std.testing.expectEqual(@as(u32, 0), insp.root_children);
    try std.testing.expectEqual(@as(u64, 1), insp.leaves_estimated);
    try std.testing.expectEqual(@as(u32, 0), insp.depth_estimated);
}

test "span at CHUNK_PAYLOAD_MAX boundary is still a leaf" {
    var bytes: [8 + 4096]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], 4096, .little);
    @memset(bytes[8..], 'B');
    const insp = try inspectChunkBytes(&bytes);
    try std.testing.expect(insp.is_leaf);
    try std.testing.expectEqual(@as(u64, 1), insp.leaves_estimated);
}

test "intermediate root: span 8192 = 2 leaves, depth 1" {
    // 2 child refs (each 32 bytes), span=8192.
    var bytes: [8 + 64]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], 8192, .little);
    @memset(bytes[8..], 0xAA);
    const insp = try inspectChunkBytes(&bytes);
    try std.testing.expect(!insp.is_leaf);
    try std.testing.expectEqual(@as(u32, 2), insp.root_children);
    try std.testing.expectEqual(@as(u64, 2), insp.leaves_estimated);
    try std.testing.expectEqual(@as(u32, 1), insp.depth_estimated);
}

test "deep tree: 2MB = 512 leaves, depth 2" {
    // Root contains 4 child refs; span is 2 MiB.
    var bytes: [8 + 128]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], 2 * 1024 * 1024, .little);
    @memset(bytes[8..], 0xBB);
    const insp = try inspectChunkBytes(&bytes);
    try std.testing.expectEqual(@as(u32, 4), insp.root_children);
    try std.testing.expectEqual(@as(u64, 512), insp.leaves_estimated);
    try std.testing.expectEqual(@as(u32, 2), insp.depth_estimated);
}

test "parsePostReference tolerates extra fields" {
    const gpa = std.testing.allocator;
    const parsed = try parsePostReference(
        gpa,
        "{\"reference\":\"abcdef01\",\"other\":42}",
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abcdef01", parsed.value.reference);
}
