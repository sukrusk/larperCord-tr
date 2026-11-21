//! Captura de janela nativa por Windows.Graphics.Capture (WinRT ABI via COM)
//! compartilhando `dxgi_cap.Nv12GpuCtx` e enumeração segura de janelas visíveis.
const std = @import("std");
const c = @import("c");
const com = @import("com.zig");
const dxgi_cap = @import("dxgi_cap.zig");
const media_if = @import("../media_if.zig");
const video_cfg = @import("../../core/video_cfg.zig");

const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const DWORD = com.DWORD;
const HWND = com.HWND;
const GUID = com.GUID;
const RECT = com.RECT;
const HSTRING = com.HSTRING;

const EnumWindowsFn = *const fn (*const fn (HWND, isize) callconv(.winapi) BOOL, isize) callconv(.winapi) BOOL;
const IsWindowVisibleFn = *const fn (HWND) callconv(.winapi) BOOL;
const IsIconicFn = *const fn (HWND) callconv(.winapi) BOOL;
const GetWindowTextWFn = *const fn (HWND, [*]u16, i32) callconv(.winapi) i32;
const GetWindowRectFn = *const fn (HWND, *RECT) callconv(.winapi) BOOL;
const GetWindowThreadProcessIdFn = *const fn (HWND, *DWORD) callconv(.winapi) DWORD;
const DwmGetWindowAttributeFn = *const fn (HWND, DWORD, *anyopaque, DWORD) callconv(.winapi) HRESULT;
const OpenProcessFn = *const fn (DWORD, BOOL, DWORD) callconv(.winapi) ?*anyopaque;
const QueryFullProcessImageNameWFn = *const fn (?*anyopaque, DWORD, [*]u16, *DWORD) callconv(.winapi) BOOL;
const CloseHandleFn = *const fn (?*anyopaque) callconv(.winapi) BOOL;
const GetCurrentProcessIdFn = *const fn () callconv(.winapi) DWORD;

const RoInitializeFn = *const fn (i32) callconv(.winapi) HRESULT;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const WindowsCreateStringReferenceFn = *const fn ([*]const u16, u32, *[24]u8, *HSTRING) callconv(.winapi) HRESULT;
const CreateDirect3D11DeviceFromDXGIDeviceFn = *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT;

const EnumCtx = struct {
    out: []media_if.WindowTarget,
    count: usize = 0,
    self_pid: DWORD = 0,
    is_visible: IsWindowVisibleFn,
    is_iconic: IsIconicFn,
    get_text: GetWindowTextWFn,
    get_rect: GetWindowRectFn,
    get_pid: GetWindowThreadProcessIdFn,
    dwm_attr: ?DwmGetWindowAttributeFn,
    open_proc: ?OpenProcessFn = null,
    query_img: ?QueryFullProcessImageNameWFn = null,
    close_handle: ?CloseHandleFn = null,
};

fn fillExeName(ctx: *const EnumCtx, tgt: *media_if.WindowTarget, pid: DWORD) void {
    const op = ctx.open_proc orelse return;
    const qi = ctx.query_img orelse return;
    const ch = ctx.close_handle orelse return;
    if (pid == 0) return;
    // PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    const proc = op(0x1000, 0, pid) orelse return;
    defer _ = ch(proc);
    var path_w: [260]u16 = undefined;
    var cap: DWORD = path_w.len;
    if (qi(proc, 0, &path_w, &cap) == 0 or cap == 0) return;
    var path_utf8: [512]u8 = undefined;
    const ulen = std.unicode.utf16LeToUtf8(&path_utf8, path_w[0..@min(cap, path_w.len)]) catch return;
    const full = path_utf8[0..ulen];
    const base = if (std.mem.lastIndexOfScalar(u8, full, '\\')) |sep| full[sep + 1 ..] else full;
    const take = @min(base.len, tgt.exe_buf.len);
    @memcpy(tgt.exe_buf[0..take], base[0..take]);
    tgt.exe_len = @intCast(take);
}

fn enumWinCb(hwnd: HWND, lparam: isize) callconv(.winapi) BOOL {
    const ctx: *EnumCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (ctx.count >= ctx.out.len) return 0;
    if (ctx.is_visible(hwnd) == 0 or ctx.is_iconic(hwnd) != 0) return 1;

    if (ctx.dwm_attr) |dwm| {
        var cloaked: DWORD = 0;
        // DWMWA_CLOAKED = 14 (oculta aplicativos UWP suspensos em outras áreas virtuais).
        if (com.succeeded(dwm(hwnd, 14, &cloaked, @sizeOf(DWORD))) and cloaked != 0) return 1;
    }

    var pid: DWORD = 0;
    _ = ctx.get_pid(hwnd, &pid);
    if (ctx.self_pid != 0 and pid == ctx.self_pid) return 1;

    var title_u16: [96]u16 = undefined;
    const wlen = ctx.get_text(hwnd, &title_u16, title_u16.len);
    if (wlen <= 0) return 1;

    var rc: RECT = .{};
    if (ctx.get_rect(hwnd, &rc) == 0) return 1;
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    if (w < 64 or h < 64) return 1;

    var tgt: media_if.WindowTarget = .{
        .handle = @intFromPtr(hwnd),
        .pid = pid,
        .width = @intCast(w),
        .height = @intCast(h),
    };
    const ulen = std.unicode.utf16LeToUtf8(&tgt.title_buf, title_u16[0..@intCast(wlen)]) catch 0;
    if (ulen == 0) return 1;
    tgt.title_len = @intCast(ulen);
    fillExeName(ctx, &tgt, pid);
    ctx.out[ctx.count] = tgt;
    ctx.count += 1;
    return 1;
}

/// Enumera janelas visíveis elegíveis para captura.
pub fn enumerateWindows(out: []media_if.WindowTarget) usize {
    const user32 = c.SDL_LoadObject("user32.dll") orelse return 0;
    defer c.SDL_UnloadObject(user32);

    const dwmapi = c.SDL_LoadObject("dwmapi.dll");
    defer if (dwmapi) |d| c.SDL_UnloadObject(d);

    const k32 = c.SDL_LoadObject("kernel32.dll");
    defer if (k32) |k| c.SDL_UnloadObject(k);

    var self_pid: DWORD = 0;
    if (k32) |k| if (c.SDL_LoadFunction(k, "GetCurrentProcessId")) |fn_p| {
        const get_self: GetCurrentProcessIdFn = @ptrCast(@alignCast(fn_p));
        self_pid = get_self();
    };

    const enum_w: EnumWindowsFn = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "EnumWindows") orelse return 0));
    var ctx: EnumCtx = .{
        .out = out,
        .self_pid = self_pid,
        .is_visible = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "IsWindowVisible") orelse return 0)),
        .is_iconic = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "IsIconic") orelse return 0)),
        .get_text = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "GetWindowTextW") orelse return 0)),
        .get_rect = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "GetWindowRect") orelse return 0)),
        .get_pid = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "GetWindowThreadProcessId") orelse return 0)),
        .dwm_attr = if (dwmapi) |d| @ptrCast(@alignCast(c.SDL_LoadFunction(d, "DwmGetWindowAttribute"))) else null,
        .open_proc = if (k32) |k| @ptrCast(@alignCast(c.SDL_LoadFunction(k, "OpenProcess"))) else null,
        .query_img = if (k32) |k| @ptrCast(@alignCast(c.SDL_LoadFunction(k, "QueryFullProcessImageNameW"))) else null,
        .close_handle = if (k32) |k| @ptrCast(@alignCast(c.SDL_LoadFunction(k, "CloseHandle"))) else null,
    };
    _ = enum_w(enumWinCb, @bitCast(@intFromPtr(&ctx)));
    return ctx.count;
}

pub fn windowProcessId(hwnd_int: u64) u32 {
    if (hwnd_int == 0) return 0;
    const user32 = c.SDL_LoadObject("user32.dll") orelse return 0;
    defer c.SDL_UnloadObject(user32);
    const get_pid: GetWindowThreadProcessIdFn = @ptrCast(@alignCast(c.SDL_LoadFunction(user32, "GetWindowThreadProcessId") orelse return 0));
    var pid: DWORD = 0;
    _ = get_pid(@ptrFromInt(@as(usize, @intCast(hwnd_int))), &pid);
    return pid;
}

pub const Capturer = struct {
    gpu: dxgi_cap.Nv12GpuCtx,
    combase_dll: ?*c.SDL_SharedObject = null,
    winrt_dev: ?*anyopaque = null,
    item: ?*anyopaque = null,
    pool: ?*anyopaque = null,
    session: ?*anyopaque = null,
    win_w: u16 = 0,
    win_h: u16 = 0,

    pub fn open(hwnd_int: u64, target_res: video_cfg.Resolution) !Capturer {
        return openTarget(hwnd_int, false, target_res);
    }

    pub fn openMonitor(hmonitor_int: u64, target_res: video_cfg.Resolution) !Capturer {
        return openTarget(hmonitor_int, true, target_res);
    }

    fn openTarget(handle_int: u64, comptime is_monitor: bool, target_res: video_cfg.Resolution) !Capturer {
        if (handle_int == 0) return error.InvalidTarget;
        const handle: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(handle_int)));

        var self: Capturer = .{
            .gpu = try dxgi_cap.Nv12GpuCtx.init(0, target_res),
        };
        errdefer self.deinit();

        self.combase_dll = c.SDL_LoadObject("combase.dll") orelse return error.CombaseMissing;
        const combase = self.combase_dll.?;
        const ro_init: RoInitializeFn = @ptrCast(@alignCast(c.SDL_LoadFunction(combase, "RoInitialize") orelse return error.RoInitMissing));
        const ro_factory: RoGetActivationFactoryFn = @ptrCast(@alignCast(c.SDL_LoadFunction(combase, "RoGetActivationFactory") orelse return error.RoFactoryMissing));
        const win_str_ref: WindowsCreateStringReferenceFn = @ptrCast(@alignCast(c.SDL_LoadFunction(combase, "WindowsCreateStringReference") orelse return error.WinStrMissing));

        // RO_INIT_MULTITHREADED = 1 (ignora S_FALSE / RPC_E_CHANGED_MODE se já inicializado).
        _ = ro_init(1);

        const d3d11 = self.gpu.d3d11_dll orelse return error.D3d11Missing;
        const create_winrt_dev: CreateDirect3D11DeviceFromDXGIDeviceFn = @ptrCast(@alignCast(c.SDL_LoadFunction(d3d11, "CreateDirect3D11DeviceFromDXGIDevice") orelse return error.WgcUnavailable));

        const dxgi_dev = com.queryInterface(self.gpu.device.?, anyopaque, &com.IID_IDXGIDevice) orelse return error.DxgiDevMissing;
        defer com.release(dxgi_dev);
        if (!com.succeeded(create_winrt_dev(dxgi_dev, &self.winrt_dev)) or self.winrt_dev == null) {
            return error.WgcDeviceFailed;
        }

        // Ativa GraphicsCaptureItem para a janela ou monitor alvo via IGraphicsCaptureItemInterop.
        const item_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Graphics.Capture.GraphicsCaptureItem");
        var hdr_item: [24]u8 align(8) = undefined;
        var hstr_item: HSTRING = null;
        if (!com.succeeded(win_str_ref(item_class.ptr, @intCast(item_class.len), &hdr_item, &hstr_item))) return error.WinStrFailed;

        var interop: ?*anyopaque = null;
        if (!com.succeeded(ro_factory(hstr_item, &com.IID_IGraphicsCaptureItemInterop, &interop)) or interop == null) {
            return error.WgcUnavailable;
        }
        defer com.release(interop);

        const slot_idx: usize = if (is_monitor) 4 else 3;
        const create_item = com.slot(interop.?, slot_idx, *const fn (*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(create_item(interop.?, handle, &com.IID_IGraphicsCaptureItem, &self.item)) or self.item == null) {
            return error.WgcCreateForWindowFailed;
        }

        // Lê tamanho inicial do GraphicsCaptureItem (slot 7 = get_Size -> u64 packed SizeInt32).
        const get_size = com.slot(self.item.?, 7, *const fn (*anyopaque, *u64) callconv(.winapi) HRESULT);
        var sz_packed: u64 = 0;
        if (!com.succeeded(get_size(self.item.?, &sz_packed))) return error.WgcSizeFailed;
        const sw: i32 = @bitCast(@as(u32, @truncate(sz_packed)));
        const sh: i32 = @bitCast(@as(u32, @truncate(sz_packed >> 32)));
        self.win_w = @intCast(@max(sw, 2));
        self.win_h = @intCast(@max(sh, 2));

        // Cria Direct3D11CaptureFramePool via CreateFreeThreaded (2 buffers em GPU).
        const pool_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Graphics.Capture.Direct3D11CaptureFramePool");
        var hdr_pool: [24]u8 align(8) = undefined;
        var hstr_pool: HSTRING = null;
        if (!com.succeeded(win_str_ref(pool_class.ptr, @intCast(pool_class.len), &hdr_pool, &hstr_pool))) return error.WinStrFailed;

        var statics2: ?*anyopaque = null;
        if (!com.succeeded(ro_factory(hstr_pool, &com.IID_IDirect3D11CaptureFramePoolStatics2, &statics2)) or statics2 == null) {
            return error.WgcStatics2Unavailable;
        }
        defer com.release(statics2);

        const create_ft = com.slot(statics2.?, 6, *const fn (*anyopaque, *anyopaque, i32, i32, u64, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(create_ft(statics2.?, self.winrt_dev.?, @intCast(com.DXGI_FORMAT_B8G8R8A8_UNORM), 2, sz_packed, &self.pool)) or self.pool == null) {
            return error.WgcPoolFailed;
        }

        const create_sess = com.slot(self.pool.?, 10, *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(create_sess(self.pool.?, self.item.?, &self.session)) or self.session == null) {
            return error.WgcSessionFailed;
        }

        const start_cap = com.slot(self.session.?, 6, *const fn (*anyopaque) callconv(.winapi) HRESULT);
        if (!com.succeeded(start_cap(self.session.?))) return error.WgcStartFailed;

        return self;
    }

    pub fn setCursorCapture(self: *Capturer, enabled: bool) void {
        const sess = self.session orelse return;
        const s2 = com.queryInterface(sess, anyopaque, &com.IID_IGraphicsCaptureSession2) orelse return;
        defer com.release(s2);
        const put_cursor = com.slot(s2, 7, *const fn (*anyopaque, u8) callconv(.winapi) HRESULT);
        _ = put_cursor(s2, if (enabled) 1 else 0);
    }

    pub fn repeatNv12(self: *Capturer, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        if (self.pool == null) return null;
        return try self.gpu.repeatFrame(want_cpu_copy, pts_us);
    }

    pub fn tryAcquireNv12(self: *Capturer, want_cpu_copy: bool, pts_us: i64) !?media_if.CaptureFrame {
        const pool = self.pool orelse return error.NotOpen;
        const try_next = com.slot(pool, 7, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);

        var latest: ?*anyopaque = null;
        while (true) {
            var next_f: ?*anyopaque = null;
            if (!com.succeeded(try_next(pool, &next_f)) or next_f == null) break;
            com.release(latest);
            latest = next_f;
        }
        const frame_obj = latest orelse return null;
        defer closeAndRelease(frame_obj);

        const get_surf = com.slot(frame_obj, 6, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var surf: ?*anyopaque = null;
        if (!com.succeeded(get_surf(frame_obj, &surf)) or surf == null) return null;
        defer com.release(surf);

        const access = com.queryInterface(surf.?, anyopaque, &com.IID_IDirect3DDxgiInterfaceAccess) orelse return null;
        defer com.release(access);

        const get_iface = com.slot(access, 3, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT);
        var tex: ?*anyopaque = null;
        if (!com.succeeded(get_iface(access, &com.IID_ID3D11Texture2D, &tex)) or tex == null) return null;
        defer com.release(tex);

        var desc: dxgi_cap.D3D11_TEXTURE2D_DESC = undefined;
        const get_desc = com.slot(tex.?, 10, *const fn (*anyopaque, *dxgi_cap.D3D11_TEXTURE2D_DESC) callconv(.winapi) void);
        get_desc(tex.?, &desc);
        const w: u16 = @intCast(@max(desc.Width, 2));
        const h: u16 = @intCast(@max(desc.Height, 2));
        self.win_w = w;
        self.win_h = h;

        return try self.gpu.convertBgraToNv12(tex.?, w, h, want_cpu_copy, pts_us);
    }

    pub fn deinit(self: *Capturer) void {
        closeAndRelease(self.session);
        closeAndRelease(self.pool);
        com.release(self.item);
        com.release(self.winrt_dev);
        self.session = null;
        self.pool = null;
        self.item = null;
        self.winrt_dev = null;
        self.gpu.deinit();
        if (self.combase_dll) |cb| {
            c.SDL_UnloadObject(cb);
            self.combase_dll = null;
        }
    }
};

fn closeAndRelease(obj: ?*anyopaque) void {
    const ptr = obj orelse return;
    if (com.queryInterface(ptr, anyopaque, &com.IID_IClosable)) |closable| {
        const close_fn = com.slot(closable, 6, *const fn (*anyopaque) callconv(.winapi) HRESULT);
        _ = close_fn(closable);
        com.release(closable);
    }
    com.release(ptr);
}
