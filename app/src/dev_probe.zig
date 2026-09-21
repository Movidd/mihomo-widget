// probe/main.zig — dev-only console probe exercising mihomo.zig against a
// live controller. Built as a console exe; not part of the shipped app.
const std = @import("std");
const mihomo = @import("mihomo.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c = mihomo.Client.init(arena, "localhost", 9090, "");

    const ver = try c.version();
    std.debug.print("version: {s}\n", .{ver});

    const snap = try c.snapshot();
    std.debug.print("groups({d}): ", .{snap.groups.len});
    for (snap.groups) |g| std.debug.print("{s}({s}) ", .{ g.name, @tagName(g.kind) });
    std.debug.print("\nnodes({d}): ", .{snap.nodes.len});
    var count: usize = 0;
    for (snap.nodes) |n| {
        if (count >= 12) break;
        std.debug.print("{s} ", .{n});
        count += 1;
    }
    std.debug.print("\n", .{});

    if (snap.groups.len > 0) {
        var g = snap.groups[0];
        try c.groupDetail(&g);
        std.debug.print("group[0] {s} now={?s} all({d}): ", .{ g.name, g.now, g.all.len });
        for (g.all) |n| std.debug.print("{s} ", .{n});
        std.debug.print("\n", .{});
    }

    if (try c.delayOf("AnyTLS-hk", "http://www.gstatic.com/generate_204", 5000)) |ms| {
        std.debug.print("delay AnyTLS-hk: {d}ms\n", .{ms});
    } else {
        std.debug.print("delay AnyTLS-hk: unreachable\n", .{});
    }
}
