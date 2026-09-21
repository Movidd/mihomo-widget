// system_win.zig — Windows system integration that needs no live controller:
// system proxy toggle and run-at-login, both via the registry.
// Values the caller owns (mixed port, absolute exe path) are passed in; this
// module holds no UI/controller state, unlike the TUN/latency/stop-core
// actions which stay in main.zig because they are tied to g_state + the
// mihomo client.
const std = @import("std");
const win = @import("win32.zig");
const proc = @import("proc.zig");

const IE_REG_SUB = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
const RUN_REG_SUB = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

pub fn sysProxyEnabled() bool {
    var key: usize = 0;
    var sw: [300]u16 = undefined;
    const sn = proc.asciiToWide(IE_REG_SUB, &sw);
    if (sn == 0) return false;
    sw[sn] = 0;
    if (win.RegOpenKeyExW(0x8000_0001, @ptrCast(&sw), 0, 0x20019, &key) != 0) return false;
    defer _ = win.RegCloseKey(key);
    var nw: [64]u16 = undefined;
    const nn = proc.asciiToWide("ProxyEnable", &nw);
    if (nn == 0) return false;
    nw[nn] = 0;
    var val: u32 = 0;
    var vsize: u32 = @sizeOf(u32);
    if (win.RegQueryValueExW(key, @ptrCast(&nw), null, null, @ptrCast(&val), &vsize) != 0) return false;
    return val != 0;
}

pub fn setSysProxy(mixed_port: u16, on: bool) void {
    var key: usize = 0;
    var sw: [300]u16 = undefined;
    const sn = proc.asciiToWide(IE_REG_SUB, &sw);
    if (sn == 0) return;
    sw[sn] = 0;
    const sam: u32 = 0x20019 | 0x2; // KEY_READ | KEY_SET_VALUE
    if (win.RegOpenKeyExW(0x8000_0001, @ptrCast(&sw), 0, sam, &key) != 0) return;
    defer _ = win.RegCloseKey(key);
    var nw: [64]u16 = undefined;
    const nn = proc.asciiToWide("ProxyEnable", &nw);
    if (nn == 0) return;
    nw[nn] = 0;
    var v: u32 = if (on) 1 else 0;
    _ = win.RegSetValueExW(key, @ptrCast(&nw), 0, 4, @ptrCast(&v), 4); // REG_DWORD
    if (on) {
        var sb: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&sb, "127.0.0.1:{d}", .{mixed_port}) catch return;
        var pw: [96]u16 = undefined;
        const pn = proc.asciiToWide(s, &pw);
        if (pn == 0) return;
        pw[pn] = 0;
        var n2: [64]u16 = undefined;
        const n2n = proc.asciiToWide("ProxyServer", &n2);
        if (n2n == 0) return;
        n2[n2n] = 0;
        _ = win.RegSetValueExW(key, @ptrCast(&n2), 0, 1, @ptrCast(&pw), @intCast((pn + 1) * 2)); // REG_SZ
    }
    _ = win.InternetSetOptionW(null, 39, null, 0); // SETTINGS_CHANGED
    _ = win.InternetSetOptionW(null, 37, null, 0); // REFRESH
}

pub fn autoStartEnabled() bool {
    var key: usize = 0;
    var sw: [300]u16 = undefined;
    const sn = proc.asciiToWide(RUN_REG_SUB, &sw);
    if (sn == 0) return false;
    sw[sn] = 0;
    if (win.RegOpenKeyExW(0x8000_0001, @ptrCast(&sw), 0, 0x20019, &key) != 0) return false;
    defer _ = win.RegCloseKey(key);
    var nw: [64]u16 = undefined;
    const nn = proc.asciiToWide("mihomo-widget", &nw);
    if (nn == 0) return false;
    nw[nn] = 0;
    var size: u32 = 0;
    return win.RegQueryValueExW(key, @ptrCast(&nw), null, null, null, &size) == 0;
}

pub fn setAutoStart(self_abs: []const u8, on: bool) bool {
    var key: usize = 0;
    var sw: [300]u16 = undefined;
    const sn = proc.asciiToWide(RUN_REG_SUB, &sw);
    if (sn == 0) return false;
    sw[sn] = 0;
    if (win.RegOpenKeyExW(0x8000_0001, @ptrCast(&sw), 0, 0x2, &key) != 0) return false;
    defer _ = win.RegCloseKey(key);
    var nw: [64]u16 = undefined;
    const nn = proc.asciiToWide("mihomo-widget", &nw);
    if (nn == 0) return false;
    nw[nn] = 0;
    if (!on) return win.RegDeleteValueW(key, @ptrCast(&nw)) == 0;
    if (self_abs.len == 0) return false;
    var wv: [520]u16 = undefined;
    var n: usize = 0;
    if (n + 1 >= wv.len) return false;
    wv[n] = 0x22; // opening quote
    n += 1;
    for (self_abs) |ch| {
        if (n + 1 >= wv.len) return false;
        wv[n] = if (ch > 0x7f) '?' else ch;
        n += 1;
    }
    if (n + 1 >= wv.len) return false;
    wv[n] = 0x22; // closing quote
    n += 1;
    wv[n] = 0;
    return win.RegSetValueExW(key, @ptrCast(&nw), 0, 1, @ptrCast(&wv), @intCast((n + 1) * 2)) == 0; // REG_SZ
}
