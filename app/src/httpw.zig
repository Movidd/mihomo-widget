// httpw.zig — minimal synchronous WinHTTP client wrapper (for the mihomo
// external controller on localhost). Uses zigwin32 bindings.
const std = @import("std");
const win32 = @import("win32");
const wh = win32.winhttp;
const kernel32 = win32.kernel32;

pub const Result = struct {
    status: u16,
    body: []const u8, // arena-allocated
};

const WINHTTP_ADDREQ_FLAG_ADD: u32 = 0x2000_0000;
const WINHTTP_QUERY_STATUS_CODE: u32 = 19;

/// ASCII-only utf8 -> null-terminated utf16, arena-allocated.
pub fn toWideZ(arena: std.mem.Allocator, s: []const u8) ![:0]u16 {
    for (s) |ch| if (ch > 0x7f) return error.NonAscii;
    const buf = try arena.alloc(u16, s.len + 1);
    for (s, 0..) |ch, i| buf[i] = ch;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// One synchronous HTTP request. `method` = "GET"/"PUT"/"PATCH"/"POST",
/// `object` = path+query (e.g. "/proxies/Proxy"), `extra_header` optional
/// e.g. "Authorization: Bearer x", `body` may be empty.
/// `timeout_ms` applies to resolve/connect/send/receive; use the short default
/// (2000) for polls so a not-yet-ready controller returns fast, and a long value
/// for long-running tasks (e.g. `/upgrade` downloads).
/// Access type NO_PROXY: always talk directly (controller is localhost).
pub fn request(
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: []const u8,
    object: []const u8,
    extra_header: ?[]const u8,
    body: []const u8,
    timeout_ms: u32,
) !Result {
    const session = wh.WinHttpOpen(null, .NO_PROXY, null, null, 0) orelse {
        std.debug.print("WinHttpOpen err=0x{x}\n", .{kernel32.GetLastError()});
        return error.WinHttpOpenFailed;
    };
    _ = wh.WinHttpSetTimeouts(session, @intCast(timeout_ms), @intCast(timeout_ms), @intCast(timeout_ms), @intCast(timeout_ms));
    defer _ = wh.WinHttpCloseHandle(session);

    const host_w = try toWideZ(arena, host);
    const conn = wh.WinHttpConnect(session, host_w.ptr, port, 0) orelse {
        std.debug.print("WinHttpConnect err=0x{x}\n", .{kernel32.GetLastError()});
        return error.WinHttpConnectFailed;
    };
    defer _ = wh.WinHttpCloseHandle(conn);

    const method_w = try toWideZ(arena, method);
    const object_w = try toWideZ(arena, object);
    const req = wh.WinHttpOpenRequest(conn, method_w.ptr, object_w.ptr, null, null, null, .{}) orelse {
        std.debug.print("WinHttpOpenRequest err=0x{x}\n", .{kernel32.GetLastError()});
        return error.WinHttpOpenRequestFailed;
    };
    defer _ = wh.WinHttpCloseHandle(req);

    if (extra_header) |h| {
        const h_w = try toWideZ(arena, h);
        if (wh.WinHttpAddRequestHeaders(req, h_w.ptr, @intCast(h_w.len), WINHTTP_ADDREQ_FLAG_ADD) == 0) {
            std.debug.print("WinHttpAddRequestHeaders err=0x{x}\n", .{kernel32.GetLastError()});
            return error.WinHttpAddHeaderFailed;
        }
    }

    const opt_body: ?*anyopaque = if (body.len > 0) @constCast(@ptrCast(body.ptr)) else null;
    if (wh.WinHttpSendRequest(req, null, 0, opt_body, @intCast(body.len), @intCast(body.len), 0) == 0) {
        std.debug.print("WinHttpSendRequest err=0x{x}\n", .{kernel32.GetLastError()});
        return error.WinHttpSendFailed;
    }
    if (wh.WinHttpReceiveResponse(req, null) == 0) return error.WinHttpReceiveFailed;

    // status code (wide string like "200")
    var status_buf: [16]u16 = undefined;
    var status_len: u32 = 16 * @sizeOf(u16); // capacity in bytes
    if (wh.WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE, null, &status_buf, &status_len, null) == 0) return error.WinHttpQueryStatusFailed;
    var status: u16 = 0;
    const chars = @min(status_len / 2, status_buf.len);
    for (status_buf[0..chars]) |d| {
        if (d == 0 or d < '0' or d > '9') break;
        status = status * 10 + @as(u16, @intCast(d - '0'));
    }

    var out = std.array_list.Managed(u8).init(arena);
    var chunk: [8192]u8 = undefined;
    while (true) {
        var avail: u32 = 0;
        if (wh.WinHttpQueryDataAvailable(req, &avail) == 0) break;
        if (avail == 0) break;
        const to_read: usize = @min(avail, chunk.len);
        var read: u32 = 0;
        if (wh.WinHttpReadData(req, &chunk, @intCast(to_read), &read) == 0) break;
        if (read == 0) break;
        try out.appendSlice(chunk[0..read]);
    }
    return .{ .status = status, .body = out.items };
}
