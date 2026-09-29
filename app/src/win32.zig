// ---------------- types (win32) ----------------
pub const HWND = isize;
pub const HDC = isize;
pub const HINSTANCE = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HBITMAP = ?*anyopaque;
pub const HFONT = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const BOOL = i32;
pub const WNDPROC = *const fn (hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.c) LRESULT;

// process memory counters (psapi) for diagnostics/logging
pub const SIZE_T = usize;
pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const POINT = extern struct { x: i32, y: i32 };
pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};
pub const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
};
pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
    hIconSm: ?*anyopaque,
};
pub const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32, dwY: u32, dwXSize: u32, dwYSize: u32, dwXCountChars: u32, dwYCountChars: u32,
    dwFillAttribute: u32, dwFlags: u32, wShowWindow: u16, cbReserved2: u16,
    lpReserved2: ?*anyopaque, hStdInput: ?*anyopaque, hStdOutput: ?*anyopaque, hStdError: ?*anyopaque,
};
pub const PROCESS_INFORMATION = extern struct { hProcess: ?*anyopaque, hThread: ?*anyopaque, dwProcessId: u32, dwThreadId: u32 };
// ---------------- user32 externs ----------------
pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) u16;
pub extern "user32" fn SetWindowPos(h: HWND, after: HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) BOOL;
pub extern "user32" fn TrackMouseEvent(e: *TRACKMOUSEEVENT) BOOL;
pub extern "user32" fn GetCursorPos(pt: *POINT) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rc: *RECT) BOOL;
pub extern "user32" fn GetDpiForSystem() u32;
pub extern "user32" fn SetProcessDpiAwarenessContext(ctx: ?*anyopaque) BOOL;
pub extern "user32" fn CreateWindowExW(ex: u32, cls: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: HWND, menu: ?*anyopaque, inst: HINSTANCE, param: ?*anyopaque) HWND;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: u32, alpha: u8, flags: u32) BOOL;
pub extern "user32" fn SetTimer(hwnd: HWND, id: usize, ms: u32, cb: ?*anyopaque) usize;
pub extern "user32" fn InvalidateRect(hwnd: HWND, rc: ?*const RECT, erase: BOOL) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, ps: *PAINTSTRUCT) BOOL;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: HWND, lo: u32, hi: u32) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) LRESULT;
pub extern "user32" fn PostQuitMessage(code: i32) void;
pub extern "user32" fn DestroyWindow(hwnd: HWND) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) LRESULT;
pub extern "user32" fn ReleaseCapture() BOOL;
pub extern "user32" fn SendMessageW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) LRESULT;
pub extern "user32" fn LoadCursorW(inst: HINSTANCE, name: ?*anyopaque) ?*anyopaque;
pub extern "user32" fn CreatePopupMenu() HMENU;
pub extern "user32" fn AppendMenuW(menu: HMENU, flags: u32, id: usize, text: ?[*:0]const u16) BOOL;
pub extern "advapi32" fn RegOpenKeyExW(key: usize, sub: [*:0]const u16, opt: u32, sam: u32, out: *usize) u32;
pub extern "advapi32" fn RegQueryValueExW(key: usize, name: [*:0]const u16, res: ?*u32, typ: ?*u32, data: ?*anyopaque, size: ?*u32) u32;
pub extern "advapi32" fn RegSetValueExW(key: usize, name: [*:0]const u16, res: u32, typ: u32, data: ?*const anyopaque, size: u32) u32;
pub extern "advapi32" fn RegCloseKey(key: usize) u32;
pub extern "advapi32" fn RegDeleteValueW(key: usize, name: [*:0]const u16) u32;
pub extern "wininet" fn InternetSetOptionW(h: ?*anyopaque, opt: u32, buf: ?*const anyopaque, len: u32) BOOL;
pub extern "user32" fn TrackPopupMenu(menu: HMENU, flags: u32, x: i32, y: i32, reserved: i32, hwnd: HWND, rect: ?*const RECT) BOOL;
pub extern "user32" fn DestroyMenu(menu: HMENU) BOOL;
pub extern "user32" fn ClientToScreen(hwnd: HWND, pt: *POINT) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) BOOL;
pub extern "user32" fn GetForegroundWindow() HWND;
pub extern "user32" fn IsIconic(hwnd: HWND) BOOL;
pub extern "user32" fn GetSystemMetrics(index: i32) i32;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, idx: i32) isize;
pub extern "user32" fn WindowFromPoint(pt: POINT) HWND;
pub extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) BOOL;
pub extern "user32" fn CheckMenuItem(menu: HMENU, id: usize, flags: u32) BOOL;
pub extern "user32" fn SetMenuDefaultItem(menu: HMENU, item: u32, flags: u32) BOOL;

// ---------------- kernel32 externs ----------------
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) HINSTANCE;
pub extern "kernel32" fn GetTickCount64() u64;


pub extern "kernel32" fn GetLastError() u32;
pub extern "kernel32" fn Sleep(ms: u32) void;
pub extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) isize;
pub extern "kernel32" fn TerminateProcess(h: isize, code: u32) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(h: isize, code: *u32) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(mod: HINSTANCE, buf: [*]u16, size: u32) u32;
pub extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, tmpl: ?*anyopaque) isize;
pub extern "kernel32" fn ReadFile(h: isize, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) BOOL;
pub extern "kernel32" fn WriteFile(h: isize, buf: [*]const u8, to_write: u32, written: *u32, ov: ?*anyopaque) BOOL;
pub extern "kernel32" fn CloseHandle(h: isize) BOOL;
pub extern "kernel32" fn CreateEventW(sec: ?*anyopaque, manual_reset: i32, initial_state: i32, name: ?[*:0]const u16) isize;
pub extern "kernel32" fn SetEvent(h: isize) BOOL;
pub extern "kernel32" fn ResetEvent(h: isize) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: isize, ms: u32) u32;
pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) void;
pub extern "kernel32" fn GetFileSizeEx(h: isize, size: *i64) BOOL;
pub extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: ?*anyopaque, pi: *anyopaque) BOOL;
pub extern "kernel32" fn GetCurrentProcess() ?*anyopaque;

// ---------------- psapi externs (memory diagnostics) ----------------
pub extern "psapi" fn GetProcessMemoryInfo(proc: ?*anyopaque, pmc: *PROCESS_MEMORY_COUNTERS, cb: u32) BOOL;

// ---------------- gdi32 externs ----------------
pub extern "gdi32" fn CreateCompatibleDC(hdc: HDC) HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, w: i32, h: i32) HBITMAP;
pub extern "gdi32" fn SelectObject(hdc: HDC, obj: ?*anyopaque) ?*anyopaque;
pub extern "gdi32" fn DeleteObject(obj: ?*anyopaque) BOOL;
pub extern "gdi32" fn DeleteDC(hdc: HDC) BOOL;
pub extern "gdi32" fn BitBlt(dst: HDC, x: i32, y: i32, w: i32, h: i32, src: HDC, sx: i32, sy: i32, op: u32) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: u32) HBRUSH;
pub extern "gdi32" fn FillRect(hdc: HDC, rc: *const RECT, brush: HBRUSH) i32;
pub extern "gdi32" fn CreateFontW(h: i32, w: i32, esc: i32, orient: i32, weight: i32, italic: u32, ul: u32, strike: u32, charset: u32, outprec: u32, clipprec: u32, qual: u32, pitch: u32, face: [*:0]const u16) HFONT;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, str: [*]const u16, len: i32) BOOL;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) u32;
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, str: [*]const u16, len: i32, sz: *EXTENT) BOOL;
pub extern "gdi32" fn GetTextMetricsW(hdc: HDC, tm: *TEXTMETRICW) BOOL;

pub const TEXTMETRICW = extern struct {
    tmHeight: i32,
    tmAscent: i32,
    tmDescent: i32,
    tmInternalLeading: i32,
    tmExternalLeading: i32,
    tmAveCharWidth: i32,
    tmMaxCharWidth: i32,
    tmWeight: i32,
    tmOverhang: i32,
    tmDigitizedAspectX: i32,
    tmDigitizedAspectY: i32,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

pub const EXTENT = extern struct { cx: i32, cy: i32 };
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) i32;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) u32;

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};

// ---------------- fullscreen detection ----------------
// （主屏矩形判定在 main.zig 的 fgFullscreen()；user32 externs 见上）

