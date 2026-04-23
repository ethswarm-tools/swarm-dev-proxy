//! Mantaray manifest inspection.
//!
//! When a dapp uploads a directory or tar via `POST /bzz`, Bee returns
//! a reference pointing at a Mantaray root node (a chunk). The chunk
//! wire format is the usual `span(LE u64) || content`, but `content`
//! here is an obfuscated Mantaray node — its first 32 bytes are a
//! random obfuscation key, and the rest is XOR-scrambled with that
//! key cycled.
//!
//! Scope of this module: detect "is this actually a Mantaray node?"
//! and, if so, report its on-disk version tag plus the popcount of
//! the 256-bit fork bitmap (i.e. how many direct children the root
//! has). Full path resolution — walking fork prefixes, recursing into
//! children, mapping paths → references — is a P2 stretch goal.
//!
//! Layout we rely on (Mantaray v0.1 / v0.2 / v1.0 all agree on the
//! leading bytes):
//!   content[0..32]    obfuscation key
//!   content[32..63]   version string (31 bytes, null-padded ASCII)
//!   content[63]       reference size (1 byte: 32 or 64)
//!   content[64..96]   entry reference (or zeroes for non-value node)
//!   content[96..128]  fork bitmap (256 bits)
//!   content[128..]    fork list (variable layout, not parsed here)
//!
//! The first 32 bytes (the key) are not XOR'd; everything from offset
//! 32 onward is. We deobfuscate into a stack buffer to avoid mutating
//! the caller's chunk bytes.

const std = @import("std");

pub const MIN_NODE_BYTES: usize = 128;
pub const MAGIC: []const u8 = "mantaray";

pub const Inspection = struct {
    is_manifest: bool,
    ref_size: ?u8 = null,
    fork_count: ?u32 = null,
    version_buf: [31]u8 = undefined,
    version_len: u8 = 0,

    /// Use this instead of a stored slice — a stored slice would go
    /// stale when the struct is copied (e.g. when moved through a
    /// `LogEvent`), because it would point at the source struct's
    /// `version_buf`.
    pub fn version(self: *const Inspection) ?[]const u8 {
        if (self.version_len == 0) return null;
        return self.version_buf[0..self.version_len];
    }
};

/// Inspect the bytes returned by `GET /chunks/{ref}` for a suspected
/// Mantaray manifest. Zero alloc — the returned `Inspection` carries
/// its own 31-byte version buffer.
pub fn inspectChunkBytes(chunk_bytes: []const u8) Inspection {
    // Strip span prefix (chunk wire format) if present.
    if (chunk_bytes.len < 8) return .{ .is_manifest = false };
    const content = chunk_bytes[8..];
    return inspectNodeBytes(content);
}

/// Inspect raw node bytes (no span prefix). Exposed for testing and
/// for callers who've already stripped the span.
pub fn inspectNodeBytes(content: []const u8) Inspection {
    var out: Inspection = .{ .is_manifest = false };
    if (content.len < MIN_NODE_BYTES) return out;

    const key = content[0..32];

    // Deobfuscate bytes 32..128 (the fixed-size header portion we care
    // about). Stack-allocated, no heap touches.
    var deob: [MIN_NODE_BYTES - 32]u8 = undefined;
    for (content[32..MIN_NODE_BYTES], 0..) |b, i| {
        // XOR cycles the key starting from key[0] for the first
        // obfuscated byte — matches mantaray-js.
        deob[i] = b ^ key[i % key.len];
    }

    const version_bytes = deob[0..31];
    if (!std.mem.startsWith(u8, version_bytes, MAGIC)) return out;

    out.is_manifest = true;
    const trimmed = trimTrailingZeros(version_bytes);
    @memcpy(out.version_buf[0..trimmed.len], trimmed);
    out.version_len = @intCast(trimmed.len);

    out.ref_size = deob[31];

    // deob[64..96] in the original node maps to deob[32..64] after
    // the 32-byte key slice.
    const bitmap = deob[64..96];
    out.fork_count = popcountBytes(bitmap);
    return out;
}

fn trimTrailingZeros(bytes: []const u8) []const u8 {
    var end: usize = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
}

fn popcountBytes(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |b| n += @popCount(b);
    return n;
}

// --- tests ---

fn buildTestNode(version_str: []const u8, ref_size: u8, bitmap: [32]u8) [MIN_NODE_BYTES]u8 {
    var obf: [MIN_NODE_BYTES]u8 = undefined;
    @memset(&obf, 0);

    // Pick an arbitrary non-zero obfuscation key.
    const key_byte: u8 = 0x5a;
    @memset(obf[0..32], key_byte);

    // Plaintext layout of bytes 32..128:
    //   [0..31]  version (null-padded to 31 bytes)
    //   [31]     ref_size
    //   [32..64] entry (zeroes)
    //   [64..96] fork bitmap
    var plain: [MIN_NODE_BYTES - 32]u8 = undefined;
    @memset(&plain, 0);
    @memcpy(plain[0..@min(version_str.len, 31)], version_str[0..@min(version_str.len, 31)]);
    plain[31] = ref_size;
    @memcpy(plain[64..96], &bitmap);

    for (plain, 0..) |b, i| {
        obf[32 + i] = b ^ key_byte;
    }
    return obf;
}

test "inspectNodeBytes detects mantaray magic and reports fork count" {
    var bitmap: [32]u8 = @splat(0);
    // Set 5 bits across the bitmap.
    bitmap[0] = 0b0000_0111;
    bitmap[15] = 0b0000_0011;
    const node = buildTestNode("mantaray:1.0", 32, bitmap);

    const insp = inspectNodeBytes(&node);
    try std.testing.expect(insp.is_manifest);
    try std.testing.expectEqualStrings("mantaray:1.0", insp.version().?);
    try std.testing.expectEqual(@as(u8, 32), insp.ref_size.?);
    try std.testing.expectEqual(@as(u32, 5), insp.fork_count.?);
}

test "inspectNodeBytes rejects random bytes" {
    var random: [MIN_NODE_BYTES]u8 = undefined;
    // Fill with a simple deterministic pattern that does not happen to
    // deobfuscate into the mantaray magic.
    for (&random, 0..) |*b, i| b.* = @intCast((i * 7 + 13) & 0xff);
    const insp = inspectNodeBytes(&random);
    try std.testing.expect(!insp.is_manifest);
}

test "inspectNodeBytes rejects too-short input" {
    const short: [16]u8 = @splat(0);
    try std.testing.expect(!inspectNodeBytes(&short).is_manifest);
}

test "inspectChunkBytes strips 8-byte span prefix" {
    var bitmap: [32]u8 = @splat(0);
    bitmap[0] = 0x01;
    const node = buildTestNode("mantaray:0.2", 32, bitmap);

    var framed: [8 + MIN_NODE_BYTES]u8 = undefined;
    std.mem.writeInt(u64, framed[0..8], node.len, .little);
    @memcpy(framed[8..], &node);

    const insp = inspectChunkBytes(&framed);
    try std.testing.expect(insp.is_manifest);
    try std.testing.expectEqualStrings("mantaray:0.2", insp.version().?);
    try std.testing.expectEqual(@as(u32, 1), insp.fork_count.?);
}
