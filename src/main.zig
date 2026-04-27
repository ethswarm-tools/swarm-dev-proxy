const std = @import("std");
const proxy_lib = @import("swarm_dev_proxy");

const usage =
    \\swarm-dev-proxy — forward HTTP proxy for the Bee API
    \\
    \\Usage: swarm-dev-proxy [options]
    \\
    \\Options:
    \\  --listen HOST:PORT     address to listen on (default 127.0.0.1:1733)
    \\  --upstream HOST:PORT   upstream Bee node (default 127.0.0.1:1633)
    \\  --no-cache             disable GET /bytes and /chunks response cache
    \\  --no-chunks            skip root-chunk side-fetch on POST /bytes and /bzz
    \\  --no-post-dedup        disable content-hash dedup of POST /bytes and /chunks
    \\  --max-body-mb N        reject requests whose content-length exceeds N MiB (413)
    \\  --cache-dir DIR        persist GET cache + POST-dedup cache to DIR across restarts
    \\  --mock                 serve from in-process mock (no upstream required)
    \\  --replay-log FILE      append every request/response to FILE as ndjson
    \\  --help, -h             show this message
    \\
;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var cfg: proxy_lib.Config = .{};
    var replay_log_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try writeStderr(usage);
            return;
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) return die("--listen requires HOST:PORT");
            try parseHostPort(args[i], &cfg.listen_addr, &cfg.listen_port);
        } else if (std.mem.eql(u8, a, "--upstream")) {
            i += 1;
            if (i >= args.len) return die("--upstream requires HOST:PORT");
            try parseHostPort(args[i], &cfg.upstream_host, &cfg.upstream_port);
        } else if (std.mem.eql(u8, a, "--no-cache")) {
            cfg.cache_enabled = false;
        } else if (std.mem.eql(u8, a, "--no-chunks")) {
            cfg.chunk_inspection_enabled = false;
        } else if (std.mem.eql(u8, a, "--no-post-dedup")) {
            cfg.post_dedup_enabled = false;
        } else if (std.mem.eql(u8, a, "--max-body-mb")) {
            i += 1;
            if (i >= args.len) return die("--max-body-mb requires a number");
            const mb = std.fmt.parseInt(u64, args[i], 10) catch
                return die("invalid --max-body-mb value");
            cfg.max_request_body_bytes = mb * 1024 * 1024;
        } else if (std.mem.eql(u8, a, "--cache-dir")) {
            i += 1;
            if (i >= args.len) return die("--cache-dir requires DIR");
            cfg.cache_dir = args[i];
        } else if (std.mem.eql(u8, a, "--mock")) {
            cfg.mock_enabled = true;
        } else if (std.mem.eql(u8, a, "--replay-log")) {
            i += 1;
            if (i >= args.len) return die("--replay-log requires FILE");
            replay_log_path = args[i];
        } else {
            try writeStderr(usage);
            return die("unknown argument");
        }
    }

    var p = proxy_lib.Proxy.init(gpa, cfg);
    defer p.deinit();

    try p.openPersistence();

    var replay_writer_storage: proxy_lib.replay.Writer = undefined;
    if (replay_log_path) |path| {
        replay_writer_storage = try proxy_lib.replay.Writer.init(gpa, path);
        p.replay_writer = &replay_writer_storage;
    }
    defer if (p.replay_writer) |rw| rw.deinit();

    try p.run();
}

/// Accepts `HOST:PORT`, or with a URL-style `http://` prefix. `https://`
/// is rejected explicitly because we don't do TLS to upstream yet.
/// Any trailing path (`/`, `/bytes`, `…?foo`) is stripped.
fn parseHostPort(spec: []const u8, host: *[]const u8, port: *u16) !void {
    var s: []const u8 = spec;
    if (std.mem.startsWith(u8, s, "https://")) {
        return die("https:// upstream not supported — use http://HOST:PORT");
    }
    if (std.mem.startsWith(u8, s, "http://")) {
        s = s["http://".len..];
    }
    // Drop any trailing path / query / fragment after the authority.
    if (std.mem.indexOfAnyPos(u8, s, 0, "/?#")) |end| {
        s = s[0..end];
    }
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse
        return die("expected HOST:PORT");
    host.* = s[0..colon];
    port.* = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch
        return die("invalid port");
}

fn writeStderr(bytes: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn die(msg: []const u8) error{BadArgs} {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print("swarm-dev-proxy: {s}\n", .{msg}) catch {};
    w.interface.flush() catch {};
    return error.BadArgs;
}

test "parseHostPort splits 127.0.0.1:1633" {
    var host: []const u8 = "";
    var port: u16 = 0;
    try parseHostPort("127.0.0.1:1633", &host, &port);
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 1633), port);
}

test "parseHostPort accepts http:// prefix and a trailing path" {
    var host: []const u8 = "";
    var port: u16 = 0;
    try parseHostPort("http://65.109.80.9:3000", &host, &port);
    try std.testing.expectEqualStrings("65.109.80.9", host);
    try std.testing.expectEqual(@as(u16, 3000), port);

    try parseHostPort("http://bee.example.org:1633/", &host, &port);
    try std.testing.expectEqualStrings("bee.example.org", host);
    try std.testing.expectEqual(@as(u16, 1633), port);

    try parseHostPort("http://host:8080/some/path?q=1", &host, &port);
    try std.testing.expectEqualStrings("host", host);
    try std.testing.expectEqual(@as(u16, 8080), port);
}
