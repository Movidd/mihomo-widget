// mihomo-widget — main entry: floating control panel for a mihomo core.
// Window: borderless layered topmost GDI panel (conf width/height, default
// 210x26 collapsed / 220x76 hover), double-buffered — BitBlt BEFORE restoring
// the DC bitmap. Polls the external controller every second; left-drag moves
// the panel, right-click opens the menu (the only way out).
const std = @import("std");
const config_mod = @import("config.zig");
const mihomo_mod = @import("mihomo.zig");
const traffic_mod = @import("traffic.zig");
const win = @import("win32.zig");
const ui_draw = @import("ui_draw.zig");
const proc = @import("proc.zig");
const system_win = @import("system_win.zig");


// ---------------- constants ----------------
const WS_POPUP: u32 = 0x8000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_EX_LAYERED: u32 = 0x0008_0000;
const WS_EX_TOPMOST: u32 = 0x0000_0008;
const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
const LWA_ALPHA: u32 = 0x0000_0002;
const SW_SHOW: i32 = 5;
const WM_PAINT: u32 = 0x000F;
const WM_TIMER: u32 = 0x0113;
const WM_DESTROY: u32 = 0x0002;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_DISPLAYCHANGE: u32 = 0x007E; // 分辨率/显示器变更：Z-order 会被重建
const GWL_EXSTYLE: i32 = -20;
const HWND_TOPMOST: win.HWND = -1;
const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
const HTCAPTION: win.WPARAM = 2;
const SRCCOPY: u32 = 0x00CC_0020;
const TRANSPARENT: i32 = 1;
const DEFAULT_CHARSET: u32 = 1;
const OPAQUE: i32 = 2;
const CLEARTYPE_QUALITY: u32 = 5;
const FW_NORMAL: i32 = 400;
const MF_STRING: u32 = 0;
const MF_CHECKED: u32 = 0x00000008;
const MF_POPUP: u32 = 0x00000010;
const MF_SEPARATOR: u32 = 0x00000800;
const MF_GRAYED: u32 = 0x00000001;
const MF_DISABLED: u32 = 0x00000002;
const MF_DISABLED_GRAYED: u32 = MF_DISABLED | MF_GRAYED;
const TPM_LEFTALIGN: u32 = 0x0000;
const TPM_RETURNCMD: u32 = 0x0100;
const TPM_RIGHTBUTTON: u32 = 0x0002;


// ---------------- timers / menu ids ----------------
const POLL_TIMER: usize = 1;
const HOVER_MS: u32 = 250;
const HOVER_TIMER: usize = 2;
const MENU_BASE_ID: usize = 1;
const MAX_NODES: usize = 40;

const Cell = struct {
    buf: [128]u8 = undefined,
    len: u8 = 0,

    fn set(c: *Cell, s: []const u8) void {
        const n = @min(s.len, c.buf.len);
        @memcpy(c.buf[0..n], s[0..n]);
        c.len = @intCast(n);
    }
    fn slice(c: *const Cell) []const u8 {
        return c.buf[0..c.len];
    }
};

var g_state = struct {
    g0_name: Cell = .{},
    g0_now: Cell = .{},
    g0_is_selector: bool = false,
    g1_name: Cell = .{},
    g1_now: Cell = .{},
    status: Cell = .{}, // api/version/error line
    nodes: [MAX_NODES]Cell = undefined,
    nodes_n: u8 = 0,
    online: bool = false,
    api_host: [128]u8 = undefined,
    api_host_len: u8 = 0,
    api_port: u16 = 9090,
    secret: [64]u8 = undefined,
    secret_len: u8 = 0,
    mixed_port: u16 = 10809,
    lat_ms: [MAX_NODES]u16 = .{0} ** MAX_NODES,
    nodes_quic: [MAX_NODES]bool = .{false} ** MAX_NODES, // 该节点是否长驻 QUIC 出站（自愈判据用）
    up_cell: Cell = .{},
    down_cell: Cell = .{},
    msg: Cell = .{},
    msg_left: u8 = 0,
}{};

var g_meter = traffic_mod.Meter{};

var g_ui = struct {
    hwnd: win.HWND = 0,
    font: win.HFONT = null,
    bg: win.HBRUSH = null,
    hovered: bool = false,
    w: i32 = 0,
    h: i32 = 0,
    font_bold: win.HFONT = null,
    font_mid: win.HFONT = null,
}{};
var g_exe_dir: [512]u8 = undefined;
var g_exe_dir_len: usize = 0;
var g_self_abs: [512]u8 = undefined;
var g_self_abs_len: usize = 0;
var g_yaml_abs: [512]u8 = undefined;
var g_yaml_len: usize = 0;
var g_core_spawned = false;

var g_core_pid: u32 = 0;

fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

// ---------------- runtime-configurable UI (mihomo-widget.conf) ----------------
/// All UI settings parsed from mihomo-widget.conf plus the derived layout
/// scale. Kept as one struct so the config surface is obvious; the widget is
/// a single instance, so a single g_cfg global is enough.
const Config = struct {
    dpi_scale: f32 = 1.0, // dpi/96
    ls: f32 = 1.0, // layout scale = dpi/96 * font_size/15
    face_w: [128]u16 = undefined, // font face (wide)
    face_len: usize = 0,
    fs: u8 = 15, // logical font size at 96dpi
    alpha: u8 = 200, // window opacity
    fold_w: i32 = 220,
    hov_w: i32 = 220,
    norm_h: i32 = 26,
    hov_h: i32 = 76,
    speed_top: i32 = 3, // top offset (logical px) for the speed row, both states
    speed_refresh_ms: u32 = 1000, // 网速采样/刷新间隔（ms）；也决定流量归一化基准
    speed_unit_auto: bool = true, // true=按量级自动选 KB/MB/GB；false=固定 MB/s
    nic_ifindex: u32 = 0, // 0=自动（全部物理网卡求和）；否则只统计该接口
    topmost_guard_ms: u32 = 5000, // 置顶巡检间隔（ms）；0=关闭
    c_bg: u32 = rgb(0x14, 0x16, 0x1c),
    c_speed: u32 = rgb(0xcb, 0xf7, 0xcc),
    c_fg: u32 = rgb(0xdd, 0xdd, 0xdd),
    c_dim: u32 = rgb(0x88, 0x88, 0x88),
    c_warn: u32 = rgb(0xff, 0xb4, 0x54),
    win_x: i32 = 0, // last window position (physical px), stored in conf
    win_y: i32 = 0,
    win_pos_ct: u8 = 0, // count of window_x/window_y keys parsed (2 = valid)
    sysproxy: bool = false, // 上次系统代理开关状态（conf 持久化）
    // 注：TUN **没有** conf 键（2026-09-18 起）。开机状态只有一个来源——`config.yaml` 的
    // `tun.enable`（核心启动时自己读），菜单里的开关只作用于本次运行、不落盘。见 AGENTS.md。

    fn setFaceDefault(self: *Config) void {
        const face = "Microsoft YaHei UI";
        self.face_len = @min(face.len, self.face_w.len - 1);
        for (face[0..self.face_len]) |c| self.face_w[c] = 0;
        for (face[0..self.face_len], 0..) |c, i| self.face_w[i] = c;
        self.face_w[self.face_len] = 0;
    }

    fn setFace(self: *Config, s: []const u8) void {
        if (s.len == 0 or s.len > 100) return;
        for (s, 0..) |c, i| {
            if (c > 0x7f) return;
            self.face_w[i] = c;
        }
        self.face_len = s.len;
        self.face_w[self.face_len] = 0;
    }

    pub fn load(self: *Config, exe_dir: []const u8) void {
        self.setFaceDefault();
        if (exe_dir.len == 0) return;
        var path_buf: [520]u8 = undefined;
        const path = proc.confPath(exe_dir, &path_buf) orelse return;
        const text = proc.readFileBytes(std.heap.page_allocator, path, 1 << 16) catch return;
        defer std.heap.page_allocator.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            const ci = std.mem.indexOfScalar(u8, line, '=') orelse std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..ci], " \t");
            const val = std.mem.trim(u8, line[ci + 1 ..], " \t\"");
            if (std.mem.eql(u8, key, "font_face")) self.setFace(val) else
            if (std.mem.eql(u8, key, "font_size")) self.fs = @intCast(std.math.clamp(std.fmt.parseInt(u32, val, 10) catch 15, 9, 30)) else
            if (std.mem.eql(u8, key, "alpha")) self.alpha = @intCast(std.math.clamp(std.fmt.parseInt(u32, val, 10) catch 200, 40, 255)) else
            if (std.mem.eql(u8, key, "width")) setInt(&self.fold_w, val) else
            if (std.mem.eql(u8, key, "width_hover")) setInt(&self.hov_w, val) else
            if (std.mem.eql(u8, key, "height")) setInt(&self.norm_h, val) else
            if (std.mem.eql(u8, key, "height_hover")) setInt(&self.hov_h, val) else
            if (std.mem.eql(u8, key, "speed_top")) self.speed_top = @max(0, std.fmt.parseInt(i32, val, 10) catch self.speed_top) else
            if (std.mem.eql(u8, key, "window_x")) {
                self.win_x = std.fmt.parseInt(i32, val, 10) catch 0;
                self.win_pos_ct += 1;
            } else if (std.mem.eql(u8, key, "window_y")) {
                self.win_y = std.fmt.parseInt(i32, val, 10) catch 0;
                self.win_pos_ct += 1;
            } else if (std.mem.eql(u8, key, "color_bg")) {
                if (hexColor(val)) |c| self.c_bg = c;
            } else if (std.mem.eql(u8, key, "color_speed")) {
                if (hexColor(val)) |c| self.c_speed = c;
            } else if (std.mem.eql(u8, key, "color_text")) {
                if (hexColor(val)) |c| self.c_fg = c;
            } else if (std.mem.eql(u8, key, "color_dim")) {
                if (hexColor(val)) |c| self.c_dim = c;
            } else if (std.mem.eql(u8, key, "color_warn")) {
                if (hexColor(val)) |c| self.c_warn = c;
            } else if (std.mem.eql(u8, key, "speed_refresh_ms")) {
                self.speed_refresh_ms = std.math.clamp(std.fmt.parseInt(u32, val, 10) catch self.speed_refresh_ms, 100, 3000);
            } else if (std.mem.eql(u8, key, "speed_unit_auto")) {
                self.speed_unit_auto = (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on"));
            } else if (std.mem.eql(u8, key, "nic_ifindex")) {
                self.nic_ifindex = std.fmt.parseInt(u32, val, 10) catch self.nic_ifindex;
            } else if (std.mem.eql(u8, key, "topmost_guard_ms")) {
                // 显式写 0 表示关闭巡检；其余值限定在 1s..60s 之间。
                const v = std.fmt.parseInt(u32, val, 10) catch self.topmost_guard_ms;
                self.topmost_guard_ms = if (v == 0) 0 else std.math.clamp(v, 1000, 60000);
            } else if (std.mem.eql(u8, key, "sysproxy")) {
                self.sysproxy = (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on"));
            }
        }
        self.fold_w = @max(120, self.fold_w);
        self.hov_w = @max(self.fold_w, self.hov_w);
        self.norm_h = @max(20, self.norm_h);
        self.hov_h = @max(self.norm_h + 20, self.hov_h);
        self.ls = self.dpi_scale * (@as(f32, @floatFromInt(self.fs)) / 15.0);
    }
};
var g_cfg: Config = .{};

fn scal(v: i32) i32 {
    return ui_draw.scaled(v, g_cfg.ls);
}

fn hexColor(s: []const u8) ?u32 {
    if (s.len != 7 or s[0] != '#') return null;
    var v: u32 = 0;
    for (s[1..7]) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    // RRGGBB -> COLORREF (0xbbggrr)
    return rgb(@intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff));
}

fn setInt(out: *i32, s: []const u8) void {
    out.* = std.fmt.parseInt(i32, s, 10) catch return;
}



fn wcs(comptime s: []const u8) [s.len:0]u16 {
    var buf: [s.len:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = @intCast(c);
    buf[s.len] = 0;
    return buf;
}
const CLASS_W = wcs("MihomoWidgetCls");
const TITLE_W = wcs("mihomo-widget");
const FONT_E = wcs("Segoe UI Symbol");
const ERR_NO_CORE = "core offline  |  right-click menu";

// ---------------- controller access ----------------
/// 把字节速率格式化为完整文本（含单位），供 drawSpeedAt 直接绘制。
/// auto=false → 固定 "MB/s"（1024²）；auto=true → 按量级自动选 KB/MB/GB。
/// 自动模式的换挡点按**显示值四舍五入后是否满 1000** 判定，而不是按 1024：
/// 否则 KB/s 会一直用到 1023.9，面板上冒出 `1000.5 KB/s` 这种 5 位数字（网速行
/// 本来就窄）。现在 KB/s 与 MB/s 最多 4 位整数（999.9），两者显示宽度一致。
fn fmtRate(buf: []u8, bytes_per_s: u64, auto: bool) []const u8 {
    const k: f64 = 1024.0; // 单位换算仍按 1024（KiB/MiB），只是换挡更早
    const m: f64 = k * k;
    const g: f64 = k * k * k;
    const v: f64 = @floatFromInt(bytes_per_s);
    if (!auto) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{v / m}) catch "?";
    const kb = v / k;
    if (kb < 999.95) return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{kb}) catch "?";
    const mb = v / m;
    if (mb < 999.95) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{mb}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2} GB/s", .{v / g}) catch "?";
}

fn clientFor(arena: std.mem.Allocator) mihomo_mod.Client {
    const st = &g_state;
    const host = st.api_host[0..st.api_host_len];
    const secret = st.secret[0..st.secret_len];
    return mihomo_mod.Client.init(arena, host, st.api_port, secret);
}

// 每秒 mihomo 状态轮询已移到后台 worker（见 pollMihomoWorker），UI 线程不再做网络请求。

// ---------------- menu ids / commands ----------------
const FUNC_BASE: usize = MENU_BASE_ID + MAX_NODES;
const FUNC_SYSPROXY: usize = FUNC_BASE + 0;
const FUNC_TUN: usize = FUNC_BASE + 1;
const FUNC_TESTLAT: usize = FUNC_BASE + 2;
const FUNC_UPDATE_CORE: usize = FUNC_BASE + 3; // 原 "Exit (keep core)" 槽位
const FUNC_EXIT_STOP: usize = FUNC_BASE + 4;
const FUNC_AUTOSTART: usize = FUNC_BASE + 5;
const FUNC_UPDATE_GEO: usize = FUNC_BASE + 6;

// 网卡选择子菜单命令 ID 基址（避开节点项 1..MAX_NODES 与功能项 FUNC_BASE..+6）。
const NIC_BASE_ID: usize = 1000;
const MAX_NICS: usize = traffic_mod.MAX_NICS;

const PROBE_URL = "http://www.gstatic.com/generate_204";

fn menuAdd(menu: win.HMENU, flags: u32, id: usize, text: []const u8) void {
    var wide: [256]u16 = undefined;
    const n = @min(text.len, wide.len - 1);
    for (text[0..n], 0..) |ch, i| wide[i] = if (ch > 0x7f) '?' else ch;
    wide[n] = 0;
    _ = win.AppendMenuW(menu, flags, id, @ptrCast(&wide));
}

fn flashMsg(text: []const u8) void {
    g_state.msg.set(text);
    g_state.msg_left = 5;
}

/// Append a timestamped line to mihomo-widget.log next to the exe. Thread-safe
/// (worker + UI both write). Keeps the most recent ~LOG_MAX bytes (drops the
/// oldest head) so a runaway loop can't fill the disk.
fn logWrite(comptime fmt: []const u8, args: anytype) void {
    win.AcquireSRWLockExclusive(&g_log_lock);
    defer win.ReleaseSRWLockExclusive(&g_log_lock);

    var mb: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&mb, fmt, args) catch return;
    const t = win.GetTickCount64();
    var lb: [1152]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "[{d}.{d}s] {s}\n", .{ t / 1000, @as(u32, @intCast((t % 1000) / 100)), msg }) catch return;

    var pb: [520]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}\\mihomo-widget.log", .{g_exe_dir[0..g_exe_dir_len]}) catch return;
    const old = proc.readFileBytes(std.heap.page_allocator, path, 1 << 24) catch "";
    defer if (old.len > 0) std.heap.page_allocator.free(old);

    var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer out.deinit();
    const tail = if (old.len > LOG_MAX) old.len - LOG_MAX else 0;
    out.appendSlice(old[tail..]) catch {};
    out.appendSlice(line) catch {};
    _ = proc.writeFileBytes(path, out.items);
}

/// Process memory in bytes: working set (task-manager口径) + private commit.
const MemStat = struct { ws: u64, priv: u64 };
fn memStat() MemStat {
    var pmc: win.PROCESS_MEMORY_COUNTERS = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS);
    pmc.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
    if (win.GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, @sizeOf(win.PROCESS_MEMORY_COUNTERS)) == 0) return .{ .ws = 0, .priv = 0 };
    return .{ .ws = pmc.working_set_size, .priv = pmc.pagefile_usage };
}

const TunLive = struct { enable: bool = false, has_device: bool = false };

/// 读 live TUN 状态。`has_device` 不可省：实测配置热重载后再发 PATCH tun.enable=true，
/// 核心返 204 但 enable 仍为 false、device 为空——虚拟网卡根本没建起来；只看 enable
/// 会把“没生效”当成成功。
fn readTunLive() TunLive {
    var out: TunLive = .{};
    if (!g_state.online) return out;
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp_arena.deinit();
    const c = clientFor(tmp_arena.allocator());
    const body = c.configsRaw() catch return out;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, tmp_arena.allocator(), body, .{}) catch return out;
    if (parsed != .object) return out;
    const t = parsed.object.get("tun") orelse return out;
    if (t != .object) return out;
    if (t.object.get("enable")) |e| out.enable = (e == .bool and e.bool);
    if (t.object.get("device")) |d| out.has_device = (d == .string and d.string.len > 0);
    return out;
}

/// TUN 是否真的可用（开关 on 且虚拟网卡已建好）：菜单标题与“要不要切换”都看这个，
/// 否则卡住的状态下菜单会显示 (on)，用户点一下反而变成关闭。
fn tunEffectivelyOn() bool {
    const t = readTunLive();
    return t.enable and t.has_device;
}

/// 轮询等待 TUN 达到目标状态（开启时额外要求设备已建好）。返回是否达成。
fn waitTun(want: bool, budget_ms: u32) bool {
    var waited: u32 = 0;
    while (true) {
        const t = readTunLive();
        if (t.enable == want and (want == false or t.has_device)) return true;
        if (waited >= budget_ms) return false;
        win.Sleep(400);
        waited += 400;
    }
}

// ---------------- background worker --------------
// 单槽后台 worker：把延迟测试 / TUN 切换 / 停止核心挪出 UI 线程，
// 完成后用 WM_APP_DONE 消息通知 UI 线程更新并重绘。
const WM_APP_DONE: u32 = 0x8001; // WM_APP + 1

const JobKind = enum(u8) { none, latency, tun, stop, update_core, update_geo, heal };

const JobBox = struct {
    kind: JobKind = .none,
    nodes: [MAX_NODES]Cell = undefined, // latency / heal 参数快照
    nodes_n: u8 = 0,
    nodes_quic: [MAX_NODES]bool = .{false} ** MAX_NODES,
};

var g_job: JobBox = .{};
var g_busy: std.atomic.Value(bool) = .init(false);
var g_quitting: std.atomic.Value(bool) = .init(false);
var g_worker_thread: ?std.Thread = null;
var g_job_ev: isize = 0; // manual-reset event，由 main 创建
const WAIT_OBJECT_0: u32 = 0;

// 后台轮询结果槽（worker 写 / UI 读，SRWLOCK 互斥）
const PollBox = struct {
    online: bool = false,
    status: Cell = .{},
    g0_name: Cell = .{},
    g0_now: Cell = .{},
    g0_is_selector: bool = false,
    nodes: [MAX_NODES]Cell = undefined,
    nodes_n: u8 = 0,
    nodes_quic: [MAX_NODES]bool = .{false} ** MAX_NODES,
    tun_on: bool = false, // TUN 真的可用（enable + 网卡已建好），自愈布防用
};
var g_poll: PollBox = .{};
var g_poll_lock: win.SRWLOCK = .{};
// QUIC 自环自愈的布防状态：TUN 每次"就位"（运行中 off->on，或核心刚起来就带 TUN）后等
// HEAL_DELAY_MS 探一次；关掉或核心掉线就作废。见 workerHeal。
const HEAL_DELAY_MS: u64 = 10_000;
var g_heal_armed_at: u64 = 0; // 0=未布防，>0=TUN 就位时刻（到点探一次）
var g_heal_tun_prev: bool = false; // 上次轮询看到的 TUN 状态（识别 off->on）

// --- diagnostics logging (mihomo-widget.log next to the exe) ---
const LOG_MAX: usize = 1 << 20; // cap ~1MB, keep the most recent tail
var g_log_lock: win.SRWLOCK = .{};
var g_log_tick: u32 = 0; // poll summary throttle counter
var g_log_last: u64 = 0; // ms of last poll summary (10s cadence)

/// 提交一个后台任务（UI 线程调用）；已有任务在跑则忽略本次。
fn enqueueJob(kind: JobKind) void {
    if (g_busy.swap(true, .acq_rel)) return;
    g_job.kind = kind;
    logWrite("job start {s}", .{@tagName(kind)});
    if (kind == .latency or kind == .heal) {
        const st = &g_state;
        g_job.nodes_n = st.nodes_n;
        for (0..st.nodes_n) |i| {
            g_job.nodes[i] = st.nodes[i];
            g_job.nodes_quic[i] = st.nodes_quic[i];
        }
    }
    _ = win.SetEvent(g_job_ev);
}

/// 后台：汇总全部节点延迟，写入 lat_ms。
/// 两条数据源（实测结论）：
///  • provider（节点池）里的节点**不注册到控制器 proxy 表**，`GET /proxies/{name}/delay` 直接 404，
///    只能读 `/providers/proxies/{name}` 的 health-check 结果（新鲜程度 = provider 的 interval）；
///  • 静态 `proxies:` 声明的节点仍可用逐个 /delay。
/// 不用 `PUT /configs` 去“逼”出一轮新测速：那会把运行时状态（mode / tun.enable）刷回文件值，
/// 开着 TUN 时等于掉隧道。
/// 注：lat_ms 为 u16 数组，x64 上单元素读写原子；与 UI 读的竞态只会读到略旧值，无撕裂/崩溃。
fn workerLatency(nodes: *const [MAX_NODES]Cell, nn: u8) isize {
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const al = tempar.allocator();
    const c = clientFor(al);

    var lat = std.array_list.Managed(mihomo_mod.Client.ProvLat).init(al);
    var prov_names = std.array_list.Managed([]const u8).init(al);
    c.proxyProviders(&prov_names) catch {};
    for (prov_names.items) |p| c.providerLatency(p, &lat) catch {};

    var alive_n: isize = 0;
    for (0..nn) |i| {
        const nm = nodes[i].slice();
        var ms: u16 = 0;
        var found = false;
        for (lat.items) |e| {
            if (std.mem.eql(u8, e.name, nm)) {
                found = true;
                ms = e.ms;
                break;
            }
        }
        if (!found) {
            ms = if (c.delayOf(nm, PROBE_URL, 1200) catch null) |m| @intCast(@min(m, 9999)) else 0;
        }
        g_state.lat_ms[i] = ms;
        if (ms != 0) alive_n += 1;
    }
    return alive_n;
}

/// 后台 TUN 切换（用户手动）：返回 0=enabled, 1=disabled, 2=needs admin / 未生效, 3=failed。
fn workerTun() isize {
    return workerTunSet(!tunEffectivelyOn());
}

/// 开 TUN 后清一次 Windows DNS 缓存：否则应用会继续用“还没接管”时解析到的真实 IP，
/// 域名得等缓存过期才回到 mihomo 的 fake-ip + TUN 路径。
fn flushDns() void {
    var tmp_pid: u32 = 0;
    _ = proc.spawnCmd(&tmp_pid, "ipconfig.exe", "ipconfig /flushdns", "");
}

/// 后台：把 TUN 强制切换到目标状态 want。已是目标状态（开启时还要求网卡已建好）则直接返回、
/// 不发送任何请求（菜单点“TUN (on)”而它已经开着时不该再切一次）。
/// mihomo 对 PATCH 会静默不生效（已实测），所以一次没达成时补一轮 off→on 逼它重建虚拟网卡。
fn workerTunSet(want: bool) isize {
    const now = readTunLive();
    if (now.enable == want and (want == false or now.has_device)) {
        // 已是目标状态：没有 PATCH 可发，但“开 TUN 后清一次 DNS 缓存”照旧要做。
        if (want) flushDns();
        return if (want) 0 else 1;
    }
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const c = clientFor(tempar.allocator());
    c.setTun(want) catch return 3;
    var ok = waitTun(want, 4_000);
    if (!ok and want) {
        logWrite("tun: apply did not settle, retry off->on", .{});
        c.setTun(false) catch {};
        win.Sleep(600);
        c.setTun(true) catch {};
        ok = waitTun(true, 8_000);
        if (ok) logWrite("tun: recovered after off->on retry", .{});
    }
    if (!ok) return 2;
    if (want) flushDns();
    return if (want) 0 else 1;
}

/// name 是否在出站长驻 QUIC 的节点名单里（/proxies 的 type 分类）。
fn nodeIsQuic(quic_names: []const []const u8, name: []const u8) bool {
    for (quic_names) |q| {
        if (std.mem.eql(u8, q, name)) return true;
    }
    return false;
}

/// 单节点探针超时（mihomo 侧）。自环的 QUIC 连接不会应答，1.2s 足够定性。
const HEAL_PROBE_MS: u32 = 1_200;

/// 后台：TUN 就位后的"QUIC 自环"体检与自愈。
///
/// 病因：核心跑着的时候建 TUN（`PATCH /configs` 开），建网卡/装路由那一瞬会把**此期间新拨的**
/// hysteria2（QUIC/UDP）连接的 socket 绑到 TUN 的地址上——核心自己的报文进自己的 TUN、
/// 命中 `MATCH,Proxy` 变自环，该节点要等 QUIC 超时重拨（实测 ~70–90s）才恢复；TCP 类
/// 节点每条连接重拨新 socket，不受影响。
///
/// 控件启动时**不再碰 TUN**（开机状态由 config.yaml 的 `tun.enable` 决定，核心启动阶段
/// 就建好网卡，早于它自己的首拨/组测速，那条路天然安全），所以本函数只服务于**运行中的
/// 切换**：菜单里手动开 TUN，或第三方（脚本 / 另一个面板）PATCH 开。见 AGENTS.md 关键决策。
///
/// 判据（不猜端口，用 `/proxies` 的 type）：有 QUIC 类节点探不通、而 TCP 类节点至少一个
/// 通 → 是自环，不是节点/网络整体挂了（核心离线时 TCP 对照也不通，于是不动作）。
///
/// 手法：让核心**就地重载自己那份配置**（`PUT /configs {}`）——`ApplyConfig` 重建全部
/// outbound，hysteria2 客户端丢掉坏连接、下次使用时重拨。重载不炸隧道的前提是那份文件
/// 的 `tun.enable` 与实时状态一致（`ReCreateTun` 判定相等 → 网卡不动），所以先校验：
/// 用 patchTunEnable 把实时值写进副本，副本与原文相同才动手；事后仍复查一次并在被刷掉
/// 时补回来。用户当前选中的节点在重载后按需重选（store-selected 不保证还原）。
/// 每次 TUN 就位只做一次（由 g_heal_armed_at 布防），不会周期性打断连接。
/// 返回 0=没命中/跳过，1=已重载，3=重载失败。
fn workerHeal(nodes: *const [MAX_NODES]Cell, quic: *const [MAX_NODES]bool, nn: u8) isize {
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const c = clientFor(tempar.allocator());

    // 1) 探针：全部 QUIC 类节点 + 最多 2 个 TCP 类节点当对照
    var quic_dead: u8 = 0;
    var quic_alive: u8 = 0;
    var tcp_alive: u8 = 0;
    var tcp_probed: u8 = 0;
    for (0..nn) |i| {
        const is_q = quic[i];
        if (!is_q and tcp_probed >= 2) continue;
        if (!is_q) tcp_probed += 1;
        const ms: ?u32 = c.delayOf(nodes[i].slice(), PROBE_URL, HEAL_PROBE_MS) catch null;
        g_state.lat_ms[i] = if (ms) |m| @intCast(@min(m, 9999)) else 0;
        if (is_q) {
            if (ms != null) quic_alive += 1 else quic_dead += 1;
        } else if (ms != null) tcp_alive += 1;
    }
    if (quic_dead == 0 or tcp_alive == 0) {
        logWrite("heal: no self-loop signature (quic dead={d} alive={d}, tcp alive={d})", .{ quic_dead, quic_alive, tcp_alive });
        return 0;
    }

    // 2) 前置校验：核心那份配置的 tun.enable 必须已经等于实时状态
    const cfg_path = g_yaml_abs[0..g_yaml_len];
    const live = readTunLive();
    const src = proc.readFileBytes(std.heap.page_allocator, cfg_path, 1 << 20) catch return 0;
    defer std.heap.page_allocator.free(src);
    const buf = std.heap.page_allocator.alloc(u8, src.len + 32) catch return 0;
    defer std.heap.page_allocator.free(buf);
    const n = proc.patchTunEnable(src, live.enable, buf) orelse {
        logWrite("heal: skip, no top-level tun: block in cfg — reload would drop the tunnel", .{});
        return 0;
    };
    if (!std.mem.eql(u8, buf[0..n], src)) {
        logWrite("heal: skip, cfg tun.enable != live({}) — reload would drop the tunnel", .{live.enable});
        return 0;
    }

    logWrite("heal: self-loop (quic dead={d}/{d}, tcp alive={d}) -> reload cfg in place", .{ quic_dead, quic_dead + quic_alive, tcp_alive });
    c.reloadConfigInPlace() catch {
        logWrite("heal: reload request failed", .{});
        return 3;
    };
    // 保险：万一重载把 TUN 刷掉了（不该发生），立刻补回来
    if (!waitTun(live.enable, 2_000)) {
        logWrite("heal: TUN lost after reload, restoring", .{});
        _ = workerTunSet(live.enable);
    }
    // 重载按 store-selected 重建分组，不保证还是用户当前选的那个节点
    if (g_state.g0_is_selector and g_state.g0_now.len > 0) {
        var g0 = mihomo_mod.Group{ .name = g_state.g0_name.slice(), .kind = .selector };
        c.groupDetail(&g0) catch {};
        const now = g0.now orelse "";
        if (!std.mem.eql(u8, now, g_state.g0_now.slice())) {
            c.select(g0.name, g_state.g0_now.slice()) catch {};
            logWrite("heal: restored selection {s} -> {s}", .{ now, g_state.g0_now.slice() });
        }
    }
    // 复查：只重探 QUIC 类节点，日志里能直接看出自愈是否生效
    var back: u8 = 0;
    var quic_n: u8 = 0;
    for (0..nn) |i| {
        if (!quic[i]) continue;
        quic_n += 1;
        const ms: ?u32 = c.delayOf(nodes[i].slice(), PROBE_URL, HEAL_PROBE_MS) catch null;
        g_state.lat_ms[i] = if (ms) |m| @intCast(@min(m, 9999)) else 0;
        if (ms != null) back += 1;
    }
    logWrite("heal: quic nodes back {d}/{d} after reload", .{ back, quic_n });
    return 1;
}

/// 后台：每秒轮询 mihomo 状态（version/snapshot/groupDetail），结果写入 g_poll。
/// 只做网络请求与解析，不碰 UI；UI 线程通过 g_poll 取最新快照。
fn pollMihomoWorker() void {
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const c = clientFor(tempar.allocator());
    var pb: PollBox = .{};

    const ver = c.version() catch null;
    if (ver == null) proc.spawnCoreIfNeeded(g_exe_dir[0..g_exe_dir_len], g_yaml_abs[0..g_yaml_len], &g_core_spawned, &g_core_pid);
    const snap = c.snapshot() catch {
        pb.online = false;
        pb.status.set("controller unreachable");
        logWrite("poll err: controller unreachable (spawn retry)", .{});
        proc.spawnCoreIfNeeded(g_exe_dir[0..g_exe_dir_len], g_yaml_abs[0..g_yaml_len], &g_core_spawned, &g_core_pid);
        win.AcquireSRWLockExclusive(&g_poll_lock);
        g_poll = pb;
        win.ReleaseSRWLockExclusive(&g_poll_lock);
        return;
    };
    pb.online = true;
    pb.status.set(if (ver) |v| v else "?");

    var pi: ?usize = null;
    var gi: ?usize = null;
    for (snap.groups, 0..) |g, idx| {
        if (g.kind == .selector and !std.mem.eql(u8, g.name, "GLOBAL") and pi == null) {
            pi = idx;
            pb.g0_is_selector = true;
        } else if (gi == null and g.kind == .selector) {
            gi = idx;
        }
    }
    const primary_idx = pi orelse gi;
    if (primary_idx) |idx0| {
        var g0 = snap.groups[idx0];
        c.groupDetail(&g0) catch {};
        pb.g0_name.set(g0.name);
        pb.g0_now.set(g0.now orelse "?");
        pb.g0_is_selector = g0.kind == .selector;
        pb.nodes_n = 0;
        for (g0.all) |nd| {
            if (pb.nodes_n >= MAX_NODES) break;
            if (std.mem.eql(u8, nd, "DIRECT") or std.mem.eql(u8, nd, "REJECT") or std.mem.eql(u8, nd, "REJECT-DROP") or std.mem.eql(u8, nd, "PASS") or std.mem.eql(u8, nd, "PASS-RULE") or std.mem.eql(u8, nd, "COMPATIBLE")) continue;
            pb.nodes[pb.nodes_n].set(nd);
            pb.nodes_quic[pb.nodes_n] = nodeIsQuic(snap.quic_nodes, nd);
            pb.nodes_n += 1;
        }
    }
    // TUN 实时状态：顺路取（自愈布防与菜单都要），省得 UI 线程再发一次 /configs
    const tl = readTunLive();
    pb.tun_on = tl.enable and tl.has_device;
    win.AcquireSRWLockExclusive(&g_poll_lock);
    g_poll = pb;
    win.ReleaseSRWLockExclusive(&g_poll_lock);
}

/// 后台：停核心。**先关 TUN，再强杀**——TUN 是核心创建并持有的虚拟网卡 + 默认路由，
/// `taskkill /F` 是硬杀、不走核心自己的清理路径，可能在机器上留一张死网卡和它的
/// `0.0.0.0/1` 路由，把整机流量黑洞掉；趁核心还活着先 `setTun(false)` 让它自己拆干净。
/// 杀完再确认一次：控制器还答得上话就是**没杀掉**（例如非提权运行时杀不动提权核心），
/// 如实返回 3，而不是像以前那样无条件报成功。
/// 返回 0=已停掉，3=核心仍在跑。
fn workerStop() isize {
    if (!g_state.online) {
        // 最后一次轮询就知道核心不在线：没什么可停的，也不必再等一次 version 超时。
        _ = proc.spawnCmd(&g_core_pid, "", "taskkill.exe /IM mihomo.exe /F", "");
        win.Sleep(200);
        return 0;
    }
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const c = clientFor(tempar.allocator());
    if (readTunLive().enable) {
        c.setTun(false) catch {};
        if (!waitTun(false, 2_000)) logWrite("stop: TUN still on after 2s, killing anyway", .{});
    }
    c.shutdown(); // GET /shutdown：本版核心没有这个路由（404），留给别的核心/版本
    win.Sleep(200);
    _ = proc.spawnCmd(&g_core_pid, "", "taskkill.exe /IM mihomo.exe /F", "");
    win.Sleep(400);
    if (c.version() catch null) |_| {
        logWrite("stop: core still answering after taskkill (needs admin?)", .{});
        return 3;
    }
    return 0;
}

/// 后台：触发 mihomo 自升级（下载完成后重启 core）或 GeoIP/GeoSite/ASN/MMDB 下载。
/// 返回 0=已触发，3=失败。升级期间 external-controller 会短暂离线。
fn workerTrigger(kind: JobKind) isize {
    var tempar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempar.deinit();
    const c = clientFor(tempar.allocator());
    switch (kind) {
        .update_core => c.upgradeCore() catch return 3,
        .update_geo => c.updateGeo() catch return 3,
        else => return 3,
    }
    return 0;
}

/// worker 线程主循环：等待 job 事件（同时以 1s 超时兼做 mihomo 轮询心跳）。
fn workerMain() void {
    while (true) {
        const r = win.WaitForSingleObject(g_job_ev, 1000); // 1s 心跳
        if (g_quitting.load(.acquire)) break;
        if (r != WAIT_OBJECT_0) {
            pollMihomoWorker(); // 无任务：轮询 mihomo
            continue;
        }
        _ = win.ResetEvent(g_job_ev);
        if (g_quitting.load(.acquire)) break;
        const kind = g_job.kind;
        var nodes: [MAX_NODES]Cell = undefined;
        var quic: [MAX_NODES]bool = .{false} ** MAX_NODES;
        var nn: u8 = 0;
        if (kind == .latency or kind == .heal) {
            nn = g_job.nodes_n;
            for (0..nn) |i| {
                nodes[i] = g_job.nodes[i];
                quic[i] = g_job.nodes_quic[i];
            }
        }
        g_busy.store(false, .release); // 释放槽，允许后续新任务
        var result: isize = 0;
        switch (kind) {
            .latency => result = workerLatency(&nodes, nn),
            .heal => result = workerHeal(&nodes, &quic, nn),
            .tun => result = workerTun(),
            .stop => result = workerStop(),
            .update_core, .update_geo => result = workerTrigger(kind),
            else => {},
        }
        _ = win.PostMessageW(g_ui.hwnd, WM_APP_DONE, @intCast(@intFromEnum(kind)), @intCast(result));
    }
}

/// UI 线程：后台任务完成后的收尾（更新提示 / 重绘 / 关窗）。
fn handleJobDone(kind: JobKind, result: isize) void {
    const hwnd = g_ui.hwnd;
    switch (kind) {
        .latency => {
            var b: [48]u8 = undefined;
            flashMsg(std.fmt.bufPrint(&b, "Latency: {d}/{d} alive", .{ result, g_state.nodes_n }) catch "Latency done");
        },
        .tun => {
            // TUN 开关只影响本次运行：写 conf 的那一套已删除（开机状态由 config.yaml 的
            // tun.enable 决定，核心启动时自己读）。这里只提示结果。
            if (result == 3) flashMsg("TUN toggle failed")
            else if (result == 2) flashMsg("TUN needs admin / config reload")
            else if (result == 1) flashMsg("TUN disabled")
            else flashMsg("TUN enabled");
        },
        .stop => {
            // result=3：核心没停掉（控制器还活着）。窗口照样关（菜单是唯一出口，不能把用户
            // 关在里面），但日志要留真相——以前这里无条件报成功。
            if (result == 3) logWrite("exit: core still running (stop failed, needs admin?)", .{});
            _ = win.DestroyWindow(hwnd);
        },
        .update_core => {
            if (result == 0) flashMsg("Core update triggered") else flashMsg("Core update failed");
        },
        .update_geo => {
            if (result == 0) flashMsg("Geo update triggered") else flashMsg("Geo update failed");
        },
        .heal => {
            // 自愈是自动的：命中才提示（result=1）。0=没命中（正常），3=重载请求失败。
            if (result == 1) flashMsg("QUIC reset (TUN self-loop)")
            else if (result == 3) flashMsg("QUIC reset failed");
        },
        else => {},
    }
    logWrite("job done {s} result={d}", .{ @tagName(kind), result });
    _ = win.InvalidateRect(hwnd, null, 0);
}

/// 二级菜单标题：主组名是 ASCII 时带上它（菜单里能看出选的是哪个分组），否则退回 `Nodes`。
fn nodeMenuTitle(buf: []u8, group: []const u8) []const u8 {
    var ok = group.len > 0 and group.len <= 64;
    for (group) |ch| {
        if (ch > 0x7f) {
            ok = false;
            break;
        }
    }
    if (!ok) return "Nodes";
    return std.fmt.bufPrint(buf, "Nodes ({s})", .{group}) catch "Nodes";
}

fn menuForGroup(hwnd: win.HWND, at: win.POINT) void {
    const st = &g_state;
    // 核心没起来（配置错误 / 端口不通 / 还没拉起）时菜单也必须弹：这是用户唯一的
    // 退出入口，早退会让控件变成一个关不掉的窗口。只把依赖核心的项置灰。
    const core_up = st.online and st.nodes_n > 0;
    const core_flag: u32 = if (core_up) 0 else MF_DISABLED_GRAYED;
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);

    menuAdd(menu, MF_STRING | core_flag, FUNC_TESTLAT, "Test All Latency");
    _ = win.AppendMenuW(menu, MF_SEPARATOR, 0, null);

    const cur = st.g0_now.slice();
    var default_id: u32 = 0;
    // 节点列表收进二级菜单：节点池可以长到 MAX_NODES 项，平铺会把功能项挤出屏幕。
    // 两个子菜单句柄都在函数作用域里创建、由下面的 defer 统一释放（defer 绑定块作用域，
    // 写进内层 if 会在 TrackPopupMenu 之前就执行；实测 USER32 对还挂在父菜单上的子菜单
    // 按引用计数保留，提前 DestroyMenu 并不会让它失效，但统一写法更不容易踩坑）。
    var nodes_sub: win.HMENU = null;
    var nic_sub: win.HMENU = null;
    defer {
        if (nodes_sub) |m| _ = win.DestroyMenu(m);
        if (nic_sub) |m| _ = win.DestroyMenu(m);
    }
    if (core_up) {
        nodes_sub = win.CreatePopupMenu() orelse return;
        for (0..st.nodes_n) |i| {
            const nm = st.nodes[i].slice();
            var tb: [200]u8 = undefined;
            const label = if (st.lat_ms[i] != 0)
                (std.fmt.bufPrint(&tb, "{s}  ({d} ms)", .{ nm, st.lat_ms[i] }) catch nm)
            else
                nm;
            const id = MENU_BASE_ID + i;
            var flags: u32 = MF_STRING;
            if (std.mem.eql(u8, nm, cur)) {
                flags |= MF_CHECKED;
                default_id = @intCast(id);
            }
            menuAdd(nodes_sub, flags, id, label);
        }
        var title_buf: [128]u8 = undefined;
        menuAdd(menu, MF_POPUP, @intFromPtr(nodes_sub), nodeMenuTitle(&title_buf, st.g0_name.slice()));
        // 默认项（回车直接选中当前节点）在子菜单里，必须对 nodes_sub 设置
        if (default_id != 0) _ = win.SetMenuDefaultItem(nodes_sub, default_id, 0);
    }
    _ = win.AppendMenuW(menu, MF_SEPARATOR, 0, null);
    const sp_on = system_win.sysProxyEnabled();
    menuAdd(menu, MF_STRING | (if (sp_on) MF_CHECKED else 0), FUNC_SYSPROXY, if (sp_on) "System Proxy (on)" else "System Proxy (off)");
    const tun_on = tunEffectivelyOn(); // 卡住（enable=true 但没网卡）时当作 off，点一下就能走重建路径
    menuAdd(menu, MF_STRING | (if (tun_on) MF_CHECKED else 0) | core_flag, FUNC_TUN, if (tun_on) "TUN Mode (on)" else "TUN Mode (off)");
    const as_on = system_win.autoStartEnabled();
    menuAdd(menu, MF_STRING | (if (as_on) MF_CHECKED else 0), FUNC_AUTOSTART, if (as_on) "Auto Start (on)" else "Auto Start (off)");

    // Network Interface selection submenu: pick which NIC to meter.
    var nic_sel: [MAX_NICS]traffic_mod.Nic = undefined;
    const nics_n = traffic_mod.listNics(&nic_sel);
    if (nics_n > 0) {
        nic_sub = win.CreatePopupMenu() orelse return;
        for (0..nics_n) |i| {
            var nf: u32 = MF_STRING;
            if (nic_sel[i].ifindex == g_cfg.nic_ifindex) nf |= MF_CHECKED;
            menuAdd(nic_sub, nf, NIC_BASE_ID + i, nic_sel[i].slice());
        }
        menuAdd(menu, MF_POPUP, @intFromPtr(nic_sub), "Network Interface");
    }

    _ = win.AppendMenuW(menu, MF_SEPARATOR, 0, null);
    menuAdd(menu, MF_STRING | core_flag, FUNC_UPDATE_CORE, "Manual Update Core");
    menuAdd(menu, MF_STRING | core_flag, FUNC_UPDATE_GEO, "Manual Update Geo");
    // "&&" because a single "&" is Win32's mnemonic prefix and would be swallowed
    menuAdd(menu, MF_STRING, FUNC_EXIT_STOP, "Exit && Stop Core");

    var sc = at;
    _ = win.ClientToScreen(hwnd, &sc);
    _ = win.SetForegroundWindow(hwnd);
    const raw: win.BOOL = win.TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_RIGHTBUTTON | TPM_RETURNCMD, sc.x, sc.y, 0, hwnd, null);
    if (raw <= 0) return;
    const cmd: usize = @intCast(raw);
    if (cmd < FUNC_BASE) {
        const idx = cmd - MENU_BASE_ID;
        if (idx < st.nodes_n) {
            var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer tmp_arena.deinit();
            const c = clientFor(tmp_arena.allocator());
            if (st.g0_is_selector) _ = c.select(st.g0_name.slice(), st.nodes[idx].slice()) catch {};
        }
        return;
    }
    if (nics_n > 0 and cmd >= NIC_BASE_ID and cmd < NIC_BASE_ID + nics_n) {
        const ni = cmd - NIC_BASE_ID;
        g_cfg.nic_ifindex = nic_sel[ni].ifindex;
        g_meter.sel = g_cfg.nic_ifindex;
        proc.saveConfState(g_exe_dir[0..g_exe_dir_len], g_cfg.sysproxy, g_cfg.nic_ifindex);
        flashMsg("Network interface set");
        _ = win.InvalidateRect(hwnd, null, 0);
        return;
    }
    switch (cmd) {
        FUNC_SYSPROXY => {
            const to = !system_win.sysProxyEnabled();
            system_win.setSysProxy(g_state.mixed_port, to);
            g_cfg.sysproxy = to;
            proc.saveConfState(g_exe_dir[0..g_exe_dir_len], g_cfg.sysproxy, g_cfg.nic_ifindex);
            _ = win.InvalidateRect(hwnd, null, 0);
        },
        FUNC_TUN => {
            enqueueJob(.tun);
            flashMsg("Toggling TUN…");
        },
        FUNC_TESTLAT => {
            enqueueJob(.latency);
            flashMsg("Testing latency…");
        },
        FUNC_AUTOSTART => {
            const want = !system_win.autoStartEnabled();
            if (system_win.setAutoStart(g_self_abs[0..g_self_abs_len], want)) {
                flashMsg(if (want) "Auto start enabled" else "Auto start disabled");
            } else flashMsg("Auto start failed");
            _ = win.InvalidateRect(hwnd, null, 0);
        },
        FUNC_UPDATE_CORE => {
            enqueueJob(.update_core);
            flashMsg("Updating core…");
        },
        FUNC_UPDATE_GEO => {
            enqueueJob(.update_geo);
            flashMsg("Updating Geo data…");
        },
        FUNC_EXIT_STOP => {
            enqueueJob(.stop);
            flashMsg("Stopping core…");
        },
        else => {},
    }
}


fn applyHover(hwnd: win.HWND) void {
    g_ui.h = if (g_ui.hovered) scal(g_cfg.hov_h) else scal(g_cfg.norm_h);
    g_ui.w = if (g_ui.hovered) scal(g_cfg.hov_w) else scal(g_cfg.fold_w);
    _ = win.SetWindowPos(hwnd, 0, 0, 0, g_ui.w, g_ui.h, SWP_NOMOVE | SWP_NOZORDER);
    _ = win.InvalidateRect(hwnd, null, 0);
}

/// Collapse once the cursor leaves the window rect (polled each timer tick).
fn hoverCheck(hwnd: win.HWND) void {
    if (!g_ui.hovered) return;
    var pt: win.POINT = undefined;
    if (win.GetCursorPos(&pt) == 0) return;
    var rc: win.RECT = undefined;
    if (win.GetWindowRect(hwnd, &rc) == 0) return;
    if (pt.x < rc.left or pt.x >= rc.right or pt.y < rc.top or pt.y >= rc.bottom) {
        g_ui.hovered = false;
        applyHover(hwnd);
    }
}

// ---------------- topmost watchdog ----------------
// 本程序从不清除 WS_EX_TOPMOST，但 Windows 会在 workstation 解锁、显示模式
// 变更、DWM 重建 Z-order 或另一个 topmost 程序退出后，把我们的窗口摆到普通
// 窗口之下（用户只能靠点一下面板把它“唤回”前台）。这里不猜是哪个事件，只
// 检测后果并静默修复，同时记日志，便于下次发生时定位。
var g_top_check_at: u64 = 0; // 上次巡检时刻（自带限流）
var g_top_fixes: u32 = 0; // 已修复次数

fn isTopmostWindow(hwnd: win.HWND) bool {
    const ex: u64 = @bitCast(win.GetWindowLongPtrW(hwnd, GWL_EXSTYLE));
    return (ex & @as(u64, WS_EX_TOPMOST)) != 0;
}

/// 重新加入 topmost 带；SWP_NOACTIVATE 保证不抢用户当前应用的焦点。
fn reassertTopmost(hwnd: win.HWND, reason: []const u8, cover: win.HWND) void {
    if (win.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) == 0) {
        logWrite("topmost guard: {s} but SetWindowPos failed (gle={d})", .{ reason, win.GetLastError() });
        return;
    }
    g_top_fixes += 1;
    logWrite("topmost guard: re-asserted ({s}, cover=0x{x}, fixes={d})", .{
        reason,
        @as(u64, @bitCast(cover)),
        g_top_fixes,
    });
}

/// 周期性巡检（间隔由 conf 的 topmost_guard_ms 控制，0 = 关闭）。
fn topmostGuard(hwnd: win.HWND) void {
    if (g_cfg.topmost_guard_ms == 0) return;
    const now = win.GetTickCount64();
    if (now - g_top_check_at < g_cfg.topmost_guard_ms) return;
    g_top_check_at = now;

    // 1) 置顶样式位被清掉了。
    if (!isTopmostWindow(hwnd)) {
        reassertTopmost(hwnd, "exstyle-lost", 0);
        return;
    }
    // 2) 样式位还在，但被普通窗口盖住了——这就是 Z-order 被重建的后果。
    //    若盖住我们的窗口自身也是 topmost（例如另一个悬浮工具），属正常层级，不去争。
    var rc: win.RECT = undefined;
    if (win.GetWindowRect(hwnd, &rc) == 0) return;
    const center = win.POINT{
        .x = rc.left + @divTrunc(rc.right - rc.left, 2),
        .y = rc.top + @divTrunc(rc.bottom - rc.top, 2),
    };
    const cover = win.WindowFromPoint(center);
    if (cover == 0 or cover == hwnd) return;
    if (isTopmostWindow(cover)) return;
    reassertTopmost(hwnd, "covered-by-plain-window", cover);
}

fn wndproc(hwnd: win.HWND, msg: u32, wp: win.WPARAM, lp: win.LPARAM) callconv(.c) win.LRESULT {
    switch (msg) {
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            var ps: win.PAINTSTRUCT = undefined;
            const hdc = win.BeginPaint(hwnd, &ps);
            // double buffer (win.BitBlt BEFORE restore)
            const mem = win.CreateCompatibleDC(hdc);
            const bmp = win.CreateCompatibleBitmap(hdc, g_ui.w, g_ui.h);
            _ = win.SelectObject(mem, bmp);
            ui_draw.fill_rect(mem, 0, 0, g_ui.w, g_ui.h, g_ui.bg);
            _ = win.SelectObject(mem, @ptrCast(g_ui.font));
            _ = win.SetBkMode(mem, TRANSPARENT);
            const st = &g_state;
            const ctx = ui_draw.DrawCtx{
                .scale = g_cfg.ls,
                .win_w = g_ui.w,
                .bg = g_cfg.c_bg,
                .fonts = .{ .normal = g_ui.font, .mid = g_ui.font_mid, .bold = g_ui.font_bold },
            };
            if (g_ui.hovered) {
                ui_draw.drawSpeedAt(mem, scal(10), scal(g_cfg.speed_top), st.up_cell.slice(), st.down_cell.slice(), g_cfg.c_speed, ctx);
                if (st.g0_name.len > 0) {
                    var line2: [256]u8 = undefined;
                    const a2 = std.fmt.bufPrint(&line2, "{s} -> {s}", .{ st.g0_name.slice(), st.g0_now.slice() }) catch return 0;
                    ui_draw.text_at(mem, scal(10), scal(30), a2, g_cfg.c_fg, ctx);
                } else {
                    ui_draw.text_at(mem, scal(10), scal(30), "waiting for core...", g_cfg.c_dim, ctx);
                }
                var line3: [300]u8 = undefined;
                const c3 = if (st.msg_left > 0)
                    st.msg.slice()
                else if (st.online) std.fmt.bufPrint(&line3, "right-click menu  |  {s}", .{st.status.slice()}) catch "mihomo"
                else ERR_NO_CORE;
                ui_draw.text_at(mem, scal(10), scal(54), c3, if (st.msg_left > 0) g_cfg.c_warn else g_cfg.c_dim, ctx);
            } else {
                ui_draw.drawSpeedAt(mem, scal(10), scal(g_cfg.speed_top), st.up_cell.slice(), st.down_cell.slice(), g_cfg.c_speed, ctx);
            }
            _ = win.BitBlt(hdc, 0, 0, g_ui.w, g_ui.h, mem, 0, 0, SRCCOPY);
            _ = win.DeleteObject(bmp);
            _ = win.DeleteDC(mem);
            _ = win.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_APP_DONE => {
            handleJobDone(@enumFromInt(@as(u8, @intCast(wp & 0xFF))), @intCast(lp));
            return 0;
        },
        WM_TIMER => {
            if (wp == POLL_TIMER) {
                // 拉取后台轮询结果到 g_state（仅 UI 线程写）
                win.AcquireSRWLockExclusive(&g_poll_lock);
                const pb = g_poll;
                win.ReleaseSRWLockExclusive(&g_poll_lock);
                const st = &g_state;
                st.online = pb.online;
                const now_ms = win.GetTickCount64();
                // QUIC 自环自愈布防：TUN 每次"就位"（运行中 off→on，或核心刚起来就带 TUN）
                // 后等 HEAL_DELAY_MS 探一次。TUN 的开机状态由 config.yaml 决定（控件启动时
                // 不发任何 TUN 请求），所以这里看到的上升沿只可能来自核心自己建网卡或用户
                // 在菜单里切换。核心掉线/TUN 又关了就作废。判据与手法见 workerHeal。
                const tun_rise = pb.online and pb.tun_on and !g_heal_tun_prev;
                g_heal_tun_prev = pb.tun_on;
                if (tun_rise) g_heal_armed_at = now_ms;
                if (g_heal_armed_at != 0) {
                    if (!pb.online or !pb.tun_on) {
                        g_heal_armed_at = 0;
                    } else if (now_ms - g_heal_armed_at >= HEAL_DELAY_MS) {
                        g_heal_armed_at = 0;
                        enqueueJob(.heal);
                    }
                }
                st.status = pb.status;
                st.g0_name = pb.g0_name;
                st.g0_now = pb.g0_now;
                st.g0_is_selector = pb.g0_is_selector;
                st.nodes_n = pb.nodes_n;
                for (0..pb.nodes_n) |i| {
                    st.nodes[i] = pb.nodes[i];
                    st.nodes_quic[i] = pb.nodes_quic[i];
                }
                // 本地流量计量（GetIfTable2，快）
                const rrate = g_meter.tick() catch traffic_mod.Rate{ .up = 0, .down = 0 };
                // tick() 返回距上次采样的字节增量；按采样间隔归一化到“每秒”，
                // 否则采样间隔改为 0.5s 后数值会偏小一倍。
                const scale: f64 = 1000.0 / @as(f64, @floatFromInt(g_cfg.speed_refresh_ms));
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                st.up_cell.set(fmtRate(&b1, @intFromFloat(@as(f64, @floatFromInt(rrate.up)) * scale), g_cfg.speed_unit_auto));
                st.down_cell.set(fmtRate(&b2, @intFromFloat(@as(f64, @floatFromInt(rrate.down)) * scale), g_cfg.speed_unit_auto));
                if (st.msg_left > 0) st.msg_left -= 1;
                if (now_ms - g_log_last >= 10000) {
                    g_log_last = now_ms;
                    const ms = memStat();
                    logWrite("poll #{d} online={} status={s} nodes={d} mem={d}/{d}MB", .{ g_log_tick, st.online, st.status.slice(), st.nodes_n, ms.ws / (1 << 20), ms.priv / (1 << 20) });
                    g_log_tick += 1;
                }
            }
            hoverCheck(hwnd);
            topmostGuard(hwnd);
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_DISPLAYCHANGE => {
            // 显示模式刚变，Z-order 极可能已被重建，立即修复而不等下一次巡检。
            reassertTopmost(hwnd, "displaychange", 0);
            return 0;
        },
        WM_LBUTTONDOWN => {
            // drag the whole window from anywhere on the panel
            var sc = win.POINT{ .x = @intCast(lp & 0xFFFF), .y = @intCast((lp >> 16) & 0xFFFF) };
            _ = win.ClientToScreen(hwnd, &sc);
            const nc_lp: win.LPARAM = (@as(win.LPARAM, @intCast(sc.y)) << 16) | @as(win.LPARAM, @intCast(sc.x));
            _ = win.ReleaseCapture();
            _ = win.SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, nc_lp);
            return 0;
        },
        WM_RBUTTONDOWN => {
            const x: i32 = @intCast(lp & 0xFFFF);
            const y: i32 = @intCast((lp >> 16) & 0xFFFF);
            menuForGroup(hwnd, .{ .x = x, .y = y });
            return 0;
        },
        WM_MOUSEMOVE => {
            if (!g_ui.hovered) {
                g_ui.hovered = true;
                applyHover(hwnd);
            }
            return 0;
        },
        WM_DESTROY => {
            const ms = memStat();
            logWrite("wm_destroy: shutting down (mem={d}/{d}MB)", .{ ms.ws / (1 << 20), ms.priv / (1 << 20) });
            // stop the background worker and join before tearing down
            g_quitting.store(true, .release);
            _ = win.SetEvent(g_job_ev);
            if (g_worker_thread) |t| {
                t.join();
                g_worker_thread = null;
            }
            // 退出时还原网络环境：核心仍在则尽力关 TUN，并清掉系统代理，避免残留劫持连接。
            if (g_state.online) {
                var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer tmp_arena.deinit();
                const c = clientFor(tmp_arena.allocator());
                if (readTunLive().enable) c.setTun(false) catch {};
            }
            if (system_win.sysProxyEnabled()) system_win.setSysProxy(g_state.mixed_port, false);
            proc.saveWindowPos(hwnd, g_exe_dir[0..g_exe_dir_len]); // remember where the panel was for next launch
            win.PostQuitMessage(0);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

// ---------------- config / yaml discovery ----------------
pub fn main() void {
    // DPI awareness: without it Windows bitmap-stretches the whole window (blurry at >100%)
    _ = win.SetProcessDpiAwarenessContext(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4))))); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (best effort)
    g_cfg.dpi_scale = @as(f32, @floatFromInt(win.GetDpiForSystem())) / 96.0;
    g_cfg.ls = g_cfg.dpi_scale;
    // ------- locate config yaml & parse api info -------
    var exe_buf: [1024]u16 = undefined;
    const n = win.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    var exe_path: [1024]u8 = undefined;
    var exe_len: usize = 0;
    for (exe_buf[0..n]) |ch| {
        if (ch > 0x7f or exe_len >= exe_path.len) break;
        exe_path[exe_len] = @intCast(ch);
        exe_len += 1;
    }
    // exe directory
    const exe_dir = proc.dirOf(exe_path[0..exe_len]);
    var yaml_path_buf: [512]u8 = undefined;
    const yaml_path = proc.findYaml(exe_dir, &yaml_path_buf);
    {
        // persist paths for core spawning
        const nself = @min(exe_len, g_self_abs.len);
        @memcpy(g_self_abs[0..nself], exe_path[0..nself]);
        g_self_abs_len = nself;
        const n2 = @min(exe_dir.len, g_exe_dir.len);
        @memcpy(g_exe_dir[0..n2], exe_dir[0..n2]);
        g_exe_dir_len = n2;
        if (yaml_path) |yp| {
            const yn = @min(yp.len, g_yaml_abs.len);
            @memcpy(g_yaml_abs[0..yn], yp[0..yn]);
            g_yaml_len = yn;
        }
    }
    // api_info 的 host/secret 是 arena 所有的切片：arena 必须活到拷进 g_state 之后，
    // 所以解析与拷贝共用同一个块作用域。（曾经把 arena 的 deinit 放在内层 if 里，
    // 出块即释放 → 拷贝时读到已 unmap 的页，启动直接 AV：只要配置里 external-controller
    // 写了具体主机或 secret 非空就必崩，window 都建不起来。）
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var api_info: config_mod.ApiInfo = .{};
        if (yaml_path) |yp| {
            if (proc.readFileBytes(std.heap.page_allocator, yp, 1 << 20)) |text| {
                defer std.heap.page_allocator.free(text);
                api_info = config_mod.parseMihomoYaml(arena.allocator(), text) catch .{};
            } else |_| {}
        }
        // copy api info into g_state
        const st = &g_state;
        if (api_info.host.len == 0) api_info.host = "127.0.0.1";
        const hn = @min(api_info.host.len, st.api_host.len);
        @memcpy(st.api_host[0..hn], api_info.host[0..hn]);
        st.api_host_len = @intCast(hn);
        st.api_port = api_info.port;
        const sl = @min(api_info.secret.len, st.secret.len);
        @memcpy(st.secret[0..sl], api_info.secret[0..sl]);
        st.secret_len = @intCast(sl);
        st.mixed_port = if (api_info.mixed_port != 0) api_info.mixed_port else 10809;
    }

    // ------- create window -------
    const inst = win.GetModuleHandleW(null);
    g_cfg.load(g_exe_dir[0..g_exe_dir_len]);
    g_meter.sel = g_cfg.nic_ifindex; // 同步网卡选择到计量器
    // TUN 不做任何启动恢复：开机状态只有一个来源——config.yaml 的 `tun.enable`（核心
    // 启动时自己读，早于它自己的首拨/组测速），控件启动时不发任何 TUN 请求。菜单里的开关
    // 只作用于本次运行（`PATCH /configs`），由此产生的自环由 workerHeal 兜。见 AGENTS.md。
    {
        const ms = memStat();
        // 记下实际用的哪份主配置（findYaml 有多个候选目录，一眼能看出命中哪里）
        const ypath = g_yaml_abs[0..g_yaml_len];
        const ybase = if (std.mem.lastIndexOfScalar(u8, ypath, '\\')) |si|
            ypath[si + 1 ..]
        else if (ypath.len > 0) ypath else "none";
        logWrite("boot nic={d} refresh_ms={d} unit_auto={d} topguard={d} cfg={s} mem={d}/{d}MB", .{ g_cfg.nic_ifindex, g_cfg.speed_refresh_ms, @intFromBool(g_cfg.speed_unit_auto), g_cfg.topmost_guard_ms, ybase, ms.ws / (1 << 20), ms.priv / (1 << 20) });
    }
    g_ui.font = win.CreateFontW(-scal(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, @ptrCast(&g_cfg.face_w));
    g_ui.font_mid = win.CreateFontW(-scal(15), 0, 0, 0, 600, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, &FONT_E); // numbers, same family as arrows
    g_ui.font_bold = win.CreateFontW(-scal(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, &FONT_E); // arrows
    g_ui.bg = win.CreateSolidBrush(g_cfg.c_bg);
    var cls = std.mem.zeroes(win.WNDCLASSEXW);
    cls.cbSize = @sizeOf(win.WNDCLASSEXW);
    cls.lpfnWndProc = wndproc;
    cls.hInstance = inst;
    cls.hCursor = win.LoadCursorW(inst, null);
    cls.hbrBackground = g_ui.bg;
    cls.lpszClassName = &CLASS_W;
    _ = win.RegisterClassExW(&cls);
    // restore last window position from conf (physical px); fall back to default
    var win_x: i32 = scal(140);
    var win_y: i32 = scal(140);
    if (g_cfg.win_pos_ct == 2) {
        win_x = g_cfg.win_x;
        win_y = g_cfg.win_y;
    }
    g_ui.w = scal(g_cfg.fold_w); // needed by CreateWindowExW and by WM_PAINT's BitBlt
    g_ui.h = scal(g_cfg.norm_h);
    g_ui.hwnd = win.CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        &CLASS_W,
        &TITLE_W,
        WS_POPUP | WS_VISIBLE,
        win_x, win_y, g_ui.w, g_ui.h,
        0, null, inst, null,
    );
    _ = win.SetLayeredWindowAttributes(g_ui.hwnd, 0, g_cfg.alpha, LWA_ALPHA);
    _ = win.ShowWindow(g_ui.hwnd, SW_SHOW);
    // 启动时按 conf 恢复系统代理（只写注册表指向 mixed-port，无需核心在线）。
    if (g_cfg.sysproxy) system_win.setSysProxy(g_state.mixed_port, true);
    // first frame paints immediately ("waiting/starting core"); poll driven by timer
    g_job_ev = win.CreateEventW(null, 1, 0, null); // manual-reset, initially non-signaled
    if (std.Thread.spawn(.{}, workerMain, .{})) |t| {
        g_worker_thread = t;
    } else |_| {} // 后台线程失败不阻断 UI，仅失去后台化
    _ = win.SetTimer(g_ui.hwnd, POLL_TIMER, g_cfg.speed_refresh_ms, null);
    _ = win.SetTimer(g_ui.hwnd, HOVER_TIMER, HOVER_MS, null);
    _ = win.InvalidateRect(g_ui.hwnd, null, 0);

    var msg: win.MSG = undefined;
    while (true) {
        const r = win.GetMessageW(&msg, 0, 0, 0);
        if (r == 0) break;
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }
}
