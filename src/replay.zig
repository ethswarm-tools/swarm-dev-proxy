//! Request/response replay log.
//!
//! Every forwarded request produces one line in the configured log
//! file. Format is newline-delimited JSON (ndjson): one record per
//! line, bodies base64-encoded so binary chunks survive intact. You
//! can tail it, jq it, diff it, or feed it back through a replay
//! driver to repro bugs against a different node.
//!
//! Appends only. Thread-safe via a single mutex around the write
//! path; callers can share one `Writer` across connections.
//!
//! Schema of each line:
//! ```
//! {
//!   "ts_ms": 1714123456789,
//!   "method": "POST",
//!   "target": "/bytes",
//!   "req_headers": [["content-type","application/octet-stream"], ...],
//!   "req_body_b64": "...",
//!   "resp_status": 201,
//!   "resp_headers": [["content-type","application/json"], ...],
//!   "resp_body_b64": "..."
//! }
//! ```

const std = @import("std");
const base64 = std.base64;

/// Re-exported so callers can feed `std.http.Header` slices directly
/// without a conversion step.
pub const Header = std.http.Header;

pub const Event = struct {
    ts_ms: i64,
    method: []const u8,
    target: []const u8,
    req_headers: []const Header,
    req_body: []const u8,
    resp_status: u16,
    resp_headers: []const Header,
    resp_body: []const u8,
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    file: std.fs.File,
    mu: std.Thread.Mutex = .{},

    /// Opens (or creates) `path` and seeks to end, so existing content
    /// is preserved and new events append.
    pub fn init(gpa: std.mem.Allocator, path: []const u8) !Writer {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
        errdefer f.close();
        try f.seekFromEnd(0);
        return .{ .gpa = gpa, .file = f };
    }

    pub fn deinit(w: *Writer) void {
        w.file.close();
    }

    pub fn record(w: *Writer, e: Event) !void {
        var line: std.Io.Writer.Allocating = .init(w.gpa);
        defer line.deinit();
        try buildLine(&line.writer, e);
        try line.writer.writeByte('\n');

        w.mu.lock();
        defer w.mu.unlock();

        // One writeAll per line so readers never see partial records.
        var file_buf: [128]u8 = undefined;
        var fw = w.file.writerStreaming(&file_buf);
        try fw.interface.writeAll(line.written());
        try fw.interface.flush();
    }
};

fn buildLine(out: *std.Io.Writer, e: Event) !void {
    try out.writeAll("{\"ts_ms\":");
    try out.print("{d}", .{e.ts_ms});

    try out.writeAll(",\"method\":\"");
    try writeJsonString(out, e.method);
    try out.writeAll("\",\"target\":\"");
    try writeJsonString(out, e.target);
    try out.writeAll("\"");

    try out.writeAll(",\"req_headers\":");
    try writeHeadersArray(out, e.req_headers);
    try out.writeAll(",\"req_body_b64\":\"");
    try writeBase64(out, e.req_body);
    try out.writeAll("\"");

    try out.writeAll(",\"resp_status\":");
    try out.print("{d}", .{e.resp_status});
    try out.writeAll(",\"resp_headers\":");
    try writeHeadersArray(out, e.resp_headers);
    try out.writeAll(",\"resp_body_b64\":\"");
    try writeBase64(out, e.resp_body);
    try out.writeAll("\"}");
}

fn writeHeadersArray(out: *std.Io.Writer, headers: []const Header) !void {
    try out.writeAll("[");
    for (headers, 0..) |h, i| {
        if (i != 0) try out.writeAll(",");
        try out.writeAll("[\"");
        try writeJsonString(out, h.name);
        try out.writeAll("\",\"");
        try writeJsonString(out, h.value);
        try out.writeAll("\"]");
    }
    try out.writeAll("]");
}

fn writeJsonString(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            // All other control chars (excluding the three handled above).
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try out.print("\\u{x:0>4}", .{c}),
            else => try out.writeByte(c),
        }
    }
}

fn writeBase64(out: *std.Io.Writer, bytes: []const u8) !void {
    const enc = base64.standard.Encoder;
    // encodeWriter's `dest` must support writeAll.
    const Adapter = struct {
        w: *std.Io.Writer,
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.w.writeAll(data);
        }
    };
    try enc.encodeWriter(Adapter{ .w = out }, bytes);
}

test "buildLine produces parseable JSON" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    try buildLine(&aw.writer, .{
        .ts_ms = 1234,
        .method = "POST",
        .target = "/bytes",
        .req_headers = &headers,
        .req_body = "abc",
        .resp_status = 201,
        .resp_headers = &.{},
        .resp_body = "{\"reference\":\"deadbeef\"}",
    });

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1234), obj.get("ts_ms").?.integer);
    try std.testing.expectEqualStrings("POST", obj.get("method").?.string);
    try std.testing.expectEqualStrings("/bytes", obj.get("target").?.string);
    try std.testing.expectEqual(@as(i64, 201), obj.get("resp_status").?.integer);
    // Base64 of "abc" is "YWJj"
    try std.testing.expectEqualStrings("YWJj", obj.get("req_body_b64").?.string);
}

test "writeJsonString escapes control chars and quotes" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeJsonString(&aw.writer, "a\"b\nc\\d");
    try std.testing.expectEqualStrings("a\\\"b\\nc\\\\d", aw.written());
}

test "Writer records a line that round-trips through json parser" {
    const gpa = std.testing.allocator;

    // Temp path; unique per run so parallel tests don't collide.
    var name_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "/tmp/swarm-dev-proxy-replay-{x}.ndjson", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try Writer.init(gpa, path);
    defer w.deinit();

    try w.record(.{
        .ts_ms = 100,
        .method = "GET",
        .target = "/health",
        .req_headers = &.{},
        .req_body = "",
        .resp_status = 200,
        .resp_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        .resp_body = "ok\n",
    });

    const contents = try std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024);
    defer gpa.free(contents);

    try std.testing.expect(std.mem.endsWith(u8, contents, "\n"));

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        std.mem.trimRight(u8, contents, "\n"),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("GET", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("/health", parsed.value.object.get("target").?.string);
    // Base64 of "ok\n" is "b2sK"
    try std.testing.expectEqualStrings("b2sK", parsed.value.object.get("resp_body_b64").?.string);
}
