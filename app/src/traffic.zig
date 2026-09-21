// traffic.zig — whole-machine NIC byte counters via GetIfTable2 (diff-based rate).
const std = @import("std");
const win32 = @import("win32");
const ip = win32.iphlpapi;
const iph = win32.network_management.ip_helper;

pub const Rate = struct { up: u64, down: u64 }; // bytes since last tick

pub const MAX_NICS = 16;

/// A selectable NIC shown in the "Network Interface" submenu. `name` is the
/// driver description (ASCII) so it stays readable in the menu; `ifindex` is
/// the stable interface index persisted to conf.
pub const Nic = struct {
    ifindex: u32,
    name: [80]u8 = undefined,
    name_len: u8 = 0,

    pub fn slice(n: *const Nic) []const u8 {
        return n.name[0..n.name_len];
    }
};

const LOOPBACK_TYPE: u32 = 24; // IF_TYPE_SOFTWARE_LOOPBACK
const TUNNEL_TYPE: u32 = 131; // IF_TYPE_TUNNEL, e.g. mihomo's "Meta" TUN NIC
const OP_UP: i32 = 1; // IF_OPER_STATUS.Up

/// Only real, physical interfaces. Virtual / tunnel adapters (mihomo TUN,
/// Hyper-V vEthernet, VPN) either report a non-physical ifType or carry no
/// MAC address; counting them double-counts traffic (app bytes go into the
/// TUN and out the physical NIC) and inflates the displayed speed.
fn isRealNic(r: *const iph.MIB_IF_ROW2) bool {
    if (r.Type == LOOPBACK_TYPE or r.Type == TUNNEL_TYPE) return false;
    switch (r.Type) {
        6, 23, 71, 132, 133 => {}, // Ethernet, PPP, 802.11, 802.11 radio mgr, LAG
        else => return false,
    }
    if (r.PhysicalAddressLength == 0) return false;
    const n: usize = @intCast(@min(r.PhysicalAddressLength, @as(u32, @intCast(r.PhysicalAddress.len))));
    for (r.PhysicalAddress[0..n]) |b| {
        if (b != 0) return true;
    }
    return false;
}

/// Case-insensitive check for filter/virtual markers in an adapter description.
/// GetIfTable2 lists every NDIS filter binding (WFP / QoS / 802.3 / WiFi filter
/// drivers) as a separate row that shares the parent NIC byte counters, so a
/// bare type+MAC check would double-count. These rows are named like
/// "<nic>-<FilterName>-0000" and described with "Filter"/"Packet Scheduler";
/// virtual adapters (Hyper-V vEthernet / Wi-Fi Direct) carry "Virtual".
fn isFilterishOrVirtual(r: *const iph.MIB_IF_ROW2) bool {
    const markers = [_][]const u8{ "filter", "packet scheduler", "virtual", "wfp" };
    var ascii: [128]u8 = undefined;
    const len = widesToAscii(&r.Description, &ascii);
    const str = ascii[0..len];
    for (markers) |m| {
        if (containsLower(str, m)) return true;
    }
    return false;
}

/// A NIC worth listing / counting: physically typed, has a MAC, is up, and is
/// not a filter binding or a virtual adapter.
fn isCandidate(r: *const iph.MIB_IF_ROW2) bool {
    if (!isRealNic(r)) return false;
    if (@as(i32, @intCast(@intFromEnum(r.OperStatus))) != OP_UP) return false;
    if (isFilterishOrVirtual(r)) return false;
    return true;
}

/// Fill `cands` with the up, real NICs of the machine and return the count.
/// Callers use this to build the "Network Interface" selection submenu.
pub fn listNics(cands: *[MAX_NICS]Nic) usize {
    const tbl = getTable() orelse return 0;
    defer _ = ip.FreeMibTable(@ptrCast(tbl));
    const rows = @as([*]iph.MIB_IF_ROW2, @ptrCast(&tbl.Table))[0..tbl.NumEntries];
    var n: usize = 0;
    var ab: [128]u8 = undefined;
    for (rows) |r| {
        if (!isCandidate(&r)) continue;
        if (n >= MAX_NICS) break;
        cands[n].ifindex = r.InterfaceIndex;
        const l = @min(widesToAscii(&r.Description, &ab), cands[n].name.len);
        @memcpy(cands[n].name[0..l], ab[0..l]);
        cands[n].name_len = @intCast(l);
        n += 1;
    }
    return n;
}

pub const Meter = struct {
    last_up: u64 = 0,
    last_dn: u64 = 0,
    first: bool = true,
    /// 0 = sum all physical candidates; otherwise only the chosen interface
    /// index (set from conf / the Network Interface submenu).
    sel: u32 = 0,

    /// Sum the delta since the previous call over the selected interface
    /// (sel != 0) or over all physical candidates (sel == 0).
    pub fn tick(self: *Meter) !Rate {
        const tbl = getTable() orelse return error.NoTable;
        defer _ = ip.FreeMibTable(@ptrCast(tbl));
        const rows = @as([*]iph.MIB_IF_ROW2, @ptrCast(&tbl.Table))[0..tbl.NumEntries];
        var up: u64 = 0;
        var dn: u64 = 0;
        if (self.sel != 0) {
            for (rows) |r| {
                if (r.InterfaceIndex == self.sel) {
                    up += r.OutOctets;
                    dn += r.InOctets;
                    break;
                }
            }
        } else {
            for (rows) |r| {
                if (!isCandidate(&r)) continue;
                up += r.OutOctets; // outbound = upload
                dn += r.InOctets; // inbound = download
            }
        }
        if (self.first) {
            self.first = false;
            self.last_up = up;
            self.last_dn = dn;
            return .{ .up = 0, .down = 0 };
        }
        const ru = up -| self.last_up;
        const rd = dn -| self.last_dn;
        self.last_up = up;
        self.last_dn = dn;
        return .{ .up = ru, .down = rd };
    }
};

/// Allocate the interface table. The caller MUST FreeMibTable the returned
/// pointer when done. MIB_IF_TABLE2.Table is a [1]MIB_IF_ROW2 placeholder in
/// the bindings, but the OS allocates NumEntries contiguous rows; index
/// through the base pointer to read the full table (otherwise this panics on
/// machines with >1 NIC).
fn getTable() ?*iph.MIB_IF_TABLE2 {
    var tbl: ?*iph.MIB_IF_TABLE2 = null;
    if (ip.GetIfTable2(&tbl) != .SUCCESS or tbl == null) return null;
    return tbl.?;
}

/// Widen a [N]u16 field (null-terminated) to ASCII, non-ASCII chars become '?'.
fn widesToAscii(p: [*]const u16, out: *[128]u8) usize {
    var i: usize = 0;
    while (i < 127) : (i += 1) {
        const c = p[i];
        if (c == 0) break;
        out[i] = if (c < 128) @intCast(c) else '?';
    }
    return i;
}

fn containsLower(s: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= s.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = asciiLower(s[i + j]);
            const b = asciiLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

test "import builds" {
    _ = Meter{};
    _ = Nic{ .ifindex = 0 };
}
