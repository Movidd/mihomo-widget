// mihomo.zig — minimal client for the mihomo external controller REST API.
// All returned strings are arena-allocated (pass an arena allocator).
// Transport: synchronous WinHTTP (see httpw.zig).
const std = @import("std");
const httpw = @import("httpw.zig");

pub const ProxyKind = enum {
    selector,
    urltest,
    fallback,
    loadbalance,
    plain,

    pub fn isGroup(self: ProxyKind) bool {
        return self != .plain;
    }
};

pub const Group = struct {
    name: []const u8,
    kind: ProxyKind,
    now: ?[]const u8 = null, // filled by groupDetail()
    all: []const []const u8 = &.{}, // filled by groupDetail()
};

pub const Snapshot = struct {
    groups: []Group = &.{},
    nodes: []const []const u8 = &.{}, // plain proxies
    quic_nodes: []const []const u8 = &.{}, // 上面那些里长驻 QUIC/UDP 的（见 isQuicType）
};

/// 出站连接是"长驻 QUIC/UDP"的代理类型。这些客户端建立后复用同一条 UDP 连接，
/// 所以会被"建 TUN 那一瞬"绑错源地址（自环，见 AGENTS.md 关键决策）；TCP 类节点
/// 不受影响（每条连接重拨新 socket）。workerHeal 靠这个分类判断自环特征：
/// QUIC 类节点全灭而 TCP 类正常 = 自环，而不是节点/网络真的挂了。
pub fn isQuicType(t: []const u8) bool {
    return std.mem.eql(u8, t, "Hysteria2") or std.mem.eql(u8, t, "Hysteria") or std.mem.eql(u8, t, "Tuic");
}

pub const Client = struct {
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    secret: []const u8,

    pub fn init(arena: std.mem.Allocator, host: []const u8, port: u16, secret: []const u8) Client {
        return .{ .arena = arena, .host = host, .port = port, .secret = secret };
    }

    fn authHeader(c: *const Client) !?[]const u8 {
        if (c.secret.len == 0) return null;
        const s = try std.fmt.allocPrint(c.arena, "Authorization: Bearer {s}", .{c.secret});
        return s;
    }

    fn raw(c: *const Client, method: []const u8, object: []const u8, payload: ?[]const u8) ![]const u8 {
        return c.rawTimeout(method, object, payload, 2000);
    }

    /// Like raw(), but with a custom total timeout (for long-running tasks such
    /// as `POST /upgrade` which downloads and replaces the core / geo files).
    fn rawTimeout(c: *const Client, method: []const u8, object: []const u8, payload: ?[]const u8, timeout_ms: u32) ![]const u8 {
        const body: []const u8 = payload orelse "";
        const r = try httpw.request(c.arena, c.host, c.port, method, object, try c.authHeader(), body, timeout_ms);
        if (!(r.status >= 200 and r.status < 300)) return error.HttpStatus;
        return r.body;
    }

    /// GET /version -> version string (e.g. "v1.19.30")
    pub fn version(c: *const Client) ![]const u8 {
        const body = try c.raw("GET", "/version", null);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        const v = parsed.object.get("version") orelse return error.NoVersion;
        if (v != .string) return error.BadJson;
        return v.string;
    }

    /// GET /proxies -> names split into groups (selector/url-test/etc) and plain nodes.
    pub fn snapshot(c: *const Client) !Snapshot {
        const body = try c.raw("GET", "/proxies", null);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        const proxies = parsed.object.get("proxies") orelse return error.NoProxies;
        if (proxies != .object) return error.BadJson;

        var groups = std.array_list.Managed(Group).init(c.arena);
        var nodes = std.array_list.Managed([]const u8).init(c.arena);
        var quic = std.array_list.Managed([]const u8).init(c.arena);
        var it = proxies.object.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (v != .object) continue;
            const t = (v.object.get("type") orelse continue);
            if (t != .string) continue;
            const kind = kindFromString(t.string);
            if (kind.isGroup()) {
                try groups.append(.{ .name = try c.arena.dupe(u8, name), .kind = kind });
            } else {
                const nm = try c.arena.dupe(u8, name);
                try nodes.append(nm);
                if (isQuicType(t.string)) try quic.append(nm);
            }
        }
        return .{
            .groups = try groups.toOwnedSlice(),
            .nodes = try nodes.toOwnedSlice(),
            .quic_nodes = try quic.toOwnedSlice(),
        };
    }

    /// GET /proxies/{name} -> fills now + all for a group.
    pub fn groupDetail(c: *const Client, g: *Group) !void {
        const path = try std.fmt.allocPrint(c.arena, "/proxies/{s}", .{g.name});
        const body = try c.raw("GET", path, null);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        if (parsed.object.get("now")) |n| {
            if (n == .string) g.now = try c.arena.dupe(u8, n.string);
        }
        if (parsed.object.get("all")) |all| {
            if (all == .array) {
                var arr = std.array_list.Managed([]const u8).init(c.arena);
                for (all.array.items) |item| {
                    if (item == .string) try arr.append(try c.arena.dupe(u8, item.string));
                }
                g.all = try arr.toOwnedSlice();
            }
        }
    }

    /// PUT /proxies/{group} {"name": node}
    pub fn select(c: *const Client, group: []const u8, node: []const u8) !void {
        const path = try std.fmt.allocPrint(c.arena, "/proxies/{s}", .{group});
        const payload = try std.fmt.allocPrint(c.arena, "{{\"name\":\"{s}\"}}", .{node});
        _ = try c.raw("PUT", path, payload);
    }

    /// GET /providers/proxies -> real provider names (skips the pseudo-providers
    /// mihomo synthesises from proxy-groups, `vehicleType: "Compatible"`).
    /// 注：本项目的 config 用静态 `proxies:`（不用 provider），所以这里通返回空；
    /// 留着是为了 `workerLatency` 对“带 provider 的配置”仍能给出延迟。
    pub fn proxyProviders(c: *const Client, out: *std.array_list.Managed([]const u8)) !void {
        const body = try c.rawTimeout("GET", "/providers/proxies", null, 5_000);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        const providers = parsed.object.get("providers") orelse return error.NoProviders;
        if (providers != .object) return error.BadJson;
        var it = providers.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const vehicle = e.value_ptr.object.get("vehicleType") orelse continue;
            if (vehicle != .string) continue;
            if (std.mem.eql(u8, vehicle.string, "Compatible")) continue;
            try out.append(try c.arena.dupe(u8, e.key_ptr.*));
        }
    }

    /// Last health-check delay of every proxy in one provider, as (name, ms).
    /// Provider members are NOT registered in the controller's proxy table
    /// (measured on v1.19.30: `GET /proxies/{name}/delay` -> 404 for a provider
    /// node, 200 for a group), so this endpoint is the only per-node source.
    /// ms == 0 means the node did not answer the probe; the value is as fresh as
    /// the provider's `health-check.interval`, not an on-demand measurement.
    pub const ProvLat = struct { name: []const u8, ms: u16 };

    pub fn providerLatency(c: *const Client, provider: []const u8, out: *std.array_list.Managed(ProvLat)) !void {
        const path = try std.fmt.allocPrint(c.arena, "/providers/proxies/{s}", .{provider});
        const body = try c.rawTimeout("GET", path, null, 5_000);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        const proxies = parsed.object.get("proxies") orelse return error.BadJson;
        if (proxies != .array) return error.BadJson;
        for (proxies.array.items) |item| {
            if (item != .object) continue;
            const nm = item.object.get("name") orelse continue;
            if (nm != .string) continue;
            var ms: u16 = 0;
            // history 里最后一条就是最近一次测速结果
            if (item.object.get("history")) |h| {
                if (h == .array and h.array.items.len > 0) {
                    const last = h.array.items[h.array.items.len - 1];
                    if (last == .object) {
                        if (last.object.get("delay")) |d| {
                            if (d == .integer and d.integer > 0 and d.integer <= 9999) ms = @intCast(d.integer);
                        }
                    }
                }
            }
            try out.append(.{ .name = try c.arena.dupe(u8, nm.string), .ms = ms });
        }
    }

    /// PUT /configs {"path": p} — 热重载指定路径的配置。
    /// ⚠ 实测：重载会按文件内容**重置运行时状态**（例如面板 PATCH 上去的 `mode`、
    /// `tun.enable` 会被刷回 config.yaml 里的值），开著 TUN 时调用会掉隧道。
    /// 本函数**没有调用者**（自愈走 reloadConfigInPlace，见下）；若以后加"应用配置修改"
    /// 菜单，必须先把实时状态取回来再还原。
    /// （JSON 里的反斜杠要转义成 `\\`，否则 Go 解不了 Windows 路径。）
    pub fn reloadConfig(c: *const Client, path: []const u8) !void {
        // JSON 里反斜杠必须转义，否则 Go 解析不了 Windows 路径
        var esc = std.array_list.Managed(u8).init(c.arena);
        for (path) |ch| {
            if (ch == '\\') try esc.appendSlice("\\\\") else try esc.append(ch);
        }
        const payload = try std.fmt.allocPrint(c.arena, "{{\"path\":\"{s}\"}}", .{esc.items});
        _ = try c.rawTimeout("PUT", "/configs", payload, 5_000);
    }

    /// PUT /configs {} —— 就地按**核心自己那份配置**（`C.Path.Config()`）重载。
    /// 空路径时核心用启动时那份文件，所以不用拼路径、也不受"路径必须在核心 home 内"的限制。
    /// 唯一调用者是 main.zig 的 workerHeal（QUIC 自环自愈：重建 outbound → hysteria2 重拨）。
    /// ⚠ 前置条件：那份文件的 `tun.enable` 必须与实时状态一致，否则重载会按文件把 TUN
    /// 刷掉（调用方负责校验；`ReCreateTun` 判定相等时网卡不动，见 AGENTS.md 关键决策）。
    pub fn reloadConfigInPlace(c: *const Client) !void {
        _ = try c.rawTimeout("PUT", "/configs", "{}", 5_000);
    }

    /// GET /proxies/{name}/delay?url=..&timeout=.. -> ms, or null when not reachable.
    pub fn delayOf(c: *const Client, name: []const u8, url: []const u8, timeout_ms: u32) !?u32 {
        const path = try std.fmt.allocPrint(c.arena, "/proxies/{s}/delay?url={s}&timeout={d}", .{ name, url, timeout_ms });
        const body = c.raw("GET", path, null) catch |err| switch (err) {
            error.HttpStatus => return null, // mihomo answers 504 for unreachable
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, body, .{});
        if (parsed != .object) return error.BadJson;
        const d = parsed.object.get("delay") orelse return error.NoDelay;
        if (d != .integer) return error.BadJson;
        return @intCast(d.integer);
    }

    /// PATCH /configs {"tun":{"enable": x}}
    pub fn setTun(c: *const Client, enable: bool) !void {
        const payload = if (enable) "{\"tun\":{\"enable\":true}}" else "{\"tun\":{\"enable\":false}}";
        _ = try c.raw("PATCH", "/configs", payload);
    }

    /// GET /configs -> raw body (tun.enable / mode / mixed-port live values).
    pub fn configsRaw(c: *const Client) ![]const u8 {
        return c.raw("GET", "/configs", null);
    }

    /// POST /upgrade -> ask the core to download & replace its own binary, then restart.
    /// Long timeout: the download can take a while; the controller briefly goes offline after restart.
    pub fn upgradeCore(c: *const Client) !void {
        _ = try c.rawTimeout("POST", "/upgrade", null, 120_000);
    }

    /// POST /upgrade/geo -> download fresh GeoIP/GeoSite/ASN/MMDB files.
    pub fn updateGeo(c: *const Client) !void {
        _ = try c.rawTimeout("POST", "/upgrade/geo", null, 120_000);
    }

    /// GET /shutdown -> ask the core to exit gracefully (best effort).
    pub fn shutdown(c: *const Client) void {
        _ = c.raw("GET", "/shutdown", null) catch {};
    }
};

fn kindFromString(t: []const u8) ProxyKind {
    if (std.mem.eql(u8, t, "Selector")) return .selector;
    if (std.mem.eql(u8, t, "URLTest")) return .urltest;
    if (std.mem.eql(u8, t, "Fallback")) return .fallback;
    if (std.mem.eql(u8, t, "LoadBalance")) return .loadbalance;
    return .plain;
}

// ---- parsing helper (unit-testable without a live controller) ----

test "snapshot parse shape" {
    const body =
        \\{"proxies":{"GLOBAL":{"type":"Selector","now":"DIRECT"},"Proxy":{"type":"Selector","now":"Auto-Select"},"Auto-Select":{"type":"URLTest","now":"AnyTLS-hk"},"Mieru-sj":{"type":"Mieru"},"AnyTLS-hk":{"type":"AnyTLS"},"hy-hk":{"type":"Hysteria2"},"DIRECT":{"type":"Direct"},"REJECT":{"type":"Reject"}}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    const proxies = parsed.object.get("proxies").?.object;
    var groups = std.array_list.Managed(Group).init(arena.allocator());
    var nodes = std.array_list.Managed([]const u8).init(arena.allocator());
    var quic = std.array_list.Managed([]const u8).init(arena.allocator());
    var it = proxies.iterator();
    while (it.next()) |e| {
        const t = e.value_ptr.*.object.get("type").?.string;
        const kind = kindFromString(t);
        if (kind.isGroup()) {
            try groups.append(.{ .name = e.key_ptr.*, .kind = kind });
        } else {
            try nodes.append(e.key_ptr.*);
            if (isQuicType(t)) try quic.append(e.key_ptr.*);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), groups.items.len);
    try std.testing.expectEqualStrings("Proxy", groups.items[1].name);
    try std.testing.expectEqual(ProxyKind.urltest, groups.items[2].kind);
    var has_mieru = false;
    for (nodes.items) |n| {
        if (std.mem.eql(u8, n, "Mieru-sj")) has_mieru = true;
    }
    try std.testing.expect(has_mieru);
    // 只有 Hysteria2 被归为长驻 QUIC（Mieru / AnyTLS / Direct / Reject 都是 TCP 出站）
    try std.testing.expectEqual(@as(usize, 1), quic.items.len);
    try std.testing.expectEqualStrings("hy-hk", quic.items[0]);
}
