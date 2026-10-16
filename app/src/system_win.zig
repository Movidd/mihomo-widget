// system_win.zig — Windows system integration that needs no live controller:
// system proxy toggle (registry) and run-at-login (scheduled task via
// schtasks.exe — the HKCU Run key cannot elevate, so an admin manifest /
// RUNASADMIN compat flag makes login launch silently skip the entry; a
// ONLOGON task with RL HIGHEST survives). Values the caller owns (mixed port,
// absolute exe path) are passed in; this module holds no UI/controller state,
// unlike the TUN/latency/stop-core actions which stay in main.zig because
// they are tied to g_state + the mihomo client.
const std = @import("std");
const win = @import("win32.zig");
const proc = @import("proc.zig");

const IE_REG_SUB = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
const RUN_REG_SUB = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const TASK_NAME = "mihomo-widget-autostart";

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
    if (!runSchtasksWait("query", "/TN \"" ++ TASK_NAME ++ "\"", null, "")) return false;
    return lastSchtasksCode() == 0;
}

pub fn setAutoStart(self_abs: []const u8, on: bool) bool {
    if (!on) {
        // absent task counts as success (idempotent disable)
        if (!autoStartEnabled()) return true;
        _ = runSchtasksWait("delete", "/TN \"" ++ TASK_NAME ++ "\" /F", null, "");
        return lastSchtasksCode() == 0;
    }
    if (self_abs.len == 0) return false;
    // quoted absolute path; non-ASCII collapses to '?' (existing convention)
    var tr: [560]u8 = undefined;
    var n: usize = 0;
    tr[n] = '"';
    n += 1;
    for (self_abs) |ch| {
        if (ch == '"') continue;
        if (n + 2 >= tr.len) return false;
        tr[n] = if (ch > 0x7f) '?' else ch;
        n += 1;
    }
    tr[n] = '"';
    n += 1;
    tr[n] = 0;
    // /F overwrites an existing task so re-enabling after a move works
    return runSchtasksWait("create", "/TN \"" ++ TASK_NAME ++ "\" /TR ", tr[0..n :0], " /SC ONLOGON /RL HIGHEST /F");
}

/// One-shot migration: delete the legacy HKCU Run-key value (it is silently
/// skipped at login when the exe requires admin, so it only ever caused
/// double-launch). Errors ignored — the value may legitimately not exist.
pub fn removeLegacyRunEntry() void {
    var key: usize = 0;
    var sw: [300]u16 = undefined;
    const sn = proc.asciiToWide(RUN_REG_SUB, &sw);
    if (sn == 0) return;
    sw[sn] = 0;
    if (win.RegOpenKeyExW(0x8000_0001, @ptrCast(&sw), 0, 0x2, &key) != 0) return;
    defer _ = win.RegCloseKey(key);
    var nw: [64]u16 = undefined;
    const nn = proc.asciiToWide("mihomo-widget", &nw);
    if (nn == 0) return;
    nw[nn] = 0;
    _ = win.RegDeleteValueW(key, @ptrCast(&nw));
}

pub fn isAdmin() bool {
    return win.IsUserAnAdmin() != 0;
}

// ---- schtasks.exe plumbing ----

var g_sch_code: u32 = 259; // last schtasks exit code (259 = STILL_ACTIVE placeholder)

fn lastSchtasksCode() u32 {
    return g_sch_code;
}

/// Run `schtasks <verb> <args...>` hidden and wait (2s cap, matching the
/// widget's all-chains-2s timeout convention). `tr` is appended after
/// `head_args`; `tail_args` after it. Returns false on spawn failure.
fn runSchtasksWait(verb: []const u8, head_args: []const u8, tr: ?[]const u8, tail_args: []const u8) bool {
    var cmd: [1200]u8 = undefined;
    var n: usize = 0;
    inline for (.{ "schtasks.exe /", verb, head_args }) |seg| {
        for (seg) |ch| {
            if (n >= cmd.len) return false;
            cmd[n] = ch;
            n += 1;
        }
    }
    if (tr) |t| {
        for (t) |ch| {
            if (n >= cmd.len) return false;
            cmd[n] = ch;
            n += 1;
        }
    }
    for (tail_args) |ch| {
        if (n >= cmd.len) return false;
        cmd[n] = ch;
        n += 1;
    }
    if (n + 1 >= cmd.len) return false;
    cmd[n] = 0;
    return proc.spawnWaitHidden("schtasks.exe", cmd[0..n :0], &g_sch_code);
}
