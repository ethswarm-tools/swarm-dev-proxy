//! `/_proxy` HTML dashboard.
//!
//! Zero-JS, server-rendered. Everything you can see in the terminal
//! log — stamp tallies, feed indexes, SOC writes, cache stats — also
//! shows up here in a browser. Auto-refreshes every 2 seconds via
//! `<meta http-equiv="refresh">`.
//!
//! Rendered HTML is escaping-naive because every value we display is
//! either hex-encoded content or a trusted enum tag. If that ever
//! changes (e.g. surfacing arbitrary request paths), run values
//! through `escapeHtml` first.

const std = @import("std");
const stamps = @import("stamps.zig");
const feeds = @import("feeds.zig");
const cache = @import("cache.zig");
const post_dedup = @import("post_dedup.zig");

pub const DashboardInputs = struct {
    batches: []const stamps.Tracker.ListEntry,
    feed_list: []const feeds.FeedStats,
    soc_list: []const feeds.SocStats,
    cache_stats: cache.Cache.Stats,
    post_dedup_stats: post_dedup.Stats,
    upstream_host: []const u8,
    upstream_port: u16,
    mock_enabled: bool,
    enc_count: u64 = 0,
    act_count: u64 = 0,
};

pub fn renderDashboard(out: *std.Io.Writer, d: DashboardInputs) !void {
    try out.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta http-equiv="refresh" content="2">
        \\<title>swarm-dev-proxy</title>
        \\<style>
        \\body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 1100px; margin: 2rem auto; padding: 0 1rem; color: #222; }
        \\h1 { font-size: 1.3rem; margin-bottom: 0.25rem; }
        \\h2 { font-size: 1.05rem; margin-top: 2rem; border-bottom: 1px solid #ddd; padding-bottom: 0.25rem; }
        \\.sub { color: #666; font-size: 0.9rem; margin-bottom: 1rem; }
        \\table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
        \\th, td { text-align: left; padding: 0.35rem 0.5rem; border-bottom: 1px solid #eee; }
        \\th { background: #f7f7f7; font-weight: 600; }
        \\td.num { text-align: right; font-variant-numeric: tabular-nums; }
        \\code, td.mono { font-family: "SF Mono", Menlo, Consolas, monospace; }
        \\.warn { color: #b95c00; font-weight: 600; }
        \\.empty { color: #999; font-style: italic; }
        \\.pill { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 0.7rem; font-size: 0.75rem; background: #eee; }
        \\.pill-mock { background: #fde68a; }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>swarm-dev-proxy</h1>
        \\<div class="sub">
    );
    try out.print("backend: <code>{s}:{d}</code>", .{ d.upstream_host, d.upstream_port });
    if (d.mock_enabled) try out.writeAll(" <span class=\"pill pill-mock\">mock</span>");
    try out.writeAll(" · auto-refreshes every 2s</div>\n");

    // Cache stats.
    try out.writeAll("<h2>Cache</h2>\n<table>\n");
    try out.writeAll("<tr><th>entries</th><th>bytes</th><th>hits</th><th>misses</th></tr>\n");
    try out.print("<tr><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td></tr>\n", .{
        d.cache_stats.entries, d.cache_stats.bytes, d.cache_stats.hits, d.cache_stats.misses,
    });
    try out.writeAll("</table>\n");

    // POST dedup stats.
    try out.writeAll("<h2>POST dedup</h2>\n<table>\n");
    try out.writeAll("<tr><th>entries</th><th>hits</th><th>misses</th><th>bytes saved</th></tr>\n");
    try out.print("<tr><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td></tr>\n", .{
        d.post_dedup_stats.entries, d.post_dedup_stats.hits, d.post_dedup_stats.misses, d.post_dedup_stats.bytes_saved,
    });
    try out.writeAll("</table>\n");

    // Encryption / ACT observation counts.
    try out.writeAll("<h2>Encryption &amp; ACT</h2>\n<table>\n");
    try out.writeAll("<tr><th>encrypted requests</th><th>ACT requests</th></tr>\n");
    try out.print("<tr><td class=\"num\">{d}</td><td class=\"num\">{d}</td></tr>\n", .{
        d.enc_count, d.act_count,
    });
    try out.writeAll("</table>\n");

    // Stamps.
    try out.writeAll("<h2>Postage batches</h2>\n");
    if (d.batches.len == 0) {
        try out.writeAll("<p class=\"empty\">no batches observed yet</p>\n");
    } else {
        try out.writeAll("<table>\n");
        try out.writeAll("<tr><th>batch</th><th>uploads</th><th>total up</th><th>util</th><th>ttl</th><th></th></tr>\n");
        for (d.batches) |e| {
            const s = e.stats;
            const short = e.batch_id[0..@min(e.batch_id.len, 16)];
            try out.print("<tr><td class=\"mono\">{s}</td>", .{short});
            try out.print("<td class=\"num\">{d}</td>", .{s.uploads});
            try out.print("<td class=\"num\">{d} B</td>", .{s.bytes_up});
            if (s.utilizationPct()) |pct| {
                const cls = if (pct >= 95.0) " class=\"warn\"" else if (pct >= 80.0) " class=\"warn\"" else "";
                try out.print("<td{s} class=\"num\">{d:.1}%</td>", .{ cls, pct });
            } else if (s.capacity_fetch_failed) {
                try out.writeAll("<td class=\"empty\">fetch failed</td>");
            } else {
                try out.writeAll("<td class=\"empty\">unknown</td>");
            }
            if (s.batch_ttl_seconds) |ttl| {
                try out.print("<td>{s}</td>", .{formatTtl(ttl)});
            } else {
                try out.writeAll("<td class=\"empty\">-</td>");
            }
            try out.writeAll("<td>");
            if (s.warned_95) try out.writeAll("<span class=\"warn\">95%</span>");
            if (s.warned_80 and !s.warned_95) try out.writeAll("<span class=\"warn\">80%</span>");
            try out.writeAll("</td></tr>\n");
        }
        try out.writeAll("</table>\n");
    }

    // Feeds.
    try out.writeAll("<h2>Feeds</h2>\n");
    if (d.feed_list.len == 0) {
        try out.writeAll("<p class=\"empty\">no feeds observed yet</p>\n");
    } else {
        try out.writeAll("<table>\n");
        try out.writeAll("<tr><th>owner</th><th>topic</th><th>reads</th><th>writes</th><th>idx</th><th>next</th></tr>\n");
        for (d.feed_list) |f| {
            try out.print(
                "<tr><td class=\"mono\">{s}</td><td class=\"mono\">{s}</td>",
                .{ short8(f.owner), short8(f.topic) },
            );
            try out.print("<td class=\"num\">{d}</td><td class=\"num\">{d}</td>", .{ f.reads, f.writes });
            try out.print("<td class=\"mono\">{s}</td>", .{f.last_index_hex orelse "-"});
            try out.print("<td class=\"mono\">{s}</td></tr>\n", .{f.next_index_hex orelse "-"});
        }
        try out.writeAll("</table>\n");
    }

    // SOCs.
    try out.writeAll("<h2>Single-owner chunks</h2>\n");
    if (d.soc_list.len == 0) {
        try out.writeAll("<p class=\"empty\">no SOCs observed yet</p>\n");
    } else {
        try out.writeAll("<table>\n");
        try out.writeAll("<tr><th>owner</th><th>id</th><th>writes</th><th>total up</th></tr>\n");
        for (d.soc_list) |s| {
            try out.print("<tr><td class=\"mono\">{s}</td><td class=\"mono\">{s}</td>", .{
                short8(s.owner), short8(s.id),
            });
            try out.print("<td class=\"num\">{d}</td><td class=\"num\">{d} B</td></tr>\n", .{ s.writes, s.bytes_up });
        }
        try out.writeAll("</table>\n");
    }

    try out.writeAll("</body></html>\n");
}

fn short8(s: []const u8) []const u8 {
    return s[0..@min(s.len, 8)];
}

fn formatTtl(seconds: i64) []const u8 {
    const S = struct {
        threadlocal var buf: [32]u8 = undefined;
    };
    if (seconds <= 0) return "expired";
    const s: u64 = @intCast(seconds);
    const d = s / 86_400;
    const h = (s % 86_400) / 3_600;
    const m = (s % 3_600) / 60;
    return std.fmt.bufPrint(&S.buf, "{d}d{d}h{d}m", .{ d, h, m }) catch "?";
}

test "renderDashboard emits valid-looking HTML with known state" {
    const gpa = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();

    const batch_entries: []const stamps.Tracker.ListEntry = &.{.{
        .batch_id = "abcdef0123456789",
        .stats = .{
            .uploads = 3,
            .bytes_up = 123,
            .depth = 20,
            .bucket_depth = 16,
            .bee_utilization = 13,
            .batch_ttl_seconds = 86_400,
            .warned_80 = true,
        },
    }};
    const feed_list: []const feeds.FeedStats = &.{.{
        .owner = "ownerhex",
        .topic = "topichex",
        .reads = 2,
        .last_index_hex = "2a",
        .next_index_hex = "2b",
    }};
    const soc_list: []const feeds.SocStats = &.{.{
        .owner = "sowner01",
        .id = "socid123",
        .writes = 1,
        .bytes_up = 256,
    }};

    try renderDashboard(&aw.writer, .{
        .batches = batch_entries,
        .feed_list = feed_list,
        .soc_list = soc_list,
        .cache_stats = .{ .entries = 2, .bytes = 1024, .hits = 5, .misses = 3 },
        .post_dedup_stats = .{ .entries = 1, .hits = 7, .misses = 2, .bytes_saved = 4096 },
        .upstream_host = "127.0.0.1",
        .upstream_port = 1633,
        .mock_enabled = true,
    });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>swarm-dev-proxy</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "pill-mock") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "abcdef0123456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "81.3%") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1d0h0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "ownerhex") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "sowner01") != null);
}

test "renderDashboard handles empty state gracefully" {
    const gpa = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();

    try renderDashboard(&aw.writer, .{
        .batches = &.{},
        .feed_list = &.{},
        .soc_list = &.{},
        .cache_stats = .{ .entries = 0, .bytes = 0, .hits = 0, .misses = 0 },
        .post_dedup_stats = .{ .entries = 0, .hits = 0, .misses = 0, .bytes_saved = 0 },
        .upstream_host = "127.0.0.1",
        .upstream_port = 1633,
        .mock_enabled = false,
    });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "no batches observed yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "no feeds observed yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "no SOCs observed yet") != null);
}
