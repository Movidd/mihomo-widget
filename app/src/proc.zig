// proc.zig — process & file plumbing: file read/write, path resolution,
// ASCII→wide conversion, and spawning the bundled mihomo core.
// Stateless on purpose: the handful of runtime values (exe dir, yaml path,
// core-pid / spawned flags) are passed in as parameters, so this module holds
// no hidden globals and behaves identically no matter who calls it.
const std = @import("std");
const win = @import("win32.zig");

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ_WRITE: u32 = 0x0000_0003;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: isize = -1;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Read a file into a fresh heap allocation (ASCII path assumed).
pub fn readFileBytes(heap: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    if (path.len >= 512) return error.PathTooLong;
    var wpath: [520]u16 = undefined;
    for (path, 0..) |ch, i| {
        if (ch > 0x7f) return error.NonAsciiPath;
        wpath[i] = ch;
    }
    wpath[path.len] = 0;
    const h = win.CreateFileW(@ptrCast(&wpath), GENERIC_READ, FILE_SHARE_READ_WRITE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return error.OpenFailed;
    defer _ = win.CloseHandle(h);
    var size: i64 = 0;
    if (win.GetFileSizeEx(h, &size) == 0 or size <= 0) size = 65536;
    const cap: usize = @intCast(@min(size, max_size));
    const buf = try heap.alloc(u8, cap);
    var off: usize = 0;
    while (off < cap) {
        var got: u32 = 0;
        if (win.ReadFile(h, buf[off..].ptr, @intCast(@min(cap - off, 65536)), &got, null) == 0) break;
        if (got == 0) break;
        off += got;
    }
    return buf[0..off];
}

/// Write ASCII data to a file (ASCII path assumed); replaces existing content.
pub fn writeFileBytes(path: []const u8, data: []const u8) bool {
    if (path.len >= 512 or data.len > 1 << 20) return false;
    var wpath: [520]u16 = undefined;
    for (path, 0..) |ch, i| {
        if (ch > 0x7f) return false;
        wpath[i] = ch;
    }
    wpath[path.len] = 0;
    const h = win.CreateFileW(@ptrCast(&wpath), GENERIC_WRITE, FILE_SHARE_READ_WRITE, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return false;
    defer _ = win.CloseHandle(h);
    var off: usize = 0;
    while (off < data.len) {
        var written: u32 = 0;
        if (win.WriteFile(h, data[off..].ptr, @intCast(@min(data.len - off, 65536)), &written, null) == 0) return false;
        if (written == 0) return false;
        off += written;
    }
    return true;
}

/// Force the top-level `tun:` block's `enable` scalar to `want`, returning the
/// length written to `out` (null = "the file has no unambiguous top-level tun
/// switch, so don't touch it").
///
/// Only that one scalar is touched: an existing `enable:` inside the block has
/// its *value token* replaced in place (indentation, trailing comment and CRLF
/// all survive); when the block has no `enable:` yet, one line is inserted right
/// after `tun:` using the block's own indentation. Returns null when there is no
/// top-level `tun:` block, when `tun:` carries a flow value (`tun: {…}`), or when
/// `enable:` holds a flow collection.
///
/// 唯一调用者是自愈的**前置校验**：把实时值写进副本，副本与原文逐字节相同就说明
/// 核心那份配置的 `tun.enable` 已经等于实时状态（`PUT /configs {}` 才不会掉隧道）。
/// `out` must be at least `src.len + 32` bytes (the value never grows by more
/// than one byte).
pub fn patchTunEnable(src: []const u8, want: bool, out: []u8) ?usize {
    const want_text: []const u8 = if (want) "true" else "false";
    if (out.len < src.len + 32) return null;

    var i: usize = 0;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n');
        const line_end = nl orelse src.len;
        const line = src[i..line_end];
        if (isTopLevelTun(line)) {
            // EOL style of this document, reused for any line we insert.
            const eol: []const u8 = if (line.len > 0 and line[line.len - 1] == '\r') "\r\n" else "\n";
            const after_tun = if (nl) |k| k + 1 else src.len; // insertion point: after the `tun:` line

            var child_indent: ?[]const u8 = null;
            var j = after_tun;
            while (j < src.len) {
                const nl2 = std.mem.indexOfScalarPos(u8, src, j, '\n');
                const end2 = nl2 orelse src.len;
                const bare2 = std.mem.trimEnd(u8, src[j..end2], " \r\t");
                const next = if (nl2) |k| k + 1 else src.len;
                defer j = next;
                if (bare2.len == 0) continue; // blank line: may still be inside the block
                const indent = indentWidth(bare2);
                if (bare2[indent] == '#') continue; // comment: never ends a block
                if (indent == 0) break; // next top-level key -> the tun block is over
                if (child_indent == null) child_indent = bare2[0..indent];
                if (indent != child_indent.?.len) continue; // nested block, not a direct child
                const body = bare2[indent..];
                // Any direct-child flow map/seq (`tun:` + indented `{…}`) can't be spliced safely.
                if (body.len > 0 and (body[0] == '{' or body[0] == '[')) return null;
                if (!std.mem.startsWith(u8, body, "enable")) continue;
                var k: usize = 6; // "enable"
                while (k < body.len and (body[k] == ' ' or body[k] == '\t')) k += 1;
                if (k >= body.len or body[k] != ':') continue; // `enabled:`, `enable_foo:`, …

                // Replace just the value token, keeping the rest of the line byte-identical.
                var vstart = j + indent + k + 1;
                while (vstart < end2 and (src[vstart] == ' ' or src[vstart] == '\t')) vstart += 1;
                if (vstart < end2 and (src[vstart] == '{' or src[vstart] == '[')) return null;
                var vend = vstart;
                while (vend < end2 and src[vend] != ' ' and src[vend] != '\t' and src[vend] != '\r' and src[vend] != '#') vend += 1;
                @memcpy(out[0..vstart], src[0..vstart]);
                @memcpy(out[vstart..][0..want_text.len], want_text);
                const tail = src[vend..];
                @memcpy(out[vstart + want_text.len ..][0..tail.len], tail);
                return vstart + want_text.len + tail.len;
            }
            // No `enable:` in the block -> add it as the first child.
            const indent = child_indent orelse "  ";
            const sep: []const u8 = if (nl != null) "" else eol; // `tun:` was the last, unterminated line
            const head = src[0..after_tun];
            const tail = src[after_tun..];
            const need = head.len + sep.len + indent.len + 8 + want_text.len + eol.len + tail.len;
            if (out.len < need) return null;
            var w: usize = 0;
            @memcpy(out[w..][0..head.len], head);
            w += head.len;
            @memcpy(out[w..][0..sep.len], sep);
            w += sep.len;
            @memcpy(out[w..][0..indent.len], indent);
            w += indent.len;
            @memcpy(out[w..][0..8], "enable: ");
            w += 8;
            @memcpy(out[w..][0..want_text.len], want_text);
            w += want_text.len;
            @memcpy(out[w..][0..eol.len], eol);
            w += eol.len;
            @memcpy(out[w..][0..tail.len], tail);
            w += tail.len;
            return w;
        }
        i = if (nl) |k| k + 1 else src.len;
    }
    return null;
}

/// `tun:` at column 0, with nothing after the colon but spaces and maybe a comment.
fn isTopLevelTun(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "tun:")) return false;
    const rest = std.mem.trim(u8, line[4..], " \t\r");
    return rest.len == 0 or rest[0] == '#';
}

/// Number of leading space/tab bytes.
fn indentWidth(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

/// The widget config file next to the exe (shared with loadConfig).
pub fn confPath(exe_dir: []const u8, out: *[520]u8) ?[]const u8 {
    if (exe_dir.len == 0) return null;
    const cfg_p = std.fmt.bufPrint(out, "{s}\\..\\cfg\\mihomo-widget.conf", .{exe_dir}) catch return null;
    if (pathExists(cfg_p)) return cfg_p;
    return std.fmt.bufPrint(out, "{s}\\mihomo-widget.conf", .{exe_dir}) catch null;
}

/// Persist the current window position into mihomo-widget.conf as
/// window_x / window_y. Every other line (comments, user settings) is
/// preserved; the keys are updated in place or appended if absent. If the
/// conf does not exist, skip (don't create one out of nowhere).
pub fn saveWindowPos(hwnd: win.HWND, exe_dir: []const u8) void {
    var rc: win.RECT = undefined;
    if (win.GetWindowRect(hwnd, &rc) == 0) return;
    var path_buf: [520]u8 = undefined;
    const path = confPath(exe_dir, &path_buf) orelse return;
    const text = readFileBytes(std.heap.page_allocator, path, 1 << 16) catch return;
    defer std.heap.page_allocator.free(text);
    var xs: [16]u8 = undefined;
    var ys: [16]u8 = undefined;
    const sx = std.fmt.bufPrint(&xs, "{d}", .{rc.left}) catch return;
    const sy = std.fmt.bufPrint(&ys, "{d}", .{rc.top}) catch return;

    var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer out.deinit();
    var found_x = false;
    var found_y = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) {
            out.appendSlice(raw) catch {};
            out.append('\n') catch {};
            continue;
        }
        // Recognize a commented key (#key = value) so we uncomment + rewrite it
        // in place instead of keeping the comment and appending a duplicate row.
        var body = line;
        if (body[0] == '#') body = std.mem.trim(u8, body[1..], " \t");
        const ci = std.mem.indexOfScalar(u8, body, '=') orelse std.mem.indexOfScalar(u8, body, ':');
        const key = if (ci) |i| std.mem.trim(u8, body[0..i], " \t") else null;
        if (std.mem.eql(u8, key orelse "", "window_x")) {
            out.appendSlice("window_x = ") catch {};
            out.appendSlice(sx) catch {};
            out.append('\n') catch {};
            found_x = true;
            continue;
        }
        if (std.mem.eql(u8, key orelse "", "window_y")) {
            out.appendSlice("window_y = ") catch {};
            out.appendSlice(sy) catch {};
            out.append('\n') catch {};
            found_y = true;
            continue;
        }
        out.appendSlice(raw) catch {};
        out.append('\n') catch {};
    }
    if (!found_x or !found_y) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') out.append('\n') catch {};
        if (!found_x) {
            out.appendSlice("window_x = ") catch {};
            out.appendSlice(sx) catch {};
            out.append('\n') catch {};
        }
        if (!found_y) {
            out.appendSlice("window_y = ") catch {};
            out.appendSlice(sy) catch {};
            out.append('\n') catch {};
        }
    }
    _ = writeFileBytes(path, out.items);
}

/// Persist the last system-proxy toggle state and the metered NIC into
/// mihomo-widget.conf as `sysproxy = 0|1` and `nic_ifindex = <index>`.
/// Preserves every other line; keys are updated in place or appended if absent.
/// Skips if the conf file is missing (same policy as saveWindowPos: never create
/// a conf out of nowhere).
/// 注意：这里**不写** TUN。TUN 的开机状态只有 `config.yaml` 的 `tun.enable` 一个来源，
/// 菜单里的开关只作用于本次运行；conf 里若残留旧的 `tun = …` 行则被 `Config.load` 忽略。
pub fn saveConfState(exe_dir: []const u8, sysproxy: bool, nic_ifindex: u32) void {
    var path_buf: [520]u8 = undefined;
    const path = confPath(exe_dir, &path_buf) orelse return;
    const text = readFileBytes(std.heap.page_allocator, path, 1 << 16) catch return;
    defer std.heap.page_allocator.free(text);
    var bs: [8]u8 = undefined;
    var ns: [8]u8 = undefined;
    const sb = std.fmt.bufPrint(&bs, "{d}", .{@as(u8, if (sysproxy) 1 else 0)}) catch return;
    const nb = std.fmt.bufPrint(&ns, "{d}", .{nic_ifindex}) catch return;

    var found_sys = false;
    var found_nic = false;
    var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer out.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) {
            out.appendSlice(raw) catch {};
            out.append('\n') catch {};
            continue;
        }
        // Recognize a commented key (#key = value) so we uncomment + rewrite it
        // in place instead of keeping the comment and appending a duplicate row.
        var body = line;
        if (body[0] == '#') body = std.mem.trim(u8, body[1..], " \t");
        const ci = std.mem.indexOfScalar(u8, body, '=') orelse std.mem.indexOfScalar(u8, body, ':');
        const key = if (ci) |i| std.mem.trim(u8, body[0..i], " \t") else null;
        if (std.mem.eql(u8, key orelse "", "sysproxy")) {
            out.appendSlice("sysproxy = ") catch {};
            out.appendSlice(sb) catch {};
            out.append('\n') catch {};
            found_sys = true;
            continue;
        }
        if (std.mem.eql(u8, key orelse "", "nic_ifindex")) {
            out.appendSlice("nic_ifindex = ") catch {};
            out.appendSlice(nb) catch {};
            out.append('\n') catch {};
            found_nic = true;
            continue;
        }
        out.appendSlice(raw) catch {};
        out.append('\n') catch {};
    }
    if (!found_sys or !found_nic) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') out.append('\n') catch {};
        if (!found_sys) {
            out.appendSlice("sysproxy = ") catch {};
            out.appendSlice(sb) catch {};
            out.append('\n') catch {};
        }
        if (!found_nic) {
            out.appendSlice("nic_ifindex = ") catch {};
            out.appendSlice(nb) catch {};
            out.append('\n') catch {};
        }
    }
    _ = writeFileBytes(path, out.items);
}

/// Collapse `.` / `..` segments into a clean path (e.g. `C:\a\bin\..\cfg` ->
/// `C:\a\cfg`). mihomo (Go) does NOT normalise ".." in -d/-f: it happily treats
/// `...\bin\..\cfg` as a different directory, and when the config file is not
/// found there it silently writes a default config and starts listening on 7890
/// with no controller — which looks exactly like "core unreachable".
pub fn normalizePath(dst: []u8, src: []const u8) ?[]const u8 {
    var segs: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\\');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n > 0 and !std.mem.eql(u8, segs[n - 1], "..") and !hasDrive(segs[n - 1])) {
                n -= 1;
                continue;
            }
            // 无法再上跳（超盘符根）：保留原样，let the OS complain
        }
        if (n >= segs.len) return null;
        segs[n] = seg;
        n += 1;
    }
    if (n == 0) return null;
    var len: usize = 0;
    for (segs[0..n], 0..) |seg, i| {
        if (i > 0) {
            if (len + 1 > dst.len) return null;
            dst[len] = '\\';
            len += 1;
        }
        if (len + seg.len > dst.len) return null;
        @memcpy(dst[len .. len + seg.len], seg);
        len += seg.len;
    }
    return dst[0..len];
}

fn hasDrive(s: []const u8) bool {
    return s.len >= 2 and s[1] == ':';
}

/// Search candidate directories for the mihomo main config.
/// Preferred name is `config.yaml` (single file: settings first, `proxies:` list last);
/// `mihomo_client.yaml` is kept as a fallback so old release bundles keep working.
/// Directories are tried nearest-first, and the returned path is always normalised
/// (no "..") because mihomo must see a clean absolute path.
pub fn findYaml(exe_dir: []const u8, out: *[512]u8) ?[]const u8 {
    const dirs = [_][]const u8{
        "..\\..\\cfg", // dev: exe in app\zig-out\bin, config in app\cfg
        // release bundle: the core and everything it reads live in <exe_dir>\mihomo.
        // Ordered *before* the flat legacy entry on purpose: a half-migrated install
        // (mihomo\config.yaml plus a stale root copy) must use the one whose directory
        // actually holds direct.yaml / geodata — pointing -d at the root instead makes
        // mihomo silently drop the RULE-SET whitelist (missing provider file).
        "mihomo",
        "", // legacy flat bundle: config beside the exe
        "..",
        "..\\..",
        "mihomo-widget",
    };
    const names = [_][]const u8{ "config.yaml", "mihomo_client.yaml" };
    for (dirs) |dir| {
        for (names) |name| {
            var tmp: [512]u8 = undefined;
            const raw = if (dir.len == 0)
                std.fmt.bufPrint(&tmp, "{s}\\{s}", .{ exe_dir, name }) catch continue
            else
                std.fmt.bufPrint(&tmp, "{s}\\{s}\\{s}", .{ exe_dir, dir, name }) catch continue;
            if (!pathExists(raw)) continue;
            const full = normalizePath(out, raw) orelse return raw;
            return full;
        }
    }
    return null;
}

/// Directory part of a file path ("a\\b\\c.yaml" -> "a\\b"); empty when there is no separator.
pub fn dirOf(path: []const u8) []const u8 {
    const si = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return "";
    return path[0..si];
}

pub fn pathExists(p: []const u8) bool {
    const text = readFileBytes(std.heap.page_allocator, p, 1) catch return false;
    std.heap.page_allocator.free(text);
    return true;
}

/// ASCII → UTF-16, clipped to buf (unsafe chars become '?'-nothing / break).
pub fn asciiToWide(ascii: []const u8, buf: []u16) usize {
    var n: usize = 0;
    for (ascii) |ch| {
        if (ch > 0x7f or n + 1 >= buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    return n;
}

/// Spawn a detached child process (hidden); writes the child pid into core_pid.
pub fn spawnCmd(core_pid: *u32, app_ascii: []const u8, cmd_ascii: []const u8, log_path: []const u8) bool {
    if (cmd_ascii.len >= 2048) return false;
    var wide: [2048]u16 = undefined;
    const n = asciiToWide(cmd_ascii, &wide);
    wide[n] = 0;
    var app_wide: [600]u16 = undefined;
    const an = asciiToWide(app_ascii, &app_wide);
    if (an > 0) app_wide[an] = 0;
    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    // redirect child stderr to a log file for diagnostics
    var log_wide: [520]u16 = undefined;
    var ln: usize = 0;
    for (log_path) |ch| {
        if (ch > 0x7f or ln + 1 >= log_wide.len) break;
        log_wide[ln] = ch;
        ln += 1;
    }
    log_wide[ln] = 0;
    const hlog = win.CreateFileW(@ptrCast(&log_wide), 0x40000000, 0x7, null, 2, 0x80, null);
    var pi: win.PROCESS_INFORMATION = undefined;
    if (hlog != -1) {
        si.dwFlags = 0x100; // STARTF_USESTDHANDLES
        si.hStdOutput = @ptrFromInt(@as(usize, @intCast(hlog)));
        si.hStdError = @ptrFromInt(@as(usize, @intCast(hlog)));
    }
    const app_ptr: ?[*:0]const u16 = if (an > 0) @ptrCast(&app_wide) else null;
    if (win.CreateProcessW(app_ptr, @ptrCast(&wide), null, null, if (hlog != -1) 1 else 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0) {
        std.debug.print("spawn CreateProcess fail err=0x{x} EOL", .{win.GetLastError()});
        if (hlog != -1) _ = win.CloseHandle(hlog);
        return false;
    }
    core_pid.* = pi.dwProcessId;
    if (hlog != -1) _ = win.CloseHandle(hlog);
    _ = win.CloseHandle(@intCast(@intFromPtr(pi.hThread)));
    _ = win.CloseHandle(@intCast(@intFromPtr(pi.hProcess)));
    return true;
}

/// Try to start the bundled mihomo core (hidden) if the controller is not up.
pub fn spawnCoreIfNeeded(exe_dir: []const u8, yaml_abs: []const u8, core_spawned: *bool, core_pid: *u32) void {
    if (core_spawned.*) return;
    if (exe_dir.len == 0) return;
    core_spawned.* = true;
    const root3 = pathUp(exe_dir, 3);
    var core_buf: [600]u8 = undefined;
    var core_path: []const u8 = "";
    if (root3.len > 0) {
        const p = std.fmt.bufPrint(&core_buf, "{s}\\.tools\\mihomo\\mihomo.exe", .{root3}) catch "";
        if (p.len > 0 and pathExists(p)) core_path = p;
    }
    if (core_path.len == 0) {
        const p = std.fmt.bufPrint(&core_buf, "{s}\\mihomo\\mihomo.exe", .{exe_dir}) catch "";
        if (p.len > 0 and pathExists(p)) core_path = p;
    }
    if (core_path.len == 0) {
        const p = std.fmt.bufPrint(&core_buf, "{s}\\mihomo.exe", .{exe_dir}) catch "";
        if (p.len > 0 and pathExists(p)) core_path = p;
    }
    if (core_path.len == 0) {
        std.debug.print("spawn: core not found EOL", .{});
        return;
    }
    std.debug.print("spawn: core={s} EOL", .{core_path});
    // 先定下要喂给核心的配置文件，再把核心 home（-d）设成它的**所在目录**：
    // mihomo 把 rule-provider 与 geodata 的相对路径都按 home 解析，所以 direct.yaml /
    // GeoIP.dat / GeoSite.dat 和配置文件同目录，才能在开发版（app\cfg）与发布包
    // （exe 同级的 mihomo\ 子目录）下用同一份配置文本。（实测：mihomo 不把 -d 归一化，
    // 也不接受跳出 home 的 provider 路径；provider 文件缺失时它只记一条 initial error，
    // 规则集静默失效——所以 -d 指错目录是最隐蔽的故障。）
    // ⇒ 配置与它的 provider / geodata 必须待在一起，别把配置单独挪走。
    var yaml_buf: [600]u8 = undefined;
    var yamlp: []const u8 = if (yaml_abs.len > 0) yaml_abs else "";
    if (yamlp.len == 0 and root3.len > 0) {
        // 兼容旧布局：配置放在仓库根目录时兜底（findYaml 未命中才会走到这里）
        const names = [_][]const u8{ "config.yaml", "mihomo_client.yaml" };
        for (names) |name| {
            const py = std.fmt.bufPrint(&yaml_buf, "{s}\\{s}", .{ root3, name }) catch continue;
            if (pathExists(py)) {
                yamlp = py;
                break;
            }
        }
    }
    if (yamlp.len == 0) return;

    var datdir: [600]u8 = undefined;
    var datdir_len: usize = 0;
    const home_src = if (dirOf(yamlp).len > 0) dirOf(yamlp) else dirOf(core_path);
    datdir_len = @min(home_src.len, datdir.len);
    @memcpy(datdir[0..datdir_len], home_src[0..datdir_len]);

    var cmd_buf: [2000]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "\"{s}\" -d \"{s}\" -f \"{s}\"", .{ core_path, datdir[0..datdir_len], yamlp }) catch return;
    _ = spawnCmd(core_pid, core_path, cmd, "");
}

/// Walk up `levels` segments in a backslash-separated path.
pub fn pathUp(p0: []const u8, levels: usize) []const u8 {
    var p = p0;
    var k: usize = 0;
    while (k < levels) : (k += 1) {
        if (std.mem.lastIndexOfScalar(u8, p, '\\')) |si| {
            if (si == 0) break;
            p = p[0..si];
        } else break;
    }
    return p;
}

const Patched = struct { buf: []u8, out: []u8 };

fn patched(alloc: std.mem.Allocator, src: []const u8, want: bool) !?Patched {
    const buf = try alloc.alloc(u8, src.len + 32);
    const n = patchTunEnable(src, want, buf) orelse {
        alloc.free(buf);
        return null;
    };
    return .{ .buf = buf, .out = buf[0..n] };
}

test "patchTunEnable rewrites the value in place" {
    const src = "tun:\r\n  enable: false # keep me\r\n  stack: mixed\r\nproxies:\r\n  - name: x\r\n";
    const g = (try patched(std.testing.allocator, src, true)).?;
    defer std.testing.allocator.free(g.buf);
    try std.testing.expectEqualStrings("tun:\r\n  enable: true # keep me\r\n  stack: mixed\r\nproxies:\r\n  - name: x\r\n", g.out);
    // already at the wanted value -> byte-identical (caller then reuses the user's file)
    const same = (try patched(std.testing.allocator, src, false)).?;
    defer std.testing.allocator.free(same.buf);
    try std.testing.expectEqualStrings(src, same.out);
}

test "patchTunEnable inserts a missing key and honours the block indent" {
    const src = "dns:\n  enable: true\ntun:\n    stack: mixed\nmode: rule\n";
    const g = (try patched(std.testing.allocator, src, true)).?;
    defer std.testing.allocator.free(g.buf);
    try std.testing.expectEqualStrings("dns:\n  enable: true\ntun:\n    enable: true\n    stack: mixed\nmode: rule\n", g.out);
}

test "patchTunEnable refuses to invent or misread a tun block" {
    // no tun block at all: dns.enable must not be touched
    try std.testing.expectEqual(@as(?Patched, null), try patched(std.testing.allocator, "dns:\n  enable: true\n", true));
    // flow mapping / collection: leave it to the user
    try std.testing.expectEqual(@as(?Patched, null), try patched(std.testing.allocator, "tun: {enable: false}\n", true));
    try std.testing.expectEqual(@as(?Patched, null), try patched(std.testing.allocator, "tun:\n  enable: []\n", true));
    // a nested `enable:` is not the tun switch -> insert the real one
    const nested = "tun:\n  something:\n    enable: false\n";
    const g = (try patched(std.testing.allocator, nested, true)).?;
    defer std.testing.allocator.free(g.buf);
    try std.testing.expectEqualStrings("tun:\n  enable: true\n  something:\n    enable: false\n", g.out);
    // `enable :` with a stray space must still be replaced, not duplicated
    const spaced = "tun:\n  enable : false\n";
    const g2 = (try patched(std.testing.allocator, spaced, true)).?;
    defer std.testing.allocator.free(g2.buf);
    try std.testing.expectEqualStrings("tun:\n  enable : true\n", g2.out);
    // `tun:` + indented flow map: splicing a sibling key would corrupt the block
    try std.testing.expectEqual(@as(?Patched, null), try patched(std.testing.allocator, "tun:\n  {enable: false}\n", true));
}
