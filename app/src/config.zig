// config.zig — widget configuration + light parsing of mihomo's YAML for the
// few scalar fields the widget needs (external-controller / secret / mixed-port).
const std = @import("std");

pub const ApiInfo = struct {
    host: []const u8 = "127.0.0.1", // allocator-owned? use slice into Arena via arena alloc
    port: u16 = 9090,
    secret: []const u8 = "",
    mixed_port: u16 = 0, // 0 = unknown
};

/// Parse scalar YAML keys of the form `key: value` (with optional comments).
/// Only handles simple unquoted/quoted values; returns error.OutOfMemory etc.
/// Values are copied into `arena`.
pub fn parseMihomoYaml(arena: std.mem.Allocator, text: []const u8) !ApiInfo {
    var info = ApiInfo{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        // strip trailing comment
        if (std.mem.indexOfScalar(u8, val, '#')) |h| val = std.mem.trim(u8, val[0..h], " \t");
        // strip quotes
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "external-controller")) {
            info = try parseController(arena, info, val);
        } else if (std.mem.eql(u8, key, "secret")) {
            info.secret = try arena.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "mixed-port")) {
            info.mixed_port = std.fmt.parseInt(u16, val, 10) catch info.mixed_port;
        }
    }
    return info;
}

fn parseController(arena: std.mem.Allocator, prev: ApiInfo, val: []const u8) !ApiInfo {
    var info = prev;
    // forms: "0.0.0.0:9090", "127.0.0.1:9090", "[::]:9090", ":9090"
    if (std.mem.lastIndexOfScalar(u8, val, ':')) |ci| {
        const port_str = val[ci + 1 ..];
        info.port = std.fmt.parseInt(u16, std.mem.trim(u8, port_str, " \t"), 10) catch 9090;
        const host_part = val[0..ci];
        const host = std.mem.trim(u8, host_part, "[]");
        if (host.len > 0 and !std.mem.eql(u8, host, "*") and !std.mem.eql(u8, host, "0.0.0.0") and !std.mem.eql(u8, host, "::")) {
            info.host = try arena.dupe(u8, host);
        }
    }
    return info;
}

test "parse minimal yaml" {
    const yaml =
        \\mixed-port: 10809
        \\external-controller: 127.0.0.1:9090
        \\secret: ""
        \\mode: rule
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try parseMihomoYaml(arena.allocator(), yaml);
    try std.testing.expectEqual(@as(u16, 10809), info.mixed_port);
    try std.testing.expectEqual(@as(u16, 9090), info.port);
    try std.testing.expectEqualStrings("127.0.0.1", info.host);
    try std.testing.expectEqualStrings("", info.secret);
}

test "parse controller with comment and quotes" {
    const yaml =
        \\external-controller: 0.0.0.0:9090 # API Port
        \\secret: "abc123"
        \\mixed-port: 7890
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try parseMihomoYaml(arena.allocator(), yaml);
    try std.testing.expectEqual(@as(u16, 9090), info.port);
    try std.testing.expectEqualStrings("abc123", info.secret);
    try std.testing.expectEqualStrings("127.0.0.1", info.host); // wildcard bound -> dial localhost
    try std.testing.expectEqual(@as(u16, 7890), info.mixed_port);
}
