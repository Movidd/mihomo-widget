// ui_draw.zig — GDI drawing helpers for the widget panel.
// Stateless on purpose: every layout-dependent value (scale, window width,
// background color, fonts) is passed in via DrawCtx, so this module holds no
// hidden globals and can be reasoned about in isolation.
const win = @import("win32.zig");

const OPAQUE: i32 = 2;

pub const DrawFonts = struct {
    normal: win.HFONT,
    mid: win.HFONT,
    bold: win.HFONT,
};

pub const DrawCtx = struct {
    scale: f32, // layout scale (= g_ls, dpi/96 * font_size/15)
    win_w: i32, // current panel width in scaled px (= g_ui.w)
    bg: u32, // background COLORREF, used as the text backdrop
    fonts: DrawFonts,
};

/// Physical px = round(logical * scale); the single implementation (main.zig's
/// scal() delegates here so the renderer and the layout math cannot drift).
pub fn scaled(v: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * scale));
}

pub fn fill_rect(hdc: win.HDC, x: i32, y: i32, w: i32, h: i32, brush: win.HBRUSH) void {
    var rc = win.RECT{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    _ = win.FillRect(hdc, &rc, brush);
}

/// ASCII + common UTF-8 (BMP, e.g. arrows) to UTF-16; anything else -> '?'.
fn textWide(buf: []u16, s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < buf.len) {
        const c = s[i];
        if (c < 0x80) {
            buf[n] = c;
            i += 1;
            n += 1;
            continue;
        }
        var cp: u21 = 0;
        var adv: usize = 0;
        if (c >= 0xC2 and c <= 0xDF and i + 1 < s.len) {
            cp = (@as(u21, c) & 0x1F) << 6 | (s[i + 1] & 0x3F);
            adv = 2;
        } else if (c >= 0xE0 and c <= 0xEF and i + 2 < s.len) {
            cp = (@as(u21, c) & 0x0F) << 12 | (@as(u21, s[i + 1]) & 0x3F) << 6 | (s[i + 2] & 0x3F);
            adv = 3;
        } else if (c >= 0xF0 and c <= 0xF7 and i + 3 < s.len) {
            cp = (@as(u21, c) & 0x07) << 18 | (@as(u21, s[i + 1]) & 0x3F) << 12 | (@as(u21, s[i + 2]) & 0x3F) << 6 | (s[i + 3] & 0x3F);
            adv = 4;
        } else {
            buf[n] = '?';
            i += 1;
            n += 1;
            continue;
        }
        buf[n] = if (cp > 0xFFFF) '?' else @intCast(cp);
        i += adv;
        n += 1;
    }
    return n;
}

pub fn text_at(hdc: win.HDC, x: i32, y: i32, s: []const u8, color: u32, ctx: DrawCtx) void {
    if (s.len == 0) return;
    var wide: [256]u16 = undefined;
    const n = textWide(&wide, s);
    _ = win.SetTextColor(hdc, color);
    _ = win.SetBkMode(hdc, OPAQUE);
    _ = win.SetBkColor(hdc, ctx.bg);
    _ = win.TextOutW(hdc, x, y, &wide, @intCast(n));
}

/// Draw a segment with the currently selected font (width: use measure()).
fn putSeg(hdc: win.HDC, x: i32, y: i32, s: []const u8, color: u32) void {
    var wide: [256]u16 = undefined;
    const n = textWide(&wide, s);
    if (n == 0) return;
    _ = win.SetTextColor(hdc, color);
    _ = win.TextOutW(hdc, x, y, &wide, @intCast(n));
}

/// Measure text width with the currently selected font (does not draw).
fn measure(hdc: win.HDC, s: []const u8) i32 {
    if (s.len == 0) return 0;
    var wide: [256]u16 = undefined;
    const n = textWide(&wide, s);
    var ext = win.EXTENT{ .cx = 0, .cy = 0 };
    _ = win.GetTextExtentPoint32W(hdc, &wide, @intCast(n), &ext);
    return ext.cx;
}

/// Draw one speed column: the arrow is pinned to the left edge, and the whole
/// "<value> <unit>" text (unit may be KB/MB/GB when speed_unit_auto=1) is
/// right-aligned to the column's right edge, so a changing digit count never
/// shifts the arrows.
fn drawRateColumn(hdc: win.HDC, col_x: i32, col_w: i32, y: i32, arrow: []const u8, val: []const u8, color: u32, ctx: DrawCtx) void {
    _ = win.SelectObject(hdc, @ptrCast(ctx.fonts.bold)); // Segoe UI Emoji arrows
    putSeg(hdc, col_x, y, arrow, color);
    const arrow_w = measure(hdc, arrow);

    _ = win.SelectObject(hdc, @ptrCast(ctx.fonts.mid)); // Segoe UI semibold numbers
    const col_end = col_x + col_w;
    const vw = measure(hdc, val); // val already contains "<value> <unit>"
    var vx = col_end - vw; // right-align value+unit to the right edge
    const min_x = col_x + arrow_w;
    if (vx < min_x) vx = min_x; // too wide: fall back to the left edge
    putSeg(hdc, vx, y, val, color);
}

/// Mixed-font speed row: arrows + Segoe UI numbers. The row sits at the
/// configurable top offset (speed_top, logical px) instead
/// of auto-centering, so the vertical position is predictable in both the
/// collapsed and expanded states. The panel is split into two equal columns so
/// the "▲"/"▼" arrows hold fixed positions while the value+unit text (unit may
/// be KB/MB/GB when speed_unit_auto=1) is right-aligned and grows/shrinks freely.
pub fn drawSpeedAt(mem: win.HDC, x0: i32, y0: i32, up: []const u8, dn: []const u8, color: u32, ctx: DrawCtx) void {
    const gap = scaled(14, ctx.scale);
    const usable = ctx.win_w - 2 * x0 - gap;
    const col_w = @max(@divTrunc(usable, 2), 1);
    drawRateColumn(mem, x0, col_w, y0, "▲ ", up, color, ctx);
    drawRateColumn(mem, x0 + col_w + gap, col_w, y0, "▼ ", dn, color, ctx);
    _ = win.SelectObject(mem, @ptrCast(ctx.fonts.normal));
}
